import CoreGraphics
import Foundation
import Observation
import OpenScreensCore
import RFBProtocol
import RFBTransport
import rootshellVNC

/// One connection to a remote computer.
///
/// `RemoteSession` sits between the interface and the engine. It decides when
/// to ask for credentials, turns a computer's settings into an engine
/// configuration, and is the single place input passes through on its way to
/// the remote computer — which is what lets "observe only" be absolute.
@Observable
public final class RemoteSession: Identifiable {

    public enum Phase: Equatable {
        case idle
        case connecting
        case awaitingCredentials(CredentialPrompt)
        /// The SSH server presented a key the user has to vouch for.
        case awaitingHostKey(HostKeyPrompt)
        case connected
        case reconnecting(attempt: Int)
        case failed(String)
        case ended
    }

    public struct CredentialPrompt: Equatable {
        public enum Purpose: Equatable, Sendable {
            /// Signing in to the computer's screen sharing.
            case screenSharing
            /// Signing in to the SSH server the connection is tunnelled through.
            case secureTunnel
        }

        public var purpose: Purpose = .screenSharing
        /// Why the user is being asked, when a previous attempt was rejected.
        public var message: String?
        public var username: String
        public var asksForUsername: Bool
    }

    /// An SSH server's key, put to the user before the connection goes on.
    public struct HostKeyPrompt: Equatable {
        public var host: String
        public var port: Int
        /// The key's algorithm, such as `ssh-ed25519`.
        public var keyType: String
        public var fingerprint: String
        /// The fingerprint on record, when the server presented a different
        /// key from the one trusted before. `nil` for a server not seen yet.
        public var expectedFingerprint: String?

        public var keyHasChanged: Bool { expectedFingerprint != nil }
    }

    public let id = UUID()
    public private(set) var computer: Computer
    /// Whether ``computer`` is in the library. Quick connections are not until
    /// the user chooses to keep them.
    public private(set) var isSaved: Bool
    /// Whether settings changed during the session are written back to the
    /// library. False for sessions opened with one-off overrides.
    @ObservationIgnored private let persistsSettings: Bool

    /// The engine session. Canvases read its layers and frames directly.
    public let engine: VNCSession
    public let clipboard: VNCClipboardSynchronizer

    /// Zoom and pan state, shared between the canvas and the toolbar.
    public var viewport = Viewport()

    #if os(iOS)
    /// Connects this session's SwiftUI chrome with its UIKit canvas.
    public let canvasBridge = CanvasBridge()
    #endif

    /// Modifier keys latched from the toolbar, applied to the next key.
    public var latchedModifiers: KeyModifiers = []
    /// Latched modifiers stay down until tapped again instead of releasing
    /// after one key.
    public var modifiersAreLocked = false

    public private(set) var statistics: SessionStatistics?
    public private(set) var connectedAt: Date?

    /// Incremented to ask the canvas to take keyboard focus back, for example
    /// after a sheet that was typing into a local field has closed.
    public private(set) var focusRequests = 0

    public func requestKeyboardFocus() {
        focusRequests += 1
    }

    /// The mode the user asked for, kept so a session that fell back to
    /// Standard can say so.
    public private(set) var requestedQuality: QualityMode

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let appSettings: AppSettings
    @ObservationIgnored private let sshKeys: SSHKeyStore
    @ObservationIgnored private let knownHosts: KnownHostsStore

    private var credentialPrompt: CredentialPrompt?
    private var hostKeyPrompt: HostKeyPrompt?
    private var failureMessage: String?
    /// Set while a magic packet is on its way and the computer is given time
    /// to wake.
    public private(set) var isWaking = false
    private var hasEnded = false
    private var isStarting = false

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var connectAttempt = 0
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCredentials: (username: String?, password: String, remember: Bool)?
    /// What the user typed when asked to sign in to the SSH server.
    @ObservationIgnored private var enteredTunnelCredentials: (username: String, password: String, remember: Bool)?
    @ObservationIgnored private var hostKeyAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var lastViewSize: CGSize = .zero
    @ObservationIgnored private var lastDisplayScale: CGFloat = 2
    @ObservationIgnored private var didRunConnectActions = false
    @ObservationIgnored private var lastStatisticsSample: (framesDecoded: UInt64, updates: UInt64, date: Date)?
    @ObservationIgnored private lazy var pointerHandler = TouchInputHandler(
        sendPointerEvent: { [weak self] mask, x, y in
            self?.engine.sendPointerEvent(buttonMask: mask, x: x, y: y)
        },
        sendScrollEvent: { [weak self] event in
            self?.engine.sendScrollEvent(event)
        },
        sendGestureEvent: { [weak self] event in
            self?.engine.sendGestureEvent(event)
        })

    public init(
        computer: Computer,
        isSaved: Bool,
        persistsSettings: Bool = true,
        library: LibraryStore,
        credentials: CredentialStore,
        settings: AppSettings,
        sshKeys: SSHKeyStore = SSHKeyStore(storage: InMemorySecretStorage()),
        knownHosts: KnownHostsStore = KnownHostsStore(fileURL: nil)
    ) {
        self.computer = computer
        self.isSaved = isSaved
        self.persistsSettings = persistsSettings
        self.library = library
        self.credentials = credentials
        self.appSettings = settings
        self.sshKeys = sshKeys
        self.knownHosts = knownHosts
        self.requestedQuality = computer.settings.quality
        let engine = VNCSession(configuration: Self.configuration(for: computer))
        self.engine = engine
        self.clipboard = VNCClipboardSynchronizer(session: engine)
        self.viewport.scaling = computer.settings.scaling
        observeEngine()
    }

    isolated deinit {
        connectTask?.cancel()
        observationTask?.cancel()
        statisticsTask?.cancel()
    }

    // MARK: - State

    public var settings: ConnectionSettings { computer.settings }

    public var phase: Phase {
        if let hostKeyPrompt { return .awaitingHostKey(hostKeyPrompt) }
        if let credentialPrompt { return .awaitingCredentials(credentialPrompt) }
        if hasEnded { return .ended }
        switch engine.connectionState {
        case .idle:
            if let failureMessage { return .failed(failureMessage) }
            return isStarting ? .connecting : .idle
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .reconnecting(let attempt, _):
            return .reconnecting(attempt: attempt)
        case .disconnecting, .disconnected:
            if let failureMessage { return .failed(failureMessage) }
            return isStarting ? .connecting : .ended
        case .failed(let message):
            // The engine still shows how the last attempt ended while the
            // next one is getting under way.
            if isStarting { return .connecting }
            return .failed(failureMessage ?? message)
        }
    }

    public var isConnected: Bool { engine.connectionState.isConnected }

    /// What the connection is doing right now, for the connecting overlay.
    public var progressDescription: String? {
        engine.connectionPhaseDescription
    }

    /// The mode the connection is actually running in.
    public var activeQuality: QualityMode {
        if engine.isHighPerformanceMode { return .highPerformance }
        switch engine.configuration.videoQualityMode {
        case .adaptive:
            // Asked for High Performance but the stream is not up (yet).
            return isConnected ? .standard : .highPerformance
        case .standard: return .standard
        case .fullQuality: return .fullQuality
        }
    }

    /// Why the session is not running in the mode that was asked for.
    public var fallbackReason: String? {
        if computer.ssh.isEnabled, requestedQuality == .highPerformance {
            // Its picture travels over UDP, which a tunnel does not carry.
            return "High Performance is not available through an SSH tunnel."
        }
        return engine.highPerformanceFallbackReason
    }

    /// Size of the remote screen being shown, in remote pixels.
    public var remoteSize: CGSize {
        engine.presentedFramebufferSize
    }

    /// Top-left of the shown screen inside the server's whole desktop.
    public var remoteOrigin: CGPoint {
        engine.presentedFramebufferRegion?.origin ?? .zero
    }

    public var modifierConvention: ModifierConvention {
        if engine.serverUsesAppleModifierConvention {
            return .apple
        }
        return ModifierConvention(
            optionIsMeta: false,
            swapsCommandAndControl: settings.swapCommandAndControl && !computer.kind.isApple)
    }

    public var canSendInput: Bool {
        isConnected && !settings.observeOnly
    }

    /// Whether gestures should be acknowledged with haptic taps.
    public var hapticsEnabled: Bool { appSettings.hapticFeedback }

    // MARK: - Connecting

    /// Starts connecting, asking for credentials first when none are saved.
    public func start() {
        guard !hasEnded, engine.connectionState.canConnect, connectTask == nil else { return }
        failureMessage = nil
        let saved = credentials.password(for: computer.id)
        let username = computer.username?.trimmingCharacters(in: .whitespaces) ?? ""

        // A Mac always signs in with an account, so there is no point dialing
        // without one. Other servers may accept a connection with no password.
        if computer.kind.isApple, username.isEmpty || saved == nil {
            credentialPrompt = CredentialPrompt(
                message: nil, username: username, asksForUsername: true)
            return
        }
        connect(username: username.isEmpty ? nil : username, password: saved ?? "", remember: false)
    }

    /// Continues after the user has answered a credential prompt.
    public func submitCredentials(username: String, password: String, remember: Bool) {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard let prompt = credentialPrompt else { return }
        credentialPrompt = nil
        switch prompt.purpose {
        case .screenSharing:
            connect(username: trimmed.isEmpty ? nil : trimmed, password: password, remember: remember)
        case .secureTunnel:
            enteredTunnelCredentials = (trimmed.isEmpty ? prompt.username : trimmed, password, remember)
            if let pending = pendingCredentials {
                connect(username: pending.username, password: pending.password, remember: pending.remember)
            } else {
                start()
            }
        }
    }

    public func cancelCredentials() {
        credentialPrompt = nil
        end()
    }

    private func connect(username: String?, password: String, remember: Bool) {
        connectTask?.cancel()
        failureMessage = nil
        didRunConnectActions = false
        pendingCredentials = (username, password, remember)

        var configuration = Self.configuration(for: computer)
        let tunnelFailure = TunnelFailure()
        if computer.ssh.isEnabled {
            switch tunnelIdentity(screenSharingUsername: username, screenSharingPassword: password) {
            case .ready(let user, let credential):
                configuration.transportProvider = tunnelProvider(
                    username: user, credential: credential, failure: tunnelFailure)
            case .needsSignIn(let user):
                credentialPrompt = CredentialPrompt(
                    purpose: .secureTunnel, message: nil,
                    username: user, asksForUsername: computer.ssh.username.isEmpty)
                return
            case .missingKey:
                failureMessage = "The SSH key chosen for this computer is not on this device. Choose another key, or a password, in the computer's settings."
                return
            }
        }

        isStarting = true
        engine.configuration = configuration
        if lastViewSize.width > 0 {
            engine.updateRemoteDisplaySize(viewSize: lastViewSize, displayScale: lastDisplayScale)
        }
        let request = VNCCredentials(
            host: computer.host,
            port: UInt16(clamping: computer.port),
            password: password,
            username: username)

        connectAttempt += 1
        let attempt = connectAttempt
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A prompt answered at once starts the next attempt before
                // this one has finished unwinding; leave its state alone.
                if self.connectAttempt == attempt {
                    self.isStarting = false
                    self.connectTask = nil
                }
            }
            do {
                if self.engine.connectionState == .disconnecting {
                    try await Task.sleep(for: .milliseconds(150))
                }
                try await self.engine.connect(credentials: request)
            } catch is CancellationError {
                return
            } catch VNCError.authenticationFailed(let reason) {
                self.pendingCredentials = nil
                self.credentialPrompt = CredentialPrompt(
                    message: Self.authenticationMessage(reason),
                    username: username ?? "",
                    asksForUsername: self.computer.kind.isApple || username != nil)
            } catch {
                if let tunnelError = tunnelFailure.take() {
                    self.tunnelFailed(tunnelError)
                } else {
                    self.pendingCredentials = nil
                    self.failureMessage = Self.describe(error)
                }
            }
        }
    }

    // MARK: - Secure tunnel

    private enum TunnelIdentity {
        case ready(username: String, credential: SSHCredential)
        case needsSignIn(username: String)
        case missingKey
    }

    /// Who to be on the SSH server.
    ///
    /// A tunnel to the computer itself is, on a Mac, a sign-in to the same
    /// account as screen sharing, so unless the user set SSH up differently
    /// the same name and password are tried before asking again.
    private func tunnelIdentity(
        screenSharingUsername: String?, screenSharingPassword: String
    ) -> TunnelIdentity {
        let ssh = computer.ssh
        let configured = ssh.username.trimmingCharacters(in: .whitespaces)
        let username = enteredTunnelCredentials?.username
            ?? (configured.isEmpty ? screenSharingUsername ?? "" : configured)

        switch ssh.authentication {
        case .key:
            guard let keyID = ssh.keyID, let key = sshKeys.privateKey(for: keyID) else {
                return .missingKey
            }
            return username.isEmpty ? .needsSignIn(username: "") : .ready(username: username, credential: .key(key))
        case .password:
            let tunnelsToItself = ssh.host.trimmingCharacters(in: .whitespaces).isEmpty
            let password = enteredTunnelCredentials?.password
                ?? credentials.password(for: computer.id, kind: .ssh)
                ?? (tunnelsToItself && !screenSharingPassword.isEmpty ? screenSharingPassword : nil)
            guard let password, !username.isEmpty else {
                return .needsSignIn(username: username)
            }
            return .ready(username: username, credential: .password(password))
        }
    }

    private func tunnelProvider(
        username: String, credential: SSHCredential, failure: TunnelFailure
    ) -> VNCTransportProvider {
        let factory = SSHTunnelFactory(
            sshHost: computer.ssh.host.trimmingCharacters(in: .whitespaces),
            sshPort: computer.ssh.port,
            username: username,
            credential: credential,
            knownHosts: knownHosts,
            hostKeyPolicy: { [weak self] challenge in
                await self?.decide(challenge) ?? false
            })
        return { host, port in
            do {
                return try await factory.makeConnection(toHost: host, port: port)
            } catch {
                // The engine reports any transport failure the same way;
                // keep the SSH error so the session can respond to it.
                failure.record(error)
                throw error
            }
        }
    }

    /// Asks the user about a host key that is not simply the one on record.
    private func decide(_ challenge: SSHHostKeyChallenge) async -> Bool {
        let expected: String?
        switch challenge.verdict {
        case .trusted:
            return true
        case .unknown:
            expected = nil
        case .mismatch(let onRecord, _):
            expected = onRecord
        }
        guard !hasEnded else { return false }
        let prompt = HostKeyPrompt(
            host: challenge.host, port: challenge.port,
            keyType: challenge.keyType, fingerprint: challenge.fingerprint,
            expectedFingerprint: expected)
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                hostKeyAnswer?.resume(returning: false)
                hostKeyAnswer = continuation
                hostKeyPrompt = prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerHostKey(trust: false)
            }
        }
        guard accepted else { return false }
        if expected != nil {
            // The new key replaces the old one rather than joining it.
            try? challenge.knownHosts.remove(host: challenge.host, port: challenge.port)
        }
        try? challenge.trust()
        return true
    }

    /// Continues, or stops, after the user has looked at a host key.
    public func answerHostKey(trust: Bool) {
        hostKeyPrompt = nil
        hostKeyAnswer?.resume(returning: trust)
        hostKeyAnswer = nil
    }

    private func tunnelFailed(_ error: any Error) {
        guard let error = error as? SSHError else {
            pendingCredentials = nil
            failureMessage = error.localizedDescription
            return
        }
        switch error {
        case .authenticationFailed where computer.ssh.authentication == .password:
            let previous = enteredTunnelCredentials?.username
                ?? computer.ssh.username.trimmingCharacters(in: .whitespaces)
            enteredTunnelCredentials = nil
            credentialPrompt = CredentialPrompt(
                purpose: .secureTunnel,
                message: "The SSH server did not accept that user name and password.",
                username: previous.isEmpty ? pendingCredentials?.username ?? "" : previous,
                asksForUsername: true)
        case .hostKeyRejected:
            pendingCredentials = nil
            failureMessage = "The connection was stopped because the SSH server's key was not trusted."
        default:
            pendingCredentials = nil
            failureMessage = error.localizedDescription
        }
    }

    // MARK: - Waking

    /// The address to wake the computer at, when one is saved and valid.
    private var wakeAddress: MACAddress? {
        computer.macAddress.flatMap { MACAddress($0) }
    }

    public var canWake: Bool { wakeAddress != nil }

    /// Sends the computer a Wake-on-LAN packet, gives it a moment to come
    /// up, and tries the connection again.
    public func wakeAndRetry() {
        guard let address = wakeAddress, !isWaking, !hasEnded else { return }
        isWaking = true
        Task { [weak self] in
            do {
                try await WakeOnLAN.wake(address)
                // A sleeping Mac answers within a few seconds of the packet.
                try await Task.sleep(for: .seconds(6))
            } catch {
                self?.failureMessage = "The wake signal could not be sent: \(error.localizedDescription)"
                self?.isWaking = false
                return
            }
            guard let self else { return }
            self.isWaking = false
            self.retry()
        }
    }

    /// Tries again after a failure, reusing the last credentials.
    public func retry() {
        guard !hasEnded else { return }
        failureMessage = nil
        if engine.connectionState.canConnect, connectTask == nil {
            if case .failed = engine.connectionState, pendingCredentials == nil {
                engine.retryConnection()
            } else {
                start()
            }
        }
    }

    /// Closes the connection. The session cannot be reused afterwards.
    public func end() {
        guard !hasEnded else { return }
        var lock: (press: [KeyTransition], release: [KeyTransition])?
        if isConnected {
            savePreviewIfWanted()
            // Nothing may stay held on the other side.
            releaseHardwareKeys()
            if settings.lockOnDisconnect, canSendInput, computer.kind.isApple {
                lock = combination(keysym: Keysym.character("q"), modifiers: [.control, .command])
            }
        }
        hasEnded = true
        answerHostKey(trust: false)
        connectTask?.cancel()
        statisticsTask?.cancel()
        statisticsTask = nil
        clipboard.invalidate()

        guard let lock else {
            engine.disconnect()
            return
        }
        // Control-Command-Q locks a Mac. The keys are queued behind whatever
        // else is on its way out, so the connection is kept just long enough
        // for the Mac to see the shortcut pressed and let go.
        emit(lock.press)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            self.emit(lock.release)
            try? await Task.sleep(for: .milliseconds(350))
            self.engine.disconnect()
        }
    }

    private func observeEngine() {
        observationTask = Task { [weak self] in
            guard let engine = self?.engine else { return }
            for await state in Observations({ engine.connectionState }) {
                guard let self else { return }
                self.engineStateChanged(state)
            }
        }
    }

    private func engineStateChanged(_ state: VNCConnectionState) {
        switch state {
        case .connected:
            guard !didRunConnectActions else { return }
            didRunConnectActions = true
            didConnect()
        case .failed, .disconnected:
            lastStatisticsSample = nil
            statistics = nil
        default:
            break
        }
    }

    private func didConnect() {
        connectedAt = .now
        if let pending = pendingCredentials {
            pendingCredentials = nil
            if pending.username != computer.username {
                computer.username = pending.username
                if isSaved { library.update(computer.id) { $0.username = pending.username } }
            }
            if pending.remember {
                try? credentials.setPassword(pending.password, for: computer.id)
            }
        }
        if let entered = enteredTunnelCredentials, entered.remember, isSaved {
            try? credentials.setPassword(entered.password, for: computer.id, kind: .ssh)
            if computer.ssh.username != entered.username, entered.username != computer.username {
                computer.ssh.username = entered.username
                library.update(computer.id) { $0.ssh.username = entered.username }
            }
        }
        if isSaved {
            library.markConnected(computer.id)
        }
        clipboard.sharedClipboardEnabled = settings.sharedClipboard && !settings.observeOnly
        if settings.curtainOnConnect {
            Task { [weak self] in
                // Curtain support is announced a moment after the handshake.
                for _ in 0..<20 {
                    guard let self, self.isConnected else { return }
                    if self.engine.supportsCurtainMode {
                        self.engine.setCurtainMode(true, message: self.settings.curtainMessage)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    // MARK: - Settings that change a live connection

    /// Applies edited settings. Changes that alter the handshake reconnect
    /// the session; everything else takes effect immediately.
    public func apply(_ newSettings: ConnectionSettings) {
        let old = computer.settings
        guard newSettings != old else { return }
        computer.settings = newSettings
        if isSaved, persistsSettings {
            library.update(computer.id) { $0.settings = newSettings }
        }
        viewport.scaling = newSettings.scaling
        requestedQuality = newSettings.quality
        clipboard.sharedClipboardEnabled = newSettings.sharedClipboard && !newSettings.observeOnly
        if newSettings.observeOnly, !old.observeOnly, isConnected {
            // Nothing may stay held on the other side once input stops.
            releaseHardwareKeys()
        }
        engine.videoBandRenderer.setBrightnessGain(newSettings.brightnessBoost)
        engine.secondaryVideoBandRenderer.setBrightnessGain(newSettings.brightnessBoost)

        let needsReconnect = newSettings.quality != old.quality
            || newSettings.resolution != old.resolution
            || newSettings.displays != old.displays
            || newSettings.colorDepth != old.colorDepth
            || newSettings.cursor != old.cursor
            || newSettings.remoteAudio != old.remoteAudio
            || newSettings.syncVideoToAudio != old.syncVideoToAudio
            || newSettings.frameRate != old.frameRate
        if needsReconnect, isConnected {
            var configuration = Self.configuration(for: computer)
            // The tunnel, if there is one, carries the new connection too.
            configuration.transportProvider = engine.configuration.transportProvider
            engine.reconnect(with: configuration)
            if lastViewSize.width > 0 {
                engine.updateRemoteDisplaySize(viewSize: lastViewSize, displayScale: lastDisplayScale)
            }
        } else {
            engine.configuration.promptForLoginPasswordAtLoginWindow =
                newSettings.offerPasswordAtLoginWindow
        }
    }

    public func update(_ edit: (inout ConnectionSettings) -> Void) {
        var copy = computer.settings
        edit(&copy)
        apply(copy)
    }

    /// Adds a quick connection to the library.
    public func saveToLibrary() {
        guard !isSaved else { return }
        computer = library.add(computer)
        isSaved = true
        library.markConnected(computer.id)
    }

    /// Tells the remote computer how much room there is, so a desktop that
    /// follows the window can be resized to fit.
    public func viewDidResize(to size: CGSize, displayScale: CGFloat) {
        guard size.width > 1, size.height > 1 else { return }
        lastViewSize = size
        lastDisplayScale = displayScale
        engine.updateRemoteDisplaySize(viewSize: size, displayScale: displayScale)
    }

    // MARK: - Pointer

    private func wirePoint(_ point: CGPoint) -> (x: UInt16, y: UInt16) {
        let origin = remoteOrigin
        return (
            UInt16(clamping: Int((point.x + origin.x).rounded(.down))),
            UInt16(clamping: Int((point.y + origin.y).rounded(.down))))
    }

    /// Sends the pointer position and which buttons are down.
    /// - Parameter point: Position on the shown screen, in remote pixels.
    public func pointer(buttons: PointerButtons, at point: CGPoint) {
        guard canSendInput else { return }
        if !buttons.isEmpty, pointerButtonsDown.isEmpty {
            emit(keyboard.pointerButtonWillPress())
        }
        pointerButtonsDown = buttons
        let wire = wirePoint(point)
        engine.sendPointerEvent(buttonMask: buttons.rawValue, x: wire.x, y: wire.y)
    }

    public func click(_ button: PointerButtons = .left, at point: CGPoint, count: Int = 1) {
        guard canSendInput else { return }
        pointer(buttons: [], at: point)
        for _ in 0..<max(1, count) {
            pointer(buttons: button, at: point)
            pointer(buttons: [], at: point)
        }
    }

    /// Sends one sample of a continuous scroll.
    /// - Parameters:
    ///   - delta: Scroll distance in points; positive values move content
    ///     right and down, as trackpads report it.
    public func scroll(
        by delta: CGSize,
        at point: CGPoint,
        phase: AppleScrollEvent.Phase = .none,
        momentum: AppleScrollEvent.MomentumPhase = .none
    ) {
        guard canSendInput else { return }
        let wire = wirePoint(point)
        let speed = settings.scrollSpeed
        let direction: CGFloat = settings.naturalScrolling ? 1 : -1
        let scaled = scrollRemainder.consume(
            deltaX: delta.width * speed * direction,
            deltaY: delta.height * speed * direction)
        if phase == .ended || phase == .cancelled || momentum == .ended {
            scrollRemainder = FractionAccumulator()
        }
        guard scaled.x != 0 || scaled.y != 0 || phase != .none || momentum != .none else { return }
        pointerHandler.handleScroll(
            x: wire.x,
            y: wire.y,
            pointDeltaX: scaled.x,
            pointDeltaY: scaled.y,
            scrollPhase: phase,
            momentumPhase: momentum)
    }

    /// Sends whole clicks of a mouse wheel.
    public func scrollWheel(steps: Int, at point: CGPoint) {
        guard canSendInput, steps != 0 else { return }
        let wire = wirePoint(point)
        pointerHandler.handleScroll(
            x: wire.x, y: wire.y,
            steps: settings.naturalScrolling ? steps : -steps)
    }

    /// Marks the start or end of a trackpad gesture, which lets a Mac lock
    /// the scroll to whatever is under the pointer.
    public func gesture(_ kind: AppleGestureEvent.Kind, at point: CGPoint) {
        guard canSendInput else { return }
        let wire = wirePoint(point)
        pointerHandler.handleGesture(kind: kind, x: wire.x, y: wire.y)
    }

    @ObservationIgnored private var scrollRemainder = FractionAccumulator()
    @ObservationIgnored private var pointerButtonsDown: PointerButtons = []

    // MARK: - Keyboard

    /// What a physical keyboard is doing, turned into key events for the
    /// remote computer.
    @ObservationIgnored private var keyboard = HardwareKeyboard(
        configuration: HardwareKeyboard.Configuration(remoteIsMac: false, convention: .standard))

    /// Whether the remote computer is a Mac running Apple's server, which
    /// types the character it is asked for whatever modifiers are held.
    private var remoteIsMac: Bool {
        engine.serverUsesAppleModifierConvention
    }

    /// How modifiers are named when a key is named for the remote system — a
    /// toolbar shortcut, the key bar — rather than pressed on a keyboard.
    /// Those say exactly which remote modifier they mean, so ⌘ and ⌃ are
    /// never swapped here.
    private var literalModifierConvention: ModifierConvention {
        remoteIsMac ? .apple : .standard
    }

    private func emit(_ transitions: [KeyTransition]) {
        for transition in transitions {
            if let keyCode = transition.keyCode {
                engine.sendKeyEvent(
                    downFlag: transition.isDown, key: transition.keysym, keyCode: keyCode)
            } else if transition.keysym != 0 {
                engine.sendKeyEvent(downFlag: transition.isDown, key: transition.keysym)
            }
        }
    }

    /// Brings the keyboard up to date with the connection and its settings.
    /// Returns false, having let go of everything, when input is not allowed.
    private func prepareKeyboard() -> Bool {
        guard canSendInput else {
            _ = keyboard.releaseAll()
            return false
        }
        let configuration = HardwareKeyboard.Configuration(
            remoteIsMac: remoteIsMac,
            takesKeyCodes: engine.serverTakesKeyCodes,
            mode: settings.keyboardInput,
            convention: modifierConvention)
        if keyboard.configuration != configuration {
            emit(keyboard.releaseAll())
            keyboard.configuration = configuration
        }
        return true
    }

    /// A modifier key on a physical keyboard went down or up.
    public func hardwareModifier(_ key: ModifierKey, down: Bool) {
        guard prepareKeyboard() else { return }
        emit(keyboard.modifierChanged(key, isDown: down))
    }

    /// A key on a physical keyboard went down, or is repeating.
    public func hardwareKeyDown(_ stroke: KeyStroke) {
        guard prepareKeyboard() else { return }
        emit(keyboard.keyDown(stroke))
    }

    /// The key that `hardwareKeyDown` reported was released.
    public func hardwareKeyUp(key: Int) {
        guard prepareKeyboard() else { return }
        emit(keyboard.keyUp(key: key))
    }

    /// Caps Lock on a physical keyboard turned on or off.
    public func hardwareCapsLock(isOn: Bool) {
        guard prepareKeyboard() else { return }
        emit(keyboard.capsLockChanged(isOn: isOn))
    }

    /// Lets go of the keys held on a physical keyboard, so nothing stays
    /// stuck when the keyboard stops being ours. Modifiers are kept when the
    /// keyboard is still in use and only the keys need releasing.
    public func releaseHardwareKeys(includingModifiers: Bool = true) {
        guard isConnected else {
            _ = keyboard.releaseAll()
            return
        }
        emit(includingModifiers ? keyboard.releaseAll() : keyboard.releaseKeys())
    }

    /// Presses and releases a key, wrapped in the given and latched modifiers.
    public func tap(_ key: RemoteKey, modifiers: KeyModifiers = []) {
        tap(keysym: key.keysym, modifiers: modifiers)
    }

    public func tap(keysym: UInt32, modifiers: KeyModifiers = []) {
        guard canSendInput, keysym != 0 else { return }
        let combination = combination(keysym: keysym, modifiers: modifiers.union(latchedModifiers))
        emit(combination.press)
        emit(combination.release)
        consumeLatchedModifiers()
    }

    /// Sends a shortcut, holding it briefly so the remote system registers
    /// the combination rather than a burst of unrelated keys.
    public func send(_ shortcut: RemoteShortcut) {
        guard canSendInput else { return }
        let keysym = shortcut.key.keysym
        guard keysym != 0 else { return }
        let combination = combination(keysym: keysym, modifiers: shortcut.modifiers)
        emit(combination.press)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(75))
            self?.emit(combination.release)
        }
    }

    private func combination(
        keysym: UInt32, modifiers: KeyModifiers
    ) -> (press: [KeyTransition], release: [KeyTransition]) {
        SyntheticKeys.combination(
            keysym: keysym,
            modifiers: modifiers,
            remoteIsMac: remoteIsMac,
            takesKeyCodes: engine.serverTakesKeyCodes,
            convention: literalModifierConvention)
    }

    /// Types text as a sequence of characters.
    public func type(_ text: String) {
        guard canSendInput else { return }
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        for keysym in Keysym.keysyms(for: text) {
            if latchedModifiers.isEmpty {
                emit([
                    KeyTransition(keysym: keysym, isDown: true),
                    KeyTransition(keysym: keysym, isDown: false),
                ])
            } else {
                tap(keysym: keysym)
            }
        }
    }

    public func toggleLatched(_ modifier: KeyModifiers) {
        if latchedModifiers.contains(modifier) {
            latchedModifiers.remove(modifier)
        } else {
            latchedModifiers.insert(modifier)
        }
        if latchedModifiers.isEmpty {
            modifiersAreLocked = false
        }
    }

    private func consumeLatchedModifiers() {
        guard !modifiersAreLocked, !latchedModifiers.isEmpty else { return }
        latchedModifiers = []
    }

    // MARK: - Remote actions

    public var canTypePassword: Bool { engine.canSendLoginPassword && canSendInput }

    /// Types the saved account password followed by Return.
    public func typePassword() {
        guard canTypePassword else { return }
        engine.sendLoginPassword()
    }

    public var supportsCurtain: Bool { engine.supportsCurtainMode }
    public var isCurtained: Bool { engine.isCurtained }

    public func setCurtain(_ enabled: Bool, message: String? = nil) {
        engine.setCurtainMode(enabled, message: message ?? settings.curtainMessage)
    }

    /// The remote screen as an image.
    public func screenshot() -> CGImage? {
        engine.snapshotImage()
    }

    private func savePreviewIfWanted() {
        guard isSaved, appSettings.savesSessionPreviews, let image = screenshot() else { return }
        PreviewStore.shared.save(image, for: computer.id)
    }

    // MARK: - Statistics

    /// Starts or stops sampling connection statistics. Sampling only runs
    /// while something is showing the numbers.
    public func setStatisticsActive(_ active: Bool) {
        if !active {
            statisticsTask?.cancel()
            statisticsTask = nil
            statistics = nil
            lastStatisticsSample = nil
            return
        }
        guard statisticsTask == nil else { return }
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sampleStatistics() async {
        guard isConnected, let raw = await engine.currentStatistics() else {
            statistics = nil
            return
        }
        let now = Date.now
        var framesPerSecond: Double?
        if let last = lastStatisticsSample {
            let interval = now.timeIntervalSince(last.date)
            if interval > 0.2 {
                let frames = raw.transport.isHighPerformanceMode
                    ? raw.framesDecoded &- last.framesDecoded
                    : raw.transport.framebufferUpdateCount &- last.updates
                framesPerSecond = Double(frames) / interval
            }
        }
        lastStatisticsSample = (raw.framesDecoded, raw.transport.framebufferUpdateCount, now)
        statistics = SessionStatistics(
            quality: activeQuality,
            remoteSize: remoteSize,
            framesPerSecond: framesPerSecond,
            bitrateKbps: raw.transport.recentBitrateKbps,
            packetLossPercent: raw.transport.recentPacketLossPercent,
            queueDelayMilliseconds: raw.transport.queueDelayMilliseconds,
            bandwidthEstimateKbps: raw.transport.bandwidthEstimateKbps,
            uptime: raw.transport.connectionUptime,
            encryption: computer.ssh.isEnabled
                ? "SSH tunnel"
                : Self.describe(engine.negotiatedContentEncryption))
    }

    // MARK: - Engine configuration

    static func configuration(for computer: Computer) -> VNCConfiguration {
        let settings = computer.settings
        let quality: VNCConfiguration.VideoQualityMode = switch settings.quality {
        case .highPerformance: .adaptive
        case .standard: .standard
        case .fullQuality: .fullQuality
        }
        let displayMode: VNCConfiguration.DisplayMode = switch settings.displays {
        case .single: .oneDisplay
        case .allCombined: .allDisplaysCombined
        case .twoVirtual: .twoVirtualDisplays
        }
        return VNCConfiguration(
            preferredPixelFormat: settings.colorDepth == .thousands ? .rgb555 : nil,
            videoQualityMode: quality,
            displaySizingMode: settings.resolution == .matchWindow ? .matchClient : .remoteDisplay,
            displayMode: displayMode,
            enableRemoteAudio: settings.remoteAudio,
            syncVideoToRemoteAudio: settings.syncVideoToAudio,
            promptForLoginPasswordAtLoginWindow: settings.offerPasswordAtLoginWindow,
            cursorRendering: settings.cursor == .local ? .client : .server,
            remoteSystem: .automatic,
            targetFrameRate: settings.frameRate,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: settings.reconnectAutomatically))
    }

    private static func authenticationMessage(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // The engine's own wording for a plain rejection carries a result
        // code and nothing a person can act on.
        if trimmed.isEmpty || trimmed.hasPrefix("Authentication failed") {
            return "The user name or password was not accepted."
        }
        return trimmed
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? VNCError {
            switch error {
            case .connectionFailed(let detail):
                if detail.localizedCaseInsensitiveContains("refused") {
                    return "The computer refused the connection. Check that Screen Sharing or its VNC server is turned on, and that the port is right."
                }
                if detail.localizedCaseInsensitiveContains("timed out") {
                    return "The computer did not answer. Check that it is awake and reachable from this network."
                }
                return detail
            case .unsupportedFeature(let detail):
                return detail
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func describe(_ encryption: VNCContentEncryption?) -> String? {
        switch encryption {
        case .tlsX509: "TLS"
        case .appleComCryption(_, let keyLength, let mediaSRTP):
            "AES" + (keyLength.map { "-\($0)" } ?? "") + (mediaSRTP ? " + SRTP" : "")
        // Signing in and typing are protected even then; the picture is not.
        case .some(.none): "Screen not encrypted"
        case nil: nil
        }
    }
}

/// Mouse buttons, in RFB's bit layout.
public struct PointerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = PointerButtons(rawValue: 0x01)
    public static let middle = PointerButtons(rawValue: 0x02)
    public static let right = PointerButtons(rawValue: 0x04)
}

/// A snapshot of how a connection is performing.
public struct SessionStatistics: Equatable, Sendable {
    public var quality: QualityMode
    public var remoteSize: CGSize
    public var framesPerSecond: Double?
    public var bitrateKbps: Double?
    public var packetLossPercent: Double?
    public var queueDelayMilliseconds: Double?
    public var bandwidthEstimateKbps: Double?
    public var uptime: TimeInterval?
    public var encryption: String?
}

/// Carries fractional scroll distance from one sample to the next so slow
/// scrolling is not rounded away.
struct FractionAccumulator {
    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0

    mutating func consume(deltaX: CGFloat, deltaY: CGFloat) -> (x: Int32, y: Int32) {
        guard deltaX.isFinite, deltaY.isFinite else { return (0, 0) }
        remainderX += deltaX
        remainderY += deltaY
        let x = remainderX.rounded(.towardZero)
        let y = remainderY.rounded(.towardZero)
        remainderX -= x
        remainderY -= y
        return (Int32(clamping: Int(x)), Int32(clamping: Int(y)))
    }
}


/// Carries the error behind a failed tunnel out of the engine's transport
/// provider, which runs off the main actor.
private nonisolated final class TunnelFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?

    func record(_ error: any Error) {
        lock.withLock { self.error = error }
    }

    func take() -> (any Error)? {
        lock.withLock {
            defer { error = nil }
            return error
        }
    }
}

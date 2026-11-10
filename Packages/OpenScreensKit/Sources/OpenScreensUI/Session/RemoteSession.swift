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
        case connected
        case reconnecting(attempt: Int)
        case failed(String)
        case ended
    }

    public struct CredentialPrompt: Equatable {
        /// Why the user is being asked, when a previous attempt was rejected.
        public var message: String?
        public var username: String
        public var asksForUsername: Bool
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

    /// Modifier keys latched from the toolbar, applied to the next key.
    public var latchedModifiers: KeyModifiers = []
    /// Latched modifiers stay down until tapped again instead of releasing
    /// after one key.
    public var modifiersAreLocked = false

    public private(set) var statistics: SessionStatistics?
    public private(set) var connectedAt: Date?

    /// The mode the user asked for, kept so a session that fell back to
    /// Standard can say so.
    public private(set) var requestedQuality: QualityMode

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let appSettings: AppSettings

    private var credentialPrompt: CredentialPrompt?
    private var failureMessage: String?
    private var hasEnded = false
    private var isStarting = false

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCredentials: (username: String?, password: String, remember: Bool)?
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
        settings: AppSettings
    ) {
        self.computer = computer
        self.isSaved = isSaved
        self.persistsSettings = persistsSettings
        self.library = library
        self.credentials = credentials
        self.appSettings = settings
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
        engine.highPerformanceFallbackReason
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
        credentialPrompt = nil
        connect(username: trimmed.isEmpty ? nil : trimmed, password: password, remember: remember)
    }

    public func cancelCredentials() {
        credentialPrompt = nil
        end()
    }

    private func connect(username: String?, password: String, remember: Bool) {
        connectTask?.cancel()
        isStarting = true
        failureMessage = nil
        didRunConnectActions = false
        pendingCredentials = (username, password, remember)
        engine.configuration = Self.configuration(for: computer)
        if lastViewSize.width > 0 {
            engine.updateRemoteDisplaySize(viewSize: lastViewSize, displayScale: lastDisplayScale)
        }
        let request = VNCCredentials(
            host: computer.host,
            port: UInt16(clamping: computer.port),
            password: password,
            username: username)

        connectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isStarting = false
                self.connectTask = nil
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
                self.pendingCredentials = nil
                self.failureMessage = Self.describe(error)
            }
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
        if isConnected {
            savePreviewIfWanted()
            if settings.lockOnDisconnect, canSendInput, computer.kind.isApple {
                send(RemoteShortcut(name: "Lock Screen", modifiers: [.control, .command], key: .character("q")))
            }
        }
        hasEnded = true
        connectTask?.cancel()
        statisticsTask?.cancel()
        statisticsTask = nil
        clipboard.invalidate()
        engine.disconnect()
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
            engine.reconnect(with: Self.configuration(for: computer))
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

    // MARK: - Keyboard

    /// Sends a raw key transition.
    public func key(_ keysym: UInt32, down: Bool) {
        guard canSendInput, keysym != 0 else { return }
        engine.sendKeyEvent(downFlag: down, key: keysym)
    }

    /// Sends a key transition coming from a physical keyboard, translating
    /// modifiers for the remote system.
    public func hardwareKey(_ keysym: UInt32, down: Bool) {
        let translated = Keysym.isModifier(keysym)
            ? modifierConvention.translate(modifierKeysym: keysym)
            : keysym
        key(translated, down: down)
    }

    /// Presses and releases a key, wrapped in the given and latched modifiers.
    public func tap(_ key: RemoteKey, modifiers: KeyModifiers = []) {
        tap(keysym: key.keysym, modifiers: modifiers)
    }

    public func tap(keysym: UInt32, modifiers: KeyModifiers = []) {
        guard canSendInput, keysym != 0 else { return }
        let all = modifiers.union(latchedModifiers)
        let modifierKeys = modifierConvention.keysyms(for: all)
        for modifier in modifierKeys {
            engine.sendKeyEvent(downFlag: true, key: modifier)
        }
        engine.sendKeyEvent(downFlag: true, key: keysym)
        engine.sendKeyEvent(downFlag: false, key: keysym)
        for modifier in modifierKeys.reversed() {
            engine.sendKeyEvent(downFlag: false, key: modifier)
        }
        consumeLatchedModifiers()
    }

    /// Sends a shortcut, holding it briefly so the remote system registers
    /// the combination rather than a burst of unrelated keys.
    public func send(_ shortcut: RemoteShortcut) {
        guard canSendInput else { return }
        let keysym = shortcut.key.keysym
        guard keysym != 0 else { return }
        let modifierKeys = modifierConvention.keysyms(for: shortcut.modifiers)
        for modifier in modifierKeys {
            engine.sendKeyEvent(downFlag: true, key: modifier)
        }
        engine.sendKeyEvent(downFlag: true, key: keysym)
        let engine = engine
        Task {
            try? await Task.sleep(for: .milliseconds(75))
            engine.sendKeyEvent(downFlag: false, key: keysym)
            for modifier in modifierKeys.reversed() {
                engine.sendKeyEvent(downFlag: false, key: modifier)
            }
        }
    }

    /// Types text as a sequence of characters.
    public func type(_ text: String) {
        guard canSendInput else { return }
        for character in text {
            let keysym = Keysym.character(character)
            guard keysym != 0 else { continue }
            if latchedModifiers.isEmpty {
                engine.sendKeyEvent(downFlag: true, key: keysym)
                engine.sendKeyEvent(downFlag: false, key: keysym)
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
            encryption: Self.describe(engine.negotiatedContentEncryption))
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
        if trimmed.isEmpty {
            return "The user name or password was not accepted."
        }
        return trimmed
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? VNCError {
            switch error {
            case .connectionFailed(let detail): return detail
            case .unsupportedFeature(let detail): return detail
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func describe(_ encryption: VNCContentEncryption?) -> String? {
        switch encryption {
        case .tlsX509: "TLS"
        case .appleComCryption(_, let keyLength, let mediaSRTP):
            "AES" + (keyLength.map { "-\($0)" } ?? "") + (mediaSRTP ? " + SRTP" : "")
        case .some(.none): "None"
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

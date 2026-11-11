import Foundation
import Observation
import OpenScreensCore

/// The app's shared state: the library, preferences, credentials and every
/// open session. One instance is created at launch and placed in the
/// environment.
@Observable
public final class AppModel {
    public let library: LibraryStore
    public let settings: AppSettings
    public let credentials: CredentialStore
    public let sessions: SessionManager

    /// Computers advertising screen sharing on the local network.
    public let nearby: NearbyBrowser
    /// Devices in the user's tailnet.
    public let tailscale: TailscaleDirectory
    /// Keeps the library the same on the user's devices through iCloud.
    public let sync: CloudSyncEngine
    public let sshKeys: SSHKeyStore
    public let knownHosts: KnownHostsStore
    /// The optional lock in front of everything, shared by every window.
    public let lock: AppLock

    /// Fixed lists shown instead of what is really out there, so previews
    /// and screenshots do not show anyone's actual network.
    public var sampleDiscovery: SampleDiscovery?

    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    /// A link waiting to be opened. Set from wherever the request arrives —
    /// a URL, a Shortcut, a widget — and consumed by the library, which is
    /// the one place that knows how to present a session.
    public var pendingLink: AppLink?

    /// The model used by the running app. App Intents and the app's scenes
    /// have to agree on one instance.
    public static let shared = AppModel()

    public init(
        library: LibraryStore? = nil,
        settings: AppSettings? = nil,
        credentials: CredentialStore? = nil
    ) {
        let library = library ?? LibraryStore()
        let settings = settings ?? AppSettings()
        // An isolated run keeps its secrets in memory so it never reads from
        // or writes to the user's keychain, and stays out of iCloud.
        let isIsolated = StorageLocation.isIsolated || credentials != nil
        let secrets: any SecretStorage = isIsolated ? InMemorySecretStorage() : KeychainStorage()
        let credentials = credentials ?? CredentialStore(storage: secrets)
        let knownHosts = isIsolated && !StorageLocation.isIsolated
            ? KnownHostsStore(fileURL: nil)
            : KnownHostsStore()
        let sshKeys = SSHKeyStore(storage: secrets)
        self.library = library
        self.settings = settings
        self.credentials = credentials
        self.sshKeys = sshKeys
        self.knownHosts = knownHosts
        self.lock = AppLock(startsUnlocked: !settings.requiresAuthentication)
        self.sessions = SessionManager(
            library: library, credentials: credentials, settings: settings,
            sshKeys: sshKeys, knownHosts: knownHosts)
        self.nearby = NearbyBrowser()
        self.tailscale = TailscaleDirectory(credentials: credentials) { [settings] in
            settings.tailscaleEnabled ? .automatic(tailnet: settings.tailnet) : .off
        }
        self.sync = CloudSyncEngine(
            library: library,
            store: isIsolated ? nil : UbiquitousKeyValueCloudStore())
        library.onChange = { [sync] document in
            sync.libraryDidChange(document)
        }
        sync.isEnabled = settings.syncsWithICloud
        library.writeAutomaticBackupIfNeeded()
        followSettings()
    }

    isolated deinit {
        settingsTask?.cancel()
    }

    // MARK: - Discovery and sync

    /// Starts what the app does while it is in use: looking for computers
    /// and catching up with iCloud. Safe to call again.
    public func becomeActive() {
        applyDiscoverySettings()
        sync.syncNow()
    }

    /// Stops looking and writes out anything unsaved, for when the app
    /// leaves the screen.
    public func resignActive() {
        nearby.stop()
        tailscale.stop()
        library.saveNow()
    }

    private func applyDiscoverySettings() {
        // Sample data stands in for the network.
        guard sampleDiscovery == nil else { return }
        if settings.showsNearbyComputers {
            nearby.start()
        } else {
            nearby.stop()
        }
        if settings.tailscaleEnabled {
            tailscale.startAutoRefresh()
        } else {
            tailscale.stop()
        }
    }

    /// Applies preference changes that switch a service on or off.
    private func followSettings() {
        settingsTask = Task { [weak self, settings] in
            let watched = Observations {
                WatchedSettings(
                    nearby: settings.showsNearbyComputers,
                    tailscale: settings.tailscaleEnabled,
                    tailnet: settings.tailnet,
                    sync: settings.syncsWithICloud)
            }
            var isFirst = true
            for await value in watched {
                guard let self else { return }
                // The first value is the state the model was built with.
                if isFirst {
                    isFirst = false
                    continue
                }
                self.sync.isEnabled = value.sync
                self.applyDiscoverySettings()
                if value.tailscale {
                    await self.tailscale.refresh()
                }
            }
        }
    }

    private struct WatchedSettings: Equatable {
        var nearby: Bool
        var tailscale: Bool
        var tailnet: String
        var sync: Bool
    }

    /// A model with sample data that touches neither disk nor keychain.
    public static func preview() -> AppModel {
        let suite = "OpenScreensPreview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let library = LibraryStore(fileURL: nil, backupsDirectory: nil)
        let studio = library.add(Computer(
            name: "Studio", host: "studio.local", username: "me", kind: .mac, isFavorite: true))
        library.add(Computer(name: "Mini Server", host: "100.101.102.103", username: "admin", kind: .mac))
        library.add(Computer(name: "Workstation", host: "192.168.1.40", kind: .windows))
        library.add(Computer(name: "Pi", host: "raspberrypi.local", kind: .raspberryPi))
        library.markConnected(studio.id)
        return AppModel(
            library: library,
            settings: AppSettings(defaults: defaults),
            credentials: CredentialStore(storage: InMemorySecretStorage()))
    }

    // MARK: - Library actions that involve more than the store

    /// Removes computers along with their saved passwords and previews.
    public func delete(_ ids: Set<Computer.ID>) {
        for id in ids {
            credentials.deleteAll(for: id)
            PreviewStore.shared.remove(for: id)
            sessions.closeSessions(for: id)
        }
        library.delete(ids)
    }

    /// Erases the library, trusted hosts, previews and preferences.
    ///
    /// - Parameter everywhere: Also remove the computers from the user's
    ///   other devices, along with every saved password and SSH key. When
    ///   false, iCloud sync is turned off here first and stays off, so what
    ///   is in iCloud is neither changed nor brought back — and the keychain
    ///   is left alone, because iCloud Keychain would carry a removal to the
    ///   other devices too.
    public func eraseAllContent(everywhere: Bool) {
        sessions.closeAll()
        if everywhere {
            library.eraseAll()
            credentials.eraseEverything()
        } else {
            sync.isEnabled = false
            library.eraseThisDeviceOnly()
        }
        // This also starts the list afresh when it could not be read.
        try? knownHosts.removeAll()
        PreviewStore.shared.removeAll()
        settings.reset()
        if !everywhere {
            settings.syncsWithICloud = false
        }
    }
}

/// Stand-ins for what discovery finds.
public struct SampleDiscovery: Sendable {
    public var nearby: [NearbyComputer]
    public var tailscale: [TailscaleDevice]

    public init(nearby: [NearbyComputer] = [], tailscale: [TailscaleDevice] = []) {
        self.nearby = nearby
        self.tailscale = tailscale
    }
}

/// Every open session.
@Observable
public final class SessionManager {
    public private(set) var sessions: [RemoteSession] = []

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sshKeys: SSHKeyStore
    @ObservationIgnored private let knownHosts: KnownHostsStore

    init(
        library: LibraryStore,
        credentials: CredentialStore,
        settings: AppSettings,
        sshKeys: SSHKeyStore,
        knownHosts: KnownHostsStore
    ) {
        self.library = library
        self.credentials = credentials
        self.settings = settings
        self.sshKeys = sshKeys
        self.knownHosts = knownHosts
    }

    public func session(_ id: RemoteSession.ID?) -> RemoteSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The live session for a computer, if one is open.
    public func session(for computerID: Computer.ID) -> RemoteSession? {
        sessions.first { $0.computer.id == computerID && $0.phase != .ended }
    }

    /// Opens a session to a saved computer, reusing one that is already open.
    ///
    /// - Parameter configure: Adjusts the settings for this session only, for
    ///   "connect using…" actions. The computer's saved settings are untouched.
    @discardableResult
    public func open(
        _ computer: Computer,
        configure: ((inout ConnectionSettings) -> Void)? = nil
    ) -> RemoteSession {
        if let existing = session(for: computer.id) {
            if let configure {
                existing.update(configure)
            }
            return existing
        }
        let current = library.computer(computer.id)
        var resolved = current ?? computer
        configure?(&resolved.settings)
        let session = RemoteSession(
            computer: resolved,
            isSaved: current != nil,
            persistsSettings: configure == nil,
            library: library,
            credentials: credentials,
            settings: settings,
            sshKeys: sshKeys,
            knownHosts: knownHosts)
        sessions.append(session)
        return session
    }

    /// Opens a session to an address that is not in the library.
    @discardableResult
    public func open(_ target: ConnectionTarget) -> RemoteSession {
        if let saved = library.existingComputer(host: target.host, port: target.port) {
            return open(saved)
        }
        var computer = Computer(
            name: target.name ?? "",
            host: target.host,
            port: target.port,
            username: target.username,
            kind: target.kind,
            settings: settings.defaultConnection)
        if !target.kind.isApple {
            computer.settings = ConnectionSettings.defaults(for: target.kind)
        }
        computer.origin = target.origin
        computer.ssh.isEnabled = target.usesSSH
        if target.observeOnly {
            computer.settings.observeOnly = true
        }
        let session = RemoteSession(
            computer: computer,
            isSaved: false,
            library: library,
            credentials: credentials,
            settings: settings,
            sshKeys: sshKeys,
            knownHosts: knownHosts)
        if let password = target.password, !password.isEmpty {
            try? credentials.setPassword(password, for: computer.id)
        }
        sessions.append(session)
        return session
    }

    public func close(_ session: RemoteSession) {
        session.end()
        if !session.isSaved {
            credentials.deleteAll(for: session.computer.id)
        }
        sessions.removeAll { $0.id == session.id }
    }

    public func closeSessions(for computerID: Computer.ID) {
        for session in sessions where session.computer.id == computerID {
            close(session)
        }
    }

    public func closeAll() {
        for session in sessions {
            close(session)
        }
    }
}

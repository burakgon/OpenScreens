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

    public init(
        library: LibraryStore? = nil,
        settings: AppSettings? = nil,
        credentials: CredentialStore = CredentialStore()
    ) {
        let library = library ?? LibraryStore()
        let settings = settings ?? AppSettings()
        self.library = library
        self.settings = settings
        self.credentials = credentials
        self.sessions = SessionManager(
            library: library, credentials: credentials, settings: settings)
        library.writeAutomaticBackupIfNeeded()
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

    /// Erases the library, saved passwords, previews and preferences.
    public func eraseAllContent() {
        sessions.closeAll()
        library.eraseAll()
        credentials.eraseEverything()
        PreviewStore.shared.removeAll()
        settings.reset()
    }
}

/// Every open session.
@Observable
public final class SessionManager {
    public private(set) var sessions: [RemoteSession] = []

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let settings: AppSettings

    init(library: LibraryStore, credentials: CredentialStore, settings: AppSettings) {
        self.library = library
        self.credentials = credentials
        self.settings = settings
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
            settings: settings)
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
        let session = RemoteSession(
            computer: computer,
            isSaved: false,
            library: library,
            credentials: credentials,
            settings: settings)
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

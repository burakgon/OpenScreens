import Foundation
import Security

/// A place to keep small secrets, addressed by account name.
public protocol SecretStorage: Sendable {
    func data(account: String) -> Data?
    /// Stores `data`, or removes the entry when `data` is `nil`.
    func set(_ data: Data?, account: String) throws
    /// Every account currently stored.
    func accounts() -> [String]
}

public struct SecretStorageError: LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
    }
}

/// Secrets in the system keychain.
///
/// Items are stored in the data-protection keychain and, when
/// ``synchronizes`` is set, marked for iCloud Keychain so saved passwords
/// follow the user to their other devices. A macOS build that is not signed
/// with the entitlements that keychain needs transparently falls back to the
/// login keychain, where items stay on this Mac.
public struct KeychainStorage: SecretStorage {
    public let service: String
    public let synchronizes: Bool

    public init(service: String = "com.burakgon.openscreens", synchronizes: Bool = true) {
        self.service = service
        self.synchronizes = synchronizes
    }

    private enum Backend: CaseIterable {
        case dataProtection
        case login
    }

    private func baseQuery(_ backend: Backend, account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain] = true
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        }
        return query
    }

    private var backends: [Backend] {
        #if os(macOS)
        Backend.allCases
        #else
        [.dataProtection]
        #endif
    }

    public func data(account: String) -> Data? {
        for backend in backends {
            var query = baseQuery(backend, account: account)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return data
            }
        }
        return nil
    }

    public func set(_ data: Data?, account: String) throws {
        // Remove from every backend first so a value never lingers in the one
        // that is not written to.
        for backend in backends {
            SecItemDelete(baseQuery(backend, account: account) as CFDictionary)
        }
        guard let data else { return }

        var lastStatus = errSecSuccess
        for backend in backends {
            var attributes = baseQuery(backend, account: account)
            attributes[kSecValueData] = data
            if backend == .dataProtection {
                attributes[kSecAttrSynchronizable] = synchronizes
                attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            }
            lastStatus = SecItemAdd(attributes as CFDictionary, nil)
            if lastStatus == errSecSuccess { return }
            // Anything other than a missing entitlement is a real failure.
            if lastStatus != errSecMissingEntitlement { break }
        }
        throw SecretStorageError(status: lastStatus)
    }

    public func accounts() -> [String] {
        var found = Set<String>()
        for backend in backends {
            var query = baseQuery(backend, account: nil)
            query[kSecReturnAttributes] = true
            query[kSecMatchLimit] = kSecMatchLimitAll
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[CFString: Any]] else { continue }
            for item in items {
                if let account = item[kSecAttrAccount] as? String {
                    found.insert(account)
                }
            }
        }
        return found.sorted()
    }
}

/// Secrets held in memory. Used by tests and SwiftUI previews.
public final class InMemorySecretStorage: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(account: String) -> Data? {
        lock.withLock { values[account] }
    }

    public func set(_ data: Data?, account: String) throws {
        lock.withLock { values[account] = data }
    }

    public func accounts() -> [String] {
        lock.withLock { values.keys.sorted() }
    }
}

/// Passwords for saved computers.
public struct CredentialStore: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// The screen sharing (VNC or macOS account) password.
        case screenSharing = "vnc"
        /// The SSH account password used for the secure tunnel.
        case ssh
    }

    private let storage: any SecretStorage

    public init(storage: any SecretStorage = KeychainStorage()) {
        self.storage = storage
    }

    private func account(_ id: UUID, _ kind: Kind) -> String {
        "computer.\(id.uuidString).\(kind.rawValue)"
    }

    public func password(for id: UUID, kind: Kind = .screenSharing) -> String? {
        storage.data(account: account(id, kind)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Saves a password. `nil` or an empty string removes it.
    public func setPassword(_ password: String?, for id: UUID, kind: Kind = .screenSharing) throws {
        let data = password.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        try storage.set(data, account: account(id, kind))
    }

    public func hasPassword(for id: UUID, kind: Kind = .screenSharing) -> Bool {
        storage.data(account: account(id, kind)) != nil
    }

    public func deleteAll(for id: UUID) {
        for kind in Kind.allCases {
            try? storage.set(nil, account: account(id, kind))
        }
    }

    // MARK: Named secrets

    /// A secret that does not belong to a computer, such as an API token.
    public func secret(named name: String) -> String? {
        storage.data(account: "secret.\(name)").flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setSecret(_ value: String?, named name: String) throws {
        let data = value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        try storage.set(data, account: "secret.\(name)")
    }

    /// Removes every password and secret OpenScreens has stored.
    public func eraseEverything() {
        for account in storage.accounts() {
            try? storage.set(nil, account: account)
        }
    }
}

import Foundation
import Security
import Synchronization

/// A place to keep small secrets, addressed by account name.
public protocol SecretStorage: Sendable {
    /// The secret stored under `account`, or `nil` when there is none.
    ///
    /// - Throws: When the storage could not be read. That is a different
    ///   answer from `nil`: the secret may well be there.
    func data(account: String) throws -> Data?
    /// Stores `data`, or removes the entry when `data` is `nil`.
    ///
    /// A secret that is already stored stays as it was if this fails.
    func set(_ data: Data?, account: String) throws
    /// Every account currently stored.
    ///
    /// - Throws: When the storage could not be read.
    func accounts() throws -> [String]
}

public struct SecretStorageError: LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
    }
}

/// The keychain calls ``KeychainStorage`` makes. They are made through this
/// so that what it does with their answers can be tested without touching
/// anyone's keychain.
protocol KeychainItems: Sendable {
    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func update(_ query: [CFString: Any], to attributes: [CFString: Any]) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

/// The system's keychain.
struct SystemKeychainItems: KeychainItems {
    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [CFString: Any], to attributes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Secrets in the system keychain.
///
/// Items are stored in the data-protection keychain and, when
/// ``synchronizes`` is set, marked for iCloud Keychain so saved passwords
/// follow the user to their other devices. A macOS build that is not signed
/// with the entitlements that keychain needs transparently falls back to the
/// login keychain, where items stay on this Mac.
///
/// Saving over an item replaces its value where it is. Nothing is removed
/// first, so a save the keychain turns down costs nothing that was stored.
public struct KeychainStorage: SecretStorage {
    /// When the system lets a stored item be read.
    public enum Accessibility: Sendable {
        /// From the first time the device is unlocked after starting up,
        /// locked or not from then on.
        case afterFirstUnlock
        /// Only while the device is unlocked. For secrets that are used
        /// with the user at the device and at no other time.
        case whenUnlocked

        fileprivate var attribute: CFString {
            switch self {
            case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
            case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
            }
        }
    }

    public let service: String
    public let synchronizes: Bool
    /// What newly stored items are given. An item that is already stored
    /// keeps what it was first stored with, also when its value changes.
    public let accessibility: Accessibility
    private let items: any KeychainItems

    public init(
        service: String = "com.burakgon.openscreens",
        synchronizes: Bool = true,
        accessibility: Accessibility = .afterFirstUnlock
    ) {
        self.init(
            service: service, synchronizes: synchronizes, accessibility: accessibility,
            items: SystemKeychainItems())
    }

    init(service: String, synchronizes: Bool, accessibility: Accessibility, items: any KeychainItems) {
        self.service = service
        self.synchronizes = synchronizes
        self.accessibility = accessibility
        self.items = items
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

    /// Whether `status` says no more than that there is nothing to find in
    /// a keychain: the item is not in it, or this build may not use it.
    private static func meansNothingThere(_ status: OSStatus) -> Bool {
        status == errSecItemNotFound || status == errSecMissingEntitlement
    }

    public func data(account: String) throws -> Data? {
        var failure: OSStatus?
        for backend in backends {
            var query = baseQuery(backend, account: account)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            let (status, result) = items.copyMatching(query)
            if status == errSecSuccess, let data = result as? Data {
                return data
            }
            if !Self.meansNothingThere(status) {
                failure = failure ?? Self.failure(status)
            }
        }
        // A keychain that would not answer may be the one holding the item,
        // so "not there" is more than can be said.
        if let failure {
            throw SecretStorageError(status: failure)
        }
        return nil
    }

    /// The status to report for a read that did not go as asked. A keychain
    /// that claims success and hands back something else has not answered.
    private static func failure(_ status: OSStatus) -> OSStatus {
        status == errSecSuccess ? errSecDecode : status
    }

    public func set(_ data: Data?, account: String) throws {
        guard let data else {
            try remove(account)
            return
        }
        var lastStatus = errSecMissingEntitlement
        for backend in backends {
            lastStatus = store(data, account: account, in: backend)
            if lastStatus == errSecSuccess {
                // A copy in the keychain that was not written to would be an
                // old value waiting to be found again.
                for other in backends where other != backend {
                    _ = items.delete(baseQuery(other, account: account))
                }
                return
            }
            // Anything other than a missing entitlement is a real failure.
            if lastStatus != errSecMissingEntitlement { break }
        }
        throw SecretStorageError(status: lastStatus)
    }

    /// Puts `data` in one keychain: in place of the item's value when the
    /// item is there, as a new item when it is not. What was stored is never
    /// taken away first, so a write that fails leaves it as it was.
    private func store(_ data: Data, account: String, in backend: Backend) -> OSStatus {
        let query = baseQuery(backend, account: account)
        let replaced = items.update(query, to: [kSecValueData: data])
        guard replaced == errSecItemNotFound else { return replaced }

        var attributes = query
        attributes[kSecValueData] = data
        if backend == .dataProtection {
            attributes[kSecAttrSynchronizable] = synchronizes
            attributes[kSecAttrAccessible] = accessibility.attribute
        }
        let added = items.add(attributes)
        // Something else stored the item between the two calls.
        return added == errSecDuplicateItem ? items.update(query, to: [kSecValueData: data]) : added
    }

    private func remove(_ account: String) throws {
        var failure: OSStatus?
        for backend in backends {
            let status = items.delete(baseQuery(backend, account: account))
            if status != errSecSuccess, !Self.meansNothingThere(status) {
                failure = failure ?? status
            }
        }
        if let failure {
            throw SecretStorageError(status: failure)
        }
    }

    public func accounts() throws -> [String] {
        var found = Set<String>()
        var failure: OSStatus?
        for backend in backends {
            var query = baseQuery(backend, account: nil)
            query[kSecReturnAttributes] = true
            query[kSecMatchLimit] = kSecMatchLimitAll
            let (status, result) = items.copyMatching(query)
            guard status == errSecSuccess, let matches = result as? [[CFString: Any]] else {
                if !Self.meansNothingThere(status) {
                    failure = failure ?? Self.failure(status)
                }
                continue
            }
            for match in matches {
                if let account = match[kSecAttrAccount] as? String {
                    found.insert(account)
                }
            }
        }
        if let failure {
            throw SecretStorageError(status: failure)
        }
        return found.sorted()
    }
}

/// Secrets held in memory. Used by tests and SwiftUI previews.
public final class InMemorySecretStorage: SecretStorage {
    private let values = Mutex<[String: Data]>([:])

    public init() {}

    public func data(account: String) -> Data? {
        values.withLock { $0[account] }
    }

    public func set(_ data: Data?, account: String) throws {
        values.withLock { $0[account] = data }
    }

    public func accounts() -> [String] {
        values.withLock { $0.keys.sorted() }
    }
}

/// Passwords for saved computers.
///
/// A password that cannot be read is treated here like one that was never
/// saved: the user is asked for it, which is what happens without one.
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
        stored(account(id, kind))
    }

    private func stored(_ account: String) -> String? {
        (try? storage.data(account: account)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Saves a password. `nil` or an empty string removes it.
    public func setPassword(_ password: String?, for id: UUID, kind: Kind = .screenSharing) throws {
        let data = password.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        try storage.set(data, account: account(id, kind))
    }

    public func hasPassword(for id: UUID, kind: Kind = .screenSharing) -> Bool {
        (try? storage.data(account: account(id, kind))) != nil
    }

    public func deleteAll(for id: UUID) {
        for kind in Kind.allCases {
            try? storage.set(nil, account: account(id, kind))
        }
    }

    // MARK: Named secrets

    /// A secret that does not belong to a computer, such as an API token.
    public func secret(named name: String) -> String? {
        stored("secret.\(name)")
    }

    public func setSecret(_ value: String?, named name: String) throws {
        let data = value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        try storage.set(data, account: "secret.\(name)")
    }

    /// Removes every password and secret OpenScreens has stored.
    public func eraseEverything() {
        for account in (try? storage.accounts()) ?? [] {
            try? storage.set(nil, account: account)
        }
    }
}

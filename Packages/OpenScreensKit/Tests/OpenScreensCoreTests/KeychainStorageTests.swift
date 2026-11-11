import Foundation
import Security
import Synchronization
import Testing
@testable import OpenScreensCore

/// A keychain made of two dictionaries, for testing what ``KeychainStorage``
/// does with a keychain's answers. No test goes near the real one.
///
/// It keeps generic passwords by service and account in a data-protection
/// keychain and a login keychain, answers the four calls the way the system
/// does for the queries `KeychainStorage` makes, and can be told to fail.
final class FakeKeychain: KeychainItems {
    enum Keychain: Hashable, Sendable {
        case dataProtection
        case login
    }

    enum Call: Hashable, Sendable {
        case copyMatching, add, update, delete
    }

    struct Item: Equatable, Sendable {
        var data: Data
        var isSynchronizable: Bool?
        var accessibility: String?
    }

    private struct State {
        var items: [Keychain: [String: [String: Item]]] = [:]
        /// What each call answers instead of doing its work, soonest first.
        var scripted: [Keychain: [Call: [OSStatus]]] = [:]
        /// What each call answers from now on instead of doing its work.
        var broken: [Keychain: [Call: OSStatus]] = [:]
        var log: [String] = []
    }

    private let state = Mutex(State())

    // MARK: Arranging

    /// Makes every `call` on `keychain` answer `status` until told otherwise
    /// with `nil`.
    func make(_ call: Call, on keychain: Keychain, answer status: OSStatus?) {
        state.withLock { $0.broken[keychain, default: [:]][call] = status }
    }

    /// Makes the next `call` on `keychain` answer `status`, once.
    func makeNext(_ call: Call, on keychain: Keychain, answer status: OSStatus) {
        state.withLock { $0.scripted[keychain, default: [:]][call, default: []].append(status) }
    }

    /// A keychain this build is not entitled to, as the data-protection
    /// keychain is to a Mac app that is not signed for it.
    func withhold(_ keychain: Keychain) {
        for call in [Call.copyMatching, .add, .update, .delete] {
            make(call, on: keychain, answer: errSecMissingEntitlement)
        }
    }

    func put(_ item: Item, account: String, service: String = "test", in keychain: Keychain) {
        state.withLock { $0.items[keychain, default: [:]][service, default: [:]][account] = item }
    }

    // MARK: Looking

    func item(_ account: String, service: String = "test", in keychain: Keychain) -> Item? {
        state.withLock { $0.items[keychain]?[service]?[account] }
    }

    /// Every call made so far, as "call keychain account".
    var log: [String] {
        state.withLock { $0.log }
    }

    func forgetLog() {
        state.withLock { $0.log = [] }
    }

    // MARK: KeychainItems

    private struct Query {
        var keychain: Keychain
        var service: String
        var account: String?

        init(_ query: [CFString: Any]) {
            keychain = (query[kSecUseDataProtectionKeychain] as? Bool) == true ? .dataProtection : .login
            service = query[kSecAttrService] as? String ?? ""
            account = query[kSecAttrAccount] as? String
        }
    }

    /// Notes the call and says what it should answer when it has been told
    /// to fail.
    private func begin(_ call: Call, _ query: Query, in state: inout State) -> OSStatus? {
        state.log.append("\(call) \(query.keychain) \(query.account ?? "*")")
        if var scripted = state.scripted[query.keychain]?[call], !scripted.isEmpty {
            let status = scripted.removeFirst()
            state.scripted[query.keychain]?[call] = scripted
            return status
        }
        return state.broken[query.keychain]?[call]
    }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        let parsed = Query(query)
        return state.withLock { state in
            if let status = begin(.copyMatching, parsed, in: &state) { return (status, nil) }
            let stored = state.items[parsed.keychain]?[parsed.service] ?? [:]
            if let account = parsed.account {
                guard let item = stored[account] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item.data as CFData)
            }
            guard !stored.isEmpty else { return (errSecItemNotFound, nil) }
            let attributes = stored.keys.sorted().map { [kSecAttrAccount: $0] as [CFString: Any] }
            return (errSecSuccess, attributes as CFArray)
        }
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        let parsed = Query(attributes)
        return state.withLock { state in
            if let status = begin(.add, parsed, in: &state) { return status }
            guard let account = parsed.account, let data = attributes[kSecValueData] as? Data else {
                return errSecParam
            }
            guard state.items[parsed.keychain]?[parsed.service]?[account] == nil else {
                return errSecDuplicateItem
            }
            state.items[parsed.keychain, default: [:]][parsed.service, default: [:]][account] = Item(
                data: data,
                isSynchronizable: attributes[kSecAttrSynchronizable] as? Bool,
                accessibility: attributes[kSecAttrAccessible] as? String)
            return errSecSuccess
        }
    }

    func update(_ query: [CFString: Any], to attributes: [CFString: Any]) -> OSStatus {
        let parsed = Query(query)
        return state.withLock { state in
            if let status = begin(.update, parsed, in: &state) { return status }
            guard let account = parsed.account, let data = attributes[kSecValueData] as? Data else {
                return errSecParam
            }
            guard state.items[parsed.keychain]?[parsed.service]?[account] != nil else {
                return errSecItemNotFound
            }
            state.items[parsed.keychain]?[parsed.service]?[account]?.data = data
            return errSecSuccess
        }
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        let parsed = Query(query)
        return state.withLock { state in
            if let status = begin(.delete, parsed, in: &state) { return status }
            guard let account = parsed.account,
                  state.items[parsed.keychain]?[parsed.service]?.removeValue(forKey: account) != nil else {
                return errSecItemNotFound
            }
            return errSecSuccess
        }
    }
}

@Suite("KeychainStorage")
struct KeychainStorageTests {
    /// What a locked keychain answers.
    static let locked = errSecInteractionNotAllowed

    let keychain = FakeKeychain()

    func storage(
        synchronizes: Bool = true,
        accessibility: KeychainStorage.Accessibility = .afterFirstUnlock
    ) -> KeychainStorage {
        KeychainStorage(
            service: "test", synchronizes: synchronizes, accessibility: accessibility, items: keychain)
    }

    // MARK: Storing

    @Test func aSecretIsAddedOnceAndReplacedWhereItIsAfterThat() throws {
        let storage = storage()
        #expect(try storage.data(account: "a") == nil)
        #expect(try storage.accounts().isEmpty)

        try storage.set(Data("first".utf8), account: "a")
        #expect(try storage.data(account: "a") == Data("first".utf8))
        #expect(keychain.item("a", in: .dataProtection) == FakeKeychain.Item(
            data: Data("first".utf8),
            isSynchronizable: true,
            accessibility: kSecAttrAccessibleAfterFirstUnlock as String))

        // Saving again changes the value of the item that is there. At no
        // point is the keychain without it.
        keychain.forgetLog()
        try storage.set(Data("second".utf8), account: "a")
        try storage.set(Data("other".utf8), account: "b")
        #expect(try storage.data(account: "a") == Data("second".utf8))
        #expect(try storage.accounts() == ["a", "b"])
        #expect(!keychain.log.contains("delete dataProtection a"))
        #expect(!keychain.log.contains("add dataProtection a"))
    }

    @Test func aSaveThatFailsLeavesWhatWasSaved() throws {
        let storage = storage()
        try storage.set(Data("the only copy".utf8), account: "key")

        // The keychain turns the new value down, as it does when the device
        // has been locked in the meantime.
        for call in [FakeKeychain.Call.update, .add] {
            keychain.make(call, on: .dataProtection, answer: Self.locked)
        }
        #expect(throws: SecretStorageError(status: Self.locked)) {
            try storage.set(Data("a new value".utf8), account: "key")
        }
        // A secret that was never saved fails the same way and leaves
        // nothing half done.
        #expect(throws: SecretStorageError(status: Self.locked)) {
            try storage.set(Data("never saved".utf8), account: "new")
        }

        for call in [FakeKeychain.Call.update, .add] {
            keychain.make(call, on: .dataProtection, answer: nil)
        }
        #expect(try storage.data(account: "key") == Data("the only copy".utf8))
        #expect(try storage.accounts() == ["key"])
    }

    @Test func aSecretSavedByAnotherHandInTheMeantimeIsReplaced() throws {
        let storage = storage()
        // The item is not there when its value is to be replaced, and is by
        // the time it is added instead: another process, or another device
        // through iCloud, got in between.
        keychain.put(.init(data: Data("theirs".utf8)), account: "a", in: .dataProtection)
        keychain.makeNext(.update, on: .dataProtection, answer: errSecItemNotFound)

        try storage.set(Data("ours".utf8), account: "a")
        #expect(try storage.data(account: "a") == Data("ours".utf8))
    }

    @Test func newItemsAreStoredTheWayTheStorageWasSetUp() throws {
        let strict = storage(synchronizes: false, accessibility: .whenUnlocked)
        try strict.set(Data("secret".utf8), account: "strict")
        #expect(keychain.item("strict", in: .dataProtection) == FakeKeychain.Item(
            data: Data("secret".utf8),
            isSynchronizable: false,
            accessibility: kSecAttrAccessibleWhenUnlocked as String))

        // An item that is already there keeps what it was first stored
        // with: only its value is replaced.
        try storage().set(Data("older".utf8), account: "older")
        try strict.set(Data("newer".utf8), account: "older")
        #expect(keychain.item("older", in: .dataProtection) == FakeKeychain.Item(
            data: Data("newer".utf8),
            isSynchronizable: true,
            accessibility: kSecAttrAccessibleAfterFirstUnlock as String))
    }

    // MARK: Reading

    @Test func aKeychainThatWillNotAnswerIsNotAnEmptyOne() throws {
        let storage = storage()
        try storage.set(Data("secret".utf8), account: "a")

        keychain.make(.copyMatching, on: .dataProtection, answer: Self.locked)
        // "There is no such secret" would be the wrong thing to say.
        #expect(throws: SecretStorageError(status: Self.locked)) { try storage.data(account: "a") }
        #expect(throws: SecretStorageError(status: Self.locked)) { try storage.data(account: "never saved") }
        #expect(throws: SecretStorageError(status: Self.locked)) { try storage.accounts() }

        keychain.make(.copyMatching, on: .dataProtection, answer: nil)
        #expect(try storage.data(account: "a") == Data("secret".utf8))
        #expect(try storage.data(account: "never saved") == nil)
    }

    @Test func anAnswerThatIsNotTheSecretIsNotTakenForNone() throws {
        let storage = storage()
        try storage.set(Data("secret".utf8), account: "a")
        // Success, with nothing to show for it.
        keychain.make(.copyMatching, on: .dataProtection, answer: errSecSuccess)
        #expect(throws: SecretStorageError(status: errSecDecode)) { try storage.data(account: "a") }
        #expect(throws: SecretStorageError(status: errSecDecode)) { try storage.accounts() }
    }

    // MARK: Removing

    @Test func removingASecretTakesItOutOfEveryKeychain() throws {
        let storage = storage()
        try storage.set(Data("secret".utf8), account: "a")
        keychain.put(.init(data: Data("an older copy".utf8)), account: "a", in: .login)

        try storage.set(nil, account: "a")
        #expect(keychain.item("a", in: .dataProtection) == nil)
        #if os(macOS)
        #expect(keychain.item("a", in: .login) == nil)
        #endif
        #expect(try storage.data(account: "a") == nil)
        // Removing what is not there is not an error.
        try storage.set(nil, account: "a")
        try storage.set(nil, account: "never saved")
    }

    @Test func aSecretThatCouldNotBeRemovedIsReportedAsStillThere() throws {
        let storage = storage()
        try storage.set(Data("secret".utf8), account: "a")
        keychain.make(.delete, on: .dataProtection, answer: Self.locked)

        #expect(throws: SecretStorageError(status: Self.locked)) { try storage.set(nil, account: "a") }
        #expect(try storage.data(account: "a") == Data("secret".utf8))
    }

    // MARK: A Mac app without the entitlement

    #if os(macOS)

    @Test func withoutTheEntitlementSecretsGoToTheLoginKeychain() throws {
        keychain.withhold(.dataProtection)
        let storage = storage()

        try storage.set(Data("first".utf8), account: "a")
        try storage.set(Data("second".utf8), account: "a")
        #expect(keychain.item("a", in: .dataProtection) == nil)
        // The login keychain has no notion of the other attributes.
        #expect(keychain.item("a", in: .login) == FakeKeychain.Item(data: Data("second".utf8)))
        #expect(try storage.data(account: "a") == Data("second".utf8))
        #expect(try storage.accounts() == ["a"])
        #expect(try storage.data(account: "never saved") == nil)

        // A failure there is a failure, with nowhere further to fall back.
        keychain.make(.update, on: .login, answer: Self.locked)
        #expect(throws: SecretStorageError(status: Self.locked)) {
            try storage.set(Data("third".utf8), account: "a")
        }
        keychain.make(.update, on: .login, answer: nil)
        #expect(try storage.data(account: "a") == Data("second".utf8))

        try storage.set(nil, account: "a")
        #expect(try storage.accounts().isEmpty)
    }

    @Test func aSecretLeftInTheLoginKeychainMovesOverWhenItIsSavedAgain() throws {
        // Saved by a build without the entitlement, read by one with it.
        keychain.put(.init(data: Data("old".utf8)), account: "a", in: .login)
        let storage = storage()
        #expect(try storage.data(account: "a") == Data("old".utf8))
        #expect(try storage.accounts() == ["a"])

        try storage.set(Data("new".utf8), account: "a")
        #expect(keychain.item("a", in: .dataProtection)?.data == Data("new".utf8))
        // The old value is not left behind to be found again some day.
        #expect(keychain.item("a", in: .login) == nil)
    }

    @Test func aSecretLeftInTheLoginKeychainStaysIfTheNewOneCannotBeSaved() throws {
        keychain.put(.init(data: Data("old".utf8)), account: "a", in: .login)
        keychain.make(.add, on: .dataProtection, answer: Self.locked)

        #expect(throws: SecretStorageError(status: Self.locked)) {
            try storage().set(Data("new".utf8), account: "a")
        }
        #expect(keychain.item("a", in: .login)?.data == Data("old".utf8))
    }

    #endif
}

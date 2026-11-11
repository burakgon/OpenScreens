import Foundation

/// What can be shown about a saved SSH key without revealing the key itself.
public struct StoredSSHKey: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The name the user gave the key.
    public var name: String
    /// The key's algorithm as people refer to it, such as "Ed25519".
    public let algorithm: String
    /// The public key's SHA-256 fingerprint, as `ssh-keygen -l` prints it.
    public let fingerprint: String
    /// The public key as an `authorized_keys` line without a comment.
    public let publicKey: String
    public let createdAt: Date

    /// The line to add to a server's `authorized_keys` file, labelled with
    /// the key's name so it can be recognised there later.
    public var authorizedKeysLine: String {
        let label = name
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? publicKey : "\(publicKey) \(label)"
    }
}

/// The user's named SSH keys, kept in secret storage.
///
/// Each key is one entry under the account `sshkey.<id>`, so keys travel with
/// iCloud Keychain like saved passwords do, and deleting one cannot disturb
/// another.
///
/// In the keychain, a key saved from now on can be read only while the
/// device is unlocked. A key is used to sign in when its owner starts a
/// connection, never behind a locked screen, so nothing is lost by that.
/// Keys saved before keep the looser setting they were saved with.
public struct SSHKeyStore: Sendable {
    private static let accountPrefix = "sshkey."

    /// What is written to secret storage for one key.
    private struct Record: Codable {
        var id: UUID
        var name: String
        var createdAt: Date
        /// The private key as an unprotected OpenSSH key file. The storage
        /// itself is what protects it.
        var privateKey: String
    }

    private let storage: any SecretStorage

    /// Where keys are kept unless a store is told otherwise: the keychain
    /// the passwords are in, with new keys readable only while the device
    /// is unlocked.
    public static var keychain: KeychainStorage {
        KeychainStorage(accessibility: .whenUnlocked)
    }

    public init(storage: any SecretStorage = SSHKeyStore.keychain) {
        self.storage = storage
    }

    // MARK: Reading

    /// Every saved key, oldest first.
    ///
    /// - Throws: When the storage could not be read, which says nothing
    ///   about whether there are keys in it.
    public func keys() throws -> [StoredSSHKey] {
        try storage.accounts()
            .filter { $0.hasPrefix(Self.accountPrefix) }
            .compactMap { try record(account: $0) }
            .compactMap { Self.describe($0) }
            .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    /// The private key saved under `id`, ready to sign in with, or `nil`
    /// when no key is saved under it.
    ///
    /// - Throws: When the storage could not be read. The key may well be
    ///   there.
    public func privateKey(for id: UUID) throws -> SSHPrivateKey? {
        guard let record = try record(account: Self.account(id)) else { return nil }
        return try? SSHPrivateKey(openSSH: record.privateKey, passphrase: nil)
    }

    // MARK: Changing

    /// Saves `key` under `name` and returns its description.
    @discardableResult
    public func add(name: String, key: SSHPrivateKey) throws -> StoredSSHKey {
        // Dates are stored to the second, so start from a whole second: the
        // description returned here then equals the one `keys()` reads back.
        let createdAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let record = Record(
            id: UUID(), name: name, createdAt: createdAt, privateKey: key.openSSHPrivateKey)
        try write(record)
        return Self.description(of: record, key: key)
    }

    /// Renames a saved key. If the new name cannot be saved, the key stays
    /// as it was, under its old name.
    /// - Returns: The updated description, or `nil` when there is no such key.
    @discardableResult
    public func rename(_ id: UUID, to name: String) throws -> StoredSSHKey? {
        guard var record = try record(account: Self.account(id)) else { return nil }
        record.name = name
        try write(record)
        return Self.describe(record)
    }

    /// Deletes a saved key. Servers that were given its public key keep
    /// accepting it until it is removed from them as well.
    public func delete(_ id: UUID) throws {
        try storage.set(nil, account: Self.account(id))
    }

    // MARK: Storage

    private static func account(_ id: UUID) -> String {
        accountPrefix + id.uuidString
    }

    /// The record stored under `account`. `nil` when there is none, and also
    /// when what is stored there is not a record.
    private func record(account: String) throws -> Record? {
        guard let data = try storage.data(account: account) else { return nil }
        return try? Self.decoder.decode(Record.self, from: data)
    }

    private func write(_ record: Record) throws {
        try storage.set(try Self.encoder.encode(record), account: Self.account(record.id))
    }

    /// Describes a stored record, or returns `nil` when its key cannot be read.
    private static func describe(_ record: Record) -> StoredSSHKey? {
        guard let key = try? SSHPrivateKey(openSSH: record.privateKey, passphrase: nil) else {
            return nil
        }
        return description(of: record, key: key)
    }

    private static func description(of record: Record, key: SSHPrivateKey) -> StoredSSHKey {
        StoredSSHKey(
            id: record.id,
            name: record.name,
            algorithm: key.algorithmName,
            fingerprint: key.fingerprint,
            publicKey: key.openSSHPublicKey,
            createdAt: record.createdAt)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

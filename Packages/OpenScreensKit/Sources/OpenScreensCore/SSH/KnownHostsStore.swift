import Foundation
import Synchronization

/// A server's host key, reduced to what a trust decision needs: its algorithm
/// and its SHA-256 fingerprint.
public struct SSHHostKey: Codable, Hashable, Sendable {
    /// The SSH name of the key's algorithm, such as `ssh-ed25519`.
    public var type: String
    /// The fingerprint as `ssh-keygen -l` prints it: `SHA256:` and unpadded
    /// base64.
    public var fingerprint: String

    public init(type: String, fingerprint: String) {
        self.type = type
        self.fingerprint = fingerprint
    }

    /// Reads a public key written the way `authorized_keys`, `known_hosts`
    /// and `.pub` files write it: `<type> <base64> [comment]`.
    public init?(openSSHPublicKey line: String) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2,
              let blob = Data(base64Encoded: String(fields[1])), !blob.isEmpty else { return nil }
        // The blob begins with its own copy of the type; a line whose two
        // halves disagree is not a public key.
        var reader = SSHWireReader(blob)
        guard let embeddedType = try? reader.readText(), embeddedType == fields[0] else { return nil }
        self.init(type: embeddedType, fingerprint: SSHFingerprint.sha256(ofPublicKeyBlob: blob))
    }
}

/// The SSH servers this device has agreed to trust, and the key each one
/// proved its identity with.
///
/// This is trust on first use: the first connection to a server records its
/// key, and every later connection must present a key that is on record.
///
/// The file is the source of truth. Every call reads it and every change
/// writes it back, under one lock shared by all instances in the process, so
/// separate instances pointed at the same file stay in step. The file is tiny
/// and is touched once per connection.
///
/// Reading never changes anything. A file that is there but cannot be read,
/// or does not make sense, is left exactly as it is: the store then refuses
/// to vouch for anyone, which is different from knowing nobody, until
/// ``removeAll()`` starts it afresh.
public final class KnownHostsStore: Sendable {

    /// What the store knows about a key a server presented.
    public enum Verdict: Equatable, Sendable {
        /// The key is on record for this server.
        case trusted
        /// Nothing is on record for this server.
        case unknown(fingerprint: String)
        /// The server is on record with a different key. Either its key was
        /// replaced or something is impersonating it.
        case mismatch(expected: String, presented: String)
        /// The store's file is there but could not be read, so there is no
        /// telling what is on record. That is not ``unknown(fingerprint:)``:
        /// the server may well be on record with another key, and to treat
        /// it as met for the first time would let through the very change
        /// the record is kept to catch. `reason` says what is wrong with the
        /// file, in words fit to show to the user.
        case storeUnreadable(reason: String)
    }

    /// The store's file is there but could not be read.
    public struct Unreadable: LocalizedError, Equatable, Sendable {
        /// What is wrong, in words fit to show to the user.
        public let reason: String

        public var errorDescription: String? { reason }
    }

    /// One server and the keys trusted for it.
    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public var host: String
        public var port: Int
        public var keys: [SSHHostKey]

        public var id: String { "\(host):\(port)" }

        public init(host: String, port: Int, keys: [SSHHostKey]) {
            self.host = host
            self.port = port
            self.keys = keys
        }
    }

    private struct Document: Codable, Equatable {
        /// The newest layout this version reads and the one it writes.
        static let currentSchemaVersion = 1

        var schemaVersion = Document.currentSchemaVersion
        var hosts: [Entry] = []

        /// What the document has to say about `key` for `host:port`.
        func verdict(on key: SSHHostKey, host: String, port: Int) -> Verdict {
            let known = hosts.first(where: KnownHostsStore.matcher(host: host, port: port))?.keys ?? []
            guard let first = known.first else {
                return .unknown(fingerprint: key.fingerprint)
            }
            if known.contains(key) {
                return .trusted
            }
            let expected = known.first { $0.type == key.type } ?? first
            return .mismatch(expected: expected.fingerprint, presented: key.fingerprint)
        }
    }

    /// The one thing every layout of the file says about itself.
    private struct Layout: Decodable {
        var schemaVersion: Int
    }

    /// Serialises every read-modify-write of a known hosts file in this
    /// process, whichever instance performs it.
    private static let fileLock = Mutex(())

    private let fileURL: URL?
    /// The entries of a store that has no file.
    private let memory = Mutex(Document())

    /// Creates a store backed by a JSON file. Pass `nil` for a store that
    /// lives in memory, for tests and previews.
    public init(fileURL: URL? = StorageLocation.knownHostsFile) {
        self.fileURL = fileURL
    }

    // MARK: Checking

    /// Judges a key presented by `host:port`.
    ///
    /// A server that is on record is held to the exact keys recorded for it:
    /// a key of a *different algorithm* counts as a mismatch too, not as
    /// unknown. OpenSSH can afford to treat that case as a first encounter
    /// because it asks servers for the key types it already knows.
    /// swift-nio-ssh always negotiates from one fixed preference list, so an
    /// impostor could otherwise sidestep the check just by offering another
    /// key type.
    public func check(host: String, port: Int, key: SSHHostKey) -> Verdict {
        do {
            return try read { $0.verdict(on: key, host: host, port: port) }
        } catch {
            return .storeUnreadable(reason: error.reason)
        }
    }

    /// Every server on record, sorted by host and port.
    ///
    /// - Throws: ``Unreadable`` when the store's file is there but cannot be
    ///   read, which is not the same as there being nothing on record.
    public func all() throws(Unreadable) -> [Entry] {
        try read { $0.hosts }.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    // MARK: Changing

    /// Records `key` as trusted for `host:port` whatever is on record now,
    /// replacing any key of the same algorithm. Keys of other algorithms stay
    /// on record: a server normally has one key per algorithm, and adding one
    /// says nothing about the others.
    ///
    /// This is for putting a key on record outright. A decision made on a
    /// ``Verdict`` goes through ``SSHHostKeyChallenge/trust()``, which makes
    /// sure the verdict still stands.
    public func trust(host: String, port: Int, key: SSHHostKey) throws {
        try update { document in
            let host = SSHHostName.normalized(host)
            if let index = document.hosts.firstIndex(where: Self.matcher(host: host, port: port)) {
                document.hosts[index].keys.removeAll { $0.type == key.type }
                document.hosts[index].keys.append(key)
            } else {
                document.hosts.append(Entry(host: host, port: port, keys: [key]))
            }
        }
    }

    /// Records `key` as trusted for `host:port`, provided the store still
    /// says about it what it said when the decision to trust it was made.
    ///
    /// Between a verdict and the decision taken on it, a person may have been
    /// reading a fingerprint for a minute, and another connection to the same
    /// server may have put a key on record. So the verdict is taken again
    /// here, under the lock the change is made under:
    ///
    /// - Nothing on record: the key is recorded.
    /// - The key itself on record: there is nothing to do.
    /// - Another key on record: the key takes the place of everything
    ///   recorded for the server, but only when that conflict is the very one
    ///   `verdict` describes, which is to say the one the decision was made
    ///   in view of. Accepting a changed key says the old ones no longer
    ///   speak for the server. A conflict nobody was shown changes nothing.
    ///
    /// - Returns: What the store says about the key afterwards: `.trusted`
    ///   when it is on record, and otherwise the verdict that stood in the
    ///   way, which the decision should now be taken on instead.
    /// - Throws: When the key should have been recorded and the file could
    ///   not be written.
    public func trust(
        host: String, port: Int, key: SSHHostKey, decidedOn verdict: Verdict
    ) throws -> Verdict {
        do {
            return try update { document in
                let current = document.verdict(on: key, host: host, port: port)
                switch current {
                case .trusted, .storeUnreadable:
                    return current
                case .mismatch where current != verdict:
                    return current
                case .unknown, .mismatch:
                    let host = SSHHostName.normalized(host)
                    document.hosts.removeAll(where: Self.matcher(host: host, port: port))
                    document.hosts.append(Entry(host: host, port: port, keys: [key]))
                    return .trusted
                }
            }
        } catch let error as Unreadable {
            return .storeUnreadable(reason: error.reason)
        }
    }

    /// Forgets `host:port`, so that its next connection is a first encounter.
    public func remove(host: String, port: Int) throws {
        try update { $0.hosts.removeAll(where: Self.matcher(host: host, port: port)) }
    }

    /// Forgets every server, so that the store is as it was before the first
    /// connection.
    ///
    /// This is also the way out when the store's file cannot be read. Such a
    /// file is not deleted: it is set aside under another name next to where
    /// it was, so that what it holds can still be recovered by hand.
    public func removeAll() throws {
        guard let fileURL else {
            memory.withLock { $0 = Document() }
            return
        }
        try Self.fileLock.withLock { _ in
            do {
                _ = try Self.load(fileURL)
            } catch {
                let aside = fileURL.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
                try FileManager.default.moveItem(at: fileURL, to: aside)
                return
            }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Nothing was on record in the first place.
            }
        }
    }

    // MARK: Storage

    fileprivate static func matcher(host: String, port: Int) -> (Entry) -> Bool {
        let host = SSHHostName.normalized(host)
        return { $0.port == port && SSHHostName.normalized($0.host) == host }
    }

    private func read<Result>(_ body: (Document) -> Result) throws(Unreadable) -> Result {
        guard let fileURL else {
            return memory.withLock { body($0) }
        }
        let document = try Self.fileLock.withLock { _ throws(Unreadable) in
            try Self.load(fileURL)
        }
        return body(document)
    }

    /// Changes what is on record, and writes it back if that changed it.
    private func update<Result>(_ change: (inout Document) -> Result) throws -> Result {
        guard let fileURL else {
            return memory.withLock { change(&$0) }
        }
        return try Self.fileLock.withLock { _ in
            // If the file is there but cannot be read, this throws rather than
            // replace records it never saw.
            let recorded = try Self.load(fileURL)
            var document = recorded
            let result = change(&document)
            guard document != recorded else { return result }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            return result
        }
    }

    /// Reads the file, and does nothing else to it.
    private static func load(_ fileURL: URL) throws(Unreadable) -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Nothing has been trusted yet.
            return Document()
        } catch {
            throw Unreadable(
                reason: "The list of trusted SSH servers could not be read. \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        // A newer layout may be arranged differently, or record things this
        // version would not understand and would drop on writing the file
        // back.
        if let layout = try? decoder.decode(Layout.self, from: data),
           layout.schemaVersion > Document.currentSchemaVersion {
            throw Unreadable(
                reason: "The list of trusted SSH servers was saved by a newer version of OpenScreens, "
                    + "which this version cannot read.")
        }
        guard let document = try? decoder.decode(Document.self, from: data) else {
            throw Unreadable(reason: "The list of trusted SSH servers is damaged and cannot be read.")
        }
        return document
    }
}

/// Host names as SSH settings compare them.
enum SSHHostName {
    /// The form in which host names are compared: without regard to case, a
    /// trailing root dot or IPv6 brackets, so that the spellings of one
    /// address count as one host.
    static func normalized(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.count > 1, host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }
}

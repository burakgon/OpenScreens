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

    private struct Document: Codable {
        var schemaVersion = 1
        var hosts: [Entry] = []
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
        let known = read { $0.hosts.first(where: Self.matcher(host: host, port: port))?.keys ?? [] }
        guard let first = known.first else {
            return .unknown(fingerprint: key.fingerprint)
        }
        if known.contains(key) {
            return .trusted
        }
        let expected = known.first { $0.type == key.type } ?? first
        return .mismatch(expected: expected.fingerprint, presented: key.fingerprint)
    }

    /// Every server on record, sorted by host and port.
    public func all() -> [Entry] {
        read { $0.hosts }.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    // MARK: Changing

    /// Records `key` as trusted for `host:port`, replacing any key of the same
    /// algorithm. Keys of other algorithms stay on record: a server normally
    /// has one key per algorithm, and accepting a new one says nothing about
    /// the others.
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

    /// Forgets `host:port`, so that its next connection is a first encounter.
    public func remove(host: String, port: Int) throws {
        try update { $0.hosts.removeAll(where: Self.matcher(host: host, port: port)) }
    }

    // MARK: Storage

    private static func matcher(host: String, port: Int) -> (Entry) -> Bool {
        let host = SSHHostName.normalized(host)
        return { $0.port == port && SSHHostName.normalized($0.host) == host }
    }

    private func read<Result>(_ body: (Document) -> Result) -> Result {
        guard let fileURL else {
            return memory.withLock { body($0) }
        }
        // A file that cannot be read vouches for nobody: every server is
        // unknown until it can be read again.
        return Self.fileLock.withLock { _ in body((try? Self.load(fileURL)) ?? Document()) }
    }

    private func update(_ change: (inout Document) -> Void) throws {
        guard let fileURL else {
            memory.withLock { change(&$0) }
            return
        }
        try Self.fileLock.withLock { _ in
            // If the file is there but cannot be read, this throws rather than
            // replace records it never saw.
            var document = try Self.load(fileURL)
            change(&document)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(document).write(to: fileURL, options: .atomic)
        }
    }

    private static func load(_ fileURL: URL) throws -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Nothing has been trusted yet.
            return Document()
        }
        if let document = try? JSONDecoder().decode(Document.self, from: data) {
            return document
        }
        // Never overwrite a file that does not make sense: set it aside so
        // the records can be recovered by hand. Every server becomes unknown,
        // so the next connection to each asks again instead of trusting
        // blindly.
        let aside = fileURL.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: fileURL, to: aside)
        return Document()
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

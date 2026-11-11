#if os(macOS)

import Foundation
import Network
import Synchronization
import Testing
@testable import OpenScreensCore

/// A private `sshd`, run as the current user on a loopback port for the
/// length of one test.
///
/// Nothing about it touches the machine's own SSH setup: the host key, the
/// one authorised client key, the configuration and the PID file all live in
/// a scratch directory, which is deleted when the test is over. It needs no
/// privileges, because a server that only ever signs in the user who started
/// it has no reason to be root.
struct PrivateSSHServer: Sendable {
    static let executable = "/usr/sbin/sshd"

    let port: Int
    /// The only account an unprivileged sshd can sign in to: its owner's.
    let username: String
    /// A key the server lets in. More can be added with ``authorize(_:)``.
    let clientKey: SSHPrivateKey
    /// What the server identifies itself with, as `ssh-keygen` describes it.
    let hostKey: SSHHostKey
    /// A scratch directory that stands for the remote file system. Client and
    /// server share one disk, so the tests can look at both ends of a
    /// transfer.
    let directory: URL
    private let authorizedKeysFile: URL
    private let process: ChildProcess

    private var processIdentifier: pid_t { process.processIdentifier }

    struct StartFailure: Error, CustomStringConvertible {
        var description: String
    }

    /// Starts a server, runs `body` against it, and stops it again whether
    /// `body` returns or throws.
    ///
    /// When no server can be started here (no sshd, a sandbox that forbids
    /// listening, a configuration this version rejects) the calling test is
    /// cancelled, which reports it as skipped rather than failed.
    ///
    /// - Parameters:
    ///   - rekeyLimit: The server's `RekeyLimit`: how much data it lets
    ///     through, and optionally how much time, before it replaces a
    ///     session's encryption keys, as in `"1M"` or `"default 2s"`. With a
    ///     limit set the server also logs each replacement, which
    ///     `completedKeyExchangeCount()` counts. `nil` leaves the server's
    ///     own limits, which no test comes near.
    ///   - hostKeyType: The `ssh-keygen -t` name of the kind of host key the
    ///     server should have. It has that key and no other.
    ///   - offersSFTP: Whether the server provides the `sftp` subsystem.
    ///   - allowsForwarding: Whether the server makes connections on behalf
    ///     of its clients, which is what a tunnel is.
    static func run<Result>(
        rekeyLimit: String? = nil,
        hostKeyType: String = "ed25519",
        offersSFTP: Bool = true,
        allowsForwarding: Bool = true,
        _ body: (PrivateSSHServer) async throws -> Result
    ) async throws -> Result {
        let scratch = try TemporaryDirectory()
        let server: PrivateSSHServer
        do {
            server = try await start(
                rekeyLimit: rekeyLimit,
                in: scratch, hostKeyType: hostKeyType,
                offersSFTP: offersSFTP, allowsForwarding: allowsForwarding)
        } catch {
            try Test.cancel("Skipped: a private sshd could not be started here. \(error)")
        }
        defer { server.stop() }
        return try await body(server)
    }

    private static func start(
        rekeyLimit: String?,
        in scratch: TemporaryDirectory,
        hostKeyType: String,
        offersSFTP: Bool,
        allowsForwarding: Bool
    ) async throws -> PrivateSSHServer {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw StartFailure(description: "\(executable) is not installed.")
        }
        let hostKeyFile = scratch.file("host_key")
        let clientKeyFile = scratch.file("client_key")
        try CommandLineTool.generateKey(at: hostKeyFile, type: hostKeyType, comment: "test host")
        try CommandLineTool.generateKey(at: clientKeyFile, type: "ed25519", comment: "test client")
        let authorizedKeysFile = scratch.file("authorized_keys")
        try FileManager.default.copyItem(
            at: clientKeyFile.appendingPathExtension("pub"), to: authorizedKeysFile)
        let directory = scratch.file("remote")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clientKey = try SSHPrivateKey(
            openSSH: String(contentsOf: clientKeyFile, encoding: .utf8), passphrase: nil)
        let hostKey = try #require(SSHHostKey(openSSHPublicKey: String(
            contentsOf: hostKeyFile.appendingPathExtension("pub"), encoding: .utf8)))

        // The server has to bind its port itself, so the port can only be
        // picked, not held, and another test may take it first. Losing that
        // race shows as the server exiting; then another port is tried.
        var lastFailure = StartFailure(description: "no attempt was made")
        for _ in 0..<5 {
            let port = try freeLoopbackPort()
            let pidFile = scratch.file("sshd-\(port).pid")
            let configurationFile = scratch.file("sshd_config-\(port)")
            let required = [
                "Port \(port)",
                "ListenAddress 127.0.0.1",
                "HostKey \(hostKeyFile.path)",
                "PidFile \(pidFile.path)",
                "AuthorizedKeysFile \(authorizedKeysFile.path)",
                // The scratch directory is not laid out like a home directory.
                "StrictModes no",
                "UsePAM no",
                "PubkeyAuthentication yes",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
                "AllowTcpForwarding \(allowsForwarding ? "yes" : "no")",
                "LogLevel VERBOSE",
            ] + (offersSFTP ? ["Subsystem sftp internal-sftp"] : [])
            // Newer servers hold a grudge against addresses that fail to sign
            // in, which is exactly what some of these tests do on purpose.
            // Older servers do not know the option, so it is dropped if it is
            // refused.
            let optional = ["PerSourcePenalties no"]
            // These go ahead of the rest, because sshd keeps the first value
            // it meets for an option: only at this log level does the server
            // say when it replaces keys.
            let renewal = rekeyLimit.map { ["RekeyLimit \($0)", "LogLevel DEBUG1"] } ?? []
            func write(_ lines: [String]) throws {
                try Data(((renewal + lines).joined(separator: "\n") + "\n").utf8).write(to: configurationFile)
            }
            try write(required + optional)
            if (try? CommandLineTool.run(executable, ["-t", "-f", configurationFile.path])) == nil {
                try write(required)
                try CommandLineTool.run(executable, ["-t", "-f", configurationFile.path])
            }

            let logFile = scratch.file("sshd-\(port).log")
            let log = open(logFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard log >= 0 else {
                throw StartFailure(description: "\(logFile.path): \(String(cString: strerror(errno)))")
            }
            defer { close(log) }
            // -D keeps it in the foreground as our child; -e sends its log to
            // standard error instead of the system log.
            let process = try ChildProcess(
                executable, ["-D", "-e", "-f", configurationFile.path], output: log)

            if try await isListening(process, pidFile: pidFile) {
                return PrivateSSHServer(
                    port: port,
                    username: NSUserName(),
                    clientKey: clientKey,
                    hostKey: hostKey,
                    directory: directory,
                    authorizedKeysFile: authorizedKeysFile,
                    process: process)
            }
            process.stop()
            let output = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            lastFailure = StartFailure(description: "sshd did not come up on port \(port): \(output)")
        }
        throw lastFailure
    }

    /// Waits for the server to be accepting connections.
    ///
    /// The sign of that is its PID file, which sshd writes once its port is
    /// bound and listening. Simply connecting to the port would not do: if
    /// this server lost the port to someone else, the connection would reach
    /// that someone, and the test would run against the wrong server.
    private static func isListening(_ process: ChildProcess, pidFile: URL) async throws -> Bool {
        for _ in 0..<400 {
            if process.exitStatusIfEnded() != nil {
                return false
            }
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
               pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) == process.processIdentifier {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func stop() {
        // The listener forks processes for each connection, and those outlive
        // it. The tests close their connections, but a failed one may not
        // have.
        killSessions()
        process.stop()
    }

    /// Lets `key` sign in as well. The server reads its list of authorised
    /// keys afresh for every attempt, so this takes effect at once.
    func authorize(_ key: SSHPrivateKey) throws {
        let handle = try FileHandle(forWritingTo: authorizedKeysFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((key.openSSHPublicKey(comment: "added by a test") + "\n").utf8))
    }

    // MARK: Looking at the server

    /// The number of connections the server is serving at the moment.
    func sessionCount() -> Int {
        // pgrep exits with status 1 when nothing matches.
        let listing = try? CommandLineTool.run("/usr/bin/pgrep", ["-P", String(processIdentifier)])
        return listing?.split(separator: "\n").count ?? 0
    }

    /// Waits for the server to have exactly `count` connections.
    func waitForSessionCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if sessionCount() == count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sessionCount() == count
    }

    /// Kills the processes serving the current connections, as abruptly as a
    /// server crash would: no SSH disconnect, just a dead socket.
    func killSessions() {
        for descendant in Self.descendants(of: processIdentifier) {
            kill(descendant, SIGKILL)
        }
    }

    /// Every process below `parent`, children before their parents. A
    /// connection is served by more than one process, and only the first of
    /// them is the listener's own child.
    private static func descendants(of parent: Int32) -> [Int32] {
        // pgrep exits with status 1 when nothing matches.
        let listing = (try? CommandLineTool.run("/usr/bin/pgrep", ["-P", String(parent)])) ?? ""
        let children = listing.split(separator: "\n").compactMap { Int32($0) }
        return children.flatMap { descendants(of: $0) + [$0] }
    }

    // MARK: Connecting

    /// Connects with the authorised key, trusting whatever host key appears.
    func connect(
        credential: SSHCredential? = nil,
        knownHosts: KnownHostsStore = KnownHostsStore(fileURL: nil),
        hostKeyPolicy: @escaping SSHHostKeyPolicy = SSHClient.knownHostsPolicy(trustUnknownHosts: true),
        timeout: Duration = .seconds(10)
    ) async throws -> SSHClient {
        try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            username: username,
            credential: credential ?? .key(clientKey),
            knownHosts: knownHosts,
            hostKeyPolicy: hostKeyPolicy,
            timeout: timeout)
    }

    // MARK: Ports

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// Asks the system for a port nothing is using right now. It is only a
    /// suggestion: the port is free again the moment this returns, and
    /// whoever binds it first has it.
    private static func freeLoopbackPort() throws -> Int {
        let bound = try bindLoopbackSocket()
        close(bound.fileDescriptor)
        return bound.port
    }

    /// Binds a socket to a loopback port of the system's choosing, without
    /// listening on it.
    fileprivate static func bindLoopbackSocket() throws -> (fileDescriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw StartFailure(description: "socket: \(String(cString: strerror(errno)))")
        }
        var address = loopbackAddress(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw StartFailure(description: "bind: \(reason)")
        }
        return (descriptor, Int(in_port_t(bigEndian: address.sin_port)))
    }

    /// A loopback port that refuses connections.
    ///
    /// It is taken from below the range the system assigns ports from, so no
    /// server started by a test running alongside can land on it, and it is
    /// checked to be refusing right now. (Holding a port by binding without
    /// listening would be surer still, but macOS lets connections to such a
    /// port time out instead of refusing them.)
    static func refusingLoopbackPort() throws -> Int {
        for _ in 0..<50 {
            let port = Int.random(in: 20_000..<45_000)
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var address = loopbackAddress(port: port)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0, errno == ECONNREFUSED {
                return port
            }
        }
        throw StartFailure(description: "no refusing port could be found")
    }
}

/// A loopback port that never answers, for as long as the value lives.
///
/// The port is bound but not listening, and the system drops connection
/// attempts to such a port without a word. That is as close to a host that
/// is switched off as the loopback interface gets.
final class UnansweringPort: Sendable {
    let port: Int
    private let fileDescriptor: Int32

    init() throws {
        (fileDescriptor, port) = try PrivateSSHServer.bindLoopbackSocket()
    }

    deinit {
        close(fileDescriptor)
    }
}

/// A TCP server on the loopback interface: the far end of a tunnel.
final class LoopbackServer: Sendable {
    enum Behavior: Sendable {
        /// Sends back whatever arrives.
        case echo
        /// Sends these bytes, then closes the connection.
        case sendThenClose(Data)
        /// Waits to be sent something, answers with these bytes, then closes.
        case replyThenClose(Data)
        /// Accepts connections and never says a word.
        case silent
        /// Sends `blockCount` numbered blocks as fast as the connection takes
        /// them, then closes. See ``floodBlock(_:)``.
        case flood(blockCount: Int)
        /// Plays the server's part of an RFB 3.8 handshake for a desktop
        /// called `name` that asks for no password, then listens without
        /// answering.
        case remoteDesktop(name: String)
    }

    static let floodBlockSize = 1024 * 1024
    private static let floodPattern = Data.testPattern(count: floodBlockSize, seed: 0xF100D)

    /// Block number `index` of a flood: its number in the first eight bytes,
    /// so that a block out of place is noticed, then a fixed pattern.
    static func floodBlock(_ index: Int) -> Data {
        var block = floodPattern
        withUnsafeBytes(of: UInt64(index).bigEndian) { block.replaceSubrange(0..<8, with: $0) }
        return block
    }

    let port: Int
    private let listener: NWListener
    private let behavior: Behavior
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let connections = Mutex<[NWConnection]>([])
    private let sentByteCount = Mutex(0)

    private init(listener: NWListener, port: Int, behavior: Behavior) {
        self.listener = listener
        self.port = port
        self.behavior = behavior
    }

    /// Bytes the network has accepted from this server so far.
    var bytesSent: Int {
        sentByteCount.withLock { $0 }
    }

    static func start(_ behavior: Behavior) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let pending = Recorder<NWConnection>()
        let queue = DispatchQueue(label: "LoopbackServer.start")

        // Connections that arrive before the server object exists are held.
        listener.newConnectionHandler = { connection in pending.record(connection) }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = FirstClaim()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim(), let port = listener.port {
                        continuation.resume(returning: Int(port.rawValue))
                    }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let server = LoopbackServer(listener: listener, port: port, behavior: behavior)
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        for connection in pending.values {
            server.accept(connection)
        }
        return server
    }

    func stop() {
        listener.cancel()
        for connection in connections.withLock({ $0 }) {
            connection.cancel()
        }
    }

    deinit {
        stop()
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        switch behavior {
        case .echo:
            echo(on: connection)
        case .sendThenClose(let data):
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .replyThenClose(let data):
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        case .silent:
            break
        case .flood(let blockCount):
            flood(on: connection, block: 0, of: blockCount)
        case .remoteDesktop(let name):
            // ServerInit: a 640 by 480 screen, 32 bits per pixel of which 24
            // are true colour, then the desktop's name.
            var serverInit = Data([0x02, 0x80, 0x01, 0xE0])
            serverInit.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            withUnsafeBytes(of: UInt32(name.utf8.count).bigEndian) { serverInit.append(contentsOf: $0) }
            serverInit.append(contentsOf: name.utf8)
            converse(on: connection, [
                // Each side names the protocol version it speaks.
                (send: Data("RFB 003.008\n".utf8), receive: 12),
                // One security type on offer, "None"; the client picks it.
                (send: Data([1, 1]), receive: 1),
                // Security result: OK. The client answers with ClientInit.
                (send: Data([0, 0, 0, 0]), receive: 1),
                (send: serverInit, receive: 0),
            ])
        }
    }

    /// Works through a script: send something, wait for exactly so many bytes
    /// in reply, go on to the next step. After the last step whatever arrives
    /// is read and ignored.
    private func converse(
        on connection: NWConnection,
        _ steps: ArraySlice<(send: Data, receive: Int)>
    ) {
        guard let step = steps.first else {
            discardInput(on: connection)
            return
        }
        connection.send(content: step.send, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                connection.cancel()
                return
            }
            guard step.receive > 0 else {
                converse(on: connection, steps.dropFirst())
                return
            }
            connection.receive(minimumIncompleteLength: step.receive, maximumLength: step.receive) {
                [weak self] data, _, _, error in
                guard data?.count == step.receive, error == nil, let self else {
                    connection.cancel()
                    return
                }
                converse(on: connection, steps.dropFirst())
            }
        })
    }

    private func discardInput(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard data != nil, !isComplete, error == nil, let self else {
                connection.cancel()
                return
            }
            discardInput(on: connection)
        }
    }

    /// Receives a chunk, sends it back, and only then receives the next, so
    /// that a peer that stops reading stops this end too.
    private func echo(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] sendError in
                if sendError == nil, !isComplete, error == nil, let self {
                    echo(on: connection)
                } else {
                    connection.cancel()
                }
            })
        }
    }

    private func flood(on connection: NWConnection, block index: Int, of blockCount: Int) {
        guard index < blockCount else {
            connection.cancel()
            return
        }
        connection.send(content: Self.floodBlock(index), completion: .contentProcessed {
            [weak self] error in
            guard error == nil, let self else {
                connection.cancel()
                return
            }
            sentByteCount.withLock { $0 += Self.floodBlockSize }
            flood(on: connection, block: index + 1, of: blockCount)
        })
    }
}

/// Collects values from callbacks that may run on any thread.
final class Recorder<Value: Sendable>: Sendable {
    private let recorded = Mutex<[Value]>([])

    var values: [Value] {
        recorded.withLock { $0 }
    }

    func record(_ value: Value) {
        recorded.withLock { $0.append(value) }
    }
}

#endif

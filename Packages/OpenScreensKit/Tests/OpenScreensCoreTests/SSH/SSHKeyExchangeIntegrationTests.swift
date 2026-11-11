#if os(macOS)

import Foundation
import Network
import RFBProtocol
import RFBTransport
import Synchronization
import Testing
@testable import OpenScreensCore

/// Sessions that go on while the server replaces their encryption keys, as
/// OpenSSH does after so much data or time (`RekeyLimit`). The server here is
/// told to do it every megabyte or every second, which in a test of a few
/// megabytes comes to dozens of key exchanges in the middle of the traffic.
extension SSHTests.SSHIntegrationTests {

    // MARK: Key exchanges during a session

    /// Runs `body`, which is expected to finish well within `limit`. If it
    /// has not by then, the connection is closed under it, so that a transfer
    /// stuck waiting for the server fails there and then with the reason
    /// instead of holding the whole run until the suite's time limit.
    static func finishing<Result>(
        within limit: Duration,
        on client: SSHClient,
        _ body: () async throws -> Result
    ) async throws -> Result {
        let watchdog = Task {
            try await Task.sleep(for: limit)
            Issue.record("Not finished after \(limit). The connection is being closed to end the wait.")
            await client.close()
        }
        defer { watchdog.cancel() }
        return try await body()
    }

    /// Sends `payload` through `tunnel` in pieces of very different sizes
    /// while reading the echo back, as input and screen updates overlap, and
    /// returns what came back.
    static func echo(_ payload: Data, through tunnel: SSHTunnelConnection) async throws -> Data {
        async let received = read(payload.count, from: tunnel)
        var sent = 0
        var size = 1
        while sent < payload.count {
            let end = min(sent + size, payload.count)
            try await tunnel.send(payload.subdata(in: sent..<end))
            sent = end
            size = size * 7 % 300_007 + 1
        }
        return try await received
    }

    @Test func aTunnelCarriesMegabytesAcrossManyKeyExchanges() async throws {
        try await PrivateSSHServer.run(rekeyLimit: "1M") { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let questions = Recorder<KnownHostsStore.Verdict>()
            let client = try await server.connect { challenge in
                questions.record(challenge.verdict)
                return true
            }
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            let disconnects = Recorder<VNCProtocolError>()
            await tunnel.setDisconnectHandler { disconnects.record($0) }

            let payload = Data.testPattern(count: 12 * 1024 * 1024 + 4321)
            let echoed = try await Self.finishing(within: .seconds(60), on: client) {
                try await Self.echo(payload, through: tunnel)
            }
            // Not a byte lost, added or out of place, in either direction.
            #expect(echoed == payload)

            // The keys really were replaced along the way, many times over…
            #expect(server.completedKeyExchangeCount() >= 8)
            // …the server proved its identity each time, and the person who
            // accepted its key when connecting was not asked again.
            #expect(questions.values == [.unknown(fingerprint: server.hostKey.fingerprint)])
            #expect(client.isConnected)
            #expect(disconnects.values.isEmpty)
            await tunnel.close()
            await client.close()
        }
    }

    @Test func overASlowLinkTrafficWaitsOutEveryKeyExchange() async throws {
        try await PrivateSSHServer.run(rekeyLimit: "1M") { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            // On the loopback interface a key exchange is over in well under
            // a millisecond. With a few milliseconds each way, as on a real
            // network, it lasts long enough for plenty of reads and writes to
            // be asked for in the meantime, all of which have to wait.
            let link = try await SlowLink.start(toPort: server.port, delay: .milliseconds(3))
            defer { link.stop() }
            let client = try await SSHClient.connect(
                host: "127.0.0.1", port: link.port, username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: { _ in true },
                timeout: .seconds(10))
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)

            let payload = Data.testPattern(count: 3 * 1024 * 1024 + 99)
            let echoed = try await Self.finishing(within: .seconds(60), on: client) {
                try await Self.echo(payload, through: tunnel)
            }
            #expect(echoed == payload)
            #expect(server.completedKeyExchangeCount() >= 4)
            await tunnel.close()
            await client.close()
        }
    }

    @Test func anIdleSessionOutlivesTheServersKeyExchangeTimer() async throws {
        try await PrivateSSHServer.run(rekeyLimit: "default 1s") { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            let disconnects = Recorder<VNCProtocolError>()
            await tunnel.setDisconnectHandler { disconnects.record($0) }

            // A few words, then silence until the server's timer comes
            // round, three times over. (OpenSSH lets the timer start a key
            // exchange only once something has been said with the last keys.)
            for round in 1...3 {
                let word = Data("round \(round)".utf8)
                try await Self.finishing(within: .seconds(30), on: client) {
                    try await tunnel.send(word)
                    #expect(try await tunnel.read(exactly: word.count) == word)
                }
                let deadline = ContinuousClock.now + .seconds(15)
                while server.completedKeyExchangeCount() < round, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(server.completedKeyExchangeCount() >= round)
                // The session is as it was.
                #expect(client.isConnected)
                #expect(disconnects.values.isEmpty)
            }

            try await Self.finishing(within: .seconds(30), on: client) {
                try await tunnel.send(Data("still here".utf8))
                #expect(try await tunnel.read(exactly: 10) == Data("still here".utf8))
            }
            await tunnel.close()
            await client.close()
        }
    }

    @Test func aDownloadLargerThanTheRekeyLimitCompletes() async throws {
        try await PrivateSSHServer.run(rekeyLimit: "1M") { server in
            let local = try TemporaryDirectory()
            let contents = Data.testPattern(count: 16 * 1024 * 1024 + 17)
            try contents.write(to: server.directory.appending(path: "large.bin"))
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // A download is many requests in flight at once. One that went
            // missing would never be answered, and a flow-control update
            // that went missing would stop the server sending.
            try await Self.finishing(within: .seconds(60), on: client) {
                try await sftp.download(
                    remotePath: server.directory.path + "/large.bin", to: local.file("large.bin"))
            }
            #expect(try Data(contentsOf: local.file("large.bin")) == contents)
            #expect(server.completedKeyExchangeCount() >= 8)

            // The session is still good for more.
            #expect(try await sftp.list(server.directory.path).map(\.name) == ["large.bin"])
            await client.close()
        }
    }

    @Test func anUploadLargerThanTheRekeyLimitCompletes() async throws {
        try await PrivateSSHServer.run(rekeyLimit: "1M") { server in
            let local = try TemporaryDirectory()
            let contents = Data.testPattern(count: 16 * 1024 * 1024 + 17)
            try contents.write(to: local.file("large.bin"))
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            try await Self.finishing(within: .seconds(60), on: client) {
                try await sftp.upload(
                    localURL: local.file("large.bin"), to: server.directory.path + "/large.bin")
            }
            #expect(try Data(contentsOf: server.directory.appending(path: "large.bin")) == contents)
            #expect(server.completedKeyExchangeCount() >= 4)
            #expect(try await sftp.list(server.directory.path).map(\.name) == ["large.bin"])
            await client.close()
        }
    }
}

extension PrivateSSHServer {
    /// How many times this server has replaced the keys of a session since
    /// it started, by its own account. It only keeps that account when it
    /// was started with a `rekeyLimit`.
    func completedKeyExchangeCount() -> Int {
        // The server's log is in its scratch directory, next to the folder
        // that stands for the remote file system. It notes the moment it
        // starts using the client's new keys, which is the last step of a
        // key exchange and the one that needs the client to have done its
        // part.
        let log = directory.deletingLastPathComponent().appending(path: "sshd-\(port).log")
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(whereSeparator: \.isNewline) ?? []
        return lines.count { $0.contains("ssh_set_newkeys: rekeying in") }
    }
}

/// A relay on the loopback interface that takes its time: what one side
/// sends reaches the other after a delay, as it would over a real network.
final class SlowLink: Sendable {
    let port: Int
    private let listener: NWListener
    private let target: NWEndpoint.Port
    private let delay: DispatchTimeInterval
    private let queue = DispatchQueue(label: "SlowLink")
    private let connections = Mutex<[NWConnection]>([])

    private init(listener: NWListener, port: Int, target: NWEndpoint.Port, delay: DispatchTimeInterval) {
        self.listener = listener
        self.port = port
        self.target = target
        self.delay = delay
    }

    /// Starts a relay to the loopback port `target` that holds everything
    /// back by `delay` in each direction.
    static func start(toPort target: Int, delay: DispatchTimeInterval) async throws -> SlowLink {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let pending = Recorder<NWConnection>()

        // Connections that arrive before the relay object exists are held.
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
            listener.start(queue: DispatchQueue(label: "SlowLink.start"))
        }

        let link = SlowLink(
            listener: listener, port: port,
            target: try #require(NWEndpoint.Port(rawValue: UInt16(clamping: target))), delay: delay)
        listener.newConnectionHandler = { [weak link] connection in link?.accept(connection) }
        for connection in pending.values {
            link.accept(connection)
        }
        return link
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

    private func accept(_ near: NWConnection) {
        let far = NWConnection(host: .ipv4(.loopback), port: target, using: .tcp)
        connections.withLock { $0 += [near, far] }
        near.start(queue: queue)
        far.start(queue: queue)
        relay(from: near, to: far)
        relay(from: far, to: near)
    }

    /// Passes on one piece at a time, each after the delay, so that nothing
    /// arrives early or out of order. When either side is done, both are.
    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                source.cancel()
                destination.cancel()
                return
            }
            queue.asyncAfter(deadline: .now() + delay) {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil, !isComplete, error == nil {
                        self.relay(from: source, to: destination)
                    } else {
                        source.cancel()
                        destination.cancel()
                    }
                })
            }
        }
    }
}

#endif

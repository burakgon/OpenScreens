#if os(macOS)

import Foundation
import RFBProtocol
import RFBTransport
import Testing
@testable import OpenScreensCore

/// Sessions that go on while the server replaces their encryption keys, as
/// OpenSSH does after so much data or time (`RekeyLimit`).
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

#endif

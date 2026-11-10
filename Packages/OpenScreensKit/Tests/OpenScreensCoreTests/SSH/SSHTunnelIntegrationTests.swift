#if os(macOS)

import Foundation
import RFBProtocol
import RFBTransport
import Testing
@testable import OpenScreensCore

/// Tunnels through a private `sshd`: the byte stream the remote-desktop
/// engine runs on, and the factory that makes one per connection attempt.
extension SSHTests.SSHIntegrationTests {

    // MARK: Tunnels

    /// Reads `count` bytes with a mix of both kinds of read and of sizes
    /// from one byte up, the way a protocol parser does.
    static func read(_ count: Int, from tunnel: SSHTunnelConnection) async throws -> Data {
        let sizes = [1, 3, 12, 4096, 65_536, 1_000_003]
        var received = Data(capacity: count)
        var step = 0
        while received.count < count {
            let size = min(count - received.count, sizes[step % sizes.count])
            if step.isMultiple(of: 2) {
                let chunk = try await tunnel.read(exactly: size)
                #expect(chunk.count == size)
                received.append(chunk)
            } else {
                let chunk = try await tunnel.read(upTo: size)
                #expect((1...size).contains(chunk.count))
                received.append(chunk)
            }
            step += 1
        }
        return received
    }

    @Test func aTunnelCarriesMegabytesInBothDirectionsIntact() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            // The engine calls this on every transport it is given.
            try await tunnel.connect()

            let payload = Data.testPattern(count: 8 * 1024 * 1024 + 4321)
            async let received = Self.read(payload.count, from: tunnel)
            // Send in pieces of very different sizes while the echo is
            // being read back, as input and screen updates overlap.
            var sent = 0
            var size = 1
            while sent < payload.count {
                let end = min(sent + size, payload.count)
                try await tunnel.send(payload.subdata(in: sent..<end))
                sent = end
                size = size * 7 % 300_007 + 1
            }

            #expect(try await received == payload)
            await tunnel.close()
            await client.close()
        }
    }

    @Test func closingATunnelReleasesAPendingRead() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            let disconnects = Recorder<VNCProtocolError>()
            await tunnel.setDisconnectHandler { disconnects.record($0) }

            // Nothing was sent, so nothing will come back: this read can
            // only end by the tunnel being closed under it.
            let pending = Task { try await tunnel.read(exactly: 16) }
            try await Task.sleep(for: .milliseconds(200))
            let clock = ContinuousClock()
            let closing = clock.now
            await tunnel.close()

            await #expect(throws: VNCProtocolError.connectionClosed) { try await pending.value }
            #expect(clock.now - closing < .seconds(2))

            // Closed means closed, for every operation, again and again.
            await tunnel.close()
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.read(exactly: 1) }
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.read(upTo: 1) }
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.send(Data([1])) }
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.connect() }

            // A close that was asked for is not a disconnect to report.
            try await Task.sleep(for: .milliseconds(200))
            #expect(disconnects.values.isEmpty)

            // The SSH connection belongs to the caller here and stays up.
            #expect(client.isConnected)
            await client.close()
        }
    }

    @Test func closingATunnelReleasesAPendingSend() async throws {
        try await PrivateSSHServer.run { server in
            // The far end accepts the connection and never reads from it.
            let silent = try await LoopbackServer.start(.silent)
            defer { silent.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: silent.port)

            // Far more than every buffer between here and there can hold, so
            // the send has to wait for room that never comes. That waiting,
            // rather than piling the bytes up in memory, is the point.
            let blocked = Task { try await tunnel.send(Data(count: 64 * 1024 * 1024)) }
            try await Task.sleep(for: .milliseconds(500))
            let clock = ContinuousClock()
            let closing = clock.now
            await tunnel.close()

            await #expect(throws: VNCProtocolError.connectionClosed) { try await blocked.value }
            #expect(clock.now - closing < .seconds(2))
            await client.close()
        }
    }

    @Test func theEndOfTheStreamIsReportedAfterTheLastByte() async throws {
        try await PrivateSSHServer.run { server in
            let farewell = Data("so long, and thanks for all the fish".utf8)
            let closing = try await LoopbackServer.start(.replyThenClose(farewell))
            defer { closing.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: closing.port)
            let disconnects = Recorder<VNCProtocolError>()
            await tunnel.setDisconnectHandler { disconnects.record($0) }
            try await tunnel.send(Data("goodbye?".utf8))

            // What the far end sent before closing is still delivered…
            #expect(try await tunnel.read(exactly: 7) == farewell.prefix(7))
            #expect(try await tunnel.read(upTo: 1000) == farewell.dropFirst(7))
            // …and only then does the stream end, also for a read that
            // was hoping for more than was left.
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.read(exactly: 1) }
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.read(upTo: 10) }

            // The handler hears about it too, once.
            try await Task.sleep(for: .milliseconds(200))
            #expect(disconnects.values == [.connectionClosed])
            await tunnel.close()
            await client.close()
        }
    }

    @Test func aFarEndThatHungUpIsStillHeardOut() async throws {
        try await PrivateSSHServer.run { server in
            // A server that refuses a client often says why and closes at
            // once, before the engine has even been handed the tunnel.
            let refusal = Data("RFB 003.008\nToo many attempts".utf8)
            let closing = try await LoopbackServer.start(.sendThenClose(refusal))
            defer { closing.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: closing.port)
            try await Task.sleep(for: .milliseconds(300))

            // The tunnel is over, but not empty: connecting succeeds and
            // the message can be read.
            try await tunnel.connect()
            #expect(try await tunnel.read(exactly: refusal.count) == refusal)
            // Once it has been read there is nothing left to connect to.
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.connect() }
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.send(Data([1])) }
            await client.close()
        }
    }

    @Test func aReadCutShortByTheEndOfTheStreamFails() async throws {
        try await PrivateSSHServer.run { server in
            let closing = try await LoopbackServer.start(.sendThenClose(Data(repeating: 7, count: 10)))
            defer { closing.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: closing.port)

            // Ten bytes arrive and the stream ends: a read for twenty can
            // never be satisfied, and must say so rather than hang.
            await #expect(throws: VNCProtocolError.connectionClosed) {
                try await tunnel.read(exactly: 20)
            }
            await client.close()
        }
    }

    @Test func invalidReadSizesAreRefused() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)

            #expect(try await tunnel.read(exactly: 0).isEmpty)
            try await tunnel.send(Data())
            for invalid in [-1, SSHTunnelConnection.maximumExactReadLength + 1] {
                let error = await #expect(throws: VNCProtocolError.self) {
                    try await tunnel.read(exactly: invalid)
                }
                guard case .protocolViolation = error else {
                    Issue.record("expected .protocolViolation, got \(String(describing: error))")
                    continue
                }
            }
            let error = await #expect(throws: VNCProtocolError.self) { try await tunnel.read(upTo: 0) }
            guard case .protocolViolation = error else {
                Issue.record("expected .protocolViolation, got \(String(describing: error))")
                return
            }
            await client.close()
        }
    }

    @Test func aTunnelToAClosedPortIsRefused() async throws {
        try await PrivateSSHServer.run { server in
            let client = try await server.connect()
            let port = try PrivateSSHServer.refusingLoopbackPort()

            let error = await #expect(throws: SSHError.self) {
                try await client.openTunnel(toHost: "127.0.0.1", port: port)
            }
            guard case .channelOpenRefused = error else {
                Issue.record("expected .channelOpenRefused, got \(String(describing: error))")
                return
            }
            // One refused channel does not spoil the connection.
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            try await tunnel.send(Data("ping".utf8))
            #expect(try await tunnel.read(exactly: 4) == Data("ping".utf8))
            await client.close()
        }
    }

    @Test func aServerThatForbidsForwardingSaysSo() async throws {
        try await PrivateSSHServer.run(allowsForwarding: false) { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()

            let error = await #expect(throws: SSHError.self) {
                try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            }
            guard case .channelOpenRefused(let reason) = error else {
                Issue.record("expected .channelOpenRefused, got \(String(describing: error))")
                return
            }
            // OpenSSH's own words for this are just "open failed"; the reason
            // code is what says the server will not do it.
            #expect(reason.contains("Not permitted by the server's configuration"))
            await client.close()
        }
    }

    @Test func nothingCanBeOpenedOnAClosedConnection() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()
            await client.close()

            await #expect(throws: SSHError.closed) {
                try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            }
            await #expect(throws: SSHError.closed) { try await client.openSFTP() }
        }
    }

    @Test func aStalledReaderHoldsTheSenderBack() async throws {
        try await PrivateSSHServer.run { server in
            // The far end pushes 96 MB as fast as it is allowed to.
            let blockCount = 96
            let flood = try await LoopbackServer.start(.flood(blockCount: blockCount))
            defer { flood.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: flood.port)

            // Read nothing, and wait for the sender to come to a stop.
            var sent = -1
            var quietChecks = 0
            for _ in 0..<200 where quietChecks < 5 {
                try await Task.sleep(for: .milliseconds(100))
                let now = flood.bytesSent
                quietChecks = now == sent ? quietChecks + 1 : 0
                sent = now
            }
            try #require(quietChecks == 5, "the sender never stopped; it got \(sent) bytes away")
            // It stopped well short of everything it had: what it got
            // away is the read-ahead, one SSH window and the socket
            // buffers along the way, not the whole stream.
            #expect(sent > 0)
            #expect(sent <= 48 * 1024 * 1024)

            // Reading sets it going again, and nothing was lost or
            // reordered while it was held. The first read asks for far more
            // than the tunnel reads ahead on its own, as a raw full-screen
            // update does: a reader's request overrides the limit.
            let blockSize = LoopbackServer.floodBlockSize
            let largeReadBlocks = 24
            let large = try await tunnel.read(exactly: largeReadBlocks * blockSize)
            for index in 0..<blockCount {
                let block = index < largeReadBlocks
                    ? large.subdata(in: index * blockSize..<(index + 1) * blockSize)
                    : try await tunnel.read(exactly: blockSize)
                guard block == LoopbackServer.floodBlock(index) else {
                    Issue.record("block \(index) arrived damaged or out of place")
                    break
                }
            }
            await #expect(throws: VNCProtocolError.connectionClosed) { try await tunnel.read(upTo: 1) }
            await client.close()
        }
    }

    @Test func losingTheSSHConnectionFailsTheTunnel() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            let disconnects = Recorder<VNCProtocolError>()
            await tunnel.setDisconnectHandler { disconnects.record($0) }
            let pending = Task { try await tunnel.read(exactly: 1) }
            try await Task.sleep(for: .milliseconds(200))

            // The server side dies without a goodbye.
            server.killSessions()

            // Both the waiting read and the handler learn of it, and as a
            // failure of the transport rather than an orderly end.
            let error = await #expect(throws: VNCProtocolError.self) { try await pending.value }
            guard case .ioError = error else {
                Issue.record("expected .ioError, got \(String(describing: error))")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
            #expect(disconnects.values.count == 1)
            #expect(disconnects.values.first == error)
            await #expect(throws: VNCProtocolError.self) { try await tunnel.send(Data([1])) }
            #expect(!client.isConnected)
            await tunnel.close()
        }
    }

    // MARK: The tunnel factory

    @Test func theFactoryDialsSSHAndTunnelsToTheSameComputer() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let factory = SSHTunnelFactory(
                sshPort: server.port,
                username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: true),
                timeout: .seconds(10))

            // The engine asks for the screen sharing address. With no SSH
            // host set, that computer is also the SSH server, and the
            // tunnel ends at its loopback interface.
            let connection: any RFBConnection = try await factory.provider("127.0.0.1", UInt16(echo.port))
            try await connection.connect()
            try await connection.send(Data("through the tunnel".utf8))
            #expect(try await connection.read(exactly: 18) == Data("through the tunnel".utf8))
            #expect(await server.waitForSessionCount(1))

            // The SSH connection was made for this tunnel and goes with it.
            await connection.close()
            #expect(await server.waitForSessionCount(0))
        }
    }

    @Test func theEnginesTransportSessionShakesHandsThroughATunnel() async throws {
        try await PrivateSSHServer.run { server in
            let desktop = try await LoopbackServer.start(.remoteDesktop(name: "Test Desktop"))
            defer { desktop.stop() }
            let provider = SSHTunnelFactory(
                sshPort: server.port,
                username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: true)
            ).provider

            // The remote-desktop engine's own transport session, given the
            // tunnel in place of the TCP connection it would otherwise make.
            // It installs its disconnect handler, connects, and reads and
            // writes the handshake exactly as it does in the app.
            let session = TransportSession(
                host: "127.0.0.1",
                port: UInt16(desktop.port),
                password: "",
                connection: try await provider("127.0.0.1", UInt16(desktop.port)),
                securityPolicy: .none)
            try await session.connect()

            let handshake = await session.handshakeInfo
            #expect(handshake.negotiatedVersion == .v3_8)
            #expect(handshake.offeredSecurityTypes == [SecurityType.none])
            #expect(handshake.selectedSecurityType == SecurityType.none)
            #expect(await server.waitForSessionCount(1))

            // The session now sits in its read loop, waiting on the tunnel
            // for a message that will not come. Disconnecting has to release
            // that read, and it takes the SSH connection down with it.
            let clock = ContinuousClock()
            let started = clock.now
            await session.disconnect()
            #expect(clock.now - started < .seconds(3))
            #expect(await server.waitForSessionCount(0))
        }
    }

    @Test func everyAttemptGetsItsOwnConnection() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let provider = SSHTunnelFactory(
                sshHost: "127.0.0.1",
                sshPort: server.port,
                username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: true)
            ).provider

            // Two attempts, as on a reconnect, are independent.
            let first = try await provider("127.0.0.1", UInt16(echo.port))
            let second = try await provider("127.0.0.1", UInt16(echo.port))
            #expect(await server.waitForSessionCount(2))
            await first.close()
            #expect(await server.waitForSessionCount(1))
            try await second.send(Data([42]))
            #expect(try await second.read(exactly: 1) == Data([42]))
            await second.close()
            #expect(await server.waitForSessionCount(0))
        }
    }

    @Test func aTunnelThatIsLetGoClosesItsConnection() async throws {
        try await PrivateSSHServer.run { server in
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let factory = SSHTunnelFactory(
                sshPort: server.port,
                username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: true))

            // Dropped without close(), as an abandoned attempt would be.
            do {
                let tunnel = try await factory.makeConnection(toHost: "127.0.0.1", port: UInt16(echo.port))
                #expect(await server.waitForSessionCount(1))
                // The tunnel's last use: nothing refers to it afterwards.
                try await tunnel.send(Data([1]))
            }
            #expect(await server.waitForSessionCount(0))
        }
    }

    @Test func aTunnelThatEndsOnItsOwnClosesItsConnection() async throws {
        try await PrivateSSHServer.run { server in
            let closing = try await LoopbackServer.start(.sendThenClose(Data([9])))
            defer { closing.stop() }
            let factory = SSHTunnelFactory(
                sshPort: server.port,
                username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: true))

            // The far end closes; nobody calls close() on the tunnel, yet
            // the SSH connection does not linger while it is still held.
            let tunnel = try await factory.makeConnection(toHost: "127.0.0.1", port: UInt16(closing.port))
            #expect(await server.waitForSessionCount(0))
            await tunnel.close()
        }
    }

    @Test func aFailedTunnelDoesNotLeaveAConnectionBehind() async throws {
        try await PrivateSSHServer.run { server in
            let factory = SSHTunnelFactory(
                sshPort: server.port,
                username: server.username,
                credential: .key(server.clientKey),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: true))
            let port = try PrivateSSHServer.refusingLoopbackPort()

            let error = await #expect(throws: SSHError.self) {
                try await factory.makeConnection(toHost: "127.0.0.1", port: UInt16(port))
            }
            guard case .channelOpenRefused = error else {
                Issue.record("expected .channelOpenRefused, got \(String(describing: error))")
                return
            }
            #expect(await server.waitForSessionCount(0))
        }
    }
}

#endif

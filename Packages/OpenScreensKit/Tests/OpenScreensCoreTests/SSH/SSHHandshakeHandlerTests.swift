import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Synchronization
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// The handshake handler as swift-nio-ssh's judge of host keys, called
    /// the way swift-nio-ssh calls it: once while the connection is made, and
    /// again every time the server replaces the session's keys.
    ///
    /// A real server cannot be made to change its host key in the middle of
    /// a session, so here the handler is given the keys directly.
    @Suite("SSHHandshakeHandler", .timeLimit(.minutes(1)))
    struct SSHHandshakeHandlerTests {
        /// Counts how often something happened, from whatever thread.
        final class Counter: Sendable {
            private let count = Mutex(0)

            var value: Int {
                count.withLock { $0 }
            }

            func increment() {
                count.withLock { $0 += 1 }
            }
        }

        /// A handler in a channel of its own, as far along as a test wants.
        struct Connection {
            let channel = NIOAsyncTestingChannel()
            let knownHosts = KnownHostsStore(fileURL: nil)
            let log = SSHConnectionLog()
            /// How many times the host key policy has been asked.
            let questions = Counter()
            let handler: NIOLoopBound<SSHHandshakeHandler>

            var loop: NIOAsyncTestingEventLoop { channel.testingEventLoop }

            init() async throws {
                let questions = self.questions
                let configuration = SSHHandshakeHandler.Configuration(
                    host: "mac.example", port: 22, username: "me",
                    credential: .password("irrelevant"),
                    knownHosts: knownHosts,
                    hostKeyPolicy: { challenge in
                        questions.increment()
                        _ = try? challenge.trust()
                        return true
                    },
                    timeout: .seconds(15))
                let (channel, log) = (self.channel, self.log)
                handler = try await channel.testingEventLoop.executeInContext {
                    let handler = SSHHandshakeHandler(
                        configuration: configuration,
                        attempt: SSHConnectionAttempt(),
                        log: log,
                        eventLoop: channel.eventLoop)
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return NIOLoopBound(handler, eventLoop: channel.eventLoop)
                }
                try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).get()
            }

            /// Puts `key` to the handler as the server's host key and waits
            /// for its answer.
            func present(_ key: NIOSSHPublicKey) async throws {
                let handler = self.handler
                let loop = self.loop
                let answer = try await loop.executeInContext {
                    let promise = loop.makePromise(of: Void.self)
                    handler.value.validateHostKey(hostKey: key, validationCompletePromise: promise)
                    return promise.futureResult
                }
                try await answer.get()
            }

            /// The server lets the user in, which is what makes the
            /// connection an established one.
            func signIn() async throws {
                channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
                let handler = self.handler
                try await loop.executeInContext { handler.value.authentication }.get()
            }
        }

        static func makeHostKey() -> NIOSSHPublicKey {
            NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        }

        static func record(of key: NIOSSHPublicKey) throws -> SSHHostKey {
            try #require(SSHHostKey(openSSHPublicKey: String(openSSHPublicKey: key)))
        }

        @Test func theKeyAcceptedWhenConnectingIsAcceptedAgainWithoutAsking() async throws {
            let connection = try await Connection()
            let hostKey = Self.makeHostKey()

            try await connection.present(hostKey)
            #expect(connection.questions.value == 1)
            try await connection.signIn()

            // The server replaces the session's keys, and proves who it is
            // again each time. It is who it was: nobody needs to be asked.
            for _ in 0..<3 {
                try await connection.present(hostKey)
            }
            #expect(connection.questions.value == 1)
            #expect(connection.channel.isActive)
            #expect(connection.log.lastFailure == nil)
        }

        @Test func aDifferentKeyDuringTheSessionIsRefused() async throws {
            let connection = try await Connection()
            let hostKey = Self.makeHostKey()
            try await connection.present(hostKey)
            try await connection.signIn()

            // Whoever answers the next key exchange has another key. That is
            // not the server the user agreed to, whatever it says, and the
            // policy does not get to wave it through: it said yes to every
            // key it was shown.
            let impostor = Self.makeHostKey()
            let refusal = try SSHError.hostKeyRejected(fingerprint: Self.record(of: impostor).fingerprint)
            await #expect(throws: refusal) {
                try await connection.present(impostor)
            }
            #expect(connection.questions.value == 1)
            // What is on record for the server is still the key it had.
            #expect(try connection.knownHosts.all() == [
                KnownHostsStore.Entry(host: "mac.example", port: 22, keys: [Self.record(of: hostKey)]),
            ])

            // swift-nio-ssh reports the refusal as an error on the
            // connection, which ends it and leaves the reason for the
            // channels to give.
            connection.channel.pipeline.fireErrorCaught(refusal)
            try await connection.channel.closeFuture.get()
            #expect(!connection.channel.isActive)
            #expect(connection.log.lastFailure == refusal.errorDescription)
        }

        @Test func aKeyOfAnotherKindDuringTheSessionIsRefusedToo() async throws {
            let connection = try await Connection()
            let hostKey = Self.makeHostKey()
            try await connection.present(hostKey)
            try await connection.signIn()

            let other = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()).publicKey
            await #expect(throws: try SSHError.hostKeyRejected(fingerprint: Self.record(of: other).fingerprint)) {
                try await connection.present(other)
            }
        }
    }
}

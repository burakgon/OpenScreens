#if os(macOS)

import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// The client against a server that does what a well-behaved one does
    /// not. The server is swift-nio-ssh itself, run in this process on a
    /// loopback port.
    @Suite("SSH against a server that opens channels", .timeLimit(.minutes(1)))
    struct SSHInboundChannelTests {
        /// Lets anyone in, whatever they offer.
        final class AcceptEveryone: NIOSSHServerUserAuthenticationDelegate {
            var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .all }

            func requestReceived(
                request: NIOSSHUserAuthenticationRequest,
                responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
            ) {
                responsePromise.succeed(.success)
            }
        }

        /// How the client answered the channels the server asked for.
        final class Answers: Sendable {
            private let answers = Mutex((confirmed: 0, refusals: [NIOSSHError.ErrorType?]()))

            var confirmed: Int { answers.withLock { $0.confirmed } }
            var refusals: [NIOSSHError.ErrorType?] { answers.withLock { $0.refusals } }

            func note(_ answer: Result<any Channel, any Error>) {
                answers.withLock { answers in
                    switch answer {
                    case .success:
                        answers.confirmed += 1
                    case .failure(let error):
                        answers.refusals.append((error as? NIOSSHError)?.type)
                    }
                }
            }
        }

        @Test func channelsTheServerOpensAreRefused() async throws {
            let requested = 500
            let answers = Answers()
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
            let listener = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let server = NIOSSHHandler(
                            role: .server(.init(hostKeys: [hostKey], userAuthDelegate: AcceptEveryone())),
                            allocator: channel.allocator,
                            // The client's own channels are let through, so
                            // that it can be seen to still open them.
                            inboundChildChannelInitializer: nil)
                        try channel.pipeline.syncOperations.addHandler(server)
                        // Asked for as soon as the client has signed in, all
                        // at once. Each would be the client's to look after,
                        // with eight megabytes of room for the server to
                        // fill.
                        for _ in 0..<requested {
                            let opened = channel.eventLoop.makePromise(of: (any Channel).self)
                            opened.futureResult.whenComplete { answers.note($0) }
                            server.createChannel(opened, channelType: .session) { child, _ in
                                child.eventLoop.makeSucceededFuture(())
                            }
                        }
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(listener.localAddress?.port)

            let client = try await SSHClient.connect(
                host: "127.0.0.1", port: port, username: "anyone",
                credential: .password("anything"),
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: { _ in true },
                timeout: .seconds(10))
            let deadline = ContinuousClock.now + .seconds(20)
            while answers.confirmed + answers.refusals.count < requested, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }

            // Not one was accepted; each was turned down as a channel that
            // could not be set up, which is all the server needs to know.
            #expect(answers.confirmed == 0)
            #expect(answers.refusals == Array(repeating: .channelSetupRejected, count: requested))

            // Saying no costs the connection nothing. It is still up, and
            // the client can still open the channels it wants itself.
            #expect(client.isConnected)
            let tunnel = try await client.openTunnel(toHost: "somewhere.example", port: 5900)
            await tunnel.close()
            await client.close()
            try await listener.close()
            try await group.shutdownGracefully()
        }
    }
}

#endif

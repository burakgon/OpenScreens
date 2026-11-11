import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSHError")
    struct SSHErrorTests {
        /// The delegates swift-nio-ssh wants of a client. Neither gets as far
        /// as being asked anything here.
        final class Delegates: NIOSSHClientUserAuthenticationDelegate, NIOSSHClientServerAuthenticationDelegate {
            func nextAuthenticationType(
                availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
            ) {
                nextChallengePromise.succeed(nil)
            }

            func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
                validationCompletePromise.succeed(())
            }
        }

        /// The error swift-nio-ssh raises when a channel message carrying
        /// `contents` turns up where none belongs: here, from a server that
        /// sends one before the two sides have agreed on keys.
        static func protocolViolation(carrying contents: [UInt8]) throws -> any Error {
            let delegates = Delegates()
            let handler = NIOSSHHandler(
                role: .client(SSHClientConfiguration(
                    userAuthDelegate: delegates, serverAuthDelegate: delegates)),
                allocator: ByteBufferAllocator(),
                inboundChildChannelInitializer: nil)
            let channel = EmbeddedChannel(handler: handler)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
            try channel.writeInbound(ByteBuffer(string: "SSH-2.0-OpenSSH_10.5\r\n"))

            // SSH_MSG_CHANNEL_DATA (RFC 4254 §5.2) in a packet that is not
            // encrypted yet (RFC 4253 §6).
            var message = ByteBuffer()
            message.writeInteger(UInt8(94))
            message.writeInteger(UInt32(0))
            message.writeInteger(UInt32(contents.count))
            message.writeBytes(contents)
            var padding = 8 - (5 + message.readableBytes) % 8
            if padding < 4 { padding += 8 }
            var packet = ByteBuffer()
            packet.writeInteger(UInt32(1 + message.readableBytes + padding))
            packet.writeInteger(UInt8(padding))
            packet.writeImmutableBuffer(message)
            packet.writeRepeatingByte(0, count: padding)

            do {
                try channel.writeInbound(packet)
            } catch {
                return error
            }
            throw NoViolation()
        }

        struct NoViolation: Error {}

        @Test func theContentsOfAMessageStayOutOfAnErrorsDescription() throws {
            // What travels in a channel is the user's: a piece of a file,
            // the picture of their screen, what they type.
            let contents = [UInt8]("typed by the user".utf8)
            let error = try Self.protocolViolation(carrying: contents)
            // swift-nio-ssh says which message was out of place by printing
            // the whole of it.
            let hex = contents.map { String(format: "%02x", $0) }.joined()
            try #require((error as? NIOSSHError)?.type == .protocolViolation)
            try #require(String(describing: error).contains(hex))

            // What this module reports, to the user and wherever errors are
            // written down, names the message and stops there.
            let described = SSHError.describe(error)
            #expect(!described.contains(hex))
            #expect(described.hasPrefix("NIOSSHError.protocolViolation: "))
            #expect(described.contains("channelData"))
            guard case .connectionFailed(let reason) = SSHError.translatingConnectFailure(error) as? SSHError else {
                Issue.record("expected .connectionFailed")
                return
            }
            #expect(reason == described)
        }

        @Test func otherErrorsAreDescribedInFull() {
            // Only that one kind of error is cut short. What another error
            // has to say in parentheses is its own business.
            struct Plain: Error, CustomStringConvertible {
                var description: String { "plain (with a remark)" }
            }
            #expect(SSHError.describe(Plain()).hasPrefix("plain (with a remark)"))
            #expect(SSHError.describe(SSHError.timeout) == "The SSH server did not respond in time.")
        }
    }
}

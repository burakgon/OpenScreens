import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// The gate on its own, in a pipeline with a stand-in for swift-nio-ssh
    /// behind it. Each test runs on one thread from start to finish, which is
    /// what the embedded channel asks for.
    @Suite("SSHKeyExchangeGate")
    struct SSHKeyExchangeGateTests {
        /// Stands where `NIOSSHHandler` does and notes what reaches it.
        final class Downstream: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            enum Event: Equatable {
                case read
                case readComplete
                case error(String)
                case inactive
            }

            private(set) var events: [Event] = []
            /// What to do when data arrives, as swift-nio-ssh does things
            /// while it works through what it received.
            var whenReading: ((ChannelHandlerContext) -> Void)?

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                events.append(.read)
                whenReading?(context)
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                events.append(.readComplete)
            }

            func errorCaught(context: ChannelHandlerContext, error: any Error) {
                events.append(.error(String(describing: error)))
            }

            func channelInactive(context: ChannelHandlerContext) {
                events.append(.inactive)
            }
        }

        let gate = SSHKeyExchangeGate(timeout: .seconds(15))
        let downstream = Downstream()
        let channel: EmbeddedChannel

        init() throws {
            channel = EmbeddedChannel(handlers: [gate, downstream])
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        }

        /// Asks the gate for operations that only record their names.
        private func ask(for names: String..., into log: Log) {
            for name in names {
                gate.perform { log.entries.append(name) }
            }
        }

        final class Log {
            var entries: [String] = []
        }

        /// What had reached the stand-in when an operation got its turn.
        final class Snapshot {
            var events: [Downstream.Event]?
        }

        // MARK: Operations

        @Test func withNoKeyExchangeUnderWayOperationsRunAtOnce() {
            let log = Log()
            ask(for: "read", "write", into: log)
            #expect(log.entries == ["read", "write"])
        }

        @Test func operationsWaitForTheNewKeysAndKeepTheirOrder() {
            let log = Log()
            gate.keyExchangeBegan()
            ask(for: "first", "second", into: log)
            #expect(log.entries.isEmpty)

            // The announcement of the new keys is still being written when
            // the gate hears of it, so nothing moves yet, and what is asked
            // for at this point queues behind what is already waiting.
            gate.newKeysSent()
            ask(for: "third", into: log)
            #expect(log.entries.isEmpty)

            channel.embeddedEventLoop.run()
            #expect(log.entries == ["first", "second", "third"])
            // After that the gate is open again.
            ask(for: "fourth", into: log)
            #expect(log.entries == ["first", "second", "third", "fourth"])
        }

        @Test func anOperationAskedForByOneThatWaitedGoesAfterTheOthersThatWaited() {
            let log = Log()
            gate.keyExchangeBegan()
            gate.perform {
                log.entries.append("first")
                // Asked for while "second" has yet to have its turn.
                self.gate.perform { log.entries.append("asked for by first") }
            }
            ask(for: "second", into: log)

            gate.newKeysSent()
            channel.embeddedEventLoop.run()
            #expect(log.entries == ["first", "second", "asked for by first"])
        }

        @Test func aKeyExchangeRightAfterAnotherKeepsEverythingWaiting() {
            let log = Log()
            gate.keyExchangeBegan()
            ask(for: "first", into: log)
            // The server sends what it had queued and at once asks for new
            // keys again, all of it arriving together: the second exchange
            // begins before what waited through the first has moved.
            gate.newKeysSent()
            gate.keyExchangeBegan()
            channel.embeddedEventLoop.run()
            #expect(log.entries.isEmpty)

            ask(for: "second", into: log)
            gate.newKeysSent()
            channel.embeddedEventLoop.run()
            #expect(log.entries == ["first", "second"])
        }

        // MARK: Received data

        @Test func theEndOfABatchWaitsForTheNewKeysAndTheOfferIsSent() throws {
            let offer = ByteBuffer(string: "key exchange offer")
            // swift-nio-ssh answers the server's offer with its own while it
            // works through the data, and leaves sending it to the end of
            // the batch.
            downstream.whenReading = { context in
                self.gate.keyExchangeBegan()
                context.write(NIOAny(offer), promise: nil)
            }
            try channel.writeInbound(ByteBuffer(string: "data and the server's offer"))

            // The end of the batch is when channels would act on their own.
            #expect(downstream.events == [.read])
            // The offer could not wait for that, and has gone.
            #expect(try channel.readOutbound(as: ByteBuffer.self) == offer)

            downstream.whenReading = { _ in self.gate.newKeysSent() }
            try channel.writeInbound(ByteBuffer(string: "the server's new keys"))
            #expect(downstream.events == [.read, .read])
            channel.embeddedEventLoop.run()
            // One end of batch stands for the two that were kept back.
            #expect(downstream.events == [.read, .read, .readComplete])

            // Without a key exchange a batch ends when it ends.
            downstream.whenReading = nil
            try channel.writeInbound(ByteBuffer(string: "more data"))
            #expect(downstream.events == [.read, .read, .readComplete, .read, .readComplete])
        }

        @Test func theEndOfABatchComesBeforeWhatTheChannelsAskedFor() throws {
            let snapshot = Snapshot()
            downstream.whenReading = { _ in self.gate.keyExchangeBegan() }
            try channel.writeInbound(ByteBuffer(string: "the server's offer"))
            gate.perform { snapshot.events = self.downstream.events }

            gate.newKeysSent()
            channel.embeddedEventLoop.run()
            // It was due first.
            #expect(snapshot.events == [.read, .readComplete])
        }

        // MARK: Giving up

        @Test func aKeyExchangeThatOutlastsTheAllowanceEndsTheConnection() {
            let log = Log()
            gate.keyExchangeBegan()
            ask(for: "waiting", into: log)

            channel.embeddedEventLoop.advanceTime(by: .seconds(14))
            #expect(downstream.events.isEmpty)
            channel.embeddedEventLoop.advanceTime(by: .seconds(2))
            // The handshake handler closes the connection on an error like
            // this one; that is what lets go of what waited.
            #expect(downstream.events == [.error(String(describing: SSHError.timeout))])
            #expect(log.entries.isEmpty)
        }

        @Test func theAllowanceIsNotSpentAcrossSeparateKeyExchanges() {
            for _ in 0..<3 {
                gate.keyExchangeBegan()
                channel.embeddedEventLoop.advanceTime(by: .seconds(10))
                gate.newKeysSent()
                channel.embeddedEventLoop.run()
            }
            channel.embeddedEventLoop.advanceTime(by: .seconds(60))
            #expect(downstream.events.isEmpty)
        }

        @Test func whatWaitedIsLetGoWhenTheConnectionEnds() throws {
            let log = Log()
            downstream.whenReading = { _ in self.gate.keyExchangeBegan() }
            try channel.writeInbound(ByteBuffer(string: "the server's offer"))
            ask(for: "first", "second", into: log)
            #expect(log.entries.isEmpty)

            // The operations run, to find their channels closed and say so.
            // The connection going away is passed on first, so that they do,
            // and the batch that was kept back never ends.
            let snapshot = Snapshot()
            gate.perform { snapshot.events = self.downstream.events }
            try channel.close().wait()
            #expect(log.entries == ["first", "second"])
            #expect(snapshot.events == [.read, .inactive])
            #expect(downstream.events == [.read, .inactive])
            // Nothing is held on a connection that is gone.
            ask(for: "afterwards", into: log)
            #expect(log.entries == ["first", "second", "afterwards"])
        }
    }

    /// The packet protection the client asks swift-nio-ssh to use.
    @Suite("SSHWatchedTransportProtection")
    struct SSHWatchedTransportProtectionTests {
        typealias Watched = SSHWatchedTransportProtection<SSHCipher.AES256GCM>

        /// The keys of one end of a session and, mirrored, of the other.
        static func keys() -> (client: NIOSSHSessionKeys, server: NIOSSHSessionKeys) {
            let toServer = (iv: [UInt8](1...12), key: SymmetricKey(size: .bits256))
            let toClient = (iv: [UInt8](101...112), key: SymmetricKey(size: .bits256))
            let unused = SymmetricKey(size: .bits128)
            let client = NIOSSHSessionKeys(
                initialInboundIV: toClient.iv, initialOutboundIV: toServer.iv,
                inboundEncryptionKey: toClient.key, outboundEncryptionKey: toServer.key,
                inboundMACKey: unused, outboundMACKey: unused)
            let server = NIOSSHSessionKeys(
                initialInboundIV: toServer.iv, initialOutboundIV: toClient.iv,
                inboundEncryptionKey: toServer.key, outboundEncryptionKey: toClient.key,
                inboundMACKey: unused, outboundMACKey: unused)
            return (client, server)
        }

        /// An SSH packet as it is handed over for encryption (RFC 4253 §6):
        /// its length, the length of its padding, the message, the padding.
        static func packet(type: UInt8, body: [UInt8] = []) -> ByteBuffer {
            let message = [type] + body
            var padding = 16 - (1 + message.count) % 16
            if padding < 4 { padding += 16 }
            var buffer = ByteBuffer()
            buffer.writeInteger(UInt32(1 + message.count + padding))
            buffer.writeInteger(UInt8(padding))
            buffer.writeBytes(message)
            buffer.writeRepeatingByte(0, count: padding)
            return buffer
        }

        /// What `receiver` makes of a packet protected by `sender`.
        static func message(
            in packet: ByteBuffer,
            from sender: any NIOSSHTransportProtection,
            to receiver: any NIOSSHTransportProtection
        ) throws -> [UInt8] {
            var packet = packet
            try sender.encryptPacket(&packet, sequenceNumber: 0)
            try receiver.decryptFirstBlock(&packet)
            let message = try receiver.decryptAndVerifyRemainingPacket(&packet, sequenceNumber: 0)
            return [UInt8](message.readableBytesView)
        }

        /// What a server and the rest of swift-nio-ssh get to know about a
        /// scheme.
        struct Parameters: Equatable {
            var cipherName: String
            var macName: String?
            var cipherBlockSize: Int
            var keySizes: ExpectedKeySizes

            init(of scheme: any NIOSSHTransportProtection.Type) {
                cipherName = scheme.cipherName
                macName = scheme.macName
                cipherBlockSize = scheme.cipherBlockSize
                keySizes = scheme.keySizes
            }
        }

        @Test func theCiphersOnOfferAreSwiftNIOSSHsOwn() {
            let offered = SSHKeyExchangeGate.transportProtectionSchemes
            let bundled = Constants.bundledTransportProtectionSchemes
            // Every one of them, in its order of preference, under the same
            // names and with the same parameters…
            let ours = offered.map { Parameters(of: $0) }
            #expect(ours == bundled.map { Parameters(of: $0) })
            #expect(ours.map(\.cipherName) == ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"])
            // …and none of them offered as it comes.
            let identities = Set(bundled.map { ObjectIdentifier($0 as Any.Type) })
            #expect(offered.allSatisfy { !identities.contains(ObjectIdentifier($0 as Any.Type)) })
        }

        @Test func packetsAreProtectedExactlyAsWithoutIt() throws {
            let bundled = try #require(Constants.bundledTransportProtectionSchemes.first {
                $0.cipherName == Watched.cipherName
            })
            let keys = Self.keys()
            let client = try Watched(initialKeys: keys.client)
            let server = try bundled.init(initialKeys: keys.server)
            #expect(client.macBytes == server.macBytes)
            #expect(client.lengthEncrypted == server.lengthEncrypted)

            // Several packets each way: the two ends count them, and stay in
            // step only if nothing is added or left out.
            for round in UInt8(0)..<4 {
                let outgoing = [94, round] + [UInt8](repeating: round, count: 200 * Int(round))
                #expect(try Self.message(
                    in: Self.packet(type: outgoing[0], body: Array(outgoing.dropFirst())),
                    from: client, to: server) == outgoing)
                let incoming = [95, round, 7, 7, 7]
                #expect(try Self.message(
                    in: Self.packet(type: incoming[0], body: Array(incoming.dropFirst())),
                    from: server, to: client) == incoming)
            }
        }

        @Test func theOfferAndTheNewKeysAreReportedToTheConnectionsGate() throws {
            let gate = SSHKeyExchangeGate(timeout: .seconds(15))
            let channel = EmbeddedChannel(handler: gate)
            let log = SSHKeyExchangeGateTests.Log()
            // swift-nio-ssh makes the protection while it works through what
            // the connection received, which is how it finds its gate.
            let protection = try SSHKeyExchangeGate.$receiving.withValue(
                NIOLoopBound(gate, eventLoop: channel.eventLoop)
            ) {
                try Watched(initialKeys: Self.keys().client)
            }

            // Channel data and the like say nothing about keys.
            for type in [UInt8(2), 80, 90, 93, 94, 96, 97, 98] {
                var packet = Self.packet(type: type, body: [20, 21])
                try protection.encryptPacket(&packet, sequenceNumber: 0)
            }
            gate.perform { log.entries.append("before") }
            #expect(log.entries == ["before"])

            // SSH_MSG_KEXINIT: from here on channels have to wait.
            var offer = Self.packet(type: 20, body: [UInt8](repeating: 0, count: 60))
            try protection.encryptPacket(&offer, sequenceNumber: 0)
            gate.perform { log.entries.append("during") }
            #expect(log.entries == ["before"])

            // SSH_MSG_NEWKEYS: and from here on they need not.
            var newKeys = Self.packet(type: 21)
            try protection.encryptPacket(&newKeys, sequenceNumber: 0)
            channel.embeddedEventLoop.run()
            #expect(log.entries == ["before", "during"])
        }

        @Test func aProtectionReportsToTheConnectionItWasMadeFor() throws {
            let gate = SSHKeyExchangeGate(timeout: .seconds(15))
            let other = SSHKeyExchangeGate(timeout: .seconds(15))
            let channel = EmbeddedChannel(handlers: [gate, other])
            let log = SSHKeyExchangeGateTests.Log()
            let protection = try SSHKeyExchangeGate.$receiving.withValue(
                NIOLoopBound(gate, eventLoop: channel.eventLoop)
            ) {
                try Watched(initialKeys: Self.keys().client)
            }

            // Its offer goes out while another connection on the same thread
            // is the one receiving.
            try SSHKeyExchangeGate.$receiving.withValue(
                NIOLoopBound(other, eventLoop: channel.eventLoop)
            ) {
                var offer = Self.packet(type: 20)
                try protection.encryptPacket(&offer, sequenceNumber: 0)
            }
            gate.perform { log.entries.append("its own connection") }
            other.perform { log.entries.append("the other connection") }
            #expect(log.entries == ["the other connection"])
        }
    }
}

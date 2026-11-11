import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Synchronization
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// A channel stream on a stand-in for its SSH channel, next to the gate
    /// of a stand-in for its connection. What is checked here is what the
    /// stream asks of the channel, and when.
    @Suite("SSHChannelStream", .timeLimit(.minutes(1)))
    struct SSHChannelStreamTests {
        struct WriteRefused: Error {}

        /// What the stream has asked of its channel so far.
        final class Requests: Sendable {
            private let counts = Mutex((reads: 0, closes: 0))

            var reads: Int { counts.withLock { $0.reads } }
            var closes: Int { counts.withLock { $0.closes } }

            func noteRead() { counts.withLock { $0.reads += 1 } }
            func noteClose() { counts.withLock { $0.closes += 1 } }
        }

        /// The last handler before the network: notes requests, and turns
        /// writes away when told to.
        final class ChannelEnd: ChannelOutboundHandler {
            typealias OutboundIn = SSHChannelData
            typealias OutboundOut = SSHChannelData

            let requests: Requests
            let refusesWrites: Bool

            init(requests: Requests, refusesWrites: Bool) {
                self.requests = requests
                self.refusesWrites = refusesWrites
            }

            func read(context: ChannelHandlerContext) {
                requests.noteRead()
                context.read()
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                if refusesWrites {
                    promise?.fail(WriteRefused())
                } else {
                    context.write(data, promise: promise)
                }
            }

            func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                requests.noteClose()
                context.close(mode: mode, promise: promise)
            }
        }

        /// Closes a stream that a test is still waiting on after ten seconds.
        /// Nothing here takes that long, and neither a read nor a write on a
        /// stream gives up by itself: this way a test that would wait for
        /// ever fails instead.
        final class Watchdog: Sendable {
            private let task: Task<Void, Never>

            init(over stream: SSHChannelStream) {
                task = Task {
                    guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
                    Issue.record("Still waiting on the stream after ten seconds. It is being closed.")
                    stream.close()
                }
            }

            deinit {
                task.cancel()
            }
        }

        struct Fixture {
            let loop = NIOAsyncTestingEventLoop()
            /// Stands for the SSH connection; all it holds is the gate.
            let connection: NIOAsyncTestingChannel
            /// Stands for the SSH channel the stream runs on.
            let channel: NIOAsyncTestingChannel
            let gate: NIOLoopBound<SSHKeyExchangeGate>
            let stream: SSHChannelStream
            let requests = Requests()
            private let watchdog: Watchdog

            init(refusingWrites: Bool = false) async throws {
                let (connection, channel) = (
                    NIOAsyncTestingChannel(loop: loop), NIOAsyncTestingChannel(loop: loop))
                self.connection = connection
                self.channel = channel
                let (loop, requests) = (self.loop, self.requests)
                gate = try await loop.executeInContext {
                    let gate = SSHKeyExchangeGate(timeout: .seconds(15))
                    try connection.pipeline.syncOperations.addHandler(gate)
                    try channel.pipeline.syncOperations.addHandler(
                        ChannelEnd(requests: requests, refusesWrites: refusingWrites))
                    return NIOLoopBound(gate, eventLoop: loop)
                }
                let address = try SocketAddress(ipAddress: "127.0.0.1", port: 22)
                try await connection.connect(to: address).get()
                try await channel.connect(to: address).get()
                stream = SSHChannelStream(channel: channel, gate: gate, connectionLog: SSHConnectionLog())
                watchdog = Watchdog(over: stream)
            }

            func beginKeyExchange() async throws {
                let gate = self.gate
                try await loop.executeInContext { gate.value.keyExchangeBegan() }
            }

            func finishKeyExchange() async throws {
                let gate = self.gate
                try await loop.executeInContext { gate.value.newKeysSent() }
                await loop.run()
            }

            /// Time for something asked of the stream on another task to
            /// have reached the channel, if it was ever going to.
            func settle() async throws {
                try await Task.sleep(for: .milliseconds(100))
                await loop.run()
            }

            func writtenBytes() async throws -> String? {
                guard let message = try await channel.readOutbound(as: SSHChannelData.self),
                      case .byteBuffer(let bytes) = message.data else { return nil }
                return String(buffer: bytes)
            }
        }

        // MARK: Writes that fail

        @Test func aQueuedWriteThatCannotBeMadeEndsTheStream() async throws {
            let fixture = try await Fixture(refusingWrites: true)
            let ends = Recorder()
            fixture.stream.setEndObserver { ends.record($0) }

            // Nobody waits to hear how a queued write went. A file transfer
            // session queues a request this way and then waits for a reply.
            fixture.stream.enqueue(ByteBuffer(string: "a request"))

            // The reply would never come, because the request never left.
            // What comes instead is the end of the stream, with the reason.
            let error = await #expect(throws: SSHChannelStreamError.self) {
                try await fixture.stream.read(exactly: 1)
            }
            guard case .failed(let reason) = error else {
                Issue.record("expected .failed, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("WriteRefused"))
            #expect(fixture.stream.endedReason == error)
            #expect(ends.values == [.failed(reason)])
            // A stream with a hole in it is no use to either side.
            try await fixture.channel.closeFuture.get()
            #expect(fixture.requests.closes == 1)
        }

        // MARK: While keys are exchanged

        @Test func aWriteWaitsForTheKeyExchangeAndThenGoes() async throws {
            let fixture = try await Fixture()
            try await fixture.stream.send(ByteBuffer(string: "before"))
            #expect(try await fixture.writtenBytes() == "before")

            try await fixture.beginKeyExchange()
            let sent = Task { try await fixture.stream.send(ByteBuffer(string: "waited")) }
            try await fixture.settle()
            fixture.stream.enqueue(ByteBuffer(string: "queued behind it"))
            try await fixture.settle()
            #expect(try await fixture.writtenBytes() == nil)

            try await fixture.finishKeyExchange()
            try await sent.value
            #expect(try await fixture.writtenBytes() == "waited")
            #expect(try await fixture.writtenBytes() == "queued behind it")
        }

        @Test func readingWaitsForTheKeyExchangeToo() async throws {
            let fixture = try await Fixture()
            try await fixture.beginKeyExchange()

            // Taking delivery of data is what makes a channel tell the
            // server it may send more, and that is a message like any other.
            let reading = Task { try await fixture.stream.read(upTo: 16) }
            try await fixture.settle()
            #expect(fixture.requests.reads == 0)

            try await fixture.finishKeyExchange()
            #expect(fixture.requests.reads == 1)
            fixture.stream.channelDidReceive(ByteBuffer(string: "data"))
            #expect(try await reading.value.makeData() == Data("data".utf8))
        }

        @Test func whatIsStillWaitingWhenTheStreamIsClosedIsNeverSent() async throws {
            let fixture = try await Fixture()
            try await fixture.beginKeyExchange()
            let sent = Task { try await fixture.stream.send(ByteBuffer(string: "never sent")) }
            fixture.stream.enqueue(ByteBuffer(string: "nor this"))
            try await fixture.settle()

            // Closing does not wait for anything: the sender hears at once.
            fixture.stream.close()
            await #expect(throws: SSHChannelStreamError.closed) { try await sent.value }
            // Telling the server waits its turn like everything else.
            try await fixture.settle()
            #expect(fixture.requests.closes == 0)

            try await fixture.finishKeyExchange()
            #expect(fixture.requests.closes == 1)
            #expect(try await fixture.writtenBytes() == nil)
        }
    }
}

extension SSHTests.SSHChannelStreamTests {
    /// The reasons a stream's end observer was given, in order.
    final class Recorder: Sendable {
        private let recorded = Mutex<[SSHChannelStreamError]>([])

        var values: [SSHChannelStreamError] {
            recorded.withLock { $0 }
        }

        func record(_ reason: SSHChannelStreamError) {
            recorded.withLock { $0.append(reason) }
        }
    }
}

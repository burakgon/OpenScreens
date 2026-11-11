import Foundation
import NIOCore
import NIOSSH
import Synchronization

/// Why a channel stream stopped.
enum SSHChannelStreamError: Error, Equatable, Sendable {
    /// The channel is closed: the peer ended it, or `close()` was called.
    case closed
    /// The channel, or the SSH connection carrying it, failed.
    case failed(String)
}

/// Bytes received on a channel and not yet read.
///
/// They are kept as the chunks they arrived in, so nothing is copied until a
/// reader takes it away, and then only once.
struct SSHInboundBuffer: Sendable {
    private var chunks = CircularBuffer<ByteBuffer>()

    /// The number of bytes waiting.
    private(set) var count = 0

    mutating func append(_ chunk: ByteBuffer) {
        guard chunk.readableBytes > 0 else { return }
        chunks.append(chunk)
        count += chunk.readableBytes
    }

    mutating func removeAll() {
        chunks.removeAll()
        count = 0
    }

    /// Removes the first `length` bytes.
    /// - Precondition: `length` is between zero and ``count``.
    mutating func take(_ length: Int) -> Taken {
        precondition((0...count).contains(length), "cannot take more bytes than are buffered")
        var taken = Taken()
        while taken.count < length, var chunk = chunks.popFirst() {
            let size = min(length - taken.count, chunk.readableBytes)
            guard let piece = chunk.readSlice(length: size) else { break }
            taken.append(piece)
            // What is left of a chunk that was only partly needed goes back
            // to the front of the queue.
            if chunk.readableBytes > 0 {
                chunks.prepend(chunk)
            }
        }
        count -= taken.count
        return taken
    }

    /// Bytes removed from the buffer, still in the pieces they arrived in.
    struct Taken: Sendable {
        // Nearly every read is served from a single chunk, so that case is
        // kept out of the array and costs no allocation.
        private var first: ByteBuffer?
        private var rest: [ByteBuffer] = []

        private(set) var count = 0

        fileprivate mutating func append(_ piece: ByteBuffer) {
            if first == nil {
                first = piece
            } else {
                rest.append(piece)
            }
            count += piece.readableBytes
        }

        /// The bytes as `Data`, copied exactly once.
        func makeData() -> Data {
            var data = Data(capacity: count)
            if let first {
                Self.append(first, to: &data)
            }
            for piece in rest {
                Self.append(piece, to: &data)
            }
            return data
        }

        private static func append(_ piece: ByteBuffer, to data: inout Data) {
            piece.withUnsafeReadableBytes { data.append($0.bindMemory(to: UInt8.self)) }
        }

        /// The bytes as one buffer: the received slice itself when they
        /// arrived together, a copy when they have to be joined.
        func makeBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
            guard let first else { return allocator.buffer(capacity: 0) }
            guard !rest.isEmpty else { return first }
            var buffer = allocator.buffer(capacity: count)
            buffer.writeImmutableBuffer(first)
            for piece in rest {
                buffer.writeImmutableBuffer(piece)
            }
            return buffer
        }
    }
}

/// Remembers why an SSH connection ended, so the channels multiplexed over
/// it can say more than "the transport went away".
final class SSHConnectionLog: Sendable {
    private let failure = Mutex<String?>(nil)

    /// The first transport or protocol error seen on the connection.
    var lastFailure: String? {
        failure.withLock { $0 }
    }

    func record(_ description: String) {
        failure.withLock { $0 = $0 ?? description }
    }
}

/// A buffered byte stream over one SSH channel: the common ground under the
/// screen sharing tunnel and the SFTP session.
///
/// **Threads.** The channel's event loop feeds the stream through
/// ``SSHChannelStreamHandler``; readers and writers call in from any task.
/// The two sides meet in one mutex-protected state, so a read that can be
/// served from memory never leaves the caller's thread. That matters to RFB,
/// which reads its stream a few bytes at a time.
///
/// **Back-pressure, inbound.** The channel does not read on its own. The
/// stream asks it for data only while fewer than ``readAheadLimit`` bytes are
/// waiting, or while a reader wants more than that. When it stops asking,
/// swift-nio-ssh stops extending the peer's flow-control window, and once the
/// window is used up the server has to stop sending. A consumer that stalls
/// therefore leaves a bounded amount waiting in this process, the read-ahead
/// plus one window (8 MiB as swift-nio-ssh sizes it), instead of everything
/// the server can produce.
///
/// **Back-pressure, outbound.** ``send(_:)`` returns when the bytes have been
/// handed to the network, which swift-nio-ssh only does as the peer's window
/// allows.
///
/// There is one reader at a time. A second concurrent read is refused.
final class SSHChannelStream: Sendable {
    /// How many unread bytes may wait in user space before the stream stops
    /// asking the channel for more.
    static let readAheadLimit = 4 * 1024 * 1024

    let channel: any Channel
    private let gate: NIOLoopBound<SSHKeyExchangeGate>
    private let connectionLog: SSHConnectionLog
    private let state = Mutex(State())

    private struct Waiter: Sendable {
        /// The reader goes back to sleep unless this many bytes are buffered.
        let demand: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// A sender waiting to hear how its write went: `nil` for success.
    private typealias SendWaiter = CheckedContinuation<SSHChannelStreamError?, Never>

    private struct State: Sendable {
        var inbound = SSHInboundBuffer()
        /// The reader that is suspended until more bytes arrive.
        var waiter: Waiter?
        /// A `channel.read()` has been issued and its batch has not ended.
        var isReading = false
        /// Senders whose bytes have not left yet, each under its own number.
        var sendWaiters: [UInt64: SendWaiter] = [:]
        var lastSendNumber: UInt64 = 0
        /// Why the channel ended, once it has, for any reason but `close()`.
        var ending: SSHChannelStreamError?
        var isClosedLocally = false
        var endObserver: (@Sendable (SSHChannelStreamError) -> Void)?

        /// Why nothing more can be sent, or `nil` while it can.
        var endedReason: SSHChannelStreamError? {
            isClosedLocally ? .closed : ending
        }

        /// Decides whether the channel should be asked for more data, and
        /// records the request so that it is made only once.
        mutating func claimRead() -> Bool {
            guard !isReading, !isClosedLocally, ending == nil else { return false }
            let waiterNeedsMore = waiter.map { $0.demand > inbound.count } ?? false
            guard waiterNeedsMore || inbound.count < SSHChannelStream.readAheadLimit else {
                return false
            }
            isReading = true
            return true
        }

        mutating func takeWaiter() -> CheckedContinuation<Void, Never>? {
            defer { waiter = nil }
            return waiter?.continuation
        }

        mutating func takeSendWaiters() -> [SendWaiter] {
            defer { sendWaiters.removeAll() }
            return Array(sendWaiters.values)
        }
    }

    init(
        channel: any Channel,
        gate: NIOLoopBound<SSHKeyExchangeGate>,
        connectionLog: SSHConnectionLog
    ) {
        self.channel = channel
        self.gate = gate
        self.connectionLog = connectionLog
    }

    /// Does something that makes the channel send: on its event loop, in
    /// the order asked, and not while the connection's keys are being
    /// replaced (see ``SSHKeyExchangeGate``).
    private func perform(_ operation: @escaping @Sendable () -> Void) {
        let gate = self.gate
        channel.eventLoop.execute {
            gate.value.perform(operation)
        }
    }

    /// Asks the channel for the next batch of received data.
    private func startReading() {
        let channel = self.channel
        perform {
            channel.read()
        }
    }

    // MARK: Reading

    /// Removes exactly `count` bytes from the stream, waiting for them to
    /// arrive. Throws `.closed` if the stream ends first, even when part of
    /// the request had already arrived.
    func read(exactly count: Int) async throws(SSHChannelStreamError) -> SSHInboundBuffer.Taken {
        try await take(atLeast: count, atMost: count)
    }

    /// Removes between one and `limit` bytes, waiting only when none are
    /// buffered.
    func read(upTo limit: Int) async throws(SSHChannelStreamError) -> SSHInboundBuffer.Taken {
        try await take(atLeast: 1, atMost: limit)
    }

    private enum Step: Sendable {
        case taken(SSHInboundBuffer.Taken, resumeReading: Bool)
        case failed(SSHChannelStreamError)
        case wait
    }

    private func take(
        atLeast minimum: Int,
        atMost maximum: Int
    ) async throws(SSHChannelStreamError) -> SSHInboundBuffer.Taken {
        while true {
            let step: Step = state.withLock { state in
                if state.isClosedLocally {
                    return .failed(.closed)
                }
                if state.waiter != nil {
                    return .failed(.failed("Another read is already waiting on this channel."))
                }
                // Buffered bytes are served before the end of the stream is
                // reported: what the peer sent before closing is still data.
                if state.inbound.count >= minimum {
                    let taken = state.inbound.take(min(maximum, state.inbound.count))
                    return .taken(taken, resumeReading: state.claimRead())
                }
                if let ending = state.ending {
                    return .failed(ending)
                }
                return .wait
            }
            switch step {
            case .taken(let taken, let resumeReading):
                if resumeReading {
                    startReading()
                }
                return taken
            case .failed(let error):
                throw error
            case .wait:
                await waitForInbound(atLeast: minimum)
            }
        }
    }

    /// Suspends until `demand` bytes are buffered or the stream is over. May
    /// return early; the caller looks at the state again either way.
    private func waitForInbound(atLeast demand: Int) async {
        enum Action {
            case resume
            case wait
            case startReading
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let action: Action = state.withLock { state in
                // The state may have moved on since the caller looked.
                if state.isClosedLocally || state.ending != nil
                    || state.inbound.count >= demand || state.waiter != nil {
                    return .resume
                }
                state.waiter = Waiter(demand: demand, continuation: continuation)
                return state.claimRead() ? .startReading : .wait
            }
            switch action {
            case .resume:
                continuation.resume()
            case .startReading:
                startReading()
            case .wait:
                break
            }
        }
    }

    // MARK: Writing

    /// Sends `bytes` and returns once they have left for the network. While
    /// the peer's flow-control window is full, that is where this waits.
    ///
    /// The wait also ends, with an error, when the stream does. That is not
    /// left to the channel: a channel that is closed while a write is held up
    /// keeps the write until the peer confirms the close, and a peer that is
    /// itself stuck (OpenSSH first drains what it holds for the far end) may
    /// never do so.
    func send(_ bytes: ByteBuffer) async throws(SSHChannelStreamError) {
        let failure: SSHChannelStreamError? = await withCheckedContinuation { continuation in
            let number: UInt64? = state.withLock { state in
                guard state.endedReason == nil else { return nil }
                state.lastSendNumber &+= 1
                state.sendWaiters[state.lastSendNumber] = continuation
                return state.lastSendNumber
            }
            guard let number else {
                continuation.resume(returning: endedReason ?? .closed)
                return
            }
            let channel = self.channel
            perform {
                // A stream that ended while the bytes were waiting their turn
                // has told the sender so already, and sends nothing more.
                guard self.state.withLock({ $0.sendWaiters[number] != nil }) else { return }
                channel.writeAndFlush(Self.message(bytes)).whenComplete { result in
                    // Whoever takes the waiter out answers it: this, or the
                    // end of the stream if that came first.
                    guard let waiter = self.state.withLock({ $0.sendWaiters.removeValue(forKey: number) })
                    else { return }
                    switch result {
                    case .success:
                        waiter.resume(returning: nil)
                    case .failure(let error):
                        waiter.resume(returning: self.endedReason ?? self.failure(for: error))
                    }
                }
            }
        }
        if let failure {
            throw failure
        }
    }

    /// Queues `bytes` without waiting for them to leave. For callers that
    /// bound their own outstanding data, as SFTP's request pipeline does; a
    /// failure shows up as the end of the stream.
    func enqueue(_ bytes: ByteBuffer) {
        let channel = self.channel
        perform {
            guard self.endedReason == nil else { return }
            channel.writeAndFlush(Self.message(bytes)).whenFailure { error in
                // Bytes that could not be sent leave a hole in the stream,
                // and whoever queued them is waiting for an answer to
                // something the peer never received. Nothing after that can
                // be trusted, so the stream ends here, with the reason.
                self.channelDidEnd(self.failure(for: error))
                channel.close(promise: nil)
            }
        }
    }

    private static func message(_ bytes: ByteBuffer) -> SSHChannelData {
        SSHChannelData(type: .channel, data: .byteBuffer(bytes))
    }

    // MARK: Ending

    /// Why the stream can no longer carry anything, or `nil` while it can.
    /// Bytes that arrived before it ended may still be waiting to be read.
    var endedReason: SSHChannelStreamError? {
        state.withLock { $0.endedReason }
    }

    /// Why a read would fail at once, or `nil` while there is something to
    /// read or still a chance of it.
    var exhaustedReason: SSHChannelStreamError? {
        state.withLock { state in
            if state.isClosedLocally { return .closed }
            return state.inbound.count == 0 ? state.ending : nil
        }
    }

    /// Installs the closure told when the stream ends for any reason other
    /// than ``close()``. It is called at most once, on the event loop.
    func setEndObserver(_ observer: (@Sendable (SSHChannelStreamError) -> Void)?) {
        state.withLock { $0.endObserver = observer }
    }

    /// Closes the channel. Idempotent, and does not wait for the peer: a
    /// suspended read or send is released immediately and unread bytes are
    /// dropped.
    func close() {
        let (reader, senders, wasOpen) = state.withLock { state in
            let wasOpen = !state.isClosedLocally
            state.isClosedLocally = true
            state.endObserver = nil
            state.inbound.removeAll()
            return (state.takeWaiter(), state.takeSendWaiters(), wasOpen)
        }
        reader?.resume()
        for sender in senders {
            sender.resume(returning: .closed)
        }
        if wasOpen {
            // This only starts the close. The channel is gone for good when
            // the peer confirms, or when the SSH connection ends.
            let channel = self.channel
            perform {
                channel.close(promise: nil)
            }
        }
    }

    // MARK: Called by the channel handler, on the event loop

    /// The channel is up: decide whether to start reading.
    func channelDidActivate() -> Bool {
        state.withLock { $0.claimRead() }
    }

    func channelDidReceive(_ bytes: ByteBuffer) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isClosedLocally else { return nil }
            state.inbound.append(bytes)
            guard let waiter = state.waiter, state.inbound.count >= waiter.demand else { return nil }
            return state.takeWaiter()
        }
        waiter?.resume()
    }

    /// The batch a `channel.read()` asked for has been delivered.
    /// - Returns: Whether to ask for another.
    func channelDidFinishBatch() -> Bool {
        state.withLock { state in
            state.isReading = false
            return state.claimRead()
        }
    }

    /// The channel is gone. Only the first reason is kept.
    func channelDidEnd(_ reason: SSHChannelStreamError) {
        typealias Outcome = (
            reader: CheckedContinuation<Void, Never>?,
            senders: [SendWaiter],
            observer: (@Sendable (SSHChannelStreamError) -> Void)?
        )
        let outcome: Outcome = state.withLock { state in
            guard state.ending == nil else { return (nil, [], nil) }
            state.ending = reason
            state.isReading = false
            // A close that was asked for locally is not news to anyone.
            let observer = state.isClosedLocally ? nil : state.endObserver
            state.endObserver = nil
            return (state.takeWaiter(), state.takeSendWaiters(), observer)
        }
        outcome.reader?.resume()
        for sender in outcome.senders {
            sender.resume(returning: reason)
        }
        outcome.observer?(reason)
    }

    /// Turns an error raised on the channel into the reason the stream ended.
    func failure(for error: any Error) -> SSHChannelStreamError {
        if let error = error as? NIOSSHError, error.type == .tcpShutdown {
            // The SSH connection died under the channel. Name what killed it.
            let cause = connectionLog.lastFailure.map { ": \($0)" } ?? ""
            return .failed("The SSH connection was lost\(cause)")
        }
        return SSHError.isClosure(error) ? .closed : .failed(SSHError.describe(error))
    }

    // MARK: Subsystems

    /// Asks the server to run `name` on this channel and waits for its answer.
    func requestSubsystem(_ name: String, timeout: TimeAmount) async throws {
        let channel = self.channel
        let gate = self.gate
        let answered: EventLoopFuture<Void> = channel.eventLoop.flatSubmit {
            let answered = channel.eventLoop.makePromise(of: Void.self)
            gate.value.perform {
                do {
                    let handler = try channel.pipeline.syncOperations.handler(
                        type: SSHChannelStreamHandler.self)
                    handler.requestSubsystem(name).cascade(to: answered)
                } catch {
                    answered.fail(error)
                }
            }
            return answered.futureResult
        }
        do {
            try await answered.value(orTimeoutAfter: timeout) { _ in }
        } catch {
            throw SSHError.translatingChannelFailure(error)
        }
    }
}

// MARK: - Channel handler

/// Connects an SSH child channel to its ``SSHChannelStream``.
///
/// Lives in the channel's pipeline and runs on its event loop.
final class SSHChannelStreamHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let stream: SSHChannelStream
    private var context: ChannelHandlerContext?
    /// The subsystem request the server has not answered yet.
    private var pendingRequest: (subsystem: String, answered: EventLoopPromise<Void>)?

    init(stream: SSHChannelStream) {
        self.stream = stream
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        if stream.channelDidActivate() {
            context.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        // Extended data is the remote process's standard error. Neither a
        // forwarded connection nor SFTP has anything to say there, and the
        // bytes must not be mixed into the stream.
        guard message.type == .channel, case .byteBuffer(let bytes) = message.data else { return }
        stream.channelDidReceive(bytes)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // A child channel hands over everything it has queued per read, then
        // waits to be asked again.
        if stream.channelDidFinishBatch() {
            context.read()
        }
        context.fireChannelReadComplete()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingRequest?.answered.succeed(())
            pendingRequest = nil
        case is ChannelFailureEvent:
            if let pendingRequest {
                pendingRequest.answered.fail(SSHError.subsystemUnavailable(pendingRequest.subsystem))
            }
            pendingRequest = nil
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        stream.channelDidEnd(stream.failure(for: error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        stream.channelDidEnd(.closed)
        pendingRequest?.answered.fail(SSHError.closed)
        pendingRequest = nil
        context.fireChannelInactive()
    }

    /// Sends a `subsystem` channel request (RFC 4254 §6.5). The future
    /// completes when the server accepts or refuses it.
    func requestSubsystem(_ name: String) -> EventLoopFuture<Void> {
        guard let context, pendingRequest == nil else {
            return stream.channel.eventLoop.makeFailedFuture(SSHError.closed)
        }
        let answered = context.eventLoop.makePromise(of: Void.self)
        pendingRequest = (name, answered)

        // The request may not even leave, for instance on a channel that is
        // closing; then no answer will come and the failure is the answer.
        let sent = context.eventLoop.makePromise(of: Void.self)
        sent.futureResult.assumeIsolated().whenFailure { error in
            self.pendingRequest?.answered.fail(error)
            self.pendingRequest = nil
        }
        let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true)
        context.triggerUserOutboundEvent(request, promise: sent)
        return answered.futureResult
    }
}

// MARK: - Waiting on the event loop

extension EventLoopFuture where Value: Sendable {
    /// Waits for the future, but no longer than `timeout` and not past the
    /// cancellation of the calling task.
    ///
    /// Giving up does not stop the work behind the future. `discard` receives
    /// a value that arrives after the wait was abandoned, so that a channel
    /// opened too late can be closed instead of leaked.
    ///
    /// - Throws: ``SSHError/timeout``, `CancellationError`, or the future's
    ///   own error.
    func value(
        orTimeoutAfter timeout: TimeAmount,
        discardingLateValueWith discard: @escaping @Sendable (Value) -> Void
    ) async throws -> Value {
        let outcome = eventLoop.makePromise(of: Value.self)
        // The result, the timer and cancellation race; the first one decides.
        let race = FirstClaim()

        whenComplete { result in
            if race.claim() {
                outcome.completeWith(result)
            } else if case .success(let value) = result {
                discard(value)
            }
        }
        let timer = eventLoop.scheduleTask(in: timeout) {
            if race.claim() {
                outcome.fail(SSHError.timeout)
            }
        }
        outcome.futureResult.whenComplete { _ in timer.cancel() }

        return try await withTaskCancellationHandler {
            try await outcome.futureResult.get()
        } onCancel: {
            if race.claim() {
                outcome.fail(CancellationError())
            }
        }
    }
}

/// Lets exactly one of several racing parties go ahead.
final class FirstClaim: Sendable {
    private let isClaimed = Mutex(false)

    /// `true` for the first caller, `false` for every one after it.
    func claim() -> Bool {
        isClaimed.withLock { isClaimed in
            defer { isClaimed = true }
            return !isClaimed
        }
    }
}

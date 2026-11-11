import NIOCore
import NIOSSH

/// Keeps a connection's channels quiet while its encryption keys are being
/// replaced.
///
/// **The problem.** A server replaces the session's keys every so often,
/// after so much data or so much time (`RekeyLimit` in OpenSSH). From the
/// moment a side sends its key exchange offer until it announces its new
/// keys, it may send nothing but the key exchange itself (RFC 4253 §7.1).
/// swift-nio-ssh keeps that rule by turning channel messages away, and
/// leaves it there: a write made in that interval fails, the first part of a
/// write that had to be split is dropped without a word, and a flow-control
/// update is lost for good, after which the server waits for room this side
/// believes it has already granted. Any one of these leaves a tunnel or a
/// file transfer cut off or waiting forever.
///
/// **What this does.** It is told of the offer and of the new keys by the
/// one place that sees each outgoing message before it is encrypted,
/// ``SSHWatchedTransportProtection``. For the time in between, it
///
/// - holds every operation a channel asks for (reading, writing, closing,
///   opening another channel), in the order asked, and
/// - keeps the end of each batch of received data from swift-nio-ssh, since
///   that is when its channels send flow-control updates and replies on
///   their own.
///
/// Once the new keys are announced, what was held goes ahead. The wait is
/// bounded: a key exchange that outlasts the connection's time allowance ends
/// the connection.
///
/// It sits ahead of `NIOSSHHandler` in the pipeline and runs on the channel's
/// event loop, like everything that calls it.
///
/// This stands in for something swift-nio-ssh ought to do itself, which is
/// to queue channel messages during a key exchange. Version 0.15.1 does not.
/// Once a version does, this file can go.
final class SSHKeyExchangeGate: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// The gate of the connection whose received data is being worked through
    /// on this thread at the moment.
    ///
    /// swift-nio-ssh makes the packet protection for a connection while it
    /// processes what that connection received, and hands it nothing that
    /// says which connection it is for. This is how the protection learns
    /// whom to tell.
    @TaskLocal static var receiving: NIOLoopBound<SSHKeyExchangeGate>?

    /// Where the connection is with replacing its keys.
    private enum KeyExchange {
        /// None is under way: channels may send.
        case none
        /// This side has made its offer and not yet announced its new keys.
        case underWay
        /// The new keys are announced, and what was held is about to go
        /// ahead.
        case finishing
    }

    /// How long channels may be kept waiting before the connection is given
    /// up.
    private let timeout: TimeAmount
    private var context: ChannelHandlerContext?

    private var keyExchange = KeyExchange.none
    /// What the channels asked for while they had to wait, oldest first.
    private var held = CircularBuffer<() -> Void>()
    /// Whether the end of a batch of received data is still to be passed on.
    private var owesReadComplete = false
    private var deadline: Scheduled<Void>?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    // MARK: For channels

    /// Runs `operation` now, or when the key exchange in progress is over.
    ///
    /// Everything that makes a channel send something goes through here,
    /// and that includes reading: taking delivery of data is what makes a
    /// channel grant the server more room.
    func perform(_ operation: @escaping () -> Void) {
        // An operation never overtakes one that is still waiting its turn.
        if keyExchange != .none || !held.isEmpty {
            held.append(operation)
        } else {
            operation()
        }
    }

    // MARK: For the packet protection

    /// This side's key exchange offer is on its way out. From here on
    /// swift-nio-ssh accepts no channel messages.
    func keyExchangeBegan() {
        guard let context else { return }
        switch keyExchange {
        case .none:
            keyExchange = .underWay
            deadline = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) {
                self.deadline = nil
                // Reported the way any failure of the transport is, which
                // ends the connection and says why.
                self.context?.fireErrorCaught(SSHError.timeout)
            }
        case .finishing:
            // The server wants new keys again before what was held has had
            // its turn. It goes on waiting, and the clock keeps running.
            keyExchange = .underWay
        case .underWay:
            break
        }
    }

    /// This side's new keys are announced, which ends the interval.
    func newKeysSent() {
        guard keyExchange == .underWay, let context else { return }
        keyExchange = .finishing
        // The announcement is still being written at this point. What was
        // held follows it rather than cutting in.
        context.eventLoop.assumeIsolated().execute {
            // Unless the next key exchange has begun by then.
            guard self.keyExchange == .finishing else { return }
            self.resume(passingOnReadComplete: true)
        }
    }

    private func resume(passingOnReadComplete: Bool) {
        guard keyExchange != .none else { return }
        keyExchange = .none
        deadline?.cancel()
        deadline = nil
        if owesReadComplete {
            owesReadComplete = false
            if passingOnReadComplete {
                context?.fireChannelReadComplete()
            }
        }
        while let operation = held.popFirst() {
            operation()
        }
    }

    // MARK: Channel events

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        connectionEnded()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        Self.$receiving.withValue(NIOLoopBound(self, eventLoop: context.eventLoop)) {
            context.fireChannelRead(data)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        guard keyExchange != .none else {
            context.fireChannelReadComplete()
            return
        }
        owesReadComplete = true
        // swift-nio-ssh sends what it has written when a batch ends, and its
        // own half of the key exchange is waiting for exactly that.
        context.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
        connectionEnded()
    }

    /// Nothing will complete a key exchange now. What was held is let go, to
    /// find the connection closed and report that in the usual way.
    private func connectionEnded() {
        resume(passingOnReadComplete: false)
    }
}

// MARK: - Packet protection

extension SSHKeyExchangeGate {
    /// The packet protection schemes to offer a server: each cipher
    /// swift-nio-ssh implements, strongest first, in the form that reports to
    /// the gate.
    ///
    /// Should a version of swift-nio-ssh implement none of the ciphers named
    /// here, its own list is used as it is. Connections still work then, but
    /// a key exchange is as unsafe for channels as it is without the gate.
    static var transportProtectionSchemes: [any NIOSSHTransportProtection.Type] {
        var schemes: [any NIOSSHTransportProtection.Type] = []
        if SSHWatchedTransportProtection<SSHCipher.AES256GCM>.isImplemented {
            schemes.append(SSHWatchedTransportProtection<SSHCipher.AES256GCM>.self)
        }
        if SSHWatchedTransportProtection<SSHCipher.AES128GCM>.isImplemented {
            schemes.append(SSHWatchedTransportProtection<SSHCipher.AES128GCM>.self)
        }
        return schemes.isEmpty ? Constants.bundledTransportProtectionSchemes : schemes
    }
}

/// A cipher swift-nio-ssh implements, by the name it is negotiated under.
protocol SSHCipherName {
    static var cipherName: String { get }
}

enum SSHCipher {
    enum AES256GCM: SSHCipherName {
        static let cipherName = "aes256-gcm@openssh.com"
    }

    enum AES128GCM: SSHCipherName {
        static let cipherName = "aes128-gcm@openssh.com"
    }
}

/// One of swift-nio-ssh's own packet protection schemes with one thing
/// added: it tells the connection's ``SSHKeyExchangeGate`` when this side's
/// key exchange offer and when its new keys pass through on the way out.
///
/// Every operation is handed to swift-nio-ssh's implementation unchanged.
/// All that is done here is to look at the type of each outgoing message,
/// which is in the clear until the implementation has encrypted it. Packet
/// protection is the one extension point that sees message types at all.
final class SSHWatchedTransportProtection<Name: SSHCipherName>: NIOSSHTransportProtection {
    /// Message numbers from RFC 4253 §12.
    private enum MessageType {
        static var keyExchangeInit: UInt8 { 20 }
        static var newKeys: UInt8 { 21 }
    }

    /// Where a packet's message type is: after its length (four bytes) and
    /// the length of its padding (one), RFC 4253 §6.
    private static var messageTypeOffset: Int { 5 }

    /// swift-nio-ssh's implementation of the cipher, if it has one.
    private static var implementation: (any NIOSSHTransportProtection.Type)? {
        Constants.bundledTransportProtectionSchemes.first { $0.cipherName == Name.cipherName }
    }

    static var isImplemented: Bool {
        implementation != nil
    }

    static var cipherName: String {
        Name.cipherName
    }

    static var macName: String? {
        implementation?.macName
    }

    // The fallbacks below are never the values in use: a scheme without an
    // implementation is not offered, and cannot be created either.

    static var cipherBlockSize: Int {
        implementation?.cipherBlockSize ?? 0
    }

    static var keySizes: ExpectedKeySizes {
        implementation?.keySizes ?? ExpectedKeySizes(ivSize: 0, encryptionKeySize: 0, macKeySize: 0)
    }

    /// swift-nio-ssh's protection, which does all the work.
    private let protection: any NIOSSHTransportProtection
    /// The gate of the connection this protection was made for.
    private let gate: NIOLoopBound<SSHKeyExchangeGate>?

    init(initialKeys: NIOSSHSessionKeys) throws {
        guard let implementation = Self.implementation else {
            throw SSHError.connectionFailed("The cipher \(Name.cipherName) is not available.")
        }
        protection = try implementation.init(initialKeys: initialKeys)
        gate = SSHKeyExchangeGate.receiving
    }

    var macBytes: Int {
        protection.macBytes
    }

    var lengthEncrypted: Bool {
        protection.lengthEncrypted
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        try protection.updateKeys(newKeys)
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        try protection.decryptFirstBlock(&source)
    }

    func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        try protection.decryptAndVerifyRemainingPacket(&source, sequenceNumber: sequenceNumber)
    }

    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let messageType = destination.getInteger(
            at: destination.readerIndex + Self.messageTypeOffset, as: UInt8.self)
        try protection.encryptPacket(&destination, sequenceNumber: sequenceNumber)
        switch messageType {
        case MessageType.keyExchangeInit:
            gate?.value.keyExchangeBegan()
        case MessageType.newKeys:
            gate?.value.newKeysSent()
        default:
            break
        }
    }
}

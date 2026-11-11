import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices

/// What a user signs in to an SSH server with.
public enum SSHCredential: Sendable {
    case password(String)
    case key(SSHPrivateKey)
}

// A password must not end up in a log or a crash report because the
// credential, or something that holds one such as an ``SSHTunnelFactory``,
// was printed or interpolated into a string somewhere.
extension SSHCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .password: "SSHCredential.password(redacted)"
        case .key: "SSHCredential.key(redacted)"
        }
    }

    public var debugDescription: String { description }
}

// The same goes for everything that looks inside a value instead of asking
// it for a description: `dump`, the debugger, and a test that prints what it
// compared. There is nothing for them to see.
extension SSHCredential: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>())
    }
}

/// A server's host key, put to a host key policy for a decision.
public struct SSHHostKeyChallenge: Sendable {
    /// The server being connected to, as the caller named it.
    public let host: String
    public let port: Int
    /// The key the server presented.
    public let key: SSHHostKey
    /// What ``knownHosts`` has on record about that key for this server.
    public let verdict: KnownHostsStore.Verdict
    /// The store the verdict came from.
    public let knownHosts: KnownHostsStore

    /// The SSH name of the key's algorithm, such as `ssh-ed25519`.
    public var keyType: String { key.type }

    /// The key's SHA-256 fingerprint, as `ssh-keygen -l` prints it. This is
    /// what to show a person who has to decide.
    public var fingerprint: String { key.fingerprint }

    /// Puts the presented key on record for this server, so that later
    /// connections find it ``KnownHostsStore/Verdict/trusted``. A policy calls
    /// this when the decision to accept the key is meant to last, and goes
    /// by what it returns.
    ///
    /// The key is recorded only if the store still says about it what
    /// ``verdict`` says. Another connection to the same server may have put
    /// a key on record since the verdict was taken, and a decision made
    /// before that must not undo it. See
    /// ``KnownHostsStore/trust(host:port:key:decidedOn:)`` for the rules.
    ///
    /// - Returns: `.trusted` when the key is on record. Anything else is the
    ///   store's verdict as it now stands, which did not allow recording the
    ///   key: the connection should not go on as if it had.
    /// - Throws: When the key should have been recorded and could not be
    ///   written.
    public func trust() throws -> KnownHostsStore.Verdict {
        try knownHosts.trust(host: host, port: port, key: key, decidedOn: verdict)
    }
}

/// Decides whether a connection may go on with the host key a server
/// presented. Return `true` to continue, `false` to end the attempt with
/// ``SSHError/hostKeyRejected(fingerprint:)``.
///
/// The policy may take as long as it needs, for example to ask the user. The
/// connection timeout is suspended while it runs. If the attempt is abandoned
/// in the meantime, the task the policy runs in is cancelled.
public typealias SSHHostKeyPolicy = @Sendable (SSHHostKeyChallenge) async -> Bool

/// One authenticated connection to an SSH server.
///
/// A client carries any number of channels at once: tunnels made with
/// ``openTunnel(toHost:port:)`` and file transfer sessions made with
/// ``openSFTP()``. Each of those keeps the client alive for as long as it is
/// in use, and the connection closes when ``close()`` is called or when the
/// client and everything opened from it have been let go.
///
/// The connection is made with Network.framework, so it follows the system's
/// routing, VPN and proxy configuration on both iOS and macOS. TCP keepalive
/// is on: a server that goes silent is noticed after about 80 seconds, and
/// the probes keep NAT mappings alive while a session sits idle.
///
/// A server may replace the connection's encryption keys whenever it sees
/// fit, typically after so much data or time (`RekeyLimit` in OpenSSH).
/// Tunnels and file transfers carry on across that. The server has to prove
/// its identity again each time, with the very host key that was accepted
/// when the connection was made: any other key ends the connection.
public final class SSHClient: Sendable {
    /// Event loops shared by all SSH connections. Each connection does its
    /// encryption on the loop it lands on, so a couple of loops keep two
    /// simultaneous sessions from queueing behind each other.
    private static let eventLoopGroup = NIOTSEventLoopGroup(
        loopCount: 2, defaultQoS: .userInitiated)

    /// Largest read taken from the socket at once. NIO's default of 8 KiB
    /// would cut every SSH packet of a screen update into several reads.
    private static let maximumReceiveLength = 256 * 1024

    /// The server this client is connected to.
    public let host: String
    public let port: Int
    public let username: String

    private let channel: any Channel
    /// What channels go through to send anything, so that nothing is sent
    /// while the connection's keys are being replaced.
    private let gate: NIOLoopBound<SSHKeyExchangeGate>
    private let log: SSHConnectionLog
    /// Time allowed for each exchange with the server that should be quick:
    /// opening a channel, starting a subsystem.
    private let timeout: TimeAmount

    private init(
        host: String,
        port: Int,
        username: String,
        channel: any Channel,
        gate: NIOLoopBound<SSHKeyExchangeGate>,
        log: SSHConnectionLog,
        timeout: TimeAmount
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.channel = channel
        self.gate = gate
        self.log = log
        self.timeout = timeout
    }

    deinit {
        // Nothing can use the connection once the client and everything
        // opened from it are gone.
        channel.close(promise: nil)
    }

    // MARK: Connecting

    /// Connects to an SSH server and signs in.
    ///
    /// - Parameters:
    ///   - host: The server's name or address.
    ///   - port: The server's SSH port.
    ///   - username: The account to sign in to.
    ///   - credential: The password or key to sign in with. It is offered
    ///     once; a server that turns it down ends the attempt.
    ///   - knownHosts: The record of trusted host keys that the verdict given
    ///     to `hostKeyPolicy` is taken from.
    ///   - hostKeyPolicy: Decides whether to trust the key the server
    ///     presents. See ``knownHostsPolicy(trustUnknownHosts:)`` for the
    ///     ready-made one.
    ///   - timeout: How long the server may take to accept the connection,
    ///     and again to complete the SSH handshake and sign-in. Time spent in
    ///     `hostKeyPolicy` does not count. The same allowance later applies
    ///     to opening each channel.
    /// - Throws: ``SSHError``, or `CancellationError` when the calling task is
    ///   cancelled, which also abandons the attempt.
    public static func connect(
        host: String,
        port: Int = 22,
        username: String,
        credential: SSHCredential,
        knownHosts: KnownHostsStore = KnownHostsStore(),
        hostKeyPolicy: @escaping SSHHostKeyPolicy,
        timeout: Duration = .seconds(15)
    ) async throws -> SSHClient {
        guard !host.isEmpty else {
            throw SSHError.connectionFailed("No server address was given.")
        }
        guard (1...65535).contains(port) else {
            throw SSHError.connectionFailed("\(port) is not a valid port number.")
        }

        let timeout = max(TimeAmount(timeout), .seconds(1))
        let configuration = SSHHandshakeHandler.Configuration(
            host: host,
            port: port,
            username: username,
            credential: credential,
            knownHosts: knownHosts,
            hostKeyPolicy: hostKeyPolicy,
            timeout: timeout)
        let attempt = SSHConnectionAttempt()
        let log = SSHConnectionLog()

        return try await withTaskCancellationHandler {
            do {
                let (channel, authentication, gate) = try await bootstrap(timeout: timeout)
                    .connect(host: host, port: port) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try attempt.adopt(channel)
                            let handshake = SSHHandshakeHandler(
                                configuration: configuration,
                                attempt: attempt,
                                log: log,
                                eventLoop: channel.eventLoop)
                            let gate = SSHKeyExchangeGate(timeout: timeout)
                            let ssh = NIOSSHHandler(
                                role: .client(SSHClientConfiguration(
                                    userAuthDelegate: handshake,
                                    serverAuthDelegate: handshake,
                                    transportProtectionSchemes: SSHKeyExchangeGate.transportProtectionSchemes)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: refuseChannel)
                            try channel.pipeline.syncOperations.addHandlers([gate, ssh, handshake])
                            return (
                                channel, handshake.authentication,
                                NIOLoopBound(gate, eventLoop: channel.eventLoop))
                        }
                    }
                try await authentication.get()
                try Task.checkCancellation()
                return SSHClient(
                    host: host, port: port, username: username,
                    channel: channel, gate: gate, log: log, timeout: timeout)
            } catch {
                attempt.abandon()
                throw attempt.outcome(for: error)
            }
        } onCancel: {
            attempt.cancel()
        }
    }

    /// Turns down a channel the server asks to open.
    ///
    /// A server opens channels towards a client for things the client asked
    /// for first: connections to a port it had the server listen on, X11
    /// windows, its key agent. This client asks for none of those, so a
    /// channel from the server is one nobody invited. Without this,
    /// swift-nio-ssh would confirm every one of them and keep it, with
    /// megabytes of room for the server to fill, for as long and as many as
    /// the server liked.
    private static func refuseChannel(
        _ channel: any Channel,
        type: SSHChannelType
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.makeFailedFuture(
            SSHError.channelOpenRefused("This client accepts no channels from the server."))
    }

    private static func bootstrap(timeout: TimeAmount) -> NIOTSConnectionBootstrap {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = Int(timeout.nanoseconds / 1_000_000_000)
        // Probe after 20 idle seconds, then every 10; six misses in a row end
        // the connection. Tolerant enough for a flaky wireless leg.
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 20
        tcpOptions.keepaliveInterval = 10
        tcpOptions.keepaliveCount = 6

        return NIOTSConnectionBootstrap(group: eventLoopGroup)
            .connectTimeout(timeout)
            .withQoS(.userInitiated)
            .tcpOptions(tcpOptions)
            .channelOption(NIOTSChannelOptions.maximumReceiveLength, value: maximumReceiveLength)
            .configureNWParameters { $0.serviceClass = .responsiveData }
    }

    /// The standard trust-on-first-use policy.
    ///
    /// - A key that is on record for the server is accepted.
    /// - A server met for the first time is accepted only when
    ///   `trustUnknownHosts` is `true`, and its key is then put on record.
    /// - A key that differs from the one on record is always refused.
    /// - While the record cannot be read, every key is refused.
    ///
    /// An app that can ask the user writes its own policy for the unknown and
    /// mismatch cases and falls back on this one for the rest.
    public static func knownHostsPolicy(trustUnknownHosts: Bool) -> SSHHostKeyPolicy {
        { challenge in
            switch challenge.verdict {
            case .trusted:
                return true
            case .unknown:
                guard trustUnknownHosts else { return false }
                do {
                    // Unknown is what the server was when this connection
                    // looked. If another connection has put a different key
                    // on record since, this one is no longer a first
                    // encounter, and its key is not recorded over the other.
                    return try challenge.trust() == .trusted
                } catch {
                    // The key could not be saved. The server simply stays
                    // unknown, and is accepted on the same terms next time.
                    return true
                }
            case .mismatch, .storeUnreadable:
                return false
            }
        }
    }

    // MARK: Channels

    /// Opens a tunnel: a connection from the SSH server to `host:port`, as
    /// the server sees that address, carried over this connection
    /// (a `direct-tcpip` channel, RFC 4254 §7.2).
    ///
    /// - Throws: ``SSHError/channelOpenRefused(_:)`` when the server cannot or
    ///   will not make the connection.
    public func openTunnel(toHost host: String, port: Int) async throws -> SSHTunnelConnection {
        let stream = try await openForwardingChannel(toHost: host, port: port)
        return SSHTunnelConnection(stream: stream, client: self, closesClient: false)
    }

    /// Starts a file transfer session (the `sftp` subsystem).
    ///
    /// - Throws: ``SSHError/subsystemUnavailable(_:)`` when the server does
    ///   not offer SFTP.
    public func openSFTP() async throws -> SFTPClient {
        let stream = try await openChannel(.session)
        do {
            try await stream.requestSubsystem("sftp", timeout: timeout)
            let sftp = SFTPClient(stream: stream, client: self)
            try await sftp.start(timeout: Duration(timeout))
            return sftp
        } catch {
            stream.close()
            throw error
        }
    }

    func openForwardingChannel(toHost host: String, port: Int) async throws -> SSHChannelStream {
        guard !host.isEmpty, (1...65535).contains(port) else {
            throw SSHError.channelOpenRefused("“\(host):\(port)” is not a valid destination.")
        }
        // The server is told where the forwarded connection comes from; this
        // end of the SSH connection is the honest answer.
        let originator = try channel.localAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await openChannel(.directTCPIP(.init(
            targetHost: host, targetPort: port, originatorAddress: originator)))
    }

    private func openChannel(_ type: SSHChannelType) async throws -> SSHChannelStream {
        let channel = self.channel
        let gate = self.gate
        let log = self.log
        let opened: EventLoopFuture<SSHChannelStream> = channel.eventLoop.flatSubmit {
            let activated = channel.eventLoop.makePromise(of: (any Channel).self)
            // Asking for a channel is a message to the server like any other.
            gate.value.perform {
                do {
                    let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(activated, channelType: type) { child, _ in
                        // A child channel starts out reading whenever its
                        // parent does. The stream pulls instead, which is
                        // what lets a slow consumer hold the server back.
                        child.setOption(ChannelOptions.autoRead, value: false).flatMapThrowing {
                            let stream = SSHChannelStream(
                                channel: child, gate: gate, connectionLog: log)
                            try child.pipeline.syncOperations.addHandler(
                                SSHChannelStreamHandler(stream: stream))
                        }
                    }
                } catch {
                    activated.fail(error)
                }
            }
            return activated.futureResult.flatMapThrowing { child in
                try child.pipeline.syncOperations.handler(
                    type: SSHChannelStreamHandler.self).stream
            }
        }
        do {
            // A channel the server confirms after the wait was given up is
            // closed again rather than left open with no owner.
            return try await opened.value(orTimeoutAfter: timeout) { $0.close() }
        } catch {
            throw SSHError.translatingChannelFailure(error)
        }
    }

    // MARK: Closing

    /// Whether the connection is still up.
    public var isConnected: Bool {
        channel.isActive
    }

    /// Closes the connection and every tunnel and file transfer session on
    /// it. Safe to call more than once.
    public func close() async {
        // Closing a channel that is already closed is reported as an error;
        // the connection is closed afterwards either way.
        try? await channel.close().get()
    }

    /// Starts closing the connection without waiting for it to finish.
    func closeWithoutWaiting() {
        channel.close(promise: nil)
    }
}

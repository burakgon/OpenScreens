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
    /// this before returning `true` when the decision is meant to last.
    public func trust() throws {
        try knownHosts.trust(host: host, port: port, key: key)
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
    private let log: SSHConnectionLog
    /// Time allowed for each exchange with the server that should be quick:
    /// opening a channel, starting a subsystem.
    private let timeout: TimeAmount

    private init(
        host: String,
        port: Int,
        username: String,
        channel: any Channel,
        log: SSHConnectionLog,
        timeout: TimeAmount
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.channel = channel
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
                let (channel, authentication) = try await bootstrap(timeout: timeout)
                    .connect(host: host, port: port) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try attempt.adopt(channel)
                            let handshake = SSHHandshakeHandler(
                                configuration: configuration,
                                attempt: attempt,
                                log: log,
                                eventLoop: channel.eventLoop)
                            let ssh = NIOSSHHandler(
                                role: .client(SSHClientConfiguration(
                                    userAuthDelegate: handshake,
                                    serverAuthDelegate: handshake)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil)
                            try channel.pipeline.syncOperations.addHandlers([ssh, handshake])
                            return (channel, handshake.authentication)
                        }
                    }
                try await authentication.get()
                try Task.checkCancellation()
                return SSHClient(
                    host: host, port: port, username: username,
                    channel: channel, log: log, timeout: timeout)
            } catch {
                attempt.abandon()
                throw attempt.outcome(for: error)
            }
        } onCancel: {
            attempt.cancel()
        }
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
                // If the key cannot be saved the server simply stays unknown,
                // and is accepted on the same terms next time.
                try? challenge.trust()
                return true
            case .mismatch:
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
        let log = self.log
        let opened: EventLoopFuture<SSHChannelStream> = channel.eventLoop.flatSubmit {
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let activated = channel.eventLoop.makePromise(of: (any Channel).self)
                ssh.createChannel(activated, channelType: type) { child, _ in
                    // A child channel starts out reading whenever its parent
                    // does. The stream pulls instead, which is what lets a
                    // slow consumer hold the server back.
                    child.setOption(ChannelOptions.autoRead, value: false).flatMapThrowing {
                        let stream = SSHChannelStream(channel: child, connectionLog: log)
                        try child.pipeline.syncOperations.addHandler(
                            SSHChannelStreamHandler(stream: stream))
                    }
                }
                return activated.futureResult.flatMapThrowing { child in
                    try child.pipeline.syncOperations.handler(
                        type: SSHChannelStreamHandler.self).stream
                }
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
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

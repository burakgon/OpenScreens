import Foundation
import NIOCore
import RFBProtocol
import RFBTransport

/// A screen sharing connection carried through an SSH tunnel.
///
/// This is the byte stream of a `direct-tcpip` channel, shaped to the
/// contract the remote-desktop engine sets for its transports in
/// ``RFBConnection``:
///
/// - **Buffering.** Received bytes wait in a user-space buffer and both
///   kinds of read are served from it first, so the stream never reorders.
///   Small reads that the buffer can satisfy return without suspending.
/// - **Back-pressure.** The tunnel stops pulling from the SSH channel once a
///   few megabytes are waiting unread, which makes the server stop sending;
///   ``send(_:)`` returns only when its bytes have left for the network. The
///   mechanics are in `SSHChannelStream`.
/// - **Errors.** Everything is reported as ``VNCProtocolError``:
///   `.connectionClosed` when the stream ends, including in the middle of a
///   read, and `.ioError` when the channel or the SSH connection fails.
/// - **Close.** ``close()`` is idempotent, returns without waiting for the
///   server, releases a suspended read or send with `.connectionClosed`, and
///   does not call the disconnect handler.
///
/// The tunnel is already open when a value exists: ``SSHClient`` opens the
/// channel before handing it over. ``connect()`` therefore has nothing left
/// to establish and only confirms that the tunnel still has something to
/// give. A closed tunnel cannot be reopened; make a new one for the next
/// attempt, which is what ``SSHTunnelFactory`` does.
public final class SSHTunnelConnection: RFBConnection {
    /// The largest single read that will be attempted, the same backstop the
    /// engine's own TCP transport applies. A raw full-screen update of a 6K
    /// display is about 100 MB; a length beyond this is a corrupt or hostile
    /// stream, and honouring it would only exhaust memory.
    static let maximumExactReadLength = 256 * 1024 * 1024

    private let stream: SSHChannelStream
    /// Keeps the SSH connection alive for as long as the tunnel is in use.
    private let client: SSHClient
    /// Whether the SSH connection exists only to carry this tunnel and
    /// should end with it.
    private let closesClient: Bool

    init(stream: SSHChannelStream, client: SSHClient, closesClient: Bool) {
        self.stream = stream
        self.client = client
        self.closesClient = closesClient
        if closesClient {
            // However the channel ends, including from the server's side
            // without anyone calling close(), its connection goes with it.
            stream.channel.closeFuture.whenComplete { _ in
                client.closeWithoutWaiting()
            }
        }
    }

    deinit {
        // A tunnel that was dropped without being closed must not keep a
        // channel, or a whole SSH connection, open behind it.
        stream.close()
        if closesClient {
            client.closeWithoutWaiting()
        }
    }

    // MARK: RFBConnection

    /// Confirms the tunnel is usable. The channel was opened when the tunnel
    /// was made, so there is nothing to establish here.
    ///
    /// A far end that has already hung up is not a failure as long as what it
    /// sent first is still unread: a server that says why it is refusing a
    /// connection and then closes should get to be heard.
    public func connect() async throws {
        if let reason = stream.exhaustedReason {
            throw Self.protocolError(for: reason)
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else {
            throw VNCProtocolError.protocolViolation("Negative read length")
        }
        guard count <= Self.maximumExactReadLength else {
            throw VNCProtocolError.protocolViolation(
                "Server demanded a \(count)-byte read; refusing "
                    + "(stream desynchronized or hostile)")
        }
        do {
            return try await stream.read(exactly: count).makeData()
        } catch {
            throw Self.protocolError(for: error)
        }
    }

    public func read(upTo maxCount: Int) async throws -> Data {
        guard maxCount > 0 else {
            throw VNCProtocolError.protocolViolation("Read length must be positive")
        }
        do {
            return try await stream.read(upTo: maxCount).makeData()
        } catch {
            throw Self.protocolError(for: error)
        }
    }

    public func send(_ data: Data) async throws {
        if let reason = stream.endedReason {
            throw Self.protocolError(for: reason)
        }
        guard !data.isEmpty else { return }
        var buffer = stream.channel.allocator.buffer(capacity: data.count)
        data.withUnsafeBytes { _ = buffer.writeBytes($0) }
        do {
            try await stream.send(buffer)
        } catch {
            throw Self.protocolError(for: error)
        }
    }

    public func close() async {
        stream.close()
        if closesClient {
            await client.close()
        }
    }

    public func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {
        guard let handler else {
            stream.setEndObserver(nil)
            return
        }
        stream.setEndObserver { reason in
            handler(Self.protocolError(for: reason))
        }
    }

    private static func protocolError(for reason: SSHChannelStreamError) -> VNCProtocolError {
        switch reason {
        case .closed: .connectionClosed
        case .failed(let description): .ioError(description)
        }
    }
}

/// Makes the tunnels the remote-desktop engine connects through.
///
/// The engine asks its transport provider for a fresh connection on every
/// attempt, reconnections included, and expects each one to stand on its own.
/// So every call dials SSH anew, signs in, opens a tunnel to the screen
/// sharing port and returns it; the SSH connection lives exactly as long as
/// that tunnel and closes with it.
///
///     configuration.transportProvider = SSHTunnelFactory(
///         username: "me",
///         credential: .key(key),
///         hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: false)
///     ).provider
public struct SSHTunnelFactory: Sendable {
    /// The SSH server. Empty means the computer being connected to.
    public var sshHost: String
    public var sshPort: Int
    public var username: String
    public var credential: SSHCredential
    public var knownHosts: KnownHostsStore
    public var hostKeyPolicy: SSHHostKeyPolicy
    /// See ``SSHClient/connect(host:port:username:credential:knownHosts:hostKeyPolicy:timeout:)``.
    public var timeout: Duration

    public init(
        sshHost: String = "",
        sshPort: Int = 22,
        username: String,
        credential: SSHCredential,
        knownHosts: KnownHostsStore = KnownHostsStore(),
        hostKeyPolicy: @escaping SSHHostKeyPolicy,
        timeout: Duration = .seconds(15)
    ) {
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.username = username
        self.credential = credential
        self.knownHosts = knownHosts
        self.hostKeyPolicy = hostKeyPolicy
        self.timeout = timeout
    }

    /// The closure to install as the engine's transport provider. `host` and
    /// `port` are where the engine wants to connect: the computer's screen
    /// sharing address.
    public var provider: @Sendable (_ host: String, _ port: UInt16) async throws -> any RFBConnection {
        { host, port in
            try await makeConnection(toHost: host, port: port)
        }
    }

    /// Dials SSH and returns an open tunnel to `host:port`.
    ///
    /// - Throws: ``SSHError``, whose description is fit to show to the user,
    ///   or `CancellationError` when the calling task is cancelled.
    public func makeConnection(toHost host: String, port: UInt16) async throws -> SSHTunnelConnection {
        let sshHost = self.sshHost.isEmpty ? host : self.sshHost
        let client = try await SSHClient.connect(
            host: sshHost,
            port: sshPort,
            username: username,
            credential: credential,
            knownHosts: knownHosts,
            hostKeyPolicy: hostKeyPolicy,
            timeout: timeout)
        do {
            let stream = try await client.openForwardingChannel(
                toHost: Self.tunnelTarget(for: host, sshHost: sshHost), port: Int(port))
            return SSHTunnelConnection(stream: stream, client: client, closesClient: true)
        } catch {
            await client.close()
            throw error
        }
    }

    /// The address the SSH server must connect to in order to reach `host`.
    ///
    /// When the SSH server *is* the computer being shared, that is its own
    /// loopback interface. The name the user typed need not mean anything on
    /// the far side (a router's public address, a Bonjour name), and a
    /// computer set up to be reached only through SSH may accept screen
    /// sharing on loopback alone. `localhost` rather than `127.0.0.1` lets
    /// the server try IPv6 and IPv4 loopback in turn.
    static func tunnelTarget(for host: String, sshHost: String) -> String {
        SSHHostName.normalized(host) == SSHHostName.normalized(sshHost) ? "localhost" : host
    }
}

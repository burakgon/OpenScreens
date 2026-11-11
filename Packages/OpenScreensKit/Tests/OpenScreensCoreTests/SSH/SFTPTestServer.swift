#if os(macOS)

import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization
import Testing
@testable import OpenScreensCore

/// An SFTP server inside the test process, for everything an honest server
/// never does.
///
/// It is a real SSH server on a loopback port, built on the same
/// swift-nio-ssh the client uses, so the client under test reaches it the way
/// it reaches any server. Behind its `sftp` subsystem is a small file system
/// kept in memory (``Volume``). Every request is shown to the test's
/// ``Script`` first, which lets it through, answers it differently, answers
/// it late, or does not answer at all. Every request is recorded too, so a
/// test can check what the client asked for.
final class SFTPTestServer: Sendable {
    /// What the server does with one request.
    enum Reaction: Sendable {
        /// What an honest server would do.
        case serve
        /// What an honest server would do, with the reply held back this long.
        /// The file system changes at once; only the client is kept waiting.
        case serveLate(Duration)
        /// Sends these packets and leaves the file system alone.
        case reply([SFTPPacket])
        /// Says nothing at all, and leaves the file system alone.
        case ignore
    }

    /// Decides what happens to each request. Runs on the connection's thread.
    typealias Script = @Sendable (SFTPPacket) -> Reaction

    let port: Int
    let volume: Volume
    private let listener: any Channel
    private let connections: Recorder<any Channel>
    private let received: Recorder<SFTPPacket>

    private init(
        port: Int,
        volume: Volume,
        listener: any Channel,
        connections: Recorder<any Channel>,
        received: Recorder<SFTPPacket>
    ) {
        self.port = port
        self.volume = volume
        self.listener = listener
        self.connections = connections
        self.received = received
    }

    /// Starts a server, runs `body` against it, and stops it again whether
    /// `body` returns or throws.
    ///
    /// - Parameters:
    ///   - extensions: What the server claims to support beyond version 3.
    ///   - script: Decides what happens to each request; by default they are
    ///     all served honestly.
    static func run<Result>(
        extensions: [SFTPExtension] = [],
        script: @escaping Script = { _ in .serve },
        _ body: (SFTPTestServer) async throws -> Result
    ) async throws -> Result {
        let server = try await start(extensions: extensions, script: script)
        do {
            let result = try await body(server)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    private static func start(
        extensions: [SFTPExtension],
        script: @escaping Script
    ) async throws -> SFTPTestServer {
        let volume = Volume()
        let connections = Recorder<any Channel>()
        let received = Recorder<SFTPPacket>()
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())

        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    connections.record(channel)
                    let ssh = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [hostKey], userAuthDelegate: AcceptAnyone())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            child.eventLoop.makeCompletedFuture {
                                guard type == .session else { throw Unsupported() }
                                try child.pipeline.syncOperations.addHandler(Session(
                                    volume: volume, extensions: extensions,
                                    script: script, received: received))
                            }
                        })
                    try channel.pipeline.syncOperations.addHandlers([ssh, ErrorSink()])
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)
        return SFTPTestServer(
            port: port, volume: volume, listener: listener,
            connections: connections, received: received)
    }

    private func stop() async {
        try? await listener.close()
        for connection in connections.values {
            try? await connection.close()
        }
    }

    /// Connects and signs in. The server lets anyone in.
    ///
    /// - Parameter timeout: The client's allowance for the server's answers.
    func connect(timeout: Duration = .seconds(10)) async throws -> SSHClient {
        try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            username: "tester",
            credential: .password("anything"),
            knownHosts: KnownHostsStore(fileURL: nil),
            hostKeyPolicy: { _ in true },
            timeout: timeout)
    }

    /// Every request received so far, in order.
    var requests: [SFTPPacket] {
        received.values
    }

    /// Waits until the requests received so far satisfy `condition`.
    /// - Returns: Whether they did before `timeout` ran out.
    func waitForRequests(
        timeout: Duration = .seconds(5),
        where condition: ([SFTPPacket]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(requests) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(requests)
    }

    private struct Unsupported: Error {}

    /// Lets everyone in.
    private final class AcceptAnyone: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods = NIOSSHAvailableUserAuthenticationMethods.all

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            responsePromise.succeed(.success)
        }
    }

    /// Ends a connection that failed, instead of letting the error fall off
    /// the end of the pipeline.
    private final class ErrorSink: ChannelInboundHandler {
        typealias InboundIn = Any

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }
}

// MARK: - The file system

extension SFTPTestServer {
    /// The server's file system: files and folders by their full path.
    ///
    /// A name here is whatever a test says it is, slashes included, because
    /// names no real file system would hold are part of what the client has
    /// to withstand. Paths are therefore never taken apart: an entry is found
    /// under exactly the path it was added with.
    final class Volume: Sendable {
        struct Node: Sendable {
            var parent: String
            var name: String
            var isDirectory: Bool
            var contents: [UInt8] = []
            /// The permission bits alone.
            var permissions: UInt32
            /// Seconds since 1970.
            var modified: UInt32 = 1_600_000_000
            /// The size to report in place of the true one.
            var claimedSize: UInt64?
            /// Whether a listing says what kind of thing this is.
            var listsKind = true
            /// Whether asking about it directly says what kind of thing it is.
            var statsKind = true
        }

        fileprivate enum Handle: Sendable {
            case file(path: String)
            /// The entries not handed over yet; `nil` once the end was reported.
            case directory(remaining: [SFTPNameEntry]?)
        }

        fileprivate struct State: Sendable {
            var nodes: [String: Node] = [
                "/": Node(parent: "", name: "/", isDirectory: true, permissions: 0o755),
            ]
            var handles: [SFTPHandle: Handle] = [:]
            var lastHandle: UInt32 = 0
        }

        fileprivate let state = Mutex(State())

        /// How many entries one reply to a listing carries, as OpenSSH sends
        /// them: a hundred at a time.
        static let listingBatchSize = 100

        static func path(of name: String, in parent: String) -> String {
            parent.hasSuffix("/") ? parent + name : parent + "/" + name
        }

        /// Adds a file called `name` to the folder at `parent`, which must
        /// exist. The name is taken as it is.
        @discardableResult
        func addFile(
            _ name: String,
            in parent: String = "/",
            contents: Data = Data(),
            permissions: UInt32 = 0o644,
            change: (inout Node) -> Void = { _ in }
        ) -> String {
            var node = Node(
                parent: parent, name: name, isDirectory: false,
                contents: [UInt8](contents), permissions: permissions)
            change(&node)
            return add(node)
        }

        /// Adds a folder called `name` to the folder at `parent`.
        @discardableResult
        func addDirectory(
            _ name: String,
            in parent: String = "/",
            permissions: UInt32 = 0o755,
            change: (inout Node) -> Void = { _ in }
        ) -> String {
            var node = Node(parent: parent, name: name, isDirectory: true, permissions: permissions)
            change(&node)
            return add(node)
        }

        private func add(_ node: Node) -> String {
            let path = Self.path(of: node.name, in: node.parent)
            state.withLock { $0.nodes[path] = node }
            return path
        }

        func node(at path: String) -> Node? {
            state.withLock { $0.nodes[path] }
        }

        func contents(of path: String) -> Data? {
            node(at: path).map { Data($0.contents) }
        }

        /// The path of everything there is except the root, sorted.
        var paths: [String] {
            state.withLock { $0.nodes.keys.filter { $0 != "/" }.sorted() }
        }

        /// The number of files and folders the client has open.
        var openHandleCount: Int {
            state.withLock { $0.handles.count }
        }
    }
}

extension SFTPTestServer.Volume.State {
    typealias Node = SFTPTestServer.Volume.Node

    private static let directoryType: UInt32 = 0o040000
    private static let regularFileType: UInt32 = 0o100000

    private func attributes(of node: Node, showingKind: Bool) -> SFTPAttributes {
        let type = node.isDirectory ? Self.directoryType : Self.regularFileType
        let date = Date(timeIntervalSince1970: TimeInterval(node.modified))
        return SFTPAttributes(
            size: node.isDirectory ? nil : node.claimedSize ?? UInt64(node.contents.count),
            mode: showingKind ? type | node.permissions : nil,
            accessDate: date,
            modificationDate: date)
    }

    private static func status(
        _ id: UInt32, _ code: SFTPStatusCode, _ message: String = ""
    ) -> SFTPPacket {
        .status(id: id, code: code, message: message, language: "")
    }

    private mutating func open(_ handle: SFTPTestServer.Volume.Handle) -> SFTPHandle {
        lastHandle += 1
        let key = SFTPHandle(bytes: withUnsafeBytes(of: lastHandle.bigEndian) { [UInt8]($0) })
        handles[key] = handle
        return key
    }

    /// Whether a new entry could be put at `path`: its folder is there.
    private func parentExists(of path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return false }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        return nodes[parent]?.isDirectory == true
    }

    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("/", path) }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        return (parent, String(path[path.index(after: slash)...]))
    }

    /// Does what an honest server does with `request` and returns its reply.
    mutating func serve(_ request: SFTPPacket, extensions: [SFTPExtension]) -> SFTPPacket? {
        switch request {
        case .initialize:
            return .version(version: SFTPPacketCodec.version, extensions: extensions)

        case .realpath(let id, let path):
            let resolved = path.isEmpty || path == "." ? "/" : path
            return .name(id: id, entries: [SFTPNameEntry(
                filename: resolved, longname: resolved,
                attributes: SFTPAttributes(mode: Self.directoryType | 0o755))])

        case .stat(let id, let path), .lstat(let id, let path):
            guard let node = nodes[path] else {
                return Self.status(id, .noSuchFile, "No such file")
            }
            return .attributes(id: id, attributes: attributes(of: node, showingKind: node.statsKind))

        case .fstat(let id, let handle):
            guard case .file(let path) = handles[handle], let node = nodes[path] else {
                return Self.status(id, .failure, "Invalid handle")
            }
            return .attributes(id: id, attributes: attributes(of: node, showingKind: node.statsKind))

        case .opendir(let id, let path):
            guard let node = nodes[path], node.isDirectory else {
                return Self.status(id, .noSuchFile, "No such file")
            }
            let special = [".", ".."].map {
                SFTPNameEntry(filename: $0, longname: $0, attributes: attributes(of: node, showingKind: true))
            }
            let children = nodes.values
                .filter { $0.parent == path && $0.name != "/" }
                .sorted { $0.name < $1.name }
                .map {
                    SFTPNameEntry(
                        filename: $0.name, longname: $0.name,
                        attributes: attributes(of: $0, showingKind: $0.listsKind))
                }
            return .handle(id: id, handle: open(.directory(remaining: special + children)))

        case .readdir(let id, let handle):
            guard case .directory(let remaining) = handles[handle] else {
                return Self.status(id, .failure, "Invalid handle")
            }
            guard let remaining, !remaining.isEmpty else {
                handles[handle] = .directory(remaining: nil)
                return Self.status(id, .endOfFile, "End of file")
            }
            let batch = remaining.prefix(SFTPTestServer.Volume.listingBatchSize)
            handles[handle] = .directory(remaining: Array(remaining.dropFirst(batch.count)))
            return .name(id: id, entries: Array(batch))

        case .close(let id, let handle):
            guard handles.removeValue(forKey: handle) != nil else {
                return Self.status(id, .failure, "Invalid handle")
            }
            return Self.status(id, .ok, "Success")

        case .open(let id, let path, let flags, let attributes):
            if let node = nodes[path] {
                if node.isDirectory || (flags.contains(.create) && flags.contains(.exclusive)) {
                    return Self.status(id, .failure, "Failure")
                }
                if flags.contains(.truncate) {
                    nodes[path]?.contents = []
                }
            } else {
                guard flags.contains(.create) else {
                    return Self.status(id, .noSuchFile, "No such file")
                }
                guard parentExists(of: path) else {
                    return Self.status(id, .noSuchFile, "No such file")
                }
                let (parent, name) = Self.split(path)
                nodes[path] = Node(
                    parent: parent, name: name, isDirectory: false,
                    permissions: (attributes.mode ?? 0o644) & 0o7777)
            }
            return .handle(id: id, handle: open(.file(path: path)))

        case .read(let id, let handle, let offset, let length):
            guard case .file(let path) = handles[handle], let node = nodes[path] else {
                return Self.status(id, .failure, "Invalid handle")
            }
            guard offset < UInt64(node.contents.count) else {
                return Self.status(id, .endOfFile, "End of file")
            }
            let start = Int(offset)
            let end = min(node.contents.count, start + Int(length))
            return .data(id: id, data: ByteBuffer(bytes: node.contents[start..<end]))

        case .write(let id, let handle, let offset, let data):
            guard case .file(let path) = handles[handle], var node = nodes[path] else {
                return Self.status(id, .failure, "Invalid handle")
            }
            let start = Int(offset)
            let end = start + data.readableBytes
            if node.contents.count < end {
                node.contents.append(contentsOf: [UInt8](repeating: 0, count: end - node.contents.count))
            }
            node.contents.replaceSubrange(start..<end, with: data.readableBytesView)
            nodes[path] = node
            return Self.status(id, .ok, "Success")

        case .remove(let id, let path):
            guard let node = nodes[path] else {
                return Self.status(id, .noSuchFile, "No such file")
            }
            guard !node.isDirectory else {
                return Self.status(id, .failure, "Failure")
            }
            nodes[path] = nil
            return Self.status(id, .ok, "Success")

        case .mkdir(let id, let path, let attributes):
            guard nodes[path] == nil else {
                return Self.status(id, .failure, "Failure")
            }
            guard parentExists(of: path) else {
                return Self.status(id, .noSuchFile, "No such file")
            }
            let (parent, name) = Self.split(path)
            nodes[path] = Node(
                parent: parent, name: name, isDirectory: true,
                permissions: (attributes.mode ?? 0o755) & 0o7777)
            return Self.status(id, .ok, "Success")

        case .rmdir(let id, let path):
            guard let node = nodes[path], node.isDirectory else {
                return Self.status(id, .noSuchFile, "No such file")
            }
            guard !nodes.values.contains(where: { $0.parent == path }) else {
                return Self.status(id, .failure, "Failure")
            }
            nodes[path] = nil
            return Self.status(id, .ok, "Success")

        case .rename(let id, let from, let to):
            // As OpenSSH does it: a name that is taken is not given away.
            guard nodes[to] == nil else {
                return Self.status(id, .failure, "Failure")
            }
            return move(id, from: from, to: to)

        case .version, .status, .handle, .data, .name, .attributes:
            // These are replies; a client has no business sending them.
            return nil
        }
    }

    /// Gives the file at `from` the path `to`, replacing what is there.
    private mutating func move(_ id: UInt32, from: String, to: String) -> SFTPPacket {
        guard var node = nodes[from] else {
            return Self.status(id, .noSuchFile, "No such file")
        }
        guard !node.isDirectory, nodes[to]?.isDirectory != true, parentExists(of: to) else {
            return Self.status(id, .failure, "Failure")
        }
        (node.parent, node.name) = Self.split(to)
        nodes[from] = nil
        nodes[to] = node
        for (handle, open) in handles {
            if case .file(from) = open {
                handles[handle] = .file(path: to)
            }
        }
        return Self.status(id, .ok, "Success")
    }
}

// MARK: - One client's session

extension SFTPTestServer {
    /// Speaks SFTP on one session channel. Lives on the channel's event loop.
    private final class Session: ChannelInboundHandler {
        typealias InboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData

        private let volume: Volume
        private let extensions: [SFTPExtension]
        private let script: Script
        private let received: Recorder<SFTPPacket>
        private var inbound = ByteBuffer()

        init(
            volume: Volume,
            extensions: [SFTPExtension],
            script: @escaping Script,
            received: Recorder<SFTPPacket>
        ) {
            self.volume = volume
            self.extensions = extensions
            self.script = script
            self.received = received
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            guard let request = event as? SSHChannelRequestEvent.SubsystemRequest else {
                context.fireUserInboundEventTriggered(event)
                return
            }
            if request.subsystem == "sftp" {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            } else {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let message = unwrapInboundIn(data)
            guard message.type == .channel, case .byteBuffer(var bytes) = message.data else { return }
            inbound.writeBuffer(&bytes)
            do {
                while let request = try SFTPPacketCodec.decodeNext(from: &inbound) {
                    handle(request, context: context)
                }
            } catch {
                context.close(promise: nil)
            }
        }

        private func handle(_ request: SFTPPacket, context: ChannelHandlerContext) {
            received.record(request)
            // The version exchange is not part of what a test scripts.
            if case .initialize = request {
                serve(request, context: context, after: nil)
                return
            }
            switch script(request) {
            case .serve:
                serve(request, context: context, after: nil)
            case .serveLate(let delay):
                serve(request, context: context, after: delay)
            case .reply(let packets):
                packets.forEach { send($0, context: context) }
            case .ignore:
                break
            }
        }

        private func serve(_ request: SFTPPacket, context: ChannelHandlerContext, after delay: Duration?) {
            let reply = volume.state.withLock { $0.serve(request, extensions: extensions) }
            guard let reply else { return }
            guard let delay else {
                send(reply, context: context)
                return
            }
            context.eventLoop.assumeIsolated().scheduleTask(in: TimeAmount(delay)) {
                self.send(reply, context: context)
            }
        }

        private func send(_ packet: SFTPPacket, context: ChannelHandlerContext) {
            guard context.channel.isActive else { return }
            let bytes = SFTPPacketCodec.encode(packet, allocator: context.channel.allocator)
            context.writeAndFlush(
                wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: nil)
        }
    }
}

/// Counts from callbacks that may run on any thread.
final class Tally: Sendable {
    private let count = Mutex(0)

    /// The number of times ``next()`` has been called.
    var value: Int {
        count.withLock { $0 }
    }

    /// Counts one more and returns how many that makes.
    @discardableResult
    func next() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}

#endif

import Foundation
import NIOCore

/// A file transfer session with an SSH server.
///
/// Speaks SFTP version 3 (draft-ietf-secsh-filexfer-02), the version every
/// server in use supports, over a session channel running the `sftp`
/// subsystem. Get one from ``SSHClient/openSFTP()``.
///
/// Paths are the server's: `/`-separated, and relative ones are resolved
/// against the directory the session starts in, normally the user's home.
///
/// Requests may be issued from several tasks at once. Each is matched to its
/// reply by ID, so one slow request does not hold up the others; the
/// transfers in this type rely on that to keep many reads or writes in flight.
/// Cancelling a task abandons the request it is waiting on.
public actor SFTPClient {
    private let stream: SSHChannelStream
    /// Keeps the SSH connection alive for as long as the session is in use.
    private let client: SSHClient

    private var lastRequestID: UInt32 = 0
    private var pendingReplies: [UInt32: CheckedContinuation<SFTPPacket, any Error>] = [:]
    private var pendingVersion: CheckedContinuation<UInt32, any Error>?
    /// Why the session is over, once it is. Every later request fails with it.
    private var ending: SFTPError?

    init(stream: SSHChannelStream, client: SSHClient) {
        self.stream = stream
        self.client = client
    }

    deinit {
        // Ends the reader task too: its pending read is released.
        stream.close()
    }

    // MARK: Session

    /// Starts receiving replies and agrees on the protocol version with the
    /// server. Nothing else may be sent before this returns.
    func start(timeout: Duration) async throws {
        // The reader owns the receiving half of the stream for the life of
        // the session. It holds the session weakly so that letting go of the
        // session is enough to end it.
        Task { [stream, weak self] in
            while true {
                do {
                    let packet = try await Self.nextPacket(from: stream)
                    guard let self else { return }
                    await self.receive(packet)
                } catch {
                    await self?.end(with: error)
                    return
                }
            }
        }

        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.failVersionExchange(with: SSHError.timeout)
        }
        defer { timer.cancel() }

        let version = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt32, any Error>) in
                if let ending {
                    continuation.resume(throwing: ending)
                    return
                }
                pendingVersion = continuation
                stream.enqueue(SFTPPacketCodec.encode(
                    .initialize(version: SFTPPacketCodec.version),
                    allocator: stream.channel.allocator))
            }
        } onCancel: {
            Task { await self.failVersionExchange(with: CancellationError()) }
        }
        // The server answers with the lower of the two versions. Anything
        // under 3 lacks operations this client depends on.
        guard version == SFTPPacketCodec.version else {
            throw SFTPError.unsupportedVersion(version)
        }
    }

    /// Ends the session. Requests still waiting fail with
    /// ``SFTPError/connectionClosed``. The SSH connection stays open.
    public func close() {
        end(with: SFTPError.connectionClosed)
    }

    private static func nextPacket(from stream: SSHChannelStream) async throws -> SFTPPacket {
        let allocator = stream.channel.allocator
        var prefix = try await stream.read(exactly: MemoryLayout<UInt32>.size)
            .makeBuffer(allocator: allocator)
        guard let length = prefix.readInteger(as: UInt32.self) else {
            throw SFTPError.invalidResponse("a truncated packet")
        }
        try SFTPPacketCodec.validate(length: length)
        let body = try await stream.read(exactly: Int(length)).makeBuffer(allocator: allocator)
        return try SFTPPacketCodec.decode(body: body)
    }

    private func receive(_ packet: SFTPPacket) {
        if case .version(let version, _) = packet {
            pendingVersion?.resume(returning: version)
            pendingVersion = nil
            return
        }
        // A reply nobody is waiting for answers a request that was cancelled.
        guard let id = packet.replyID, let waiting = pendingReplies.removeValue(forKey: id) else {
            return
        }
        waiting.resume(returning: packet)
    }

    private func failVersionExchange(with error: any Error) {
        pendingVersion?.resume(throwing: error)
        pendingVersion = nil
    }

    private func end(with error: any Error) {
        guard ending == nil else { return }
        let reason = Self.sessionError(for: error)
        ending = reason
        for waiting in pendingReplies.values {
            waiting.resume(throwing: reason)
        }
        pendingReplies.removeAll()
        failVersionExchange(with: reason)
        stream.close()
    }

    private static func sessionError(for error: any Error) -> SFTPError {
        switch error {
        case let error as SFTPError: error
        case SSHChannelStreamError.closed: .connectionClosed
        case SSHChannelStreamError.failed(let reason): .connectionFailed(reason)
        default: .connectionFailed(SSHError.describe(error))
        }
    }

    // MARK: Requests

    /// Sends a request and waits for the reply that carries its ID.
    ///
    /// The request is queued without waiting for it to reach the network.
    /// Nothing can pile up that way: a caller holds one request at a time,
    /// and the transfers cap how many callers there are.
    private func exchange(_ request: (UInt32) -> SFTPPacket) async throws -> SFTPPacket {
        if let ending {
            throw ending
        }
        try Task.checkCancellation()

        repeat {
            lastRequestID &+= 1
        } while pendingReplies[lastRequestID] != nil
        let id = lastRequestID
        let bytes = SFTPPacketCodec.encode(request(id), allocator: stream.channel.allocator)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SFTPPacket, any Error>) in
                pendingReplies[id] = continuation
                stream.enqueue(bytes)
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Stops waiting for the reply to a request whose task was cancelled.
    /// The server still answers; ``receive(_:)`` drops that reply.
    private func abandon(_ id: UInt32) {
        pendingReplies.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Checks the reply to a request that only succeeds or fails.
    private func expectSuccess(_ reply: SFTPPacket) throws {
        guard case .status(_, .ok, _, _) = reply else {
            throw Self.failure(for: reply)
        }
    }

    /// The error for a reply that is not what its request called for: the
    /// server's own refusal when it sent one, a protocol error otherwise.
    private static func failure(for reply: SFTPPacket) -> SFTPError {
        if case .status(_, let code, let message, _) = reply, code != .ok {
            return .status(code: code, message: message)
        }
        return .invalidResponse("a reply that does not fit the request")
    }

    // MARK: Paths

    /// Resolves `path` to the absolute path the server knows it by, with `.`,
    /// `..` and symbolic links worked out. How much of the path has to exist
    /// is up to the server; OpenSSH only lets the last component be missing.
    public func realPath(_ path: String) async throws -> String {
        let reply = try await exchange { .realpath(id: $0, path: path) }
        guard case .name(_, let entries) = reply, let entry = entries.first else {
            throw Self.failure(for: reply)
        }
        return entry.filename
    }

    /// The directory the session starts in: the user's home, unless the
    /// server is set up otherwise.
    public func homeDirectory() async throws -> String {
        try await realPath(".")
    }

    // MARK: Looking

    /// The contents of a directory, sorted by name the way Finder sorts.
    /// The `.` and `..` entries are left out.
    public func list(_ path: String) async throws -> [SFTPItem] {
        try await entries(of: path)
            .map { SFTPItem(name: $0.filename, directory: path, attributes: $0.attributes) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The raw entries of a directory, for callers that need more than
    /// ``SFTPItem`` shows.
    func entries(of path: String) async throws -> [SFTPNameEntry] {
        let reply = try await exchange { .opendir(id: $0, path: path) }
        guard case .handle(_, let handle) = reply else {
            throw Self.failure(for: reply)
        }

        var entries: [SFTPNameEntry] = []
        do {
            // The server hands the listing over in batches and says
            // end-of-file when there is nothing more.
            reading: while true {
                let reply = try await exchange { .readdir(id: $0, handle: handle) }
                switch reply {
                case .name(_, let batch):
                    entries.append(contentsOf: batch.filter { Self.isUsableName($0.filename) })
                case .status(_, .endOfFile, _, _):
                    break reading
                default:
                    throw Self.failure(for: reply)
                }
            }
        } catch {
            await closeAbandoned(handle)
            throw error
        }
        try await close(handle)
        return entries
    }

    /// Whether a name from a listing can be used as one. `.` and `..` are not
    /// contents, and a name with a slash or a NUL in it is not a name: taken
    /// at face value it would let a server point a download outside the
    /// folder it was aimed at.
    private static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    /// What the server knows about the file at `path`.
    ///
    /// - Parameter followSymlinks: When `true`, a symbolic link is looked
    ///   through and its target is described; when `false`, the link itself.
    public func attributes(of path: String, followSymlinks: Bool = true) async throws -> SFTPAttributes {
        let reply = try await exchange {
            followSymlinks ? .stat(id: $0, path: path) : .lstat(id: $0, path: path)
        }
        guard case .attributes(_, let attributes) = reply else {
            throw Self.failure(for: reply)
        }
        return attributes
    }

    // MARK: Changing

    /// Creates a directory. Its parent must exist.
    public func makeDirectory(_ path: String) async throws {
        try expectSuccess(await exchange { .mkdir(id: $0, path: path, attributes: SFTPAttributes()) })
    }

    /// Deletes a file or a symbolic link.
    public func remove(_ path: String) async throws {
        try expectSuccess(await exchange { .remove(id: $0, path: path) })
    }

    /// Deletes a directory, which must be empty.
    public func removeDirectory(_ path: String) async throws {
        try expectSuccess(await exchange { .rmdir(id: $0, path: path) })
    }

    /// Renames or moves a file or directory. Version 3 leaves it to the
    /// server whether an existing `newPath` is replaced; OpenSSH refuses.
    public func rename(_ path: String, to newPath: String) async throws {
        try expectSuccess(await exchange { .rename(id: $0, from: path, to: newPath) })
    }

    // MARK: Open files

    func open(_ path: String, flags: SFTPOpenFlags) async throws -> SFTPHandle {
        let reply = try await exchange {
            .open(id: $0, path: path, flags: flags, attributes: SFTPAttributes())
        }
        guard case .handle(_, let handle) = reply else {
            throw Self.failure(for: reply)
        }
        return handle
    }

    func close(_ handle: SFTPHandle) async throws {
        try expectSuccess(await exchange { .close(id: $0, handle: handle) })
    }

    /// Closes a handle that is being given up on. This runs in a task of its
    /// own because the caller may have been cancelled, and a cancelled task
    /// cannot make requests.
    nonisolated func closeAbandoned(_ handle: SFTPHandle) async {
        await Task { try? await self.close(handle) }.value
    }

    func attributes(of handle: SFTPHandle) async throws -> SFTPAttributes {
        let reply = try await exchange { .fstat(id: $0, handle: handle) }
        guard case .attributes(_, let attributes) = reply else {
            throw Self.failure(for: reply)
        }
        return attributes
    }

    /// Reads up to `length` bytes at `offset`. The server may return fewer.
    /// - Returns: `nil` at the end of the file.
    func read(from handle: SFTPHandle, at offset: UInt64, length: Int) async throws -> ByteBuffer? {
        let reply = try await exchange {
            .read(id: $0, handle: handle, offset: offset, length: UInt32(clamping: length))
        }
        switch reply {
        case .data(_, let data):
            return data
        case .status(_, .endOfFile, _, _):
            return nil
        default:
            throw Self.failure(for: reply)
        }
    }

    func write(_ data: ByteBuffer, to handle: SFTPHandle, at offset: UInt64) async throws {
        try expectSuccess(await exchange {
            .write(id: $0, handle: handle, offset: offset, data: data)
        })
    }
}

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
///
/// A request does not wait for ever. When the server has sent nothing at all
/// for as long as the connection's timeout, every request that has been
/// waiting that long fails with ``SSHError/timeout``. A server that is slow
/// but keeps answering is waited for: what counts is how long it has been
/// silent, not how long one request has been out, because a transfer on a
/// slow link has requests queued behind each other for longer than that.
public actor SFTPClient {
    private let stream: SSHChannelStream
    /// Keeps the SSH connection alive for as long as the session is in use.
    private let client: SSHClient

    /// A request that was sent and is not answered yet.
    private struct PendingRequest {
        let reply: CheckedContinuation<SFTPPacket, any Error>
        /// When it was handed to the connection.
        let sentAt: ContinuousClock.Instant
        /// For a request that opens something: what to do if the server
        /// opens it after the request was given up on.
        let opening: AbandonedOpen?
    }

    /// What becomes of a file or directory that the server opens after the
    /// request for it was given up on. The handle arrives with nobody left
    /// to use it or to close it.
    private enum AbandonedOpen {
        /// It is closed.
        case close
        /// It is closed and the file at this path is deleted: the request
        /// was to create that file.
        case closeAndRemove(String)
    }

    private var lastRequestID: UInt32 = 0
    private var pendingReplies: [UInt32: PendingRequest] = [:]
    /// The requests to open something that were given up on and may yet be
    /// answered, by ID.
    private var abandonedOpens: [UInt32: AbandonedOpen] = [:]
    private var pendingVersion: CheckedContinuation<UInt32, any Error>?
    /// Whether the server renames over a file that exists when asked to
    /// (`posix-rename@openssh.com`).
    private var supportsPOSIXRename = false
    /// Why the session is over, once it is. Every later request fails with it.
    private var ending: SFTPError?

    /// How long the server may stay silent before the requests waiting on it
    /// are given up on. Set from the connection's timeout when the session
    /// starts.
    private var requestTimeout = Duration.seconds(15)
    /// When the server last sent a packet.
    private var lastHeardFromServer = ContinuousClock.now
    /// The task that gives up on overdue requests; `nil` while none are
    /// waiting.
    private var watchdog: Task<Void, Never>?

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
        requestTimeout = timeout
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
        lastHeardFromServer = .now
        if case .version(let version, let extensions) = packet {
            // Only the answer to this session's own greeting counts.
            guard let pendingVersion else { return }
            supportsPOSIXRename = extensions.contains { $0.name == SFTPExtension.posixRename }
            pendingVersion.resume(returning: version)
            self.pendingVersion = nil
            return
        }
        guard let id = packet.replyID else { return }
        if let waiting = pendingReplies.removeValue(forKey: id) {
            waiting.reply.resume(returning: packet)
            return
        }
        // A reply nobody is waiting for answers a request that was given up
        // on: its task was cancelled, or its time ran out. It is dropped,
        // unless it says that the server went on to open something.
        guard let opening = abandonedOpens.removeValue(forKey: id),
              case .handle(_, let handle) = packet else { return }
        switch opening {
        case .close:
            discard(handle)
        case .closeAndRemove(let path):
            discard(handle, removing: path)
        }
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
            waiting.reply.resume(throwing: reason)
        }
        pendingReplies.removeAll()
        abandonedOpens.removeAll()
        watchdog?.cancel()
        watchdog = nil
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
    ///
    /// - Parameter opening: For a request that opens a file or a directory,
    ///   what is done about it if it is opened after this has stopped
    ///   waiting.
    /// - Throws: ``SSHError/timeout`` when the server stays silent for too
    ///   long, `CancellationError` when the calling task is cancelled, and
    ///   the reason the session ended when it does.
    private func exchange(
        opening: AbandonedOpen? = nil,
        _ request: (UInt32) -> SFTPPacket
    ) async throws -> SFTPPacket {
        if let ending {
            throw ending
        }
        try Task.checkCancellation()

        let id = nextRequestID()
        let bytes = SFTPPacketCodec.encode(request(id), allocator: stream.channel.allocator)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SFTPPacket, any Error>) in
                pendingReplies[id] = PendingRequest(reply: continuation, sentAt: .now, opening: opening)
                stream.enqueue(bytes)
                watchPendingRequests()
            }
        } onCancel: {
            Task { await self.abandon(id, because: CancellationError()) }
        }
    }

    private func nextRequestID() -> UInt32 {
        repeat {
            lastRequestID &+= 1
        } while pendingReplies[lastRequestID] != nil || abandonedOpens[lastRequestID] != nil
        return lastRequestID
    }

    /// Stops waiting for the reply to a request, because its task was
    /// cancelled or the server left it unanswered for too long. The server
    /// may answer yet. ``receive(_:)`` drops that reply, after closing what
    /// the server opened if the request was to open something.
    private func abandon(_ id: UInt32, because reason: any Error) {
        guard let request = pendingReplies.removeValue(forKey: id) else { return }
        abandonedOpens[id] = request.opening
        request.reply.resume(throwing: reason)
    }

    /// Makes sure the requests that are waiting have someone watching the
    /// clock for them. One task does that for all of them, and ends when
    /// there are none left.
    private func watchPendingRequests() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while let nextDeadline = await self?.failOverdueRequests() {
                try? await Task.sleep(until: nextDeadline, clock: .continuous)
                if Task.isCancelled { return }
            }
        }
    }

    /// Fails the requests whose time is up.
    ///
    /// A request's time runs from when it was sent or from when the server
    /// was last heard from, whichever is later.
    ///
    /// - Returns: When the next request's time will be up as things stand, or
    ///   `nil` when no request is waiting. The watchdog stops at `nil`.
    private func failOverdueRequests() -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        var overdue: [UInt32] = []
        var nextDeadline: ContinuousClock.Instant?
        for (id, request) in pendingReplies {
            let deadline = max(request.sentAt, lastHeardFromServer) + requestTimeout
            if deadline <= now {
                overdue.append(id)
            } else {
                nextDeadline = min(nextDeadline ?? deadline, deadline)
            }
        }
        for id in overdue {
            abandon(id, because: SSHError.timeout)
        }
        if nextDeadline == nil {
            watchdog = nil
        }
        return nextDeadline
    }

    /// Tells the server to close `handle`, and then to delete the file at
    /// `path`, without waiting to hear how either went.
    ///
    /// This is how a transfer or a listing that is being given up on tidies
    /// up after itself. By the time it returns, the requests are on their way
    /// in this order, ahead of anything that is asked afterwards. Nothing
    /// waits on a server that may never answer, and a task that has been
    /// cancelled, which can no longer make requests of its own, can still
    /// call this.
    func discard(_ handle: SFTPHandle?, removing path: String? = nil) {
        guard ending == nil else { return }
        let allocator = stream.channel.allocator
        if let handle {
            stream.enqueue(SFTPPacketCodec.encode(
                .close(id: nextRequestID(), handle: handle), allocator: allocator))
        }
        if let path {
            stream.enqueue(SFTPPacketCodec.encode(
                .remove(id: nextRequestID(), path: path), allocator: allocator))
        }
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

    /// The most entries taken from one directory, `.` and `..` included. A
    /// listing is held in memory whole, and the server decides how long it
    /// is; one that never says it has reached the end would otherwise be
    /// collected for as long as it kept sending.
    static let maximumListingEntries = SFTPPacketCodec.maximumNameCount

    /// The most bytes of names taken from one directory, long names
    /// included. No directory with names a file system allows comes near
    /// this within ``maximumListingEntries``.
    static let maximumListingBytes = 64 * 1024 * 1024

    /// The raw entries of a directory, for callers that need more than
    /// ``SFTPItem`` shows.
    func entries(of path: String) async throws -> [SFTPNameEntry] {
        let reply = try await exchange(opening: .close) { .opendir(id: $0, path: path) }
        guard case .handle(_, let handle) = reply else {
            throw Self.failure(for: reply)
        }

        var entries: [SFTPNameEntry] = []
        // What the server lists counts towards the limits whether or not it
        // is kept, so that a listing of nothing but names to leave out comes
        // to an end too.
        var listedCount = 0
        var listedBytes = 0
        do {
            // The server hands the listing over in batches and says
            // end-of-file when there is nothing more.
            reading: while true {
                let reply = try await exchange { .readdir(id: $0, handle: handle) }
                switch reply {
                case .name(_, let batch):
                    // A batch of no names is not something the protocol has.
                    // It is taken for the end, as OpenSSH's client takes it;
                    // a server that sends one may never say end-of-file.
                    guard !batch.isEmpty else { break reading }
                    listedCount += batch.count
                    for entry in batch {
                        listedBytes += entry.filename.utf8.count + entry.longname.utf8.count
                    }
                    guard listedCount <= Self.maximumListingEntries else {
                        throw SFTPError.tooManyEntries(limit: Self.maximumListingEntries)
                    }
                    guard listedBytes <= Self.maximumListingBytes else {
                        throw SFTPError.invalidResponse(
                            "a folder listing of more than \(Self.maximumListingBytes / (1024 * 1024)) MB")
                    }
                    // `.` and `..` are not contents, and anything else that
                    // is not one plain name cannot be used as one.
                    entries.append(contentsOf: batch.filter { SFTPPath.isUsableName($0.filename) })
                case .status(_, .endOfFile, _, _):
                    break reading
                default:
                    throw Self.failure(for: reply)
                }
            }
        } catch {
            discard(handle)
            throw error
        }
        try await close(handle)
        return entries
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

    /// Gives the finished file at `temporary` the name `path`, in place of
    /// whatever file has that name.
    ///
    /// With `posix-rename@openssh.com`, which OpenSSH and most other servers
    /// offer, that is one request and the server does it in one step: the
    /// name leads to the old file or to the new one, and never to nothing.
    ///
    /// Version 3 itself only has a rename that a server may refuse when the
    /// new name is taken. Without the extension that rename is tried first,
    /// and is all it takes when nothing is in the way or the server replaces
    /// anyway. If it is refused and a file is in the way, that file is moved
    /// aside, the new one renamed into place and the old one deleted; if the
    /// new one cannot be renamed even then, the old one is moved back. This
    /// is the best the protocol allows. For the moment between the two
    /// renames nothing has the name, and a connection lost in that moment
    /// leaves the old file whole under the name it was moved aside to.
    ///
    /// A folder in the way is never moved: the rename fails and the folder
    /// stays.
    ///
    /// The steps run in a task of their own, so that cancelling the caller
    /// cannot stop them half-way. The wait is bounded all the same, by the
    /// time each request is given.
    func moveIntoPlace(_ temporary: String, as path: String) async throws {
        try await Task { try await self.replace(path, with: temporary) }.value
    }

    private func replace(_ path: String, with temporary: String) async throws {
        if supportsPOSIXRename {
            try expectSuccess(await exchange { .posixRename(id: $0, from: temporary, to: path) })
            return
        }

        let refusal: SFTPError
        do {
            try await rename(temporary, to: path)
            return
        } catch let error as SFTPError where error.statusCode != nil {
            refusal = error
        }
        // Version 3 has no code for "the name is taken", so look. Anything
        // but a file or a link in the way leaves the refusal standing.
        guard let inTheWay = try? await attributes(of: path, followSymlinks: false),
              inTheWay.isRegularFile || inTheWay.isSymbolicLink else {
            throw refusal
        }
        let aside = SFTPPath.sibling(of: path, named: SFTPPath.temporaryName(kind: "previous"))
        try await rename(path, to: aside)
        do {
            try await rename(temporary, to: path)
        } catch {
            try? await rename(aside, to: path)
            throw error
        }
        // The upload is done. If the old file cannot be deleted it stays
        // where it was moved to, which is no reason to call the upload
        // failed.
        try? await remove(aside)
    }

    // MARK: Open files

    /// Opens a file.
    ///
    /// - Parameters:
    ///   - permissions: Who may read, write and run the file, if this
    ///     creates it; `nil` leaves that to the server. The server's own
    ///     mask for new files still applies, so the file can end up with
    ///     fewer permissions than asked for, never with more. Only the nine
    ///     ordinary bits are sent.
    ///   - removingIfAbandoned: Whether the file is a new one that this
    ///     request creates, to be deleted again if the request is given up
    ///     on and the server creates it all the same.
    func open(
        _ path: String,
        flags: SFTPOpenFlags,
        permissions: UInt16? = nil,
        removingIfAbandoned: Bool = false
    ) async throws -> SFTPHandle {
        let attributes = SFTPAttributes(mode: permissions.map { UInt32($0 & 0o777) })
        let reply = try await exchange(opening: removingIfAbandoned ? .closeAndRemove(path) : .close) {
            .open(id: $0, path: path, flags: flags, attributes: attributes)
        }
        guard case .handle(_, let handle) = reply else {
            throw Self.failure(for: reply)
        }
        return handle
    }

    func close(_ handle: SFTPHandle) async throws {
        try expectSuccess(await exchange { .close(id: $0, handle: handle) })
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
            // More than was asked for is not an answer to this request. It
            // would be written over the place of the chunk after it, and
            // would let the server decide how much is held here at once.
            guard data.readableBytes <= length else {
                throw SFTPError.invalidResponse(
                    "\(data.readableBytes) bytes in answer to a read of \(length)")
            }
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

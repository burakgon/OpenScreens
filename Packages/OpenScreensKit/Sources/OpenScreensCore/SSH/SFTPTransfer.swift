import Darwin
import Foundation
import NIOCore

// MARK: - Transfers

extension SFTPClient {
    /// Bytes asked for or sent per request. 32 KiB is the most a server is
    /// obliged to accept in one packet, and what OpenSSH's own client uses.
    static let transferChunkSize = 32 * 1024

    /// Requests kept in flight during a transfer. One megabyte on the wire at
    /// a time lets a transfer fill a fast link despite the round trip each
    /// request costs, while keeping what is buffered here small.
    static let transferPipelineDepth = 32

    /// The most files and folders one folder download takes on. The whole
    /// tree is walked before the first file is fetched, and what the walk
    /// finds is held in memory until the last one is.
    static let maximumTreeEntries = 250_000

    /// Copies a remote file to this device.
    ///
    /// The file is fetched with many reads in flight at once into a hidden
    /// file beside `localURL`, which takes the place of whatever is at
    /// `localURL` in one step when it is complete. If the transfer fails or
    /// its task is cancelled, the partial file is removed and what was at
    /// `localURL` is as it was. Cancelling returns at once, whether or not
    /// the server is still answering.
    ///
    /// A symbolic link at `localURL` is replaced by the file; it is not
    /// written through to what it points at.
    ///
    /// The copy is dated as the remote file is. A new file gets the remote
    /// file's permissions, within what this device's mask for new files
    /// allows; a file that is replaced passes its own permissions on to the
    /// one that replaces it.
    ///
    /// - Parameter progress: Called as data arrives with the bytes received
    ///   so far and the file's size, when the server reports one.
    public nonisolated func download(
        remotePath: String,
        to localURL: URL,
        progress: SFTPProgressHandler? = nil
    ) async throws {
        _ = try await downloadFile(remotePath: remotePath, to: localURL, progress: progress)
    }

    /// Copies a file on this device to the server.
    ///
    /// The file is written, with many writes in flight at once, to a hidden
    /// file beside `remotePath`, which is given the name `remotePath` when
    /// it is complete (see ``moveIntoPlace(_:as:)`` for how, and for what a
    /// server without the means to do that in one step can and cannot
    /// promise). If the transfer fails or its task is cancelled before that,
    /// the server is told to remove the partial file, the call returns
    /// without waiting for it to do so, and what was at `remotePath` is as
    /// it was.
    ///
    /// The folder has to allow a new file to be made in it, even when the
    /// upload replaces a file that could itself be written to. A symbolic
    /// link at `remotePath` is replaced by the file, not written through.
    ///
    /// A new file is made with the local file's permissions, and a file that
    /// is replaced passes its own on to the one that replaces it, both
    /// within what the server's mask for new files allows. The new file
    /// belongs to whoever uploaded it, and is dated as of the upload.
    ///
    /// - Parameter progress: Called as the server confirms data with the
    ///   bytes confirmed so far and the file's size.
    public nonisolated func upload(
        localURL: URL,
        to remotePath: String,
        progress: SFTPProgressHandler? = nil
    ) async throws {
        _ = try await uploadFile(localURL: localURL, to: remotePath, progress: progress)
    }

    /// Copies a remote directory and everything in it to this device.
    ///
    /// `localURL` becomes the copy of the directory itself; it is created if
    /// needed and merged into if it exists. Symbolic links and special files
    /// are skipped: a link may lead outside the directory or back into it,
    /// and neither is content that can be copied.
    ///
    /// The whole directory is looked through before anything is written, and
    /// one that holds more than ``maximumTreeEntries`` files and folders is
    /// not taken on.
    ///
    /// Files are copied as ``download(remotePath:to:progress:)`` copies them.
    /// A folder that is made here lets the same others in as the remote one
    /// does; the owner can always write to it.
    ///
    /// - Parameter progress: Called with the bytes received so far across all
    ///   files and the total found when the directory was first walked.
    public nonisolated func downloadDirectory(
        remotePath: String,
        to localURL: URL,
        progress: SFTPProgressHandler? = nil
    ) async throws {
        /// The server's path for what is at `path` inside the directory.
        func remote(_ path: String) -> String {
            path.isEmpty ? remotePath : SFTPPath.join(remotePath, path)
        }
        /// Where on this device that goes. Every name on the way is checked
        /// again here, at the point of writing.
        func local(_ path: String) throws -> URL {
            guard let url = SFTPPath.localURL(forPath: path, in: localURL) else {
                throw SFTPError.invalidResponse("a name that leads outside the folder being copied")
            }
            return url
        }

        // Walk the tree first. That gives the total for progress, and shows
        // whether this is a tree to take on at all before anything is
        // written. Folders and files are kept by their path inside the
        // directory, the empty path being the directory itself: a path is
        // all it takes to find them at either end, and what is kept per
        // entry decides how large a tree can be walked.
        let root = try await entryIfPresent(at: remotePath, followingSymlinks: true)
        var folders = [(path: "", permissions: root?.copiedFolderPermissions)]
        var files: [String] = []
        var total: Int64 = 0
        var keptBytes = 0
        var unvisited = [""]
        let localRoot = localURL.path(percentEncoded: false)
        while let folder = unvisited.popLast() {
            try Task.checkCancellation()
            let localFolder = SFTPPath.LocalFolder(try local(folder))
            for entry in try await entries(of: remote(folder)) {
                // Links and special files are not copied.
                let isFolder = entry.attributes.isDirectory
                guard isFolder || entry.attributes.isRegularFile else { continue }
                // The listing has already left out names that are not plain
                // names. This looks at where the name leads instead, so that
                // nothing is written outside the folder even if that check
                // and the file system should ever disagree about a name.
                guard localFolder.url(for: entry.filename) != nil else { continue }

                let path = folder.isEmpty ? entry.filename : folder + "/" + entry.filename
                // A path the local file system has no room for cannot be
                // copied, and is turned down the way the system would turn
                // it down. Here rather than later, so that nothing has been
                // written by then; and it is what ends the walk of a tree
                // that goes down without end.
                guard localRoot.utf8.count + 1 + path.utf8.count < Int(PATH_MAX) else {
                    throw SFTPError.localFile(
                        path: localRoot + "/" + path, reason: String(cString: strerror(ENAMETOOLONG)))
                }
                keptBytes += path.utf8.count
                guard folders.count + files.count <= Self.maximumTreeEntries,
                      keptBytes <= Self.maximumListingBytes else {
                    throw SFTPError.tooManyEntries(limit: Self.maximumTreeEntries)
                }
                if isFolder {
                    folders.append((path, entry.attributes.copiedFolderPermissions))
                    unvisited.append(path)
                } else {
                    files.append(path)
                    total = total.addingClamped(Int64(clamping: entry.attributes.size ?? 0))
                }
            }
        }

        // Parents were found before their children, so creating the folders
        // in this order always finds the parent in place. Only the folder
        // the copy goes to may have to have its own parents made.
        for folder in folders {
            try LocalFile.createDirectory(
                at: local(folder.path), permissions: folder.permissions, withParents: folder.path.isEmpty)
        }
        let expectedTotal = total
        var completed: Int64 = 0
        progress?(0, expectedTotal)
        for file in files {
            let previouslyCompleted = completed
            let received = try await downloadFile(
                remotePath: remote(file), to: local(file)
            ) { received, _ in
                let overall = previouslyCompleted.addingClamped(received)
                progress?(overall, max(expectedTotal, overall))
            }
            completed = completed.addingClamped(received)
        }
    }

    /// Copies a directory on this device and everything in it to the server.
    ///
    /// `remotePath` becomes the copy of the directory itself; it is created if
    /// needed and merged into if it exists. Symbolic links and special files
    /// are skipped.
    ///
    /// Files are copied as ``upload(localURL:to:progress:)`` copies them. A
    /// folder that is made on the server lets the same others in as the
    /// local one does; the owner can always write to it.
    ///
    /// - Parameter progress: Called with the bytes confirmed so far across
    ///   all files and their total size.
    public nonisolated func uploadDirectory(
        localURL: URL,
        to remotePath: String,
        progress: SFTPProgressHandler? = nil
    ) async throws {
        // Parents are found before their children, so creating the remote
        // directories in this order always finds the parent in place.
        var directories = [(path: remotePath, permissions: try LocalFile.folderPermissions(of: localURL))]
        var files: [(localURL: URL, remotePath: String)] = []
        var total: Int64 = 0
        var unvisited = [(localURL: localURL, remotePath: remotePath)]
        while let directory = unvisited.popLast() {
            try Task.checkCancellation()
            for child in try LocalFile.contents(of: directory.localURL) {
                let childPath = SFTPPath.join(directory.remotePath, child.url.lastPathComponent)
                switch child.kind {
                case .directory(let permissions):
                    directories.append((childPath, permissions))
                    unvisited.append((child.url, childPath))
                case .file(let size):
                    files.append((child.url, childPath))
                    total = total.addingClamped(size)
                case .other:
                    break
                }
            }
        }

        for directory in directories {
            try await makeDirectoryIfMissing(directory.path, permissions: directory.permissions)
        }
        let expectedTotal = total
        var completed: Int64 = 0
        progress?(0, expectedTotal)
        for file in files {
            let previouslyCompleted = completed
            let sent = try await uploadFile(
                localURL: file.localURL, to: file.remotePath
            ) { sent, _ in
                let overall = previouslyCompleted.addingClamped(sent)
                progress?(overall, max(expectedTotal, overall))
            }
            completed = completed.addingClamped(sent)
        }
    }

    // MARK: One file

    /// - Returns: The number of bytes received.
    private nonisolated func downloadFile(
        remotePath: String,
        to localURL: URL,
        progress: SFTPProgressHandler?
    ) async throws -> Int64 {
        let handle = try await open(remotePath, flags: .read)
        let received: Int64
        do {
            // The size is only a hint, for progress and for pacing, and the
            // permissions and the date are niceties; a server that will not
            // say is not a reason to fail.
            let remote = try await attributesIfOffered(of: handle)
            let size = remote?.size.map { Int64(clamping: $0) }
            // Written beside the destination and moved over it when every
            // byte is there. Until then, and if it never comes to that,
            // what is at the destination stays as it is.
            let file = try LocalFile(replacing: localURL, permissions: remote?.copiedPermissions)
            do {
                received = try await fetch(handle, into: file, expectedSize: size, progress: progress)
                try file.finish(modified: remote?.modificationDate)
            } catch {
                file.abandon()
                throw error
            }
        } catch {
            await discard(handle)
            throw error
        }
        try await close(handle)
        return received
    }

    /// What is at `path` on the server; `nil` when the server says nothing
    /// is, or refuses to say.
    ///
    /// - Parameter followingSymlinks: Whether a link at `path` is looked
    ///   through, or is itself what is described.
    private nonisolated func entryIfPresent(
        at path: String, followingSymlinks: Bool = false
    ) async throws -> SFTPAttributes? {
        do {
            return try await attributes(of: path, followSymlinks: followingSymlinks)
        } catch let error as SFTPError where error.statusCode != nil {
            return nil
        }
    }

    /// What the server says about an open file, or `nil` when it refuses to
    /// say. Only a refusal is passed over: a server that does not answer, or
    /// a task that was cancelled, still ends the transfer here.
    private nonisolated func attributesIfOffered(of handle: SFTPHandle) async throws -> SFTPAttributes? {
        do {
            return try await attributes(of: handle)
        } catch let error as SFTPError where error.statusCode != nil {
            return nil
        }
    }

    /// The outcome of one read request of a download.
    private struct FetchedChunk: Sendable {
        var offset: UInt64
        var requestedLength: Int
        /// `nil` when the server answered that the file ends at or before
        /// `offset`.
        var data: ByteBuffer?
    }

    /// Reads a whole remote file into `file`, keeping a window of read
    /// requests in flight. Replies are written where they belong as they
    /// arrive, in whatever order that is.
    private nonisolated func fetch(
        _ handle: SFTPHandle,
        into file: LocalFile,
        expectedSize: Int64?,
        progress: SFTPProgressHandler?
    ) async throws -> Int64 {
        let chunkSize = Self.transferChunkSize
        return try await withThrowingTaskGroup(of: FetchedChunk.self) { group in
            /// Where the next request in sequence starts.
            var nextOffset: UInt64 = 0
            /// The lowest offset at which the server reported end-of-file.
            var endOfFile: UInt64?
            /// One past the last byte written so far.
            var writtenEnd: UInt64 = 0
            var received: Int64 = 0
            var inFlight = 0

            progress?(0, expectedSize)
            while true {
                while inFlight < Self.transferPipelineDepth {
                    if let endOfFile, nextOffset >= endOfFile { break }
                    // Past the size the server advertised, go one request at
                    // a time. The size may be stale or absent, and only an
                    // end-of-file reply settles where the file stops, but
                    // there is no point racing a whole window past the end.
                    if let expectedSize, nextOffset >= UInt64(clamping: expectedSize), inFlight > 0 {
                        break
                    }
                    try Task.checkCancellation()
                    let offset = nextOffset
                    group.addTask {
                        FetchedChunk(
                            offset: offset,
                            requestedLength: chunkSize,
                            data: try await self.read(from: handle, at: offset, length: chunkSize))
                    }
                    inFlight += 1
                    nextOffset += UInt64(chunkSize)
                }

                guard let chunk = try await group.next() else { break }
                inFlight -= 1
                guard let data = chunk.data, data.readableBytes > 0 else {
                    endOfFile = min(endOfFile ?? .max, chunk.offset)
                    continue
                }

                // The write refuses a position past what a file can have,
                // so the sums on offsets below stay far inside 64 bits.
                try file.write(data, at: chunk.offset)
                let count = data.readableBytes
                received = received.addingClamped(Int64(count))
                writtenEnd = max(writtenEnd, chunk.offset + UInt64(count))
                progress?(received, expectedSize.map { max($0, received) })

                if count < chunk.requestedLength {
                    // A server may return less than was asked for without
                    // being at the end. The rest of the range is asked for
                    // again; if this was the end, that request says so.
                    let offset = chunk.offset + UInt64(count)
                    let length = chunk.requestedLength - count
                    group.addTask {
                        FetchedChunk(
                            offset: offset,
                            requestedLength: length,
                            data: try await self.read(from: handle, at: offset, length: length))
                    }
                    inFlight += 1
                }
            }

            // Every gap below the last byte written was asked for again, so
            // an end-of-file below it means the file shrank or was replaced
            // in the middle of the transfer. The copy is not a file that ever
            // existed on the server.
            if let endOfFile, writtenEnd > endOfFile {
                throw SFTPError.invalidResponse("the file changed while it was being read")
            }
            return received
        }
    }

    /// - Returns: The number of bytes sent.
    private nonisolated func uploadFile(
        localURL: URL,
        to remotePath: String,
        progress: SFTPProgressHandler?
    ) async throws -> Int64 {
        let file = try LocalFile(reading: localURL)
        let (size, ownPermissions) = try file.status()
        // A file that is replaced hands its permissions on to its
        // replacement: putting new contents into a file that was private
        // must not make it public. A new file is as private as the one it
        // is a copy of.
        let replaced = try await entryIfPresent(at: remotePath)
        let permissions = replaced?.isRegularFile == true
            ? replaced?.copiedPermissions ?? ownPermissions : ownPermissions
        // Written under a name of its own beside the destination, which is
        // not touched until the whole file is on the server. The name is
        // new, so the file is created and must not be there already.
        let temporary = SFTPPath.sibling(of: remotePath, named: SFTPPath.temporaryName(kind: "partial"))
        let handle = try await open(
            temporary, flags: [.write, .create, .exclusive],
            permissions: permissions, removingIfAbandoned: true)
        let sent: Int64
        do {
            sent = try await store(file, into: handle, size: size, progress: progress)
            try await close(handle)
            // The last point at which cancelling still leaves everything as
            // it was. Past it the file is moved into place, and that is not
            // left half-done.
            try Task.checkCancellation()
        } catch {
            // The server is told to take the partial file away again, and is
            // not waited for: it may be the reason the transfer failed.
            await discard(handle, removing: temporary)
            throw error
        }
        do {
            try await moveIntoPlace(temporary, as: remotePath)
        } catch {
            await discard(nil, removing: temporary)
            throw error
        }
        return sent
    }

    /// Writes all of `file` to an open remote file, keeping a window of write
    /// requests in flight.
    private nonisolated func store(
        _ file: LocalFile,
        into handle: SFTPHandle,
        size: Int64,
        progress: SFTPProgressHandler?
    ) async throws -> Int64 {
        let allocator = ByteBufferAllocator()
        return try await withThrowingTaskGroup(of: Int.self) { group in
            var offset: UInt64 = 0
            var sent: Int64 = 0
            var inFlight = 0
            var reachedEnd = false

            progress?(0, size)
            while true {
                while inFlight < Self.transferPipelineDepth, !reachedEnd {
                    try Task.checkCancellation()
                    var chunk = allocator.buffer(capacity: Self.transferChunkSize)
                    let count = try file.read(
                        into: &chunk, maximumLength: Self.transferChunkSize, at: offset)
                    guard count > 0 else {
                        reachedEnd = true
                        break
                    }
                    let (data, position) = (chunk, offset)
                    group.addTask {
                        try await self.write(data, to: handle, at: position)
                        return count
                    }
                    inFlight += 1
                    offset += UInt64(count)
                }

                guard let confirmed = try await group.next() else { break }
                inFlight -= 1
                sent += Int64(confirmed)
                progress?(sent, max(size, sent))
            }
            return sent
        }
    }

    /// Creates a remote directory unless it is already there. One that is
    /// there is left as it is, permissions included.
    private nonisolated func makeDirectoryIfMissing(_ path: String, permissions: UInt16) async throws {
        do {
            try await makeDirectory(path, permissions: permissions)
        } catch let error as SFTPError where error.statusCode != nil {
            // Version 3 has no "already exists" code, only a general failure,
            // so ask what is at the path before giving up.
            guard (try? await attributes(of: path))?.isDirectory == true else {
                throw error
            }
        }
    }
}

// MARK: - Local files

/// A file on this device, open for the positioned reads or writes of a
/// transfer. Positioned access is what lets a download write its chunks in
/// the order they arrive.
///
/// Not thread-safe; a transfer uses it from its own task only.
final class LocalFile {
    /// The file this is about: the one being read, or the one being
    /// replaced. Errors name it.
    let path: String
    /// Where the bytes go while a file that is to replace another is being
    /// written; `nil` for a file that is read.
    private let temporaryPath: String?
    private var descriptor: Int32

    private init(path: String, temporaryPath: String?, descriptor: Int32) {
        self.path = path
        self.temporaryPath = temporaryPath
        self.descriptor = descriptor
    }

    /// Opens an existing file for reading.
    convenience init(reading url: URL) throws(SFTPError) {
        let path = url.path(percentEncoded: false)
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.failure(path: path, code: errno)
        }
        self.init(path: path, temporaryPath: nil, descriptor: descriptor)
    }

    /// Starts a file that is to take the place of whatever is at `url` once
    /// it is complete.
    ///
    /// The bytes go to a new, hidden file in the same folder. ``finish()``
    /// moves that file over `url` in one step, so what is at `url` is whole
    /// at every moment: the old file, then the new one. ``abandon()``
    /// deletes it and leaves `url` as it was.
    ///
    /// - Parameter permissions: Who may read, write and run the file if it is
    ///   a new one, within what the user's mask for new files allows. A file
    ///   that replaces another takes that one's permissions instead.
    convenience init(replacing url: URL, permissions: UInt16? = nil) throws(SFTPError) {
        let path = url.path(percentEncoded: false)
        let temporaryPath = url.deletingLastPathComponent()
            .appending(path: SFTPPath.temporaryName(kind: "partial"))
            .path(percentEncoded: false)
        // A file that is replaced hands its permissions on to its
        // replacement: new contents do not change who may read a file.
        var status = stat()
        let replacedMode = lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
            ? status.st_mode & 0o777 : nil
        // The file is new by its name; if something is there after all, it
        // is not this transfer's to write into. Where nothing is replaced,
        // the mode is narrowed by the user's umask as usual.
        let newMode = permissions.map { mode_t($0 & 0o777) } ?? 0o666
        let descriptor = Darwin.open(
            temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, replacedMode ?? newMode)
        guard descriptor >= 0 else {
            throw Self.failure(path: path, code: errno)
        }
        // The umask has no say in what an existing file is allowed to be.
        if let replacedMode, fchmod(descriptor, replacedMode) != 0 {
            let code = errno
            Darwin.close(descriptor)
            unlink(temporaryPath)
            throw Self.failure(path: path, code: code)
        }
        self.init(path: path, temporaryPath: temporaryPath, descriptor: descriptor)
    }

    deinit {
        // Still open means neither finished nor abandoned. What there is of
        // a file that was being written is not left lying about.
        if descriptor >= 0 {
            Darwin.close(descriptor)
            if let temporaryPath {
                unlink(temporaryPath)
            }
        }
    }

    /// How large the file is, and who may read, write and run it.
    func status() throws(SFTPError) -> (size: Int64, permissions: UInt16) {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw Self.failure(path: path, code: errno)
        }
        return (Int64(status.st_size), UInt16(status.st_mode & 0o777))
    }

    /// Where a run of `length` bytes at `offset` starts, as the system counts
    /// positions in a file. A run that would end past the largest position
    /// there is cannot be read or written, and is refused the way the system
    /// refuses a file that is too large.
    private func position(of offset: UInt64, length: Int) throws(SFTPError) -> off_t {
        guard let start = off_t(exactly: offset),
              !start.addingReportingOverflow(off_t(length)).overflow else {
            throw Self.failure(path: path, code: EFBIG)
        }
        return start
    }

    /// Reads up to `maximumLength` bytes at `offset` onto the end of `buffer`.
    /// - Returns: The number of bytes read; zero at the end of the file.
    func read(
        into buffer: inout ByteBuffer,
        maximumLength: Int,
        at offset: UInt64
    ) throws(SFTPError) -> Int {
        let start = try position(of: offset, length: maximumLength)
        var failure: SFTPError?
        let count = buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: maximumLength) { space in
            while true {
                let count = pread(
                    descriptor, space.baseAddress, min(maximumLength, space.count), start)
                if count >= 0 { return count }
                if errno != EINTR {
                    failure = Self.failure(path: path, code: errno)
                    return 0
                }
            }
        }
        if let failure {
            throw failure
        }
        return count
    }

    /// Writes all of `buffer` at `offset`.
    func write(_ buffer: ByteBuffer, at offset: UInt64) throws(SFTPError) {
        let start = try position(of: offset, length: buffer.readableBytes)
        var failure: SFTPError?
        buffer.withUnsafeReadableBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = pwrite(
                    descriptor, bytes.baseAddress.map { $0 + written }, bytes.count - written,
                    start + off_t(written))
                if count > 0 {
                    written += count
                } else if count == 0 || errno != EINTR {
                    failure = Self.failure(path: path, code: count == 0 ? EIO : errno)
                    return
                }
            }
        }
        if let failure {
            throw failure
        }
    }

    /// Closes the file. A write that the system had deferred can fail here,
    /// so a transfer is not complete until this returns.
    func close() throws(SFTPError) {
        guard descriptor >= 0 else { return }
        let result = Darwin.close(descriptor)
        descriptor = -1
        guard result == 0 else {
            throw Self.failure(path: path, code: errno)
        }
    }

    /// Completes a file started with ``init(replacing:)``: closes it and
    /// moves it into the place of what it replaces. If that cannot be done,
    /// what there is of it is deleted and the destination is left as it was.
    ///
    /// - Parameter modified: When the file's contents were last changed, as
    ///   far as the place they came from knows. The file is dated then, and
    ///   as of now when this is `nil`.
    func finish(modified: Date? = nil) throws(SFTPError) {
        guard let temporaryPath else {
            try close()
            return
        }
        if let modified, descriptor >= 0 {
            // The time of last access is left alone. A date that cannot be
            // set is no reason to give up a file that is otherwise complete.
            let seconds = modified.timeIntervalSince1970.rounded(.down)
            let times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(
                    tv_sec: Int(seconds),
                    tv_nsec: Int((modified.timeIntervalSince1970 - seconds) * 1_000_000_000)),
            ]
            futimens(descriptor, times)
        }
        do {
            try close()
        } catch {
            unlink(temporaryPath)
            throw error
        }
        guard rename(temporaryPath, path) == 0 else {
            let code = errno
            unlink(temporaryPath)
            throw Self.failure(path: path, code: code)
        }
    }

    /// Gives up on a file started with ``init(replacing:)`` and deletes what
    /// there is of it. What it was to replace is left as it was.
    func abandon() {
        try? close()
        if let temporaryPath {
            unlink(temporaryPath)
        }
    }

    private static func failure(path: String, code: Int32) -> SFTPError {
        .localFile(path: path, reason: String(cString: strerror(code)))
    }

    // MARK: Directories

    enum Kind {
        /// A folder, with the permissions a copy of it is given: who may
        /// list, change and enter it, the owner always being among them.
        case directory(permissions: UInt16)
        case file(size: Int64)
        /// A symbolic link or a special file.
        case other
    }

    /// Creates a directory unless it exists. One that exists is left as it
    /// is, permissions included.
    ///
    /// - Parameters:
    ///   - permissions: Who may list, change and enter the directory, within
    ///     what the user's mask for new files allows; everyone that mask
    ///     allows, when `nil`.
    ///   - withParents: Whether the folders above it are created too where
    ///     they are missing.
    static func createDirectory(
        at url: URL, permissions: UInt16? = nil, withParents: Bool = false
    ) throws(SFTPError) {
        let path = url.path(percentEncoded: false)
        let mode = permissions.map { mode_t($0 & 0o777) } ?? 0o777
        if mkdir(path, mode) == 0 { return }
        var code = errno
        if code == ENOENT, withParents {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw .localFile(path: path, reason: error.localizedDescription)
            }
            if mkdir(path, mode) == 0 { return }
            code = errno
        }
        // Something has the name. A folder, or a link to one, will do.
        var status = stat()
        if code == EEXIST, stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR { return }
        throw failure(path: path, code: code)
    }

    /// The permissions a copy of the folder at `url` is given.
    static func folderPermissions(of url: URL) throws(SFTPError) -> UInt16 {
        let path = url.path(percentEncoded: false)
        var status = stat()
        guard stat(path, &status) == 0 else {
            throw failure(path: path, code: errno)
        }
        return UInt16(status.st_mode & 0o777) | 0o700
    }

    /// The entries of a directory, sorted by name. Links are reported as
    /// links, not as what they point to.
    static func contents(of url: URL) throws(SFTPError) -> [(url: URL, kind: Kind)] {
        let children: [URL]
        do {
            children = try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw .localFile(path: url.path(percentEncoded: false), reason: error.localizedDescription)
        }
        var contents: [(url: URL, kind: Kind)] = []
        for child in children {
            let path = child.path(percentEncoded: false)
            var status = stat()
            guard lstat(path, &status) == 0 else {
                throw failure(path: path, code: errno)
            }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                contents.append((child, .directory(permissions: UInt16(status.st_mode & 0o777) | 0o700)))
            case S_IFREG:
                contents.append((child, .file(size: Int64(status.st_size))))
            default:
                contents.append((child, .other))
            }
        }
        return contents
    }
}

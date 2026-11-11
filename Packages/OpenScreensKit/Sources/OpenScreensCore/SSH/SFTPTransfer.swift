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
    /// The file is fetched with many reads in flight at once and written
    /// straight to `localURL`, replacing what is there. If the transfer fails
    /// or its task is cancelled, the partial file is removed. Cancelling
    /// returns at once, whether or not the server is still answering.
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
    /// The remote file is created, or emptied if it exists, and filled with
    /// many writes in flight at once. If the transfer fails or its task is
    /// cancelled, the server is told to remove the partial file, and the
    /// call returns without waiting for it to do so.
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
        var folders = [""]
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
                    folders.append(path)
                    unvisited.append(path)
                } else {
                    files.append(path)
                    total = total.addingClamped(Int64(clamping: entry.attributes.size ?? 0))
                }
            }
        }

        // Parents were found before their children, so creating the folders
        // in this order always finds the parent in place.
        for folder in folders {
            try LocalFile.createDirectory(at: local(folder))
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
    /// - Parameter progress: Called with the bytes confirmed so far across
    ///   all files and their total size.
    public nonisolated func uploadDirectory(
        localURL: URL,
        to remotePath: String,
        progress: SFTPProgressHandler? = nil
    ) async throws {
        // Parents are found before their children, so creating the remote
        // directories in this order always finds the parent in place.
        var directories = [remotePath]
        var files: [(localURL: URL, remotePath: String)] = []
        var total: Int64 = 0
        var unvisited = [(localURL: localURL, remotePath: remotePath)]
        while let directory = unvisited.popLast() {
            try Task.checkCancellation()
            for child in try LocalFile.contents(of: directory.localURL) {
                let childPath = SFTPPath.join(directory.remotePath, child.url.lastPathComponent)
                switch child.kind {
                case .directory:
                    directories.append(childPath)
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
            try await makeDirectoryIfMissing(directory)
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
            // The size is only a hint, for progress and for pacing; a server
            // that will not say is not a reason to fail.
            let size = try await attributesIfOffered(of: handle)?.size.map { Int64(clamping: $0) }
            let file = try LocalFile(creating: localURL)
            do {
                received = try await fetch(handle, into: file, expectedSize: size, progress: progress)
                try file.close()
            } catch {
                file.closeAndRemove()
                throw error
            }
        } catch {
            await discard(handle)
            throw error
        }
        try await close(handle)
        return received
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
        let size = try file.size()
        let handle = try await open(remotePath, flags: [.write, .create, .truncate])
        let sent: Int64
        do {
            sent = try await store(file, into: handle, size: size, progress: progress)
            try await close(handle)
        } catch {
            // A half-written file under the real name would pass for the
            // whole thing. The server is told to take it away again, and is
            // not waited for: it may be the reason the transfer failed.
            await discard(handle, removing: remotePath)
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

    /// Creates a remote directory unless it is already there.
    private nonisolated func makeDirectoryIfMissing(_ path: String) async throws {
        do {
            try await makeDirectory(path)
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
    let path: String
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    /// Opens an existing file for reading.
    convenience init(reading url: URL) throws(SFTPError) {
        try self.init(url: url, flags: O_RDONLY)
    }

    /// Creates a file for writing, emptying it if it exists.
    convenience init(creating url: URL) throws(SFTPError) {
        try self.init(url: url, flags: O_WRONLY | O_CREAT | O_TRUNC)
    }

    private convenience init(url: URL, flags: Int32) throws(SFTPError) {
        let path = url.path(percentEncoded: false)
        // The mode only matters when the file is created; the user's umask
        // narrows it as usual.
        let descriptor = Darwin.open(path, flags | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            throw Self.failure(path: path, code: errno)
        }
        self.init(path: path, descriptor: descriptor)
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func size() throws(SFTPError) -> Int64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw Self.failure(path: path, code: errno)
        }
        return Int64(status.st_size)
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

    /// Gives up on a file that was being written and deletes what there is
    /// of it.
    func closeAndRemove() {
        try? close()
        unlink(path)
    }

    private static func failure(path: String, code: Int32) -> SFTPError {
        .localFile(path: path, reason: String(cString: strerror(code)))
    }

    // MARK: Directories

    enum Kind {
        case directory
        case file(size: Int64)
        /// A symbolic link or a special file.
        case other
    }

    /// Creates a directory, and any missing parents, unless it exists.
    static func createDirectory(at url: URL) throws(SFTPError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .localFile(path: url.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }

    /// The entries of a directory, sorted by name. Links are reported as
    /// links, not as what they point to.
    static func contents(of url: URL) throws(SFTPError) -> [(url: URL, kind: Kind)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        do {
            return try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { child -> (url: URL, kind: Kind) in
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isDirectory == true {
                        return (child, .directory)
                    }
                    if values.isRegularFile == true {
                        return (child, .file(size: Int64(values.fileSize ?? 0)))
                    }
                    return (child, .other)
                }
        } catch {
            throw .localFile(path: url.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }
}

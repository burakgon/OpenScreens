#if os(macOS)

import Foundation
import NIOCore
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// Runs the client against a server that does what no honest one does.
    /// See ``SFTPTestServer``.
    @Suite("SFTP against a server that misbehaves", .timeLimit(.minutes(2)))
    struct SFTPHostileServerTests {

        /// The names in a local folder, sorted.
        static func names(in directory: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        }

        struct DidNotFinish: Error {}

        /// Waits for `operation`, but only so long: what is being tested
        /// here is often that the client stops waiting, or stops taking
        /// what a server keeps sending. An operation that is still going
        /// after `limit` is cancelled and reported as ``DidNotFinish``.
        static func finishing<Value: Sendable>(
            within limit: Duration,
            _ operation: @escaping @Sendable () async throws -> Value
        ) async throws -> Value {
            let task = Task(operation: operation)
            let outcome = Recorder<Result<Value, any Error>>()
            Task { outcome.record(await task.result) }
            let deadline = ContinuousClock.now + limit
            while outcome.values.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let result = outcome.values.first else {
                task.cancel()
                throw DidNotFinish()
            }
            return try result.get()
        }

        // MARK: The test server itself

        @Test func theTestServerServesAnHonestClient() async throws {
            try await SFTPTestServer.run { server in
                let local = try TemporaryDirectory()
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                #expect(try await sftp.homeDirectory() == "/")

                let contents = Data.testPattern(count: 3 * SFTPClient.transferChunkSize + 77)
                let source = local.file("source.bin")
                try contents.write(to: source)
                try await sftp.makeDirectory("/Folder")
                try await sftp.upload(localURL: source, to: "/Folder/data.bin")
                #expect(server.volume.contents(of: "/Folder/data.bin") == contents)

                #expect(try await sftp.list("/").map(\.name) == ["Folder"])
                let listing = try await sftp.list("/Folder")
                #expect(listing.map(\.name) == ["data.bin"])
                #expect(listing.first?.size == Int64(contents.count))
                #expect(listing.first?.isDirectory == false)

                let copy = local.file("copy.bin")
                try await sftp.download(remotePath: "/Folder/data.bin", to: copy)
                #expect(try Data(contentsOf: copy) == contents)

                let tree = local.file("tree")
                try await sftp.downloadDirectory(remotePath: "/", to: tree)
                #expect(try Data(contentsOf: tree.appending(path: "Folder/data.bin")) == contents)

                try await sftp.rename("/Folder/data.bin", to: "/Folder/renamed.bin")
                try await sftp.remove("/Folder/renamed.bin")
                try await sftp.removeDirectory("/Folder")
                #expect(server.volume.paths.isEmpty)
                #expect(server.volume.openHandleCount == 0)
                await client.close()
            }
        }

        // MARK: Names

        /// A slash followed by a combining mark or an invisible character is
        /// one character to Swift, and still a path separator to the file
        /// system.
        @Test func aNameWithAHiddenSlashCannotLeaveTheFolder() async throws {
            try await SFTPTestServer.run { server in
                let scratch = try TemporaryDirectory()
                let outer = scratch.file("outer")
                let chosen = outer.appending(path: "chosen")
                try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)

                server.volume.addFile("inside.txt", contents: Data("inside".utf8))
                server.volume.addFile("../\u{0301}escaped-file.txt", contents: Data("outside".utf8))
                let folder = server.volume.addDirectory("../\u{200D}escaped-folder")
                server.volume.addFile("nested.txt", in: folder, contents: Data("outside".utf8))

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let listed = try await sftp.list("/").map(\.name)
                #expect(listed == ["inside.txt"])

                try await sftp.downloadDirectory(remotePath: "/", to: chosen)
                #expect(try Self.names(in: outer) == ["chosen"])
                #expect(try Self.names(in: chosen) == ["inside.txt"])
                // Nothing that was left out was even asked for.
                #expect(!server.requests.contains { request in
                    if case .open(_, let path, _, _) = request { return path != "/inside.txt" }
                    if case .opendir(_, let path) = request { return path != "/" }
                    return false
                })
                await client.close()
            }
        }

        @Test func namesThatAreNotOneEntryAreLeftOutOfAListing() async throws {
            try await SFTPTestServer.run { server in
                let folder = server.volume.addDirectory("Folder")
                server.volume.addFile("plain.txt", in: folder)
                for name in ["a/\u{0301}b", "/\u{0301}", "nul\0byte", "trailing/", "/leading", "", "\u{200D}/.."] {
                    server.volume.addFile(name, in: folder)
                }
                // Odd, but each of these is one entry and nothing more.
                let harmless = ["..\u{200D}", ".\u{0301}", "...", "back\\slash", "new\nline", "%2F", "~"]
                for name in harmless {
                    server.volume.addFile(name, in: folder)
                }

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let listed = try await sftp.list(folder).map(\.name)
                #expect(listed.sorted() == (harmless + ["plain.txt"]).sorted())
                await client.close()
            }
        }

        // MARK: Sizes

        /// Each size fits in 63 bits. Their sum does not.
        @Test func sizesThatDoNotAddUpDoNotStopADownload() async throws {
            try await SFTPTestServer.run { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("a.bin", contents: Data("first".utf8)) { $0.claimedSize = UInt64(Int64.max) }
                server.volume.addFile("b.bin", contents: Data("second".utf8)) { $0.claimedSize = UInt64(Int64.max) }
                server.volume.addFile("c.bin", contents: Data("third".utf8)) { $0.claimedSize = .max }

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                #expect(try await sftp.list("/").map(\.size) == [.max, .max, .max])

                let copy = local.file("copy")
                let progress = Recorder<[Int64?]>()
                try await sftp.downloadDirectory(remotePath: "/", to: copy) { completed, total in
                    progress.record([completed, total])
                }
                #expect(try Self.names(in: copy) == ["a.bin", "b.bin", "c.bin"])
                #expect(try Data(contentsOf: copy.appending(path: "b.bin")) == Data("second".utf8))
                // The total is as large as a total gets, and what arrived is
                // counted for what it was.
                #expect(progress.values.first == [0, .max])
                #expect(progress.values.last == [16, .max])

                // One file on its own, with a size that is past even that.
                let single = local.file("single.bin")
                let singleProgress = Recorder<[Int64?]>()
                try await sftp.download(remotePath: "/c.bin", to: single) { completed, total in
                    singleProgress.record([completed, total])
                }
                #expect(try Data(contentsOf: single) == Data("third".utf8))
                #expect(singleProgress.values.last == [5, .max])
                await client.close()
            }
        }

        // MARK: Memory

        static func entry(_ name: String, mode: UInt32 = 0o100644) -> SFTPNameEntry {
            SFTPNameEntry(filename: name, longname: name, attributes: SFTPAttributes(size: 1, mode: mode))
        }

        @Test func aListingThatNeverEndsIsGivenUpOn() async throws {
            let batch = (0..<2000).map { Self.entry("file-\($0)") }
            try await SFTPTestServer.run(script: { request in
                // The same two thousand names, as often as they are asked for.
                if case .readdir(let id, _) = request {
                    return .reply([.name(id: id, entries: batch)])
                }
                return .serve
            }) { server in
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let limit = SFTPClient.maximumListingEntries
                await #expect(throws: SFTPError.tooManyEntries(limit: limit)) {
                    try await Self.finishing(within: .seconds(20)) { try await sftp.list("/") }
                }
                // It stopped asking soon after it had enough.
                let asked = server.requests.count { if case .readdir = $0 { true } else { false } }
                #expect(asked <= limit / batch.count + 1)
                // The session is none the worse for it.
                #expect(try await sftp.realPath(".") == "/")
                #expect(server.volume.openHandleCount == 0)
                await client.close()
            }
        }

        @Test func aListingOfNamesWithoutEndIsGivenUpOn() async throws {
            // A megabyte of name apiece: few entries, and a great deal to keep.
            let megabyte = 1 << 20
            let batch = (0..<4).map {
                SFTPNameEntry(
                    filename: String(repeating: "n", count: megabyte - 1) + "\($0)", longname: "",
                    attributes: SFTPAttributes(mode: 0o100644))
            }
            try await SFTPTestServer.run(script: { request in
                if case .readdir(let id, _) = request {
                    return .reply([.name(id: id, entries: batch)])
                }
                return .serve
            }) { server in
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let megabytes = SFTPClient.maximumListingBytes / megabyte
                await #expect(throws: SFTPError.invalidResponse("a folder listing of more than \(megabytes) MB")) {
                    try await Self.finishing(within: .seconds(20)) { try await sftp.list("/") }
                }
                let asked = server.requests.count { if case .readdir = $0 { true } else { false } }
                #expect(asked == megabytes / batch.count + 1)
                // The session is none the worse for it.
                #expect(try await sftp.realPath(".") == "/")
                await client.close()
            }
        }

        @Test func aListingReplyWithNothingInItIsTheEnd() async throws {
            try await SFTPTestServer.run(script: { request in
                // Not an end-of-file, and not a name either, however often
                // it is asked.
                if case .readdir(let id, _) = request {
                    return .reply([.name(id: id, entries: [])])
                }
                return .serve
            }) { server in
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let listed = try await Self.finishing(within: .seconds(10)) { try await sftp.list("/") }
                #expect(listed.isEmpty)
                await client.close()
            }
        }

        @Test func aTreeWithoutEndIsGivenUpOnBeforeAnythingIsWritten() async throws {
            // Every folder holds fifty thousand folders, each of which holds
            // fifty thousand folders.
            let batch = (0..<50_000).map {
                SFTPNameEntry(filename: "d\($0)", longname: "", attributes: SFTPAttributes(mode: 0o040755))
            }
            let handle = SFTPHandle(bytes: [1])
            let listings = Tally()
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .opendir(let id, _):
                    return .reply([.handle(id: id, handle: handle)])
                case .readdir(let id, _):
                    // One reply with the folders, then the end, by turns.
                    return listings.next().isMultiple(of: 2)
                        ? .reply([.status(id: id, code: .endOfFile, message: "", language: "")])
                        : .reply([.name(id: id, entries: batch)])
                case .close(let id, _):
                    return .reply([.status(id: id, code: .ok, message: "", language: "")])
                default:
                    return .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                let destination = local.file("copy")
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                await #expect(throws: SFTPError.tooManyEntries(limit: SFTPClient.maximumTreeEntries)) {
                    try await Self.finishing(within: .seconds(30)) {
                        try await sftp.downloadDirectory(remotePath: "/", to: destination)
                    }
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                let walked = server.requests.count { if case .opendir = $0 { true } else { false } }
                #expect(walked <= SFTPClient.maximumTreeEntries / batch.count + 1)
                await client.close()
            }
        }

        @Test func aTreeThatGoesDownWithoutEndIsGivenUpOnBeforeAnythingIsWritten() async throws {
            // Every folder holds one folder.
            let handle = SFTPHandle(bytes: [1])
            let listings = Tally()
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .opendir(let id, _):
                    return .reply([.handle(id: id, handle: handle)])
                case .readdir(let id, _):
                    return listings.next().isMultiple(of: 2)
                        ? .reply([.status(id: id, code: .endOfFile, message: "", language: "")])
                        : .reply([.name(id: id, entries: [Self.entry("deeper", mode: 0o040755)])])
                case .close(let id, _):
                    return .reply([.status(id: id, code: .ok, message: "", language: "")])
                default:
                    return .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                let destination = local.file("copy")
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let error = await #expect(throws: SFTPError.self) {
                    try await Self.finishing(within: .seconds(20)) {
                        try await sftp.downloadDirectory(remotePath: "/", to: destination)
                    }
                }
                // It ends where the local file system would have ended it:
                // at a path too long to exist. But it ends in the walk.
                guard case .localFile(let path, let reason) = error else {
                    Issue.record("expected a local error, got \(String(describing: error))")
                    return
                }
                #expect(reason == String(cString: strerror(ENAMETOOLONG)))
                #expect(path.hasPrefix(destination.path + "/deeper/deeper/"))
                #expect(path.utf8.count >= Int(PATH_MAX))
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                let walked = server.requests.count { if case .opendir = $0 { true } else { false } }
                #expect(walked <= Int(PATH_MAX) / "/deeper".utf8.count)
                await client.close()
            }
        }

        @Test func aHandleLongerThanTheProtocolAllowsIsNeverSentBack() async throws {
            let oversized = SFTPHandle(bytes: [UInt8](repeating: 0x48, count: SFTPHandle.maximumLength + 1))
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .open(let id, _, _, _), .opendir(let id, _):
                    return .reply([.handle(id: id, handle: oversized)])
                default:
                    return .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 100_000))
                let client = try await server.connect()
                let sftp = try await client.openSFTP()

                let refusal = SFTPError.invalidResponse("a handle of \(oversized.bytes.count) bytes")
                await #expect(throws: refusal) {
                    try await sftp.download(remotePath: "/data.bin", to: local.file("data.bin"))
                }
                #expect(!FileManager.default.fileExists(atPath: local.file("data.bin").path))
                // A server that breaks the protocol is not talked to further.
                await #expect(throws: refusal) { try await sftp.list("/") }
                #expect(server.requests.count == 2)
                await client.close()
            }
        }

        @Test func aReadThatReturnsMoreThanWasAskedForIsRefused() async throws {
            let reads = Tally()
            try await SFTPTestServer.run(script: { request in
                // The first read is answered with one byte too many.
                if case .read(let id, _, _, let length) = request, reads.next() == 1 {
                    return .reply([.data(id: id, data: ByteBuffer(repeating: 0x41, count: Int(length) + 1))])
                }
                return .serve
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 100_000))
                let client = try await server.connect()
                let sftp = try await client.openSFTP()

                let error = await #expect(throws: SFTPError.self) {
                    try await sftp.download(remotePath: "/data.bin", to: local.file("data.bin"))
                }
                guard case .invalidResponse = error else {
                    Issue.record("expected an invalid response, got \(String(describing: error))")
                    return
                }
                #expect(!FileManager.default.fileExists(atPath: local.file("data.bin").path))
                await client.close()
            }
        }

        // MARK: Silence

        @Test func aRequestTheServerNeverAnswersIsGivenUpOn() async throws {
            try await SFTPTestServer.run(script: { request in
                if case .opendir = request { return .ignore }
                return .serve
            }) { server in
                let client = try await server.connect(timeout: .seconds(1))
                let sftp = try await client.openSFTP()

                let clock = ContinuousClock()
                let started = clock.now
                await #expect(throws: SSHError.timeout) {
                    try await Self.finishing(within: .seconds(10)) { try await sftp.list("/") }
                }
                // Not before the allowance the connection was made with was
                // used up, and not long after.
                let waited = clock.now - started
                #expect(waited >= .seconds(1) && waited < .seconds(4), "waited \(waited)")

                // One request without an answer is not the end of the session.
                #expect(try await sftp.realPath(".") == "/")
                await client.close()
            }
        }

        /// A server that answers slowly is not a server that does not answer:
        /// as long as replies keep coming, the ones still outstanding are
        /// waited for, however long ago they were asked for.
        @Test func aServerThatKeepsAnsweringIsWaitedFor() async throws {
            let reads = Tally()
            try await SFTPTestServer.run(script: { request in
                // The twelve reads that fetch the file are asked for at
                // once and answered 200 ms apart, so the last of them waits
                // well over two seconds. The read after them finds the end.
                if case .read = request {
                    let number = reads.next()
                    return .serveLate(.milliseconds(number <= 12 ? 200 * number : 100))
                }
                return .serve
            }) { server in
                let local = try TemporaryDirectory()
                let contents = Data.testPattern(count: 12 * SFTPClient.transferChunkSize)
                server.volume.addFile("data.bin", contents: contents)
                let client = try await server.connect(timeout: .seconds(2))
                let sftp = try await client.openSFTP()

                let clock = ContinuousClock()
                let started = clock.now
                try await Self.finishing(within: .seconds(30)) {
                    try await sftp.download(remotePath: "/data.bin", to: local.file("data.bin"))
                }
                #expect(try Data(contentsOf: local.file("data.bin")) == contents)
                // Longer than any one request was allowed to go unanswered.
                #expect(clock.now - started > .seconds(2))
                await client.close()
            }
        }

        @Test func aTransferFromAServerThatGoesSilentFails() async throws {
            let reads = Tally()
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .read:
                    return reads.next() <= 8 ? .serve : .ignore
                case .close:
                    return .ignore
                default:
                    return .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 1 << 20))
                let client = try await server.connect(timeout: .seconds(1))
                let sftp = try await client.openSFTP()

                let destination = local.file("data.bin")
                await #expect(throws: SSHError.timeout) {
                    try await Self.finishing(within: .seconds(10)) {
                        try await sftp.download(remotePath: "/data.bin", to: destination)
                    }
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                await client.close()
            }
        }

        @Test func cancellingADownloadDoesNotWaitForAServerThatWentSilent() async throws {
            let reads = Tally()
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .read:
                    return reads.next() <= 8 ? .serve : .ignore
                case .close:
                    // Nor is the request to close the file answered.
                    return .ignore
                default:
                    return .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 1 << 20))
                let client = try await server.connect()
                let sftp = try await client.openSFTP()

                let destination = local.file("data.bin")
                let transfer = Task { try await sftp.download(remotePath: "/data.bin", to: destination) }
                #expect(await server.waitForRequests { _ in reads.value > 8 })
                try await Task.sleep(for: .milliseconds(100))

                let clock = ContinuousClock()
                let cancelled = clock.now
                transfer.cancel()
                await #expect(throws: CancellationError.self) {
                    try await Self.finishing(within: .seconds(5)) { try await transfer.value }
                }
                #expect(clock.now - cancelled < .seconds(3))
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                // The server was still told to close the file, should it
                // ever come round to it.
                #expect(await server.waitForRequests { $0.contains { if case .close = $0 { true } else { false } } })
                await client.close()
            }
        }

        @Test func cancellingAnUploadDoesNotWaitForAServerThatWentSilent() async throws {
            let writes = Tally()
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .write:
                    return writes.next() <= 8 ? .serve : .ignore
                case .close, .remove:
                    return .ignore
                default:
                    return .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                let source = local.file("data.bin")
                try Data.testPattern(count: 1 << 20).write(to: source)
                let client = try await server.connect()
                let sftp = try await client.openSFTP()

                let transfer = Task { try await sftp.upload(localURL: source, to: "/data.bin") }
                #expect(await server.waitForRequests { _ in writes.value > 8 })
                try await Task.sleep(for: .milliseconds(100))

                let clock = ContinuousClock()
                let cancelled = clock.now
                transfer.cancel()
                await #expect(throws: CancellationError.self) {
                    try await Self.finishing(within: .seconds(5)) { try await transfer.value }
                }
                #expect(clock.now - cancelled < .seconds(3))

                // The server was told to close the file and then to remove
                // it, and both were on their way before the upload returned:
                // what is asked next comes after them.
                #expect(try await sftp.realPath(".") == "/")
                let tidying: [String] = server.requests.compactMap { request in
                    switch request {
                    case .close: "close"
                    case .remove(_, let path): Self.isTemporary(path) ? "remove what was written" : "remove \(path)"
                    case .realpath: "realpath"
                    default: nil
                    }
                }
                #expect(tidying == ["close", "remove what was written", "realpath"])
                await client.close()
            }
        }

        @Test func cancellingAListingDoesNotWaitForAServerThatWentSilent() async throws {
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .readdir, .close: .ignore
                default: .serve
                }
            }) { server in
                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let listing = Task { try await sftp.list("/") }
                #expect(await server.waitForRequests { $0.contains { if case .readdir = $0 { true } else { false } } })

                let clock = ContinuousClock()
                let cancelled = clock.now
                listing.cancel()
                await #expect(throws: CancellationError.self) {
                    try await Self.finishing(within: .seconds(5)) { try await listing.value }
                }
                #expect(clock.now - cancelled < .seconds(3))
                #expect(await server.waitForRequests { $0.contains { if case .close = $0 { true } else { false } } })
                await client.close()
            }
        }

        // MARK: What was there before

        static let old = Data("what was there before".utf8)

        /// Whether `path` is the name a file is written under until it is
        /// complete: hidden, beside `/notes.txt`, and nobody else's.
        static func isTemporary(_ path: String) -> Bool {
            path.hasPrefix("/.openscreens-") && path.hasSuffix(".partial")
        }

        /// The requests that name a path, as words.
        static func pathRequests(_ requests: [SFTPPacket]) -> [String] {
            func name(_ path: String) -> String {
                if isTemporary(path) { return "temporary" }
                return path.hasSuffix(".previous") ? "aside" : path
            }
            return requests.compactMap { request in
                switch request {
                case .open(_, let path, _, _): "open \(name(path))"
                case .rename(_, let from, let to): "rename \(name(from)) to \(name(to))"
                case .posixRename(_, let from, let to): "posix-rename \(name(from)) to \(name(to))"
                case .remove(_, let path): "remove \(name(path))"
                case .lstat(_, let path): "lstat \(name(path))"
                case .stat(_, let path): "stat \(name(path))"
                default: nil
                }
            }
        }

        @Test func aDownloadThatFailsLeavesTheFileThatWasThere() async throws {
            try await SFTPTestServer.run(script: { request in
                // The file reads well for a quarter of a megabyte.
                if case .read(let id, _, let offset, _) = request, offset >= 256 * 1024 {
                    return .reply([.status(id: id, code: .failure, message: "I/O error", language: "")])
                }
                return .serve
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 1 << 20))
                let destination = local.file("data.bin")
                try Self.old.write(to: destination)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                await #expect(throws: SFTPError.status(code: .failure, message: "I/O error")) {
                    try await sftp.download(remotePath: "/data.bin", to: destination)
                }
                #expect(try Data(contentsOf: destination) == Self.old)
                #expect(try Self.names(in: local.url) == ["data.bin"])
                await client.close()
            }
        }

        @Test func aCancelledDownloadLeavesTheFileThatWasThere() async throws {
            try await SFTPTestServer.run { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 4 << 20))
                let destination = local.file("data.bin")
                try Self.old.write(to: destination)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let transfer = Task {
                    try await sftp.download(remotePath: "/data.bin", to: destination) { completed, _ in
                        if completed > 1 << 20 {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }
                }
                await #expect(throws: CancellationError.self) { try await transfer.value }
                #expect(try Data(contentsOf: destination) == Self.old)
                #expect(try Self.names(in: local.url) == ["data.bin"])
                await client.close()
            }
        }

        @Test func whatADownloadReplacesStaysWholeUntilTheNewFileIs() async throws {
            try await SFTPTestServer.run { server in
                let local = try TemporaryDirectory()
                let contents = Data.testPattern(count: 1 << 20)
                server.volume.addFile("data.bin", contents: contents)
                let destination = local.file("data.bin")
                try Self.old.write(to: destination)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let seen = Recorder<Data?>()
                try await sftp.download(remotePath: "/data.bin", to: destination) { completed, _ in
                    // Part of the way through, and with the last byte in.
                    if completed > 1 << 19 {
                        seen.record(try? Data(contentsOf: destination))
                    }
                }
                #expect(!seen.values.isEmpty)
                #expect(seen.values.allSatisfy { $0 == Self.old })
                #expect(try Data(contentsOf: destination) == contents)
                #expect(try Self.names(in: local.url) == ["data.bin"])
                await client.close()
            }
        }

        @Test func anUploadIsWrittenAsideAndMovedIntoPlaceInOneStep() async throws {
            try await SFTPTestServer.run(extensions: [SFTPTestServer.posixRename]) { server in
                let local = try TemporaryDirectory()
                let contents = Data.testPattern(count: 300_000)
                let source = local.file("notes.txt")
                try contents.write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old, permissions: 0o640)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let seen = Recorder<Data?>()
                try await sftp.upload(localURL: source, to: "/notes.txt") { _, _ in
                    seen.record(server.volume.contents(of: "/notes.txt"))
                }
                // Whatever the upload had confirmed, the old file was whole.
                #expect(seen.values.dropLast().allSatisfy { $0 == Self.old })
                #expect(server.volume.contents(of: "/notes.txt") == contents)
                #expect(server.volume.paths == ["/notes.txt"])
                #expect(Self.pathRequests(server.requests) == [
                    "lstat /notes.txt", "open temporary", "posix-rename temporary to /notes.txt",
                ])
                // The temporary file is new, and nobody else's by its name.
                // It is made as private as the file it is to replace.
                guard case .open(_, _, let flags, let attributes)? = server.requests.first(where: {
                    if case .open = $0 { true } else { false }
                }) else {
                    Issue.record("no file was opened")
                    return
                }
                #expect(flags == [.write, .create, .exclusive])
                #expect(attributes == SFTPAttributes(mode: 0o640))
                #expect(server.volume.node(at: "/notes.txt")?.permissions == 0o640)
                await client.close()
            }
        }

        @Test func withoutThatExtensionAPlainRenameDoesWhenNothingIsInTheWay() async throws {
            try await SFTPTestServer.run { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                try await sftp.upload(localURL: source, to: "/notes.txt")
                #expect(server.volume.contents(of: "/notes.txt") == Data("new".utf8))
                #expect(server.volume.paths == ["/notes.txt"])
                #expect(Self.pathRequests(server.requests) == [
                    "lstat /notes.txt", "open temporary", "rename temporary to /notes.txt",
                ])
                await client.close()
            }
        }

        @Test func withoutThatExtensionAFileInTheWayIsMovedAsideFirst() async throws {
            try await SFTPTestServer.run { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                try await sftp.upload(localURL: source, to: "/notes.txt")
                #expect(server.volume.contents(of: "/notes.txt") == Data("new".utf8))
                #expect(server.volume.paths == ["/notes.txt"])
                #expect(Self.pathRequests(server.requests) == [
                    "lstat /notes.txt",
                    "open temporary",
                    // Refused, as version 3 lets a server refuse it.
                    "rename temporary to /notes.txt",
                    "lstat /notes.txt",
                    "rename /notes.txt to aside",
                    "rename temporary to /notes.txt",
                    "remove aside",
                ])
                await client.close()
            }
        }

        @Test func ifTheNewFileCannotTakeItsPlaceTheOldOneIsPutBack() async throws {
            try await SFTPTestServer.run(script: { request in
                // The new file is never let into place, not even once the
                // old one is out of the way.
                if case .rename(let id, let from, "/notes.txt") = request, Self.isTemporary(from) {
                    return .reply([.status(id: id, code: .failure, message: "Not today", language: "")])
                }
                return .serve
            }) { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                await #expect(throws: SFTPError.status(code: .failure, message: "Not today")) {
                    try await sftp.upload(localURL: source, to: "/notes.txt")
                }
                #expect(try await sftp.realPath(".") == "/")
                #expect(server.volume.contents(of: "/notes.txt") == Self.old)
                #expect(server.volume.paths == ["/notes.txt"])
                #expect(Self.pathRequests(server.requests) == [
                    "lstat /notes.txt",
                    "open temporary",
                    "rename temporary to /notes.txt",
                    "lstat /notes.txt",
                    "rename /notes.txt to aside",
                    "rename temporary to /notes.txt",
                    "rename aside to /notes.txt",
                    "remove temporary",
                ])
                await client.close()
            }
        }

        @Test(arguments: [true, false])
        func anUploadThatFailsLeavesTheFileThatWasThere(renamesInOneStep: Bool) async throws {
            let writes = Tally()
            try await SFTPTestServer.run(
                extensions: renamesInOneStep ? [SFTPTestServer.posixRename] : [],
                script: { request in
                    if case .write(let id, _, _, _) = request, writes.next() == 3 {
                        return .reply([.status(id: id, code: .failure, message: "Disk full", language: "")])
                    }
                    return .serve
                }
            ) { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data.testPattern(count: 300_000).write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                await #expect(throws: SFTPError.status(code: .failure, message: "Disk full")) {
                    try await sftp.upload(localURL: source, to: "/notes.txt")
                }
                // What is asked next is answered after the tidying up.
                #expect(try await sftp.realPath(".") == "/")
                #expect(server.volume.contents(of: "/notes.txt") == Self.old)
                #expect(server.volume.paths == ["/notes.txt"])
                #expect(server.volume.openHandleCount == 0)
                #expect(Self.pathRequests(server.requests) == ["lstat /notes.txt", "open temporary", "remove temporary"])
                await client.close()
            }
        }

        @Test(arguments: [true, false])
        func aFolderInTheWayOfAnUploadIsLeftAlone(renamesInOneStep: Bool) async throws {
            try await SFTPTestServer.run(
                extensions: renamesInOneStep ? [SFTPTestServer.posixRename] : []
            ) { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)
                let folder = server.volume.addDirectory("notes.txt")
                server.volume.addFile("kept", in: folder, contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let error = await #expect(throws: SFTPError.self) {
                    try await sftp.upload(localURL: source, to: "/notes.txt")
                }
                #expect(error?.statusCode == .failure)
                #expect(try await sftp.realPath(".") == "/")
                #expect(server.volume.paths == ["/notes.txt", "/notes.txt/kept"])
                #expect(server.volume.node(at: "/notes.txt")?.isDirectory == true)
                await client.close()
            }
        }

        /// Once the whole file is on the server, giving it its name is not
        /// something to stop half-way: least of all where that takes two
        /// renames, with nothing under the name in between.
        @Test(arguments: [true, false])
        func cancellingWhileTheFileIsMovedIntoPlaceLetsThatFinish(renamesInOneStep: Bool) async throws {
            try await SFTPTestServer.run(
                extensions: renamesInOneStep ? [SFTPTestServer.posixRename] : [],
                script: { request in
                    switch request {
                    case .rename, .posixRename: .serveLate(.milliseconds(300))
                    default: .serve
                    }
                }
            ) { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let upload = Task { try await sftp.upload(localURL: source, to: "/notes.txt") }
                #expect(await server.waitForRequests { requests in
                    requests.contains { request in
                        switch request {
                        case .rename, .posixRename: true
                        default: false
                        }
                    }
                })
                upload.cancel()
                // The upload was complete in all but name, and completes.
                try await upload.value
                #expect(server.volume.contents(of: "/notes.txt") == Data("new".utf8))
                #expect(server.volume.paths == ["/notes.txt"])
                await client.close()
            }
        }

        @Test func cancellingWhileTheFinishedFileIsBeingClosedStillLeavesWhatWasThere() async throws {
            try await SFTPTestServer.run(
                extensions: [SFTPTestServer.posixRename],
                script: { request in
                    if case .close = request { return .serveLate(.milliseconds(300)) }
                    return .serve
                }
            ) { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let upload = Task { try await sftp.upload(localURL: source, to: "/notes.txt") }
                #expect(await server.waitForRequests { $0.contains { if case .close = $0 { true } else { false } } })
                upload.cancel()
                await #expect(throws: CancellationError.self) { try await upload.value }

                #expect(try await sftp.realPath(".") == "/")
                #expect(server.volume.contents(of: "/notes.txt") == Self.old)
                #expect(server.volume.paths == ["/notes.txt"])
                #expect(!Self.pathRequests(server.requests).contains { $0.contains("rename") })
                await client.close()
            }
        }

        @Test func anUploadCancelledWhileItsFileIsBeingOpenedLeavesNothingBehind() async throws {
            try await SFTPTestServer.run(
                extensions: [SFTPTestServer.posixRename],
                script: { request in
                    // The server opens the file at once and takes its time
                    // to say so.
                    if case .open = request { return .serveLate(.seconds(2)) }
                    return .serve
                }
            ) { server in
                let local = try TemporaryDirectory()
                let source = local.file("notes.txt")
                try Data("new".utf8).write(to: source)
                server.volume.addFile("notes.txt", contents: Self.old)

                let client = try await server.connect()
                let sftp = try await client.openSFTP()
                let upload = Task { try await sftp.upload(localURL: source, to: "/notes.txt") }
                #expect(await server.waitForRequests { $0.contains { if case .open = $0 { true } else { false } } })
                #expect(server.volume.openHandleCount == 1)

                let clock = ContinuousClock()
                let cancelled = clock.now
                upload.cancel()
                await #expect(throws: CancellationError.self) { try await upload.value }
                #expect(clock.now - cancelled < .milliseconds(1500))

                // The answer arrives with nobody waiting for it. The file it
                // opened is closed and taken away all the same.
                #expect(await server.waitForRequests { $0.contains { if case .remove = $0 { true } else { false } } })
                #expect(try await sftp.realPath(".") == "/")
                #expect(server.volume.openHandleCount == 0)
                #expect(server.volume.contents(of: "/notes.txt") == Self.old)
                #expect(server.volume.paths == ["/notes.txt"])
                await client.close()
            }
        }

        @Test func aDownloadCancelledWhileItsFileIsBeingOpenedClosesItOnceItIs() async throws {
            try await SFTPTestServer.run(script: { request in
                switch request {
                case .open, .opendir: .serveLate(.seconds(1))
                default: .serve
                }
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 100_000))
                let client = try await server.connect()
                let sftp = try await client.openSFTP()

                // A file, and a folder for a listing.
                let download = Task { try await sftp.download(remotePath: "/data.bin", to: local.file("data.bin")) }
                let listing = Task { try await sftp.list("/") }
                #expect(await server.waitForRequests { _ in server.volume.openHandleCount == 2 })
                download.cancel()
                listing.cancel()
                await #expect(throws: CancellationError.self) { try await download.value }
                await #expect(throws: CancellationError.self) { try await listing.value }

                #expect(await server.waitForRequests { _ in server.volume.openHandleCount == 0 })
                #expect(try Self.names(in: local.url).isEmpty)
                await client.close()
            }
        }

        @Test func aFileOpenedAfterItsRequestTimedOutIsClosed() async throws {
            try await SFTPTestServer.run(script: { request in
                if case .open = request { return .serveLate(.seconds(3)) }
                return .serve
            }) { server in
                let local = try TemporaryDirectory()
                server.volume.addFile("data.bin", contents: .testPattern(count: 100_000))
                let client = try await server.connect(timeout: .seconds(1))
                let sftp = try await client.openSFTP()

                await #expect(throws: SSHError.timeout) {
                    try await sftp.download(remotePath: "/data.bin", to: local.file("data.bin"))
                }
                #expect(server.volume.openHandleCount == 1)
                #expect(await server.waitForRequests { _ in server.volume.openHandleCount == 0 })
                await client.close()
            }
        }
    }
}

#endif

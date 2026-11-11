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
    }
}

#endif

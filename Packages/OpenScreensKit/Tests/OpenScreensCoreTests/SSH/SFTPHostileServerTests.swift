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
    }
}

#endif

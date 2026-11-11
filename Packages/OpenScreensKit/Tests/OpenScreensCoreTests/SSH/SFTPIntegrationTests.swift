#if os(macOS)

import Foundation
import Testing
@testable import OpenScreensCore

/// File transfer through a private `sshd`. Client and server share a disk
/// here, so both ends of every transfer can be inspected.
extension SSHTests.SSHIntegrationTests {

    // MARK: File transfer

    @Test func filesMakeTheRoundTrip() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // Where the session starts, and what paths resolve to.
            let home = try await sftp.homeDirectory()
            #expect(home.hasPrefix("/"))
            #expect(home == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path)
            let base = try await sftp.realPath(server.directory.path)
            #expect(try base == server.directory.canonicalPath)

            // Make a directory and upload into it. The size is not a
            // multiple of the transfer chunk, so the tail is exercised.
            let directory = base + "/Uploads"
            try await sftp.makeDirectory(directory)
            #expect(try await sftp.realPath(directory + "/../Uploads/./data.bin") == directory + "/data.bin")
            let contents = Data.testPattern(count: 5 * 1024 * 1024 + 123)
            let source = local.file("source.bin")
            try contents.write(to: source)
            let uploadProgress = Recorder<[Int64?]>()
            try await sftp.upload(localURL: source, to: directory + "/data.bin") { completed, total in
                uploadProgress.record([completed, total])
            }
            #expect(try Data(contentsOf: server.directory.appending(path: "Uploads/data.bin")) == contents)
            Self.expectSteadyProgress(uploadProgress.values, to: Int64(contents.count))

            // The listing describes it.
            let listing = try await sftp.list(directory)
            #expect(listing.map(\.name) == ["data.bin"])
            let item = try #require(listing.first)
            #expect(item.path == directory + "/data.bin")
            #expect(item.size == Int64(contents.count))
            #expect(!item.isDirectory && !item.isSymlink)
            // The server created the file with its usual permissions.
            let mode = try FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions]
            #expect(item.permissions == (mode as? NSNumber)?.uint16Value)
            #expect(abs(try #require(item.modified).timeIntervalSinceNow) < 120)
            #expect(try await sftp.list(base).map(\.name) == ["Uploads"])
            #expect(try await sftp.list(base).first?.isDirectory == true)

            let attributes = try await sftp.attributes(of: item.path)
            #expect(attributes.size == UInt64(contents.count))
            #expect(attributes.isRegularFile)
            #expect(try await sftp.attributes(of: directory).isDirectory)

            // Download it again and compare.
            let destination = local.file("copy.bin")
            let downloadProgress = Recorder<[Int64?]>()
            try await sftp.download(remotePath: item.path, to: destination) { completed, total in
                downloadProgress.record([completed, total])
            }
            #expect(try Data(contentsOf: destination) == contents)
            Self.expectSteadyProgress(downloadProgress.values, to: Int64(contents.count))

            // Rename, then remove.
            try await sftp.rename(item.path, to: directory + "/renamed.bin")
            #expect(try await sftp.list(directory).map(\.name) == ["renamed.bin"])
            try await sftp.remove(directory + "/renamed.bin")
            #expect(try await sftp.list(directory).isEmpty)
            try await sftp.removeDirectory(directory)
            #expect(try await sftp.list(base).isEmpty)

            await sftp.close()
            // The session ended; the connection it ran on did not.
            #expect(client.isConnected)
            await #expect(throws: SFTPError.connectionClosed) { try await sftp.list(base) }
            await client.close()
        }
    }

    /// Progress must start at zero, never go backwards, end at `size`, and
    /// name `size` as the total throughout.
    private static func expectSteadyProgress(
        _ reports: [[Int64?]],
        to size: Int64,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let completed = reports.compactMap { $0.first ?? nil }
        #expect(completed.first == 0, sourceLocation: sourceLocation)
        #expect(completed.last == size, sourceLocation: sourceLocation)
        #expect(completed == completed.sorted(), sourceLocation: sourceLocation)
        #expect(completed.count > 10, sourceLocation: sourceLocation)
        #expect(reports.allSatisfy { $0.last == size }, sourceLocation: sourceLocation)
    }

    @Test func aServerWithoutFileTransferSaysSo() async throws {
        try await PrivateSSHServer.run(offersSFTP: false) { server in
            let client = try await server.connect()
            await #expect(throws: SSHError.subsystemUnavailable("sftp")) {
                try await client.openSFTP()
            }
            // The refusal cost a channel, not the connection.
            #expect(client.isConnected)
            await client.close()
        }
    }

    @Test func filesOfAwkwardSizesArriveWhole() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let chunk = SFTPClient.transferChunkSize

            // Empty, one byte, around one chunk, exactly a pipeline's
            // worth, and a name that needs encoding.
            let sizes = [0, 1, chunk - 1, chunk, chunk + 1, chunk * SFTPClient.transferPipelineDepth]
            for (index, size) in sizes.enumerated() {
                let contents = Data.testPattern(count: size, seed: UInt64(index + 1))
                let source = local.file("source-\(index)")
                try contents.write(to: source)
                let remotePath = server.directory.path + "/dätä \(index).bin"

                try await sftp.upload(localURL: source, to: remotePath)
                #expect(try Data(contentsOf: URL(filePath: remotePath)) == contents, "upload of \(size) bytes")

                let copy = local.file("copy-\(index)")
                try await sftp.download(remotePath: remotePath, to: copy)
                #expect(try Data(contentsOf: copy) == contents, "download of \(size) bytes")
            }

            // Uploading over an existing file replaces it entirely.
            let shorter = local.file("shorter")
            try Data("short".utf8).write(to: shorter)
            let target = server.directory.path + "/dätä 5.bin"
            try await sftp.upload(localURL: shorter, to: target)
            #expect(try Data(contentsOf: URL(filePath: target)) == Data("short".utf8))
            // And so does downloading over one.
            let existing = local.file("copy-5")
            try await sftp.download(remotePath: target, to: existing)
            #expect(try Data(contentsOf: existing) == Data("short".utf8))

            // Nothing was left lying beside the files at either end.
            let remoteNames = try FileManager.default.contentsOfDirectory(atPath: server.directory.path)
            #expect(remoteNames.sorted() == sizes.indices.map { "dätä \($0).bin" })
            let localNames = try FileManager.default.contentsOfDirectory(atPath: local.url.path)
            #expect(localNames.count == 2 * sizes.count + 1)
            #expect(!localNames.contains { $0.hasPrefix(".") })
            await client.close()
        }
    }

    @Test func theServersRefusalsComeBackAsTypedErrors() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let base = server.directory.path

            func statusCode(_ operation: () async throws -> Void) async -> SFTPStatusCode? {
                do {
                    try await operation()
                    Issue.record("the operation was expected to fail")
                    return nil
                } catch let error as SFTPError {
                    return error.statusCode
                } catch {
                    Issue.record("expected an SFTPError, got \(error)")
                    return nil
                }
            }

            #expect(await statusCode { _ = try await sftp.attributes(of: base + "/missing") } == .noSuchFile)
            #expect(await statusCode { _ = try await sftp.list(base + "/missing") } == .noSuchFile)
            #expect(await statusCode { try await sftp.remove(base + "/missing") } == .noSuchFile)
            #expect(await statusCode {
                try await sftp.rename(base + "/missing", to: base + "/elsewhere")
            } == .noSuchFile)

            // Version 3 has only a general failure for these.
            try await sftp.makeDirectory(base + "/full")
            try Data("x".utf8).write(to: server.directory.appending(path: "full/file"))
            #expect(await statusCode { try await sftp.removeDirectory(base + "/full") } == .failure)
            #expect(await statusCode { try await sftp.makeDirectory(base + "/full") } == .failure)

            // A download that cannot start leaves no file behind…
            let destination = local.file("never.bin")
            #expect(await statusCode {
                try await sftp.download(remotePath: base + "/missing", to: destination)
            } == .noSuchFile)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            // …and an upload of a file that is not there is a local error.
            let error = await #expect(throws: SFTPError.self) {
                try await sftp.upload(localURL: local.file("absent"), to: base + "/absent")
            }
            guard case .localFile = error else {
                Issue.record("expected .localFile, got \(String(describing: error))")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: base + "/absent"))

            // None of that harmed the session.
            #expect(try await sftp.list(base).map(\.name) == ["full"])
            await client.close()
        }
    }

    @Test func aListingTellsFilesFoldersAndLinksApart() async throws {
        try await PrivateSSHServer.run { server in
            let base = server.directory
            try FileManager.default.createDirectory(
                at: base.appending(path: "Folder"), withIntermediateDirectories: false)
            try Data("12345".utf8).write(to: base.appending(path: "file10.txt"))
            try Data().write(to: base.appending(path: "file2.txt"))
            try Data().write(to: base.appending(path: ".hidden"))
            try FileManager.default.createSymbolicLink(
                at: base.appending(path: "link"), withDestinationURL: base.appending(path: "Folder"))

            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let listing = try await sftp.list(base.path)

            // Sorted the way Finder sorts, with numbers in order.
            #expect(listing.map(\.name) == [".hidden", "file2.txt", "file10.txt", "Folder", "link"])
            let byName = Dictionary(uniqueKeysWithValues: listing.map { ($0.name, $0) })
            #expect(byName["Folder"]?.isDirectory == true)
            #expect(byName["file10.txt"]?.isDirectory == false)
            #expect(byName["file10.txt"]?.size == 5)
            // A link is listed as a link, whatever it points to…
            #expect(byName["link"]?.isSymlink == true)
            #expect(byName["link"]?.isDirectory == false)
            // …and following it is a separate question.
            #expect(try await sftp.attributes(of: base.path + "/link").isDirectory)
            #expect(try await sftp.attributes(of: base.path + "/link", followSymlinks: false).isSymbolicLink)
            await client.close()
        }
    }

    @Test func aCancelledUploadStopsAndCleansUp() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let source = local.file("big.bin")
            try Data.testPattern(count: 48 * 1024 * 1024).write(to: source)
            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let remotePath = server.directory.path + "/big.bin"

            let transfer = Task {
                try await sftp.upload(localURL: source, to: remotePath) { completed, _ in
                    // Progress is reported from the transferring task, so
                    // this cancels the transfer from within, part way.
                    if completed > 2 * 1024 * 1024 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            await #expect(throws: CancellationError.self) { try await transfer.value }
            // The server was told to take away what had been written, and
            // the upload did not wait to hear that it had. Whatever is asked
            // next is answered after that is done, so the listing shows it
            // gone; and the session is still good for the next transfer.
            #expect(try await sftp.list(server.directory.path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: remotePath))
            await client.close()
        }
    }

    @Test func aCancelledUploadLeavesTheFileThatWasThere() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let source = local.file("big.bin")
            try Data.testPattern(count: 48 * 1024 * 1024).write(to: source)
            let remote = server.directory.appending(path: "report.bin")
            let original = Data("last week's good copy".utf8)
            try original.write(to: remote)
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            let seen = Recorder<Data?>()
            let transfer = Task {
                try await sftp.upload(localURL: source, to: remote.path) { completed, _ in
                    if completed > 2 * 1024 * 1024 {
                        // Megabytes have gone up, and the file they are to
                        // replace has not been touched.
                        seen.record(try? Data(contentsOf: remote))
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            await #expect(throws: CancellationError.self) { try await transfer.value }
            #expect(!seen.values.isEmpty && seen.values.allSatisfy { $0 == original })
            // Once the server has tidied up, what was there is all there is.
            #expect(try await sftp.list(server.directory.path).map(\.name) == ["report.bin"])
            #expect(try Data(contentsOf: remote) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: server.directory.path) == ["report.bin"])
            await client.close()
        }
    }

    @Test func anUploadReplacesAFileWithoutAMomentOfItBeingGone() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let contents = Data.testPattern(count: 3 * 1024 * 1024)
            let source = local.file("report.bin")
            try contents.write(to: source)
            let remote = server.directory.appending(path: "report.bin")
            let original = Data("last week's good copy".utf8)
            try original.write(to: remote)
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // Read the file over and over while it is being replaced. It is
            // the old one or the new one every time, never missing and
            // never half of either.
            let watcher = Task {
                var seen = Set<Data?>()
                while !Task.isCancelled {
                    seen.insert(try? Data(contentsOf: remote))
                    await Task.yield()
                }
                return seen
            }
            try await sftp.upload(localURL: source, to: remote.path)
            #expect(try Data(contentsOf: remote) == contents)
            watcher.cancel()
            let seen = await watcher.value
            #expect(seen.isSubset(of: [original, contents]))
            #expect(seen.contains(original))
            #expect(try FileManager.default.contentsOfDirectory(atPath: server.directory.path) == ["report.bin"])
            await client.close()
        }
    }

    // MARK: Permissions and dates

    private static func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require((value as? NSNumber)?.intValue)
    }

    private static func setPermissions(_ permissions: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// What became of `original` at the receiving end, where new files are
    /// made under a mask that may take permissions away: nothing was added,
    /// and what the owner may do, which no mask in use takes away, is as it
    /// was.
    private static func expectCarried(
        _ carried: Int, from original: Int, _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(carried & ~original == 0, comment, sourceLocation: sourceLocation)
        #expect(carried & 0o700 == original & 0o700, comment, sourceLocation: sourceLocation)
    }

    @Test func aFileKeepsItsPermissionsOnTheWayUp() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // A private key, a script, an ordinary file, and one with bits
            // that are not to travel at all.
            for (name, mode) in [("id_ed25519", 0o600), ("deploy.sh", 0o755), ("notes.txt", 0o644), ("odd", 0o4750)] {
                let source = local.file(name)
                try Data(name.utf8).write(to: source)
                try Self.setPermissions(mode, of: source)
                let remote = server.directory.appending(path: name)
                try await sftp.upload(localURL: source, to: remote.path)

                let arrived = try Self.permissions(remote)
                Self.expectCarried(arrived, from: mode & 0o777, "\(name) arrived as \(String(arrived, radix: 8))")
            }
            #expect(try Self.permissions(server.directory.appending(path: "id_ed25519")) == 0o600)
            await client.close()
        }
    }

    @Test func aFileKeepsItsPermissionsAndItsDateOnTheWayDown() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let written = Date(timeIntervalSince1970: 981_173_106)

            for (name, mode) in [("id_ed25519", 0o600), ("deploy.sh", 0o755), ("notes.txt", 0o644), ("odd", 0o6751)] {
                let remote = server.directory.appending(path: name)
                try Data(name.utf8).write(to: remote)
                try Self.setPermissions(mode, of: remote)
                try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: remote.path)
                let copy = local.file(name)
                try await sftp.download(remotePath: remote.path, to: copy)

                let arrived = try Self.permissions(copy)
                Self.expectCarried(arrived, from: mode & 0o777, "\(name) arrived as \(String(arrived, radix: 8))")
                let modified = try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate]
                #expect(modified as? Date == written, "\(name)")
            }
            #expect(try Self.permissions(local.file("id_ed25519")) == 0o600)
            await client.close()
        }
    }

    @Test func foldersKeepWhoElseMayLookIntoThem() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // A private folder with a private file in it, and beside it a
            // folder nobody may write to, the owner included.
            let tree = local.file("tree")
            for (folder, mode) in [("private", 0o700), ("readonly", 0o555)] {
                let url = tree.appending(path: folder)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("secret".utf8).write(to: url.appending(path: "key"))
                try Self.setPermissions(0o600, of: url.appending(path: "key"))
                try Self.setPermissions(mode, of: url)
            }
            try Self.setPermissions(0o750, of: tree)
            defer { try? Self.setPermissions(0o755, of: tree.appending(path: "readonly")) }

            func expectCopy(at root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
                Self.expectCarried(try Self.permissions(root), from: 0o750, "the folder itself", sourceLocation: sourceLocation)
                #expect(try Self.permissions(root.appending(path: "private")) == 0o700, sourceLocation: sourceLocation)
                #expect(try Self.permissions(root.appending(path: "private/key")) == 0o600, sourceLocation: sourceLocation)
                // The owner can always write to the copy of a folder: it had
                // to be filled. Nobody else gained anything.
                let readonly = try Self.permissions(root.appending(path: "readonly"))
                #expect(readonly & 0o700 == 0o700, sourceLocation: sourceLocation)
                #expect(readonly & ~0o755 == 0, sourceLocation: sourceLocation)
                #expect(try Data(contentsOf: root.appending(path: "readonly/key")) == Data("secret".utf8),
                        sourceLocation: sourceLocation)
            }

            let remote = server.directory.appending(path: "tree")
            try await sftp.uploadDirectory(localURL: tree, to: remote.path)
            try expectCopy(at: remote)

            // The owner's own write permission is taken away again on the
            // server, as it was on the folder the copy was made from.
            try Self.setPermissions(0o555, of: remote.appending(path: "readonly"))
            defer { try? Self.setPermissions(0o755, of: remote.appending(path: "readonly")) }
            let copy = local.file("copy")
            try await sftp.downloadDirectory(remotePath: remote.path, to: copy)
            try expectCopy(at: copy)
            await client.close()
        }
    }

    @Test func replacingAFileDoesNotChangeWhoMayReadIt() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            func permissions(_ url: URL) throws -> Int? {
                (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            }
            func make(_ url: URL, _ text: String, permissions: Int) throws {
                try Data(text.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // A private file on the server is given new contents from a
            // file anyone may read here, and the other way round; and one
            // that others may write to stays that way.
            let source = local.file("source.txt")
            try make(source, "new", permissions: 0o644)
            for (name, mode) in [("private.txt", 0o600), ("shared.txt", 0o664), ("script.sh", 0o755)] {
                let remote = server.directory.appending(path: name)
                try make(remote, "old", permissions: mode)
                try await sftp.upload(localURL: source, to: remote.path)
                #expect(try Data(contentsOf: remote) == Data("new".utf8), "\(name)")
                // The server's mask for new files may take bits away, as it
                // would from any new file, and never adds one.
                let now = try #require(try permissions(remote), "\(name)")
                #expect(now & ~mode == 0, "\(name) went from \(String(mode, radix: 8)) to \(String(now, radix: 8))")
                #expect(now & 0o700 == mode & 0o700, "\(name)")

                let copy = local.file(name)
                try make(copy, "old", permissions: mode)
                try make(remote, "newer", permissions: 0o644)
                try await sftp.download(remotePath: remote.path, to: copy)
                #expect(try Data(contentsOf: copy) == Data("newer".utf8), "\(name)")
                #expect(try permissions(copy) == mode, "\(name)")
            }
            await client.close()
        }
    }

    @Test func anUploadIntoAFolderThatTakesNoNewFilesIsRefused() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let source = local.file("report.bin")
            try Data("new".utf8).write(to: source)
            // The file can be written. The folder it is in cannot.
            let folder = server.directory.appending(path: "locked")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let remote = folder.appending(path: "report.bin")
            let original = Data("last week's good copy".utf8)
            try original.write(to: remote)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
            let client = try await server.connect()
            let sftp = try await client.openSFTP()

            // Writing straight into the file would work, and would leave it
            // in pieces if the upload then failed. There is nowhere to put
            // the new file until it is whole, so the upload is not begun.
            let error = await #expect(throws: SFTPError.self) {
                try await sftp.upload(localURL: source, to: remote.path)
            }
            #expect(error?.statusCode == .permissionDenied)
            #expect(try Data(contentsOf: remote) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.bin"])
            await client.close()
        }
    }

    @Test func aCancelledDownloadRemovesThePartialFile() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let remote = server.directory.appending(path: "big.bin")
            try Data.testPattern(count: 48 * 1024 * 1024).write(to: remote)
            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let destination = local.file("big.bin")

            let transfer = Task {
                try await sftp.download(remotePath: remote.path, to: destination) { completed, _ in
                    if completed > 2 * 1024 * 1024 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            await #expect(throws: CancellationError.self) { try await transfer.value }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try await sftp.list(server.directory.path).map(\.name) == ["big.bin"])
            await client.close()
        }
    }

    @Test func directoriesAreCopiedWithEverythingInThem() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            // A small tree with the cases that matter: nesting, an empty
            // folder, an empty file, and a link that must not be followed.
            let files: [String: Data] = [
                "readme.txt": Data("hello".utf8),
                "empty": Data(),
                "nested/deeper/data.bin": .testPattern(count: 200_000),
                "nested/other.bin": .testPattern(count: 70_000, seed: 2),
            ]
            let tree = local.file("tree")
            for (path, contents) in files {
                let url = tree.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url)
            }
            try FileManager.default.createDirectory(
                at: tree.appending(path: "hollow"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: tree.appending(path: "loop"), withDestinationURL: tree)
            let total = Int64(files.values.reduce(0) { $0 + $1.count })

            let client = try await server.connect()
            let sftp = try await client.openSFTP()
            let remote = server.directory.path + "/tree"

            let uploadProgress = Recorder<[Int64?]>()
            try await sftp.uploadDirectory(localURL: tree, to: remote) { completed, total in
                uploadProgress.record([completed, total])
            }
            #expect(uploadProgress.values.last == [total, total])
            #expect(try Self.contents(of: URL(filePath: remote)) == files)
            #expect(FileManager.default.fileExists(atPath: remote + "/hollow"))
            #expect(!FileManager.default.fileExists(atPath: remote + "/loop"))

            // Uploading again merges into what is there.
            try await sftp.uploadDirectory(localURL: tree, to: remote)
            #expect(try Self.contents(of: URL(filePath: remote)) == files)

            // The server's copy has the link too; it is skipped on the
            // way back as well.
            try FileManager.default.createSymbolicLink(
                atPath: remote + "/loop", withDestinationPath: remote)
            let copy = local.file("copy")
            let downloadProgress = Recorder<[Int64?]>()
            try await sftp.downloadDirectory(remotePath: remote, to: copy) { completed, total in
                downloadProgress.record([completed, total])
            }
            #expect(downloadProgress.values.last == [total, total])
            #expect(try Self.contents(of: copy) == files)
            #expect(FileManager.default.fileExists(atPath: copy.appending(path: "hollow").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "loop").path))
            await client.close()
        }
    }

    /// Every regular file under `root`, by its path relative to it.
    private static func contents(of root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        var found: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = url.resolvingSymlinksInPath().path
            found[String(path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return found
    }

    @Test func oneConnectionCarriesATunnelAndATransferAtOnce() async throws {
        try await PrivateSSHServer.run { server in
            let local = try TemporaryDirectory()
            let echo = try await LoopbackServer.start(.echo)
            defer { echo.stop() }
            let contents = Data.testPattern(count: 6 * 1024 * 1024)
            try contents.write(to: server.directory.appending(path: "file.bin"))

            let client = try await server.connect()
            let tunnel = try await client.openTunnel(toHost: "127.0.0.1", port: echo.port)
            let sftp = try await client.openSFTP()
            #expect(await server.waitForSessionCount(1))

            // A download runs while the tunnel is busy echoing.
            let destination = local.file("file.bin")
            async let download: Void = sftp.download(
                remotePath: server.directory.path + "/file.bin", to: destination)
            let payload = Data.testPattern(count: 2 * 1024 * 1024, seed: 9)
            async let echoed = Self.read(payload.count, from: tunnel)
            for offset in stride(from: 0, to: payload.count, by: 100_000) {
                try await tunnel.send(payload.subdata(in: offset..<min(offset + 100_000, payload.count)))
            }
            #expect(try await echoed == payload)
            try await download
            #expect(try Data(contentsOf: destination) == contents)

            // Closing the connection ends everything on it.
            await client.close()
            await #expect(throws: (any Error).self) { try await tunnel.read(exactly: 1) }
            await #expect(throws: SFTPError.self) { try await sftp.list("/") }
        }
    }

    @Test func aSessionThatIsLetGoClosesItsChannel() async throws {
        try await PrivateSSHServer.run { server in
            // The client, and with it the connection, lives only as long
            // as something uses it: here, a file transfer session.
            var sftp: SFTPClient? = try await server.connect().openSFTP()
            #expect(try await sftp?.realPath("/") == "/")
            #expect(await server.waitForSessionCount(1))
            sftp = nil
            #expect(await server.waitForSessionCount(0))
        }
    }
}

#endif

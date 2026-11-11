import Foundation
import NIOCore
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// The local end of a transfer: the file being read or written.
    @Suite("SFTP local files")
    struct SFTPLocalFileTests {

        @Test func sizesAreAddedWithoutOverflowing() {
            #expect(Int64(40).addingClamped(2) == 42)
            #expect(Int64(40).addingClamped(-42) == -2)
            #expect(Int64.max.addingClamped(0) == .max)
            #expect(Int64.max.addingClamped(1) == .max)
            #expect(Int64.max.addingClamped(.max) == .max)
            #expect((Int64.max - 1).addingClamped(1) == .max)
            #expect(Int64.max.addingClamped(.min) == -1)
            #expect(Int64.min.addingClamped(-1) == .min)
        }

        @Test func aPositionNoFileCanHaveIsRefusedNotTrappedOn() throws {
            let directory = try TemporaryDirectory()
            let url = directory.file("data.bin")
            try Data("0123456789".utf8).write(to: url)
            let file = try LocalFile(reading: url)

            // Positions in a file are signed 64-bit numbers to the system.
            // An offset comes in as an unsigned one.
            for offset in [UInt64(Int64.max) + 1, .max, UInt64(Int64.max) - 2] {
                var buffer = ByteBuffer()
                let error = #expect(throws: SFTPError.self, "\(offset)") {
                    _ = try file.read(into: &buffer, maximumLength: 8, at: offset)
                }
                #expect(error == .localFile(path: url.path, reason: String(cString: strerror(EFBIG))))
                #expect(throws: SFTPError.self, "\(offset)") {
                    try file.write(ByteBuffer(bytes: [1, 2, 3, 4, 5, 6, 7, 8]), at: offset)
                }
            }

            // The last position there is can still be asked about, and what
            // is in the file is still read.
            var buffer = ByteBuffer()
            #expect(try file.read(into: &buffer, maximumLength: 1, at: UInt64(Int64.max) - 1) == 0)
            #expect(try file.read(into: &buffer, maximumLength: 4, at: 6) == 4)
            #expect(buffer == ByteBuffer(string: "6789"))
        }

        // MARK: Replacing a file

        private static let old = Data("what was there before".utf8)
        private static let new = ByteBuffer(string: "what replaces it")

        private func names(in directory: TemporaryDirectory) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted()
        }

        @Test func aFileIsWrittenBesideWhatItReplacesAndMovedOverIt() throws {
            let directory = try TemporaryDirectory()
            let url = directory.file("notes.txt")
            try Self.old.write(to: url)

            let file = try LocalFile(replacing: url)
            try file.write(Self.new, at: 0)
            // So far there are two files: the old one, untouched, and a
            // hidden one beside it.
            #expect(try Data(contentsOf: url) == Self.old)
            let present = try names(in: directory)
            #expect(present.count == 2 && present.last == "notes.txt")
            #expect(present.first?.hasPrefix(".openscreens-") == true)
            #expect(present.first?.hasSuffix(".partial") == true)

            try file.finish()
            #expect(try Data(contentsOf: url) == Data(Self.new.readableBytesView))
            #expect(try names(in: directory) == ["notes.txt"])
        }

        @Test func aFileThatIsAbandonedLeavesWhatWasThere() throws {
            let directory = try TemporaryDirectory()
            let url = directory.file("notes.txt")
            try Self.old.write(to: url)

            let file = try LocalFile(replacing: url)
            try file.write(Self.new, at: 0)
            file.abandon()
            #expect(try Data(contentsOf: url) == Self.old)
            #expect(try names(in: directory) == ["notes.txt"])

            // And nothing at all where there was nothing.
            let other = try LocalFile(replacing: directory.file("other.txt"))
            try other.write(Self.new, at: 0)
            other.abandon()
            #expect(try names(in: directory) == ["notes.txt"])
        }

        @Test func aFileThatIsLetGoOfUnfinishedIsNotLeftBehind() throws {
            let directory = try TemporaryDirectory()
            do {
                let file = try LocalFile(replacing: directory.file("notes.txt"))
                try file.write(Self.new, at: 0)
            }
            #expect(try names(in: directory).isEmpty)
        }

        @Test func aFolderIsNotReplacedByAFile() throws {
            let directory = try TemporaryDirectory()
            let url = directory.file("notes.txt")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Self.old.write(to: url.appending(path: "kept"))

            let file = try LocalFile(replacing: url)
            try file.write(Self.new, at: 0)
            let error = #expect(throws: SFTPError.self) { try file.finish() }
            // The error is about the place the file was meant for, not the
            // hidden name it was written under.
            #expect(error == .localFile(path: url.path, reason: String(cString: strerror(EISDIR))))
            #expect(try names(in: directory) == ["notes.txt"])
            #expect(try Data(contentsOf: url.appending(path: "kept")) == Self.old)
        }

        @Test func aLinkIsReplacedNotWrittenThrough() throws {
            let directory = try TemporaryDirectory()
            let target = directory.file("target.txt")
            try Self.old.write(to: target)
            let link = directory.file("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let file = try LocalFile(replacing: link)
            try file.write(Self.new, at: 0)
            try file.finish()
            #expect(try Data(contentsOf: target) == Self.old)
            #expect(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
                == .typeRegular)
            #expect(try Data(contentsOf: link) == Data(Self.new.readableBytesView))
        }

        @Test func aFileWithNowhereToGoSaysWhereItWasMeantToGo() throws {
            let directory = try TemporaryDirectory()
            let url = directory.file("missing/notes.txt")
            let error = #expect(throws: SFTPError.self) { _ = try LocalFile(replacing: url) }
            #expect(error == .localFile(path: url.path, reason: String(cString: strerror(ENOENT))))
        }

        // MARK: Permissions and dates

        private func permissions(_ url: URL) throws -> Int {
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            return try #require((value as? NSNumber)?.intValue)
        }

        @Test func aNewFileIsAsPrivateAsItIsToldToBeAndDatedAsItIsTold() throws {
            let directory = try TemporaryDirectory()
            let url = directory.file("key")
            // Only the nine ordinary bits are ever taken.
            let file = try LocalFile(replacing: url, permissions: 0o6600)
            try file.write(Self.new, at: 0)
            let written = Date(timeIntervalSince1970: 981_173_106)
            try file.finish(modified: written)

            #expect(try permissions(url) == 0o600)
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)
        }

        @Test func aFileThatIsReplacedKeepsItsOwnPermissions() throws {
            let directory = try TemporaryDirectory()
            for (name, mode) in [("private", 0o600), ("shared", 0o666), ("tool", 0o750)] {
                let url = directory.file(name)
                try Self.old.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)

                // Whatever the new contents came with, and whatever the mask
                // for new files would have made of that.
                let file = try LocalFile(replacing: url, permissions: 0o644)
                try file.write(Self.new, at: 0)
                try file.finish()
                #expect(try permissions(url) == mode, "\(name)")
                #expect(try Data(contentsOf: url) == Data(Self.new.readableBytesView), "\(name)")
            }
        }

        @Test func aFolderIsMadeWithThePermissionsItIsGivenAndLeftAloneIfItIsThere() throws {
            let directory = try TemporaryDirectory()
            let folder = directory.file("private")
            try LocalFile.createDirectory(at: folder, permissions: 0o700)
            #expect(try permissions(folder) == 0o700)

            // Asking again changes nothing about a folder that exists.
            try LocalFile.createDirectory(at: folder, permissions: 0o755)
            #expect(try permissions(folder) == 0o700)

            // A folder whose own folder is missing is made only when asked.
            let deep = directory.file("a/b/c")
            #expect(throws: SFTPError.self) { try LocalFile.createDirectory(at: deep) }
            try LocalFile.createDirectory(at: deep, permissions: 0o700, withParents: true)
            #expect(try permissions(deep) == 0o700)

            // A file with the name is in the way, and stays.
            let file = directory.file("file")
            try Self.old.write(to: file)
            let error = #expect(throws: SFTPError.self) { try LocalFile.createDirectory(at: file) }
            #expect(error == .localFile(path: file.path, reason: String(cString: strerror(EEXIST))))
            #expect(try Data(contentsOf: file) == Self.old)
        }

        @Test func whatAFolderHoldsIsToldApartWithoutFollowingLinks() throws {
            let directory = try TemporaryDirectory()
            let folder = directory.file("folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o550], ofItemAtPath: folder.path)
            try Self.old.write(to: directory.file("file"))
            try FileManager.default.createSymbolicLink(at: directory.file("link"), withDestinationURL: folder)

            let contents = try LocalFile.contents(of: directory.url)
            #expect(contents.map(\.url.lastPathComponent) == ["file", "folder", "link"])
            guard case .file(let size) = contents[0].kind,
                  case .directory(let permissions) = contents[1].kind,
                  case .other = contents[2].kind else {
                Issue.record("unexpected kinds: \(contents.map(\.kind))")
                return
            }
            #expect(size == Int64(Self.old.count))
            // Whoever copies the folder will have to be able to fill it.
            #expect(permissions == 0o750)
            #expect(try LocalFile.folderPermissions(of: folder) == 0o750)
        }
    }
}

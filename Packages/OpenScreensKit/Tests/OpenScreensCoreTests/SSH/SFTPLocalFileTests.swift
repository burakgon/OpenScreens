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
    }
}

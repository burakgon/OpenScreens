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
    }
}

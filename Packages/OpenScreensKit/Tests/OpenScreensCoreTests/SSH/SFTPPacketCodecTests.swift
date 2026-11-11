import Foundation
import NIOCore
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SFTP packet codec")
    struct SFTPPacketCodecTests {
        static let handle = SFTPHandle(bytes: [0x00, 0x01, 0xFE, 0xFF])

        static let fullAttributes = SFTPAttributes(
            size: 0x1_0000_0001,
            userID: 501,
            groupID: 20,
            mode: 0o100644,
            accessDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_800_000_000))

        static func buffer(_ bytes: [UInt8]) -> ByteBuffer {
            ByteBuffer(bytes: bytes)
        }

        /// One of every packet, with values chosen to catch a field that is
        /// misplaced, truncated or read with the wrong width.
        static let packets: [SFTPPacket] = [
            .initialize(version: 3),
            .open(id: 1, path: "/tmp/ünïcödé.txt", flags: [.write, .create, .truncate],
                  attributes: SFTPAttributes(mode: 0o600)),
            .open(id: 0xFFFF_FFFF, path: "", flags: .read, attributes: SFTPAttributes()),
            .close(id: 2, handle: handle),
            .read(id: 3, handle: handle, offset: 0xFFFF_FFFF_0000_0001, length: 32768),
            .write(id: 4, handle: handle, offset: 1 << 40, data: buffer([1, 2, 3, 0, 255])),
            .write(id: 5, handle: handle, offset: 0, data: buffer([])),
            .lstat(id: 6, path: "/a"),
            .fstat(id: 7, handle: handle),
            .opendir(id: 8, path: "/home/someone"),
            .readdir(id: 9, handle: handle),
            .remove(id: 10, path: "file with spaces"),
            .mkdir(id: 11, path: "new", attributes: fullAttributes),
            .rmdir(id: 12, path: "old"),
            .realpath(id: 13, path: "."),
            .stat(id: 14, path: "/b"),
            .rename(id: 15, from: "/from", to: "/to"),
            .version(version: 3, extensions: []),
            .version(version: 3, extensions: [
                SFTPExtension(name: "posix-rename@openssh.com", data: "1"),
                SFTPExtension(name: "limits@openssh.com", data: "1"),
            ]),
            .status(id: 16, code: .ok, message: "Success", language: "en"),
            .status(id: 17, code: .noSuchFile, message: "No such file", language: ""),
            .status(id: 18, code: SFTPStatusCode(rawValue: 4242), message: "", language: ""),
            .handle(id: 19, handle: handle),
            .handle(id: 20, handle: SFTPHandle(bytes: [])),
            .data(id: 21, data: buffer(Array(repeating: 0xAB, count: 1000))),
            .name(id: 22, entries: []),
            .name(id: 23, entries: [
                SFTPNameEntry(
                    filename: "notes.txt",
                    longname: "-rw-r--r--    1 me       staff          12 Nov 10 22:00 notes.txt",
                    attributes: fullAttributes),
                SFTPNameEntry(
                    filename: "Projects", longname: "",
                    attributes: SFTPAttributes(mode: 0o040755)),
                SFTPNameEntry(filename: "bare", longname: "bare", attributes: SFTPAttributes()),
            ]),
            .attributes(id: 24, attributes: fullAttributes),
            .attributes(id: 25, attributes: SFTPAttributes(size: 0)),
        ]

        // MARK: Round trips

        @Test(arguments: packets)
        func aPacketSurvivesEncodingAndDecoding(_ packet: SFTPPacket) throws {
            var encoded = SFTPPacketCodec.encode(packet)
            // The length prefix counts everything that follows it.
            #expect(encoded.getInteger(at: encoded.readerIndex, as: UInt32.self)
                == UInt32(encoded.readableBytes - 4))

            let decoded = try SFTPPacketCodec.decodeNext(from: &encoded)
            #expect(decoded == packet)
            #expect(encoded.readableBytes == 0)
        }

        @Test func packetsAreTakenOffAStreamOneAtATime() throws {
            var stream = ByteBuffer()
            for packet in Self.packets {
                var encoded = SFTPPacketCodec.encode(packet)
                stream.writeBuffer(&encoded)
            }

            var decoded: [SFTPPacket] = []
            while let packet = try SFTPPacketCodec.decodeNext(from: &stream) {
                decoded.append(packet)
            }
            #expect(decoded == Self.packets)
        }

        @Test func anIncompletePacketIsLeftInTheBuffer() throws {
            let whole = SFTPPacketCodec.encode(.realpath(id: 7, path: "/some/path"))

            // Every proper prefix is "not yet", never an error and never a
            // packet, and must leave the bytes where they were.
            for length in 0..<whole.readableBytes {
                var partial = try #require(whole.getSlice(at: whole.readerIndex, length: length))
                let packet = try SFTPPacketCodec.decodeNext(from: &partial)
                #expect(packet == nil)
                #expect(partial.readableBytes == length)
            }
        }

        // MARK: Wire format

        @Test func encodesTheBytesTheSpecificationDescribes() {
            // SSH_FXP_INIT: length 5, type 1, version 3.
            #expect(SFTPPacketCodec.encode(.initialize(version: 3))
                == Self.buffer([0, 0, 0, 5, 1, 0, 0, 0, 3]))

            // SSH_FXP_READ: type 5, id, handle as a string, 64-bit offset,
            // 32-bit length.
            #expect(SFTPPacketCodec.encode(
                .read(id: 0x0102_0304, handle: SFTPHandle(bytes: [0xAA, 0xBB]),
                      offset: 0x0000_0001_0000_0002, length: 0x8000))
                == Self.buffer([
                    0, 0, 0, 23,
                    5,
                    1, 2, 3, 4,
                    0, 0, 0, 2, 0xAA, 0xBB,
                    0, 0, 0, 1, 0, 0, 0, 2,
                    0, 0, 0x80, 0,
                ]))

            // SSH_FXP_OPEN with only the permissions attribute: the flags
            // word announces it (0x4) and nothing else follows it.
            #expect(SFTPPacketCodec.encode(
                .open(id: 1, path: "a", flags: [.read, .write], attributes: SFTPAttributes(mode: 0o644)))
                == Self.buffer([
                    0, 0, 0, 22,
                    3,
                    0, 0, 0, 1,
                    0, 0, 0, 1, 0x61,
                    0, 0, 0, 3,
                    0, 0, 0, 4,
                    0, 0, 0x01, 0xA4,
                ]))
        }

        @Test func decodesAReplyTheWayOpenSSHSendsIt() throws {
            // SSH_FXP_STATUS, id 9, SSH_FX_NO_SUCH_FILE, "No such file", "".
            let packet = try SFTPPacketCodec.decode(body: Self.buffer(
                [101, 0, 0, 0, 9, 0, 0, 0, 2, 0, 0, 0, 12]
                    + Array("No such file".utf8)
                    + [0, 0, 0, 0]))
            #expect(packet == .status(id: 9, code: .noSuchFile, message: "No such file", language: ""))
            #expect(packet.replyID == 9)
        }

        @Test func aStatusWithoutMessageIsAccepted() throws {
            // Servers older than version 3 end the packet after the code.
            let packet = try SFTPPacketCodec.decode(body: Self.buffer([101, 0, 0, 0, 5, 0, 0, 0, 1]))
            #expect(packet == .status(id: 5, code: .endOfFile, message: "", language: ""))
        }

        @Test func extendedAttributesAreSteppedOver() throws {
            // An attribute block with a size and one extended pair, followed
            // by a second directory entry that must still be found.
            var body = ByteBuffer()
            body.writeInteger(UInt8(104))
            body.writeInteger(UInt32(77))
            body.writeInteger(UInt32(2))
            for name in ["first", "second"] {
                for text in [name, "long " + name] {
                    body.writeInteger(UInt32(text.utf8.count))
                    body.writeString(text)
                }
                body.writeInteger(UInt32(0x8000_0001))
                body.writeInteger(UInt64(name.utf8.count))
                body.writeInteger(UInt32(1))
                for text in ["vendor@example.com", "opaque value"] {
                    body.writeInteger(UInt32(text.utf8.count))
                    body.writeString(text)
                }
            }

            let packet = try SFTPPacketCodec.decode(body: body)
            #expect(packet == .name(id: 77, entries: [
                SFTPNameEntry(filename: "first", longname: "long first", attributes: SFTPAttributes(size: 5)),
                SFTPNameEntry(filename: "second", longname: "long second", attributes: SFTPAttributes(size: 6)),
            ]))
        }

        @Test func halfSetAttributePairsAreNotSent() throws {
            // The user and group IDs share one flag, as do the two times.
            let lopsided = SFTPAttributes(userID: 501, accessDate: Date(timeIntervalSince1970: 1))
            var encoded = SFTPPacketCodec.encode(.attributes(id: 1, attributes: lopsided))
            let decoded = try SFTPPacketCodec.decodeNext(from: &encoded)
            #expect(decoded == .attributes(id: 1, attributes: SFTPAttributes()))
        }

        @Test func fileNamesThatAreNotUTF8AreStillDecoded() throws {
            // Latin-1 "é" is not valid UTF-8. The name must come through as
            // something, and the fields after it must still line up.
            let packet = try SFTPPacketCodec.decode(body: Self.buffer(
                [104, 0, 0, 0, 1, 0, 0, 0, 1]
                    + [0, 0, 0, 4, 0x63, 0x61, 0x66, 0xE9]
                    + [0, 0, 0, 0]
                    + [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3]))
            guard case .name(1, let entries) = packet, let entry = entries.first else {
                Issue.record("expected one name entry, got \(packet)")
                return
            }
            #expect(entry.filename == "caf\u{FFFD}")
            #expect(entry.attributes == SFTPAttributes(size: 3))
        }

        // MARK: Rejecting bad input

        @Test func refusesLengthsNoPacketCanHave() {
            var empty = Self.buffer([0, 0, 0, 0])
            #expect(throws: SFTPError.self) { try SFTPPacketCodec.decodeNext(from: &empty) }

            // A length field of 4 GiB is corruption, not a packet to wait for.
            var huge = Self.buffer([0xFF, 0xFF, 0xFF, 0xFF, 101])
            #expect(throws: SFTPError.self) { try SFTPPacketCodec.decodeNext(from: &huge) }
        }

        @Test func refusesUnknownPacketTypes() {
            #expect(throws: SFTPError.self) {
                try SFTPPacketCodec.decode(body: Self.buffer([99, 0, 0, 0, 1]))
            }
        }

        @Test(arguments: packets)
        func refusesEveryTruncatedBody(_ packet: SFTPPacket) throws {
            if case .status = packet { return }  // its text fields are optional
            if case .version = packet { return }  // its extensions are optional
            var encoded = SFTPPacketCodec.encode(packet)
            encoded.moveReaderIndex(forwardBy: 4)

            for length in 0..<encoded.readableBytes {
                let body = try #require(encoded.getSlice(at: encoded.readerIndex, length: length))
                #expect(throws: SFTPError.self, "\(length) of \(encoded.readableBytes) bytes") {
                    try SFTPPacketCodec.decode(body: body)
                }
            }
        }

        @Test func aDirectoryListingCannotClaimMoreEntriesThanItHolds() {
            // A count of four billion with no entries behind it must fail
            // cleanly rather than reserve memory for them.
            #expect(throws: SFTPError.self) {
                try SFTPPacketCodec.decode(body: Self.buffer(
                    [104, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF]))
            }
        }

        @Test func aHandleLongerThanTheProtocolAllowsIsRefused() throws {
            let longest = SFTPHandle(bytes: [UInt8](repeating: 7, count: SFTPHandle.maximumLength))
            var encoded = SFTPPacketCodec.encode(.handle(id: 1, handle: longest))
            #expect(try SFTPPacketCodec.decodeNext(from: &encoded) == .handle(id: 1, handle: longest))

            // One byte more, in whichever packet it comes.
            let tooLong = SFTPHandle(bytes: longest.bytes + [7])
            let carriers: [SFTPPacket] = [
                .handle(id: 1, handle: tooLong),
                .close(id: 1, handle: tooLong),
                .read(id: 1, handle: tooLong, offset: 0, length: 1),
                .write(id: 1, handle: tooLong, offset: 0, data: Self.buffer([1])),
                .fstat(id: 1, handle: tooLong),
                .readdir(id: 1, handle: tooLong),
            ]
            for packet in carriers {
                var encoded = SFTPPacketCodec.encode(packet)
                #expect(throws: SFTPError.invalidResponse("a handle of \(tooLong.bytes.count) bytes")) {
                    try SFTPPacketCodec.decodeNext(from: &encoded)
                }
            }
        }

        @Test func aListingReplyCannotCarryMoreEntriesThanAListingMayHold() throws {
            /// A reply of `count` entries of the smallest kind: no name, no
            /// long name, no attributes. Twelve bytes each.
            func reply(count: Int) -> ByteBuffer {
                var body = Self.buffer([104, 0, 0, 0, 1])
                body.writeInteger(UInt32(count))
                body.writeRepeatingByte(0, count: count * 12)
                return body
            }
            let limit = SFTPPacketCodec.maximumNameCount
            guard case .name(1, let entries) = try SFTPPacketCodec.decode(body: reply(count: limit)) else {
                Issue.record("expected a listing reply")
                return
            }
            #expect(entries.count == limit)
            // The entries are all there. It is their number that is refused,
            // before any of them is taken apart.
            #expect(throws: SFTPError.invalidResponse("a listing of \(limit + 1) entries in one reply")) {
                try SFTPPacketCodec.decode(body: reply(count: limit + 1))
            }
        }

        @Test func aVersionReplyCannotAnnounceExtensionsWithoutEnd() throws {
            /// A version reply with `count` extensions of the smallest kind:
            /// no name and no data. Eight bytes each.
            func reply(count: Int) -> ByteBuffer {
                var body = Self.buffer([2, 0, 0, 0, 3])
                body.writeRepeatingByte(0, count: count * 8)
                return body
            }
            let limit = SFTPPacketCodec.maximumExtensionCount
            guard case .version(3, let extensions) = try SFTPPacketCodec.decode(body: reply(count: limit)) else {
                Issue.record("expected a version reply")
                return
            }
            #expect(extensions.count == limit)
            #expect(throws: SFTPError.invalidResponse("more than \(limit) extensions")) {
                try SFTPPacketCodec.decode(body: reply(count: limit + 1))
            }
        }

        // MARK: Attributes

        @Test func attributesTellFileKindsApart() {
            let directory = SFTPAttributes(mode: 0o040755)
            let file = SFTPAttributes(mode: 0o100644)
            let link = SFTPAttributes(mode: 0o120777)
            let unknown = SFTPAttributes()

            #expect(directory.isDirectory && !directory.isRegularFile && !directory.isSymbolicLink)
            #expect(file.isRegularFile && !file.isDirectory && !file.isSymbolicLink)
            #expect(link.isSymbolicLink && !link.isDirectory && !link.isRegularFile)
            #expect(!unknown.isDirectory && !unknown.isRegularFile && !unknown.isSymbolicLink)

            #expect(directory.permissions == 0o755)
            #expect(SFTPAttributes(mode: 0o104755).permissions == 0o4755)
            #expect(unknown.permissions == nil)
        }

        @Test func aListingEntryBecomesAnItem() {
            let item = SFTPItem(name: "notes.txt", directory: "/home/me", attributes: Self.fullAttributes)
            #expect(item.name == "notes.txt")
            #expect(item.path == "/home/me/notes.txt")
            #expect(item.id == item.path)
            #expect(!item.isDirectory && !item.isSymlink)
            #expect(item.size == 0x1_0000_0001)
            #expect(item.modified == Date(timeIntervalSince1970: 1_800_000_000))
            #expect(item.permissions == 0o644)

            #expect(SFTPItem(name: "x", directory: "/", attributes: SFTPAttributes()).path == "/x")
            #expect(SFTPItem(name: "x", directory: "dir/", attributes: SFTPAttributes()).path == "dir/x")
            #expect(SFTPItem(name: "x", directory: "", attributes: SFTPAttributes()).path == "x")
            #expect(SFTPItem(name: "x", directory: ".", attributes: SFTPAttributes()).size == 0)
        }

        @Test func errorsCarryTheServersCodeAndMessage() {
            let error = SFTPError.status(code: .permissionDenied, message: "Permission denied")
            #expect(error.statusCode == .permissionDenied)
            #expect(SFTPError.connectionClosed.statusCode == nil)
            #expect(error.errorDescription == "The server did not permit the operation.")
            #expect(SFTPError.status(code: .failure, message: "Directory not empty").errorDescription
                == "The server could not complete the operation: Directory not empty")
            #expect(SFTPError.status(code: SFTPStatusCode(rawValue: 99), message: "").errorDescription
                == "The server could not complete the operation (code 99).")
            #expect(SFTPError.tooManyEntries(limit: 100_000).errorDescription
                == "The folder holds more than \(100_000.formatted()) items, "
                    + "which is more than can be handled at once.")
        }
    }
}

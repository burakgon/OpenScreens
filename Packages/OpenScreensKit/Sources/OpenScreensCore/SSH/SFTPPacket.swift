import Foundation
import NIOCore

/// An opaque reference to an open file or directory, issued by the server.
struct SFTPHandle: Hashable, Sendable {
    /// The longest handle the protocol lets a server issue
    /// (draft-ietf-secsh-filexfer-02 §4). Every request about an open file
    /// repeats its handle, and a transfer keeps dozens of those in flight, so
    /// a longer one is refused when it arrives, not taken along.
    static let maximumLength = 256

    var bytes: [UInt8]
}

/// How to open a file (`pflags` of `SSH_FXP_OPEN`).
struct SFTPOpenFlags: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let append = SFTPOpenFlags(rawValue: 0x04)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
    static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// One entry of an `SSH_FXP_NAME` reply.
struct SFTPNameEntry: Equatable, Sendable {
    var filename: String
    /// The entry as `ls -l` would print it. For display only; its format is
    /// up to the server.
    var longname: String
    var attributes: SFTPAttributes
}

/// A protocol extension the server advertises in `SSH_FXP_VERSION`.
struct SFTPExtension: Equatable, Sendable {
    var name: String
    var data: String

    /// The name of OpenSSH's extension for renaming the way POSIX `rename`
    /// does: in one step, replacing whatever has the new name. Most servers
    /// have taken it up.
    static let posixRename = "posix-rename@openssh.com"
}

/// A message of SFTP version 3 (draft-ietf-secsh-filexfer-02), limited to
/// the ones a client for browsing and transferring files needs.
///
/// Every request carries an `id` chosen by the client, and the server's reply
/// repeats it. That is the only link between the two: replies may come back
/// in any order.
enum SFTPPacket: Equatable, Sendable {
    // Client to server.
    case initialize(version: UInt32)
    case open(id: UInt32, path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes)
    case close(id: UInt32, handle: SFTPHandle)
    case read(id: UInt32, handle: SFTPHandle, offset: UInt64, length: UInt32)
    case write(id: UInt32, handle: SFTPHandle, offset: UInt64, data: ByteBuffer)
    case lstat(id: UInt32, path: String)
    case fstat(id: UInt32, handle: SFTPHandle)
    case opendir(id: UInt32, path: String)
    case readdir(id: UInt32, handle: SFTPHandle)
    case remove(id: UInt32, path: String)
    case mkdir(id: UInt32, path: String, attributes: SFTPAttributes)
    case rmdir(id: UInt32, path: String)
    case realpath(id: UInt32, path: String)
    case stat(id: UInt32, path: String)
    case rename(id: UInt32, from: String, to: String)
    /// `posix-rename@openssh.com`, an extended request. Unlike ``rename``,
    /// which version 3 lets a server refuse when `to` exists, this replaces
    /// what is there. Only for servers that advertise it.
    case posixRename(id: UInt32, from: String, to: String)

    // Server to client.
    case version(version: UInt32, extensions: [SFTPExtension])
    case status(id: UInt32, code: SFTPStatusCode, message: String, language: String)
    case handle(id: UInt32, handle: SFTPHandle)
    case data(id: UInt32, data: ByteBuffer)
    case name(id: UInt32, entries: [SFTPNameEntry])
    case attributes(id: UInt32, attributes: SFTPAttributes)

    /// The request this packet answers; `nil` for packets that are not
    /// replies to a numbered request.
    var replyID: UInt32? {
        switch self {
        case .status(let id, _, _, _), .handle(let id, _), .data(let id, _),
             .name(let id, _), .attributes(let id, _):
            id
        default:
            nil
        }
    }
}

/// Converts ``SFTPPacket`` values to and from their wire form.
///
/// On the wire a packet is a 32-bit length, a type byte and the fields of
/// that type, all big-endian, with strings prefixed by a 32-bit length. The
/// codec is pure: bytes in, values out, no connection involved.
enum SFTPPacketCodec {
    /// The protocol version this codec speaks.
    static let version: UInt32 = 3

    /// The longest packet accepted from a server. OpenSSH never sends more
    /// than 256 KiB; the margin is for servers that pack large directory
    /// listings into one reply. Anything longer is a corrupt length field.
    static let maximumPacketLength = 16 * 1024 * 1024

    /// The most entries one reply to a listing may carry: as many as a whole
    /// listing may come to. OpenSSH sends a hundred at a time. Without a
    /// limit, a single packet of the largest size could announce over a
    /// million entries of a few bytes each, and decoding them would take a
    /// hundred times the memory the packet did.
    static let maximumNameCount = 100_000

    /// The most extensions a server may announce when the session starts.
    /// OpenSSH has about a dozen. Like the entries of a listing, they take
    /// more room decoded than they do in the packet.
    static let maximumExtensionCount = 256

    fileprivate enum PacketType: UInt8 {
        case initialize = 1
        case version = 2
        case open = 3
        case close = 4
        case read = 5
        case write = 6
        case lstat = 7
        case fstat = 8
        case opendir = 11
        case readdir = 12
        case remove = 13
        case mkdir = 14
        case rmdir = 15
        case realpath = 16
        case stat = 17
        case rename = 18
        case extended = 200
        case status = 101
        case handle = 102
        case data = 103
        case name = 104
        case attributes = 105
    }

    // MARK: Encoding

    /// Writes `packet` in wire form, length prefix included.
    static func encode(
        _ packet: SFTPPacket,
        allocator: ByteBufferAllocator = ByteBufferAllocator()
    ) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 64)
        // The length is only known once the body is written.
        let lengthIndex = buffer.writerIndex
        buffer.writeInteger(UInt32(0))

        switch packet {
        case .initialize(let version):
            buffer.writeInteger(PacketType.initialize.rawValue)
            buffer.writeInteger(version)
        case .open(let id, let path, let flags, let attributes):
            buffer.writeHeader(.open, id)
            buffer.writeLengthPrefixed(path)
            buffer.writeInteger(flags.rawValue)
            buffer.writeAttributes(attributes)
        case .close(let id, let handle):
            buffer.writeHeader(.close, id)
            buffer.writeLengthPrefixed(handle.bytes)
        case .read(let id, let handle, let offset, let length):
            buffer.writeHeader(.read, id)
            buffer.writeLengthPrefixed(handle.bytes)
            buffer.writeInteger(offset)
            buffer.writeInteger(length)
        case .write(let id, let handle, let offset, let data):
            buffer.writeHeader(.write, id)
            buffer.writeLengthPrefixed(handle.bytes)
            buffer.writeInteger(offset)
            buffer.writeInteger(UInt32(clamping: data.readableBytes))
            buffer.writeImmutableBuffer(data)
        case .lstat(let id, let path):
            buffer.writeHeader(.lstat, id)
            buffer.writeLengthPrefixed(path)
        case .fstat(let id, let handle):
            buffer.writeHeader(.fstat, id)
            buffer.writeLengthPrefixed(handle.bytes)
        case .opendir(let id, let path):
            buffer.writeHeader(.opendir, id)
            buffer.writeLengthPrefixed(path)
        case .readdir(let id, let handle):
            buffer.writeHeader(.readdir, id)
            buffer.writeLengthPrefixed(handle.bytes)
        case .remove(let id, let path):
            buffer.writeHeader(.remove, id)
            buffer.writeLengthPrefixed(path)
        case .mkdir(let id, let path, let attributes):
            buffer.writeHeader(.mkdir, id)
            buffer.writeLengthPrefixed(path)
            buffer.writeAttributes(attributes)
        case .rmdir(let id, let path):
            buffer.writeHeader(.rmdir, id)
            buffer.writeLengthPrefixed(path)
        case .realpath(let id, let path):
            buffer.writeHeader(.realpath, id)
            buffer.writeLengthPrefixed(path)
        case .stat(let id, let path):
            buffer.writeHeader(.stat, id)
            buffer.writeLengthPrefixed(path)
        case .rename(let id, let from, let to):
            buffer.writeHeader(.rename, id)
            buffer.writeLengthPrefixed(from)
            buffer.writeLengthPrefixed(to)
        case .posixRename(let id, let from, let to):
            // An extended request names the extension, then carries whatever
            // that extension defines: here, the two paths.
            buffer.writeHeader(.extended, id)
            buffer.writeLengthPrefixed(SFTPExtension.posixRename)
            buffer.writeLengthPrefixed(from)
            buffer.writeLengthPrefixed(to)
        case .version(let version, let extensions):
            buffer.writeInteger(PacketType.version.rawValue)
            buffer.writeInteger(version)
            for item in extensions {
                buffer.writeLengthPrefixed(item.name)
                buffer.writeLengthPrefixed(item.data)
            }
        case .status(let id, let code, let message, let language):
            buffer.writeHeader(.status, id)
            buffer.writeInteger(code.rawValue)
            buffer.writeLengthPrefixed(message)
            buffer.writeLengthPrefixed(language)
        case .handle(let id, let handle):
            buffer.writeHeader(.handle, id)
            buffer.writeLengthPrefixed(handle.bytes)
        case .data(let id, let data):
            buffer.writeHeader(.data, id)
            buffer.writeInteger(UInt32(clamping: data.readableBytes))
            buffer.writeImmutableBuffer(data)
        case .name(let id, let entries):
            buffer.writeHeader(.name, id)
            buffer.writeInteger(UInt32(clamping: entries.count))
            for entry in entries {
                buffer.writeLengthPrefixed(entry.filename)
                buffer.writeLengthPrefixed(entry.longname)
                buffer.writeAttributes(entry.attributes)
            }
        case .attributes(let id, let attributes):
            buffer.writeHeader(.attributes, id)
            buffer.writeAttributes(attributes)
        }

        let length = buffer.writerIndex - lengthIndex - MemoryLayout<UInt32>.size
        buffer.setInteger(UInt32(clamping: length), at: lengthIndex)
        return buffer
    }

    // MARK: Decoding

    /// Takes the next complete packet off the front of `buffer`.
    ///
    /// - Returns: `nil`, leaving `buffer` untouched, when the packet has not
    ///   fully arrived yet.
    /// - Throws: ``SFTPError/invalidResponse(_:)`` when the bytes are not a
    ///   valid packet.
    static func decodeNext(from buffer: inout ByteBuffer) throws(SFTPError) -> SFTPPacket? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else {
            return nil
        }
        try validate(length: length)
        let prefix = MemoryLayout<UInt32>.size
        guard buffer.readableBytes >= prefix + Int(length) else { return nil }
        buffer.moveReaderIndex(forwardBy: prefix)
        guard let body = buffer.readSlice(length: Int(length)) else { return nil }
        return try decode(body: body)
    }

    /// Checks a length prefix before its packet is waited for.
    static func validate(length: UInt32) throws(SFTPError) {
        guard length >= 1, length <= UInt32(maximumPacketLength) else {
            throw .invalidResponse("a packet of \(length) bytes")
        }
    }

    /// Decodes a packet from its body: everything after the length prefix.
    static func decode(body: ByteBuffer) throws(SFTPError) -> SFTPPacket {
        var body = body
        guard let rawType = body.readInteger(as: UInt8.self) else {
            throw .invalidResponse("an empty packet")
        }
        guard let type = PacketType(rawValue: rawType) else {
            throw .invalidResponse("a packet of unknown type \(rawType)")
        }
        guard let packet = try read(type, from: &body) else {
            throw .invalidResponse("a malformed packet of type \(rawType)")
        }
        return packet
    }

    /// Reads the fields of a packet of `type`. `nil` means the body ended
    /// before all of them were there.
    ///
    /// - Throws: When the fields are all there and one of them is something
    ///   the protocol does not allow.
    private static func read(
        _ type: PacketType, from body: inout ByteBuffer
    ) throws(SFTPError) -> SFTPPacket? {
        switch type {
        case .initialize:
            guard let version = body.readInteger(as: UInt32.self) else { return nil }
            return .initialize(version: version)
        case .version:
            guard let version = body.readInteger(as: UInt32.self) else { return nil }
            var extensions: [SFTPExtension] = []
            while body.readableBytes > 0 {
                guard extensions.count < maximumExtensionCount else {
                    throw .invalidResponse("more than \(maximumExtensionCount) extensions")
                }
                guard let name = body.readLengthPrefixedText(),
                      let data = body.readLengthPrefixedText() else { return nil }
                extensions.append(SFTPExtension(name: name, data: data))
            }
            return .version(version: version, extensions: extensions)
        default:
            break
        }

        // Every other packet starts with the request ID.
        guard let id = body.readInteger(as: UInt32.self) else { return nil }
        switch type {
        case .initialize, .version:
            return nil
        case .open:
            guard let path = body.readLengthPrefixedText(),
                  let flags = body.readInteger(as: UInt32.self),
                  let attributes = body.readAttributes() else { return nil }
            return .open(
                id: id, path: path, flags: SFTPOpenFlags(rawValue: flags), attributes: attributes)
        case .close:
            return try body.readHandle().map { .close(id: id, handle: $0) }
        case .read:
            guard let handle = try body.readHandle(),
                  let offset = body.readInteger(as: UInt64.self),
                  let length = body.readInteger(as: UInt32.self) else { return nil }
            return .read(id: id, handle: handle, offset: offset, length: length)
        case .write:
            guard let handle = try body.readHandle(),
                  let offset = body.readInteger(as: UInt64.self),
                  let data = body.readLengthPrefixed() else { return nil }
            return .write(id: id, handle: handle, offset: offset, data: data)
        case .lstat:
            return body.readLengthPrefixedText().map { .lstat(id: id, path: $0) }
        case .fstat:
            return try body.readHandle().map { .fstat(id: id, handle: $0) }
        case .opendir:
            return body.readLengthPrefixedText().map { .opendir(id: id, path: $0) }
        case .readdir:
            return try body.readHandle().map { .readdir(id: id, handle: $0) }
        case .remove:
            return body.readLengthPrefixedText().map { .remove(id: id, path: $0) }
        case .mkdir:
            guard let path = body.readLengthPrefixedText(), let attributes = body.readAttributes() else {
                return nil
            }
            return .mkdir(id: id, path: path, attributes: attributes)
        case .rmdir:
            return body.readLengthPrefixedText().map { .rmdir(id: id, path: $0) }
        case .realpath:
            return body.readLengthPrefixedText().map { .realpath(id: id, path: $0) }
        case .stat:
            return body.readLengthPrefixedText().map { .stat(id: id, path: $0) }
        case .rename:
            guard let from = body.readLengthPrefixedText(), let to = body.readLengthPrefixedText() else { return nil }
            return .rename(id: id, from: from, to: to)
        case .extended:
            guard let name = body.readLengthPrefixedText() else { return nil }
            // What follows the name is laid out by the extension, so one
            // that is not known here cannot be read past its name.
            guard name == SFTPExtension.posixRename else {
                throw .invalidResponse("an extended request this client does not make")
            }
            guard let from = body.readLengthPrefixedText(), let to = body.readLengthPrefixedText() else { return nil }
            return .posixRename(id: id, from: from, to: to)
        case .status:
            guard let code = body.readInteger(as: UInt32.self) else { return nil }
            // The message and language were added in version 3, and some
            // servers that claim it still leave them out.
            let message = body.readLengthPrefixedText() ?? ""
            let language = body.readLengthPrefixedText() ?? ""
            return .status(
                id: id, code: SFTPStatusCode(rawValue: code), message: message, language: language)
        case .handle:
            return try body.readHandle().map { .handle(id: id, handle: $0) }
        case .data:
            return body.readLengthPrefixed().map { .data(id: id, data: $0) }
        case .name:
            guard let count = body.readInteger(as: UInt32.self) else { return nil }
            guard count <= UInt32(maximumNameCount) else {
                throw .invalidResponse("a listing of \(count) entries in one reply")
            }
            var entries: [SFTPNameEntry] = []
            // The count comes from the server; let the body's real size, not
            // the claim, decide how much is allocated.
            entries.reserveCapacity(min(Int(count), body.readableBytes / 12))
            for _ in 0..<count {
                guard let filename = body.readLengthPrefixedText(),
                      let longname = body.readLengthPrefixedText(),
                      let attributes = body.readAttributes() else { return nil }
                entries.append(SFTPNameEntry(
                    filename: filename, longname: longname, attributes: attributes))
            }
            return .name(id: id, entries: entries)
        case .attributes:
            return body.readAttributes().map { .attributes(id: id, attributes: $0) }
        }
    }
}

// MARK: - Wire primitives

/// Which optional fields an attribute block carries.
private struct SFTPAttributeFlags: OptionSet {
    let rawValue: UInt32

    static let size = SFTPAttributeFlags(rawValue: 0x0000_0001)
    static let ownership = SFTPAttributeFlags(rawValue: 0x0000_0002)
    static let mode = SFTPAttributeFlags(rawValue: 0x0000_0004)
    static let times = SFTPAttributeFlags(rawValue: 0x0000_0008)
    static let extended = SFTPAttributeFlags(rawValue: 0x8000_0000)
}

extension ByteBuffer {
    fileprivate mutating func writeHeader(_ type: SFTPPacketCodec.PacketType, _ id: UInt32) {
        writeInteger(type.rawValue)
        writeInteger(id)
    }

    /// Writes text as an SFTP `string`: a 32-bit length, then the bytes.
    fileprivate mutating func writeLengthPrefixed(_ text: String) {
        writeInteger(UInt32(clamping: text.utf8.count))
        writeString(text)
    }

    fileprivate mutating func writeLengthPrefixed(_ bytes: [UInt8]) {
        writeInteger(UInt32(clamping: bytes.count))
        writeBytes(bytes)
    }

    /// Reads an SFTP `string` as a slice of this buffer, without copying.
    fileprivate mutating func readLengthPrefixed() -> ByteBuffer? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self),
              readableBytes - MemoryLayout<UInt32>.size >= Int(length) else { return nil }
        moveReaderIndex(forwardBy: MemoryLayout<UInt32>.size)
        return readSlice(length: Int(length))
    }

    /// Reads an SFTP `string` holding text. File names are UTF-8 by
    /// convention only, so bytes that are not valid UTF-8 are replaced, not
    /// refused.
    fileprivate mutating func readLengthPrefixedText() -> String? {
        readLengthPrefixed().map { String(decoding: $0.readableBytesView, as: UTF8.self) }
    }

    /// Reads a handle. One that is longer than the protocol allows is
    /// well-formed, so it is not `nil`, but it is not a handle to work with.
    fileprivate mutating func readHandle() throws(SFTPError) -> SFTPHandle? {
        guard let bytes = readLengthPrefixed() else { return nil }
        guard bytes.readableBytes <= SFTPHandle.maximumLength else {
            throw .invalidResponse("a handle of \(bytes.readableBytes) bytes")
        }
        return SFTPHandle(bytes: [UInt8](bytes.readableBytesView))
    }

    /// An attribute block: a flags word, then only the fields it announces.
    /// User and group travel as a pair, and so do the two timestamps, so a
    /// half-set pair is not sent at all.
    fileprivate mutating func writeAttributes(_ attributes: SFTPAttributes) {
        var flags: SFTPAttributeFlags = []
        if attributes.size != nil { flags.insert(.size) }
        if attributes.userID != nil, attributes.groupID != nil { flags.insert(.ownership) }
        if attributes.mode != nil { flags.insert(.mode) }
        if attributes.accessDate != nil, attributes.modificationDate != nil { flags.insert(.times) }
        writeInteger(flags.rawValue)

        if let size = attributes.size {
            writeInteger(size)
        }
        if let userID = attributes.userID, let groupID = attributes.groupID {
            writeInteger(userID)
            writeInteger(groupID)
        }
        if let mode = attributes.mode {
            writeInteger(mode)
        }
        if let accessDate = attributes.accessDate, let modificationDate = attributes.modificationDate {
            writeInteger(Self.wireTime(accessDate))
            writeInteger(Self.wireTime(modificationDate))
        }
    }

    /// Version 3 timestamps are whole seconds since 1970 in 32 unsigned bits.
    private static func wireTime(_ date: Date) -> UInt32 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(UInt32.max) ? .max : UInt32(seconds)
    }

    fileprivate mutating func readAttributes() -> SFTPAttributes? {
        guard let rawFlags = readInteger(as: UInt32.self) else { return nil }
        let flags = SFTPAttributeFlags(rawValue: rawFlags)
        var attributes = SFTPAttributes()

        if flags.contains(.size) {
            guard let size = readInteger(as: UInt64.self) else { return nil }
            attributes.size = size
        }
        if flags.contains(.ownership) {
            guard let userID = readInteger(as: UInt32.self),
                  let groupID = readInteger(as: UInt32.self) else { return nil }
            attributes.userID = userID
            attributes.groupID = groupID
        }
        if flags.contains(.mode) {
            guard let mode = readInteger(as: UInt32.self) else { return nil }
            attributes.mode = mode
        }
        if flags.contains(.times) {
            guard let accessTime = readInteger(as: UInt32.self),
                  let modificationTime = readInteger(as: UInt32.self) else { return nil }
            attributes.accessDate = Date(timeIntervalSince1970: TimeInterval(accessTime))
            attributes.modificationDate = Date(timeIntervalSince1970: TimeInterval(modificationTime))
        }
        if flags.contains(.extended) {
            // Vendor-specific name and value pairs. Nothing here uses them,
            // but they have to be stepped over to reach what follows.
            guard let count = readInteger(as: UInt32.self) else { return nil }
            for _ in 0..<count {
                guard readLengthPrefixed() != nil, readLengthPrefixed() != nil else { return nil }
            }
        }
        return attributes
    }
}

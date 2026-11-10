import CryptoKit
import Foundation

/// The byte stream ended before a complete value could be read.
struct SSHWireTruncated: Error {}

/// Reads the primitive types of the SSH wire encoding (RFC 4251 §5): big-endian
/// integers, length-prefixed strings and multiple-precision integers.
///
/// Used for key files and public key blobs, which are small. Channel traffic
/// goes through NIO's `ByteBuffer` instead.
struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remainingCount: Int { bytes.count - offset }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func readUInt32() throws(SSHWireTruncated) -> UInt32 {
        guard remainingCount >= 4 else { throw SSHWireTruncated() }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) throws(SSHWireTruncated) -> Data {
        guard count >= 0, count <= remainingCount else { throw SSHWireTruncated() }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    /// A `string`: a 32-bit length followed by that many bytes.
    mutating func readString() throws(SSHWireTruncated) -> Data {
        let length = try readUInt32()
        guard length <= UInt32(clamping: remainingCount) else { throw SSHWireTruncated() }
        return try readBytes(Int(length))
    }

    /// A `string` holding text. Invalid UTF-8 is repaired rather than
    /// rejected: the fields read this way are algorithm names and comments.
    mutating func readText() throws(SSHWireTruncated) -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    /// An `mpint`, returned as its unsigned big-endian magnitude without
    /// leading zero bytes. Negative values do not occur in key material.
    mutating func readMagnitude() throws(SSHWireTruncated) -> Data {
        let encoded = try readString()
        return Data(encoded.drop(while: { $0 == 0 }))
    }

    mutating func readRemaining() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}

/// Writes the primitive types of the SSH wire encoding (RFC 4251 §5).
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writeString(_ bytes: Data) {
        writeUInt32(UInt32(clamping: bytes.count))
        data.append(bytes)
    }

    mutating func writeString(_ text: String) {
        writeString(Data(text.utf8))
    }

    /// An `mpint` from an unsigned big-endian magnitude: leading zeros are
    /// dropped, and one zero byte is put back when the top bit is set so the
    /// two's-complement value stays positive.
    mutating func writeMagnitude(_ magnitude: Data) {
        var encoded = Data(magnitude.drop(while: { $0 == 0 }))
        if let first = encoded.first, first & 0x80 != 0 {
            encoded.insert(0, at: encoded.startIndex)
        }
        writeString(encoded)
    }
}

enum SSHFingerprint {
    /// The fingerprint `ssh-keygen -l` prints for a public key blob: the
    /// SHA-256 digest in base64, without padding.
    static func sha256(ofPublicKeyBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.prefix(while: { $0 != "=" })
    }
}

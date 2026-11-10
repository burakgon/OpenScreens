import Foundation

/// Apple's `SetKeyboardInputSource` message (`0x1a`), which tells a Mac the
/// keyboard input source its viewer types with — for example
/// `com.apple.keylayout.ABC`.
///
/// A viewer that sends keys by position uses it to have both ends read those
/// positions the same way. macOS has been seen to switch to the named source
/// for the length of the session, including one that is not among the
/// account's enabled input sources, and to return to its own afterwards.
public enum AppleKeyboardInputSource {
    public static let messageType: UInt8 = 0x1a
    public static let version: UInt16 = 1
    public static let maximumIdentifierByteCount = 255

    /// The message naming an input source: type, padding, the size of what
    /// follows, version, identifier length and the UTF-8 identifier.
    /// `nil` when the identifier is empty or too long to send.
    public static func wireMessage(identifier: String) -> Data? {
        let name = Data(identifier.utf8)
        guard !name.isEmpty, name.count <= maximumIdentifierByteCount else { return nil }
        let size = UInt16(2 + 2 + name.count)
        var message = Data([messageType, 0x00])
        message.append(contentsOf: [UInt8(size >> 8), UInt8(size & 0xFF)])
        message.append(contentsOf: [UInt8(version >> 8), UInt8(version & 0xFF)])
        message.append(contentsOf: [UInt8(name.count >> 8), UInt8(name.count & 0xFF)])
        message.append(name)
        return message
    }
}

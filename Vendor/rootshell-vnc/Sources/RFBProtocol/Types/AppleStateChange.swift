import Foundation

/// Apple server message 20: something about the session changed.
///
///     14 00
///     <size: u16>     size of what follows, 4
///     00 01           version
///     <code: u16>
///
/// The codes below are the ones `screensharingd` was seen to send or builds
/// in its own code on macOS 27.2. It forwards others it is handed by its
/// agent, so an unknown code is expected and means nothing by itself.
public struct AppleStateChange: Sendable, Equatable {
    public static let messageType: UInt8 = 0x14
    /// Type, padding and the size field, which every message starts with.
    public static let headerWireSize = 4
    /// The whole message as every known server sends it.
    public static let wireSize = 8

    /// The user at the remote Mac ended this viewer's connection.
    public static let localUserClosedConnection: UInt16 = 1
    /// The remote pasteboard has new contents. The viewer fetches them with
    /// a clipboard request if it wants them.
    public static let pasteboardChanged: UInt16 = 2
    /// Nothing changed. The server sends this when it has sent nothing else
    /// on the connection for two seconds, which in High Performance mode,
    /// where the picture travels beside the connection, is all the time.
    public static let idle: UInt16 = 4
    /// The Mac's console went to another user session.
    public static let userSessionChanged: UInt16 = 0x11

    public let code: UInt16

    public init(code: UInt16) {
        self.code = code
    }

    /// Reads a whole message, type byte included. Nil when it is not one or
    /// is too short to carry a code.
    public init?(wire: Data) {
        let bytes = [UInt8](wire)
        guard bytes.count >= Self.wireSize,
              bytes[0] == Self.messageType,
              Self.payloadSize(header: wire) >= 4 else { return nil }
        code = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
    }

    /// How many bytes follow the four-byte header, from the header alone.
    public static func payloadSize(header: Data) -> Int {
        let bytes = [UInt8](header.prefix(headerWireSize))
        guard bytes.count == headerWireSize else { return 0 }
        return Int(bytes[2]) << 8 | Int(bytes[3])
    }

    /// Whether the viewer should fetch the remote pasteboard.
    public var announcesPasteboard: Bool {
        code == Self.pasteboardChanged
    }
}

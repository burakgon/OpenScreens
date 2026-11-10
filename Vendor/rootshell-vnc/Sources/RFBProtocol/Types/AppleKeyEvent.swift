import Foundation

/// Apple's version-2 key event, as its own Screen Sharing viewer sends it.
///
/// A plain RFB `KeyEvent` carries only an X11 keysym, which the Mac has to
/// translate back into a key through its current keyboard layout. Apple's
/// viewer sends more: the keysym, the virtual key code of the key that was
/// pressed, and the keyboard type the code belongs to. With a key code the
/// Mac posts exactly that key, so shortcuts, key repeat and layout-specific
/// keys behave as they do on a keyboard plugged into it.
///
/// The event travels as input message type 23, subtype 12. Its 16-byte body
/// is one AES-128 block encrypted in ECB mode under the key the
/// authentication exchange produced, whether or not the rest of the session
/// is encrypted.
public struct AppleKeyEvent: Sendable, Equatable {
    public static let messageType: UInt8 = 0x17
    public static let inputEventVersion: UInt16 = 1
    public static let keyMouseSubtype: UInt16 = 12
    public static let blockByteCount = 16
    /// Version, subtype, two flag bytes and the encrypted block.
    public static let payloadByteCount: UInt16 = 22
    public static let wireByteCount = 26

    /// The keyboard type Screen Sharing itself uses for keys it synthesizes:
    /// a standard ANSI layout of virtual key codes.
    public static let standardKeyboardType: UInt16 = 198

    public var keysym: UInt32
    public var isDown: Bool
    /// The macOS virtual key code, when the key is known by position.
    public var keyCode: UInt16?
    public var keyboardType: UInt16

    public init(
        keysym: UInt32,
        isDown: Bool,
        keyCode: UInt16? = nil,
        keyboardType: UInt16 = AppleKeyEvent.standardKeyboardType
    ) {
        self.keysym = keysym
        self.isDown = isDown
        self.keyCode = keyCode
        self.keyboardType = keyboardType
    }

    /// The event body before encryption.
    ///
    /// Byte 0 marks a key event and byte 10 says no pointer event shares the
    /// block; the server treats any other marker values as a failed decrypt.
    public var plainBlock: Data {
        var block = Data(count: Self.blockByteCount)
        block[0] = 0xff
        block[1] = isDown ? 1 : 0
        block[2] = UInt8(keysym >> 24)
        block[3] = UInt8((keysym >> 16) & 0xff)
        block[4] = UInt8((keysym >> 8) & 0xff)
        block[5] = UInt8(keysym & 0xff)
        block[10] = 0x00
        block[12] = UInt8(keyboardType >> 8)
        block[13] = UInt8(keyboardType & 0xff)
        let code = keyCode ?? 0
        block[14] = UInt8(code >> 8)
        block[15] = UInt8(code & 0xff)
        return block
    }

    /// The complete message around an already encrypted body.
    public func wireMessage(encryptedBlock: Data) -> Data? {
        guard encryptedBlock.count == Self.blockByteCount else { return nil }
        var data = Data(count: Self.wireByteCount)
        data[0] = Self.messageType
        data[1] = 0x00 // no timestamp follows
        data[2] = UInt8(Self.payloadByteCount >> 8)
        data[3] = UInt8(Self.payloadByteCount & 0xff)
        data[4] = UInt8(Self.inputEventVersion >> 8)
        data[5] = UInt8(Self.inputEventVersion & 0xff)
        data[6] = UInt8(Self.keyMouseSubtype >> 8)
        data[7] = UInt8(Self.keyMouseSubtype & 0xff)
        data[8] = 0x00
        // Bit 0 tells the Mac to post the key code as given rather than
        // translating the keysym; bit 1 keeps that true for every viewer
        // version it knows.
        data[9] = keyCode == nil ? 0x00 : 0x03
        data.replaceSubrange(10..<26, with: encryptedBlock)
        return data
    }
}

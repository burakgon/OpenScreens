import Foundation

/// Maps physical keys to X11 keysyms.
///
/// Characters are resolved from what the key types; these tables cover the
/// keys that do not type anything — navigation, function and modifier keys —
/// which have to be recognised by position instead.
public enum KeyCodes {

    /// Keysym for a macOS virtual key code (`NSEvent.keyCode`), or `nil` when
    /// the key should be resolved from its characters.
    public static func keysym(forMacKeyCode keyCode: UInt16) -> UInt32? {
        macTable[keyCode]
    }

    /// Keysym for a modifier key's macOS virtual key code.
    public static func modifierKeysym(forMacKeyCode keyCode: UInt16) -> UInt32? {
        macModifiers[keyCode]
    }

    /// Keysym for a USB HID keyboard usage (`UIKey.keyCode`), or `nil` when
    /// the key should be resolved from its characters.
    public static func keysym(forHIDUsage usage: Int) -> UInt32? {
        switch usage {
        case 0x28: Keysym.returnKey
        case 0x29: Keysym.escape
        case 0x2A: Keysym.backspace
        case 0x2B: Keysym.tab
        case 0x39: Keysym.capsLock
        case 0x3A...0x45: Keysym.function(usage - 0x3A + 1)
        case 0x46: Keysym.printScreen
        case 0x47: Keysym.scrollLock
        case 0x48: Keysym.pause
        case 0x49: Keysym.insert
        case 0x4A: Keysym.home
        case 0x4B: Keysym.pageUp
        case 0x4C: Keysym.delete
        case 0x4D: Keysym.end
        case 0x4E: Keysym.pageDown
        case 0x4F: Keysym.right
        case 0x50: Keysym.left
        case 0x51: Keysym.down
        case 0x52: Keysym.up
        case 0x53: Keysym.numLock
        case 0x58: Keysym.keypadEnter
        case 0x65: Keysym.menu
        case 0x68...0x73: Keysym.function(usage - 0x68 + 13)
        case 0xE0: Keysym.controlLeft
        case 0xE1: Keysym.shiftLeft
        case 0xE2: Keysym.altLeft
        case 0xE3: Keysym.superLeft
        case 0xE4: Keysym.controlRight
        case 0xE5: Keysym.shiftRight
        case 0xE6: Keysym.altRight
        case 0xE7: Keysym.superRight
        default: nil
        }
    }

    /// Whether a HID usage is one of the eight modifier keys.
    public static func isModifier(hidUsage usage: Int) -> Bool {
        (0xE0...0xE7).contains(usage)
    }

    // Virtual key codes from Carbon's Events.h (kVK_*).
    private static let macTable: [UInt16: UInt32] = [
        36: Keysym.returnKey,
        48: Keysym.tab,
        51: Keysym.backspace,
        53: Keysym.escape,
        71: 0xFF0B,                 // Clear
        76: Keysym.keypadEnter,
        114: Keysym.insert,         // Help / Insert
        115: Keysym.home,
        116: Keysym.pageUp,
        117: Keysym.delete,         // Forward delete
        119: Keysym.end,
        121: Keysym.pageDown,
        123: Keysym.left,
        124: Keysym.right,
        125: Keysym.down,
        126: Keysym.up,
        122: Keysym.function(1),
        120: Keysym.function(2),
        99: Keysym.function(3),
        118: Keysym.function(4),
        96: Keysym.function(5),
        97: Keysym.function(6),
        98: Keysym.function(7),
        100: Keysym.function(8),
        101: Keysym.function(9),
        109: Keysym.function(10),
        103: Keysym.function(11),
        111: Keysym.function(12),
        105: Keysym.function(13),
        107: Keysym.function(14),
        113: Keysym.function(15),
        106: Keysym.function(16),
        64: Keysym.function(17),
        79: Keysym.function(18),
        80: Keysym.function(19),
        90: Keysym.function(20),
    ]

    private static let macModifiers: [UInt16: UInt32] = [
        56: Keysym.shiftLeft,
        60: Keysym.shiftRight,
        59: Keysym.controlLeft,
        62: Keysym.controlRight,
        58: Keysym.altLeft,
        61: Keysym.altRight,
        55: Keysym.superLeft,
        54: Keysym.superRight,
        57: Keysym.capsLock,
    ]
}

// MARK: - macOS virtual key codes

extension KeyCodes {

    /// A key on a Mac keyboard: its virtual key code and whether Shift has to
    /// be held to get the wanted character from it.
    public struct MacKey: Equatable, Sendable {
        public var code: UInt16
        public var needsShift: Bool

        public init(code: UInt16, needsShift: Bool = false) {
            self.code = code
            self.needsShift = needsShift
        }
    }

    /// Virtual key codes of the modifier keys.
    public static let macShift: UInt16 = 56
    public static let macControl: UInt16 = 59
    public static let macOption: UInt16 = 58
    public static let macCommand: UInt16 = 55

    /// The Mac key that produces a keysym on a US ANSI keyboard.
    ///
    /// Macs take key events by position, so a character has to be turned
    /// back into the key that types it. Returns `nil` for characters that are
    /// not on the US layout; those are sent by keysym alone and the Mac
    /// inserts them as text.
    public static func macKey(forKeysym keysym: UInt32) -> MacKey? {
        if let code = macKeyCodesBySpecialKeysym[keysym] {
            return MacKey(code: code)
        }
        guard keysym < 0x80, let scalar = Unicode.Scalar(keysym) else { return nil }
        let character = Character(scalar)
        if let code = macKeyCodesByCharacter[character] {
            return MacKey(code: code)
        }
        if let code = macKeyCodesByShiftedCharacter[character] {
            return MacKey(code: code, needsShift: true)
        }
        if character.isUppercase, let code = macKeyCodesByCharacter[Character(character.lowercased())] {
            return MacKey(code: code, needsShift: true)
        }
        return nil
    }

    /// The character a key types on a US ANSI keyboard with no modifiers
    /// held, which is the name shortcuts know the key by.
    public static func usCharacter(forMacKeyCode keyCode: UInt16) -> Character? {
        usCharactersByMacKeyCode[keyCode]
    }

    /// The macOS virtual key code for a USB HID keyboard usage, as reported
    /// for hardware keyboards on iPhone and iPad.
    public static func macKeyCode(forHIDUsage usage: Int) -> UInt16? {
        macKeyCodesByHIDUsage[usage]
    }

    private static let macKeyCodesByCharacter: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    private static let usCharactersByMacKeyCode: [UInt16: Character] = {
        var table: [UInt16: Character] = [:]
        for (character, code) in macKeyCodesByCharacter {
            table[code] = character
        }
        return table
    }()

    private static let macKeyCodesByShiftedCharacter: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26,
        "_": 27, "*": 28, ")": 29, "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42,
        "<": 43, "?": 44, ">": 47, "~": 50,
    ]

    private static let macKeyCodesBySpecialKeysym: [UInt32: UInt16] = {
        var table: [UInt32: UInt16] = [:]
        // The position tables already map key codes to keysyms; invert them.
        for (code, keysym) in macTable {
            table[keysym] = code
        }
        for (code, keysym) in macModifiers {
            table[keysym] = code
        }
        // Option and Command arrive under either of two keysyms each,
        // depending on which convention the sender follows.
        table[Keysym.metaLeft] = 58
        table[Keysym.metaRight] = 61
        table[Keysym.altLeft] = table[Keysym.altLeft] ?? 58
        table[Keysym.altRight] = table[Keysym.altRight] ?? 61
        table[Keysym.space] = 49
        return table
    }()

    private static let macKeyCodesByHIDUsage: [Int: UInt16] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4, 0x0C: 34,
        0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12,
        0x15: 15, 0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28,
        0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33,
        0x30: 30, 0x31: 42, 0x32: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47,
        0x38: 44, 0x39: 57,
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100,
        0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        0x46: 105, 0x47: 107, 0x48: 113, 0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117,
        0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        0x53: 71, 0x54: 75, 0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76,
        0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87, 0x5E: 88, 0x5F: 89, 0x60: 91,
        0x61: 92, 0x62: 82, 0x63: 65, 0x64: 10, 0x67: 81,
        0x68: 105, 0x69: 107, 0x6A: 113, 0x6B: 106, 0x6C: 64, 0x6D: 79, 0x6E: 80, 0x6F: 90,
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
    ]
}

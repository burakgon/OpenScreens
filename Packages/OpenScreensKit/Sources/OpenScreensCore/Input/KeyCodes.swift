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

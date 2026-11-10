import Foundation

/// Modifier keys, named as they are on a Mac keyboard.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// The modifiers in the order they are conventionally written.
    public static let displayOrder: [KeyModifiers] = [.control, .option, .shift, .command]

    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }

    public func title(of single: KeyModifiers, on kind: ComputerKind) -> String {
        switch single {
        case .control: "Control"
        case .option: kind.isApple ? "Option" : "Alt"
        case .shift: "Shift"
        case .command: kind.isApple ? "Command" : (kind == .windows ? "Windows" : "Super")
        default: ""
        }
    }
}

/// How a computer expects modifier keys to arrive.
///
/// Macs and everything else disagree about which X11 key means Option, and a
/// Mac user's ⌘C is ⌃C to a PC. The convention captures both differences so
/// callers can keep thinking in Mac terms.
public struct ModifierConvention: Hashable, Sendable {
    /// Send Option as Meta rather than Alt. True for Apple servers.
    public var optionIsMeta: Bool
    /// Send ⌘ as Control and ⌃ as Super, so Mac shortcuts do the expected
    /// thing on Windows and Linux.
    public var swapsCommandAndControl: Bool

    public init(optionIsMeta: Bool, swapsCommandAndControl: Bool) {
        self.optionIsMeta = optionIsMeta
        self.swapsCommandAndControl = swapsCommandAndControl
    }

    public static let apple = ModifierConvention(optionIsMeta: true, swapsCommandAndControl: false)
    public static let standard = ModifierConvention(optionIsMeta: false, swapsCommandAndControl: false)

    /// X11 keysyms for a set of modifiers, in press order.
    public func keysyms(for modifiers: KeyModifiers) -> [UInt32] {
        var result: [UInt32] = []
        if modifiers.contains(.control) {
            result.append(swapsCommandAndControl ? Keysym.superLeft : Keysym.controlLeft)
        }
        if modifiers.contains(.option) {
            result.append(optionIsMeta ? Keysym.metaLeft : Keysym.altLeft)
        }
        if modifiers.contains(.shift) {
            result.append(Keysym.shiftLeft)
        }
        if modifiers.contains(.command) {
            result.append(swapsCommandAndControl ? Keysym.controlLeft : Keysym.superLeft)
        }
        return result
    }

    /// Rewrites a single modifier keysym coming from a physical keyboard.
    public func translate(modifierKeysym keysym: UInt32) -> UInt32 {
        switch keysym {
        case Keysym.altLeft where optionIsMeta: Keysym.metaLeft
        case Keysym.altRight where optionIsMeta: Keysym.metaRight
        case Keysym.metaLeft where !optionIsMeta: Keysym.altLeft
        case Keysym.metaRight where !optionIsMeta: Keysym.altRight
        case Keysym.superLeft where swapsCommandAndControl: Keysym.controlLeft
        case Keysym.superRight where swapsCommandAndControl: Keysym.controlRight
        case Keysym.controlLeft where swapsCommandAndControl: Keysym.superLeft
        case Keysym.controlRight where swapsCommandAndControl: Keysym.superRight
        default: keysym
        }
    }
}

/// X11 keysym values used by the RFB protocol.
public enum Keysym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let pause: UInt32 = 0xFF13
    public static let scrollLock: UInt32 = 0xFF14
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let printScreen: UInt32 = 0xFF61
    public static let insert: UInt32 = 0xFF63
    public static let menu: UInt32 = 0xFF67
    public static let numLock: UInt32 = 0xFF7F
    public static let keypadEnter: UInt32 = 0xFF8D
    public static let f1: UInt32 = 0xFFBE
    public static let shiftLeft: UInt32 = 0xFFE1
    public static let shiftRight: UInt32 = 0xFFE2
    public static let controlLeft: UInt32 = 0xFFE3
    public static let controlRight: UInt32 = 0xFFE4
    public static let capsLock: UInt32 = 0xFFE5
    public static let metaLeft: UInt32 = 0xFFE7
    public static let metaRight: UInt32 = 0xFFE8
    public static let altLeft: UInt32 = 0xFFE9
    public static let altRight: UInt32 = 0xFFEA
    public static let superLeft: UInt32 = 0xFFEB
    public static let superRight: UInt32 = 0xFFEC
    public static let delete: UInt32 = 0xFFFF
    public static let space: UInt32 = 0x0020

    public static func function(_ number: Int) -> UInt32 {
        guard (1...24).contains(number) else { return 0 }
        return f1 + UInt32(number - 1)
    }

    /// The keysym that types a character.
    ///
    /// Printable ASCII and Latin-1 map to themselves; everything else uses the
    /// X11 Unicode range. Returns 0 for characters that cannot be typed.
    public static func character(_ character: Character) -> UInt32 {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        return Self.scalar(scalar)
    }

    /// The keysyms that type a piece of text, one for each Unicode scalar.
    ///
    /// The text is composed first, so a letter and its accent become the one
    /// key press that types the accented letter.
    public static func keysyms(for text: String) -> [UInt32] {
        text.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { scalar($0) }
            .filter { $0 != 0 }
    }

    /// The keysym that types a Unicode scalar, or 0 when there is none.
    public static func scalar(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        switch value {
        case 0x20...0x7E, 0xA0...0xFF: return value
        case 0x08: return backspace
        case 0x09: return tab
        case 0x0A, 0x0D: return returnKey
        case 0x1B: return escape
        case 0x7F: return delete
        case 0x100...: return 0x0100_0000 | value
        default: return 0
        }
    }

    public static func isModifier(_ keysym: UInt32) -> Bool {
        (shiftLeft...superRight).contains(keysym)
    }
}

/// A non-character key.
public enum SpecialKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case returnKey, tab, space, escape, delete, forwardDelete, insert
    case home, end, pageUp, pageDown
    case left, right, up, down
    case printScreen, scrollLock, pause, menu, capsLock

    public var id: Self { self }

    public var keysym: UInt32 {
        switch self {
        case .returnKey: Keysym.returnKey
        case .tab: Keysym.tab
        case .space: Keysym.space
        case .escape: Keysym.escape
        case .delete: Keysym.backspace
        case .forwardDelete: Keysym.delete
        case .insert: Keysym.insert
        case .home: Keysym.home
        case .end: Keysym.end
        case .pageUp: Keysym.pageUp
        case .pageDown: Keysym.pageDown
        case .left: Keysym.left
        case .right: Keysym.right
        case .up: Keysym.up
        case .down: Keysym.down
        case .printScreen: Keysym.printScreen
        case .scrollLock: Keysym.scrollLock
        case .pause: Keysym.pause
        case .menu: Keysym.menu
        case .capsLock: Keysym.capsLock
        }
    }

    public var title: String {
        switch self {
        case .returnKey: "Return"
        case .tab: "Tab"
        case .space: "Space"
        case .escape: "Escape"
        case .delete: "Delete"
        case .forwardDelete: "Forward Delete"
        case .insert: "Insert"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .printScreen: "Print Screen"
        case .scrollLock: "Scroll Lock"
        case .pause: "Pause"
        case .menu: "Menu"
        case .capsLock: "Caps Lock"
        }
    }

    /// Short glyph for key caps and shortcut strings.
    public var glyph: String {
        switch self {
        case .returnKey: "↩"
        case .tab: "⇥"
        case .space: "␣"
        case .escape: "⎋"
        case .delete: "⌫"
        case .forwardDelete: "⌦"
        case .insert: "Ins"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .printScreen: "PrtSc"
        case .scrollLock: "ScrLk"
        case .pause: "Pause"
        case .menu: "Menu"
        case .capsLock: "⇪"
        }
    }

    /// Keys that should repeat while held on the on-screen toolbar.
    public var repeatsWhenHeld: Bool {
        switch self {
        case .left, .right, .up, .down, .pageUp, .pageDown, .tab, .returnKey,
             .delete, .forwardDelete, .space:
            true
        default:
            false
        }
    }
}

/// One key on the remote keyboard.
public enum RemoteKey: Codable, Hashable, Sendable {
    case character(String)
    case special(SpecialKey)
    case function(Int)

    public var keysym: UInt32 {
        switch self {
        case .character(let string):
            string.lowercased().first.map(Keysym.character) ?? 0
        case .special(let key):
            key.keysym
        case .function(let number):
            Keysym.function(number)
        }
    }

    public var glyph: String {
        switch self {
        case .character(let string): string.uppercased()
        case .special(let key): key.glyph
        case .function(let number): "F\(number)"
        }
    }

    public var title: String {
        switch self {
        case .character(let string): string.uppercased()
        case .special(let key): key.title
        case .function(let number): "F\(number)"
        }
    }
}

/// A key combination that can be sent to the remote computer in one tap.
public struct RemoteShortcut: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var modifiers: KeyModifiers
    public var key: RemoteKey
    public var symbolName: String

    public init(
        id: UUID = UUID(),
        name: String,
        modifiers: KeyModifiers = [],
        key: RemoteKey,
        symbolName: String = "keyboard"
    ) {
        self.id = id
        self.name = name
        self.modifiers = modifiers
        self.key = key
        self.symbolName = symbolName
    }

    /// The combination written out, for example `⌃⌘Q`.
    public var keyString: String {
        modifiers.symbols + key.glyph
    }

    /// The combination spelled with PC key names, for example `Ctrl+Alt+Del`.
    public func pcKeyString(for kind: ComputerKind) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append(kind == .windows ? "Win" : "Super") }
        let keyName: String = switch key {
        case .special(.forwardDelete): "Del"
        // The Mac's Delete key is what a PC keyboard calls Backspace.
        case .special(.delete): "Backspace"
        case .special(.escape): "Esc"
        case .special(let special): special.title
        default: key.glyph
        }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    public func displayString(for kind: ComputerKind) -> String {
        kind.isApple ? keyString : pcKeyString(for: kind)
    }
}

// MARK: - Built-in shortcuts

extension RemoteShortcut {
    /// Shortcuts worth having one tap away for a kind of computer.
    public static func builtIn(for kind: ComputerKind) -> [RemoteShortcut] {
        switch kind {
        case .mac: macShortcuts
        case .windows: windowsShortcuts
        case .linux, .raspberryPi, .other: linuxShortcuts
        }
    }

    // Stable identifiers so a built-in shortcut keeps its identity across launches.
    private static func make(
        _ index: Int,
        _ name: String,
        _ modifiers: KeyModifiers,
        _ key: RemoteKey,
        _ symbol: String
    ) -> RemoteShortcut {
        let suffix = String(index, radix: 16, uppercase: true)
        let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
        return RemoteShortcut(
            id: UUID(uuidString: "0F5C0000-0000-4000-8000-\(padded)") ?? UUID(),
            name: name,
            modifiers: modifiers,
            key: key,
            symbolName: symbol)
    }

    static let macShortcuts: [RemoteShortcut] = [
        make(0x101, "Spotlight", [.command], .special(.space), "magnifyingglass"),
        make(0x102, "App Switcher", [.command], .special(.tab), "rectangle.on.rectangle"),
        make(0x103, "Mission Control", [.control], .special(.up), "rectangle.3.group"),
        make(0x104, "App Exposé", [.control], .special(.down), "rectangle.stack"),
        make(0x105, "Show Desktop", [], .function(11), "menubar.dock.rectangle"),
        make(0x106, "Previous Space", [.control], .special(.left), "arrow.left.square"),
        make(0x107, "Next Space", [.control], .special(.right), "arrow.right.square"),
        make(0x108, "Hide Application", [.command], .character("h"), "eye.slash"),
        make(0x109, "Quit Application", [.command], .character("q"), "xmark.square"),
        make(0x10A, "Close Window", [.command], .character("w"), "xmark.rectangle"),
        make(0x10B, "Force Quit", [.option, .command], .special(.escape), "exclamationmark.octagon"),
        make(0x10C, "Screenshot", [.shift, .command], .character("5"), "camera.viewfinder"),
        make(0x10D, "Lock Screen", [.control, .command], .character("q"), "lock"),
        make(0x10E, "Toggle Dock", [.option, .command], .character("d"), "dock.rectangle"),
        make(0x10F, "Emoji Picker", [.control, .command], .special(.space), "face.smiling"),
    ]

    static let windowsShortcuts: [RemoteShortcut] = [
        make(0x201, "Ctrl+Alt+Del", [.control, .option], .special(.forwardDelete), "exclamationmark.shield"),
        make(0x202, "Start Menu", [.control], .special(.escape), "square.grid.2x2"),
        make(0x203, "Switch Windows", [.option], .special(.tab), "rectangle.on.rectangle"),
        make(0x204, "Task View", [.command], .special(.tab), "rectangle.3.group"),
        make(0x205, "Show Desktop", [.command], .character("d"), "menubar.dock.rectangle"),
        make(0x206, "File Explorer", [.command], .character("e"), "folder"),
        make(0x207, "Run", [.command], .character("r"), "play.rectangle"),
        make(0x208, "Task Manager", [.control, .shift], .special(.escape), "chart.bar"),
        make(0x209, "Close Window", [.option], .function(4), "xmark.rectangle"),
        make(0x20A, "Lock", [.command], .character("l"), "lock"),
        make(0x20B, "Settings", [.command], .character("i"), "gearshape"),
        make(0x20C, "Screenshot", [.shift, .command], .character("s"), "camera.viewfinder"),
        make(0x20D, "Print Screen", [], .special(.printScreen), "printer"),
    ]

    static let linuxShortcuts: [RemoteShortcut] = [
        make(0x301, "Ctrl+Alt+Del", [.control, .option], .special(.forwardDelete), "exclamationmark.shield"),
        make(0x302, "Activities", [.command], .special(.space), "square.grid.2x2"),
        make(0x303, "Switch Windows", [.option], .special(.tab), "rectangle.on.rectangle"),
        make(0x304, "Terminal", [.control, .option], .character("t"), "terminal"),
        make(0x305, "Close Window", [.option], .function(4), "xmark.rectangle"),
        make(0x306, "Run Command", [.option], .function(2), "play.rectangle"),
        make(0x307, "Lock", [.command], .character("l"), "lock"),
        make(0x308, "Show Desktop", [.command], .character("d"), "menubar.dock.rectangle"),
        make(0x309, "Print Screen", [], .special(.printScreen), "printer"),
        make(0x30A, "Virtual Console 1", [.control, .option], .function(1), "1.square"),
        make(0x30B, "Virtual Console 7", [.control, .option], .function(7), "7.square"),
    ]
}

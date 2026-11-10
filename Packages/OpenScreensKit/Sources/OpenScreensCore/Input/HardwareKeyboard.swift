import Foundation

/// A key going down or up on the remote computer.
public struct KeyTransition: Equatable, Sendable {
    public var keysym: UInt32
    public var isDown: Bool
    /// The macOS virtual key code of the key, for a server that takes keys by
    /// position. `nil` sends the keysym alone.
    public var keyCode: UInt16?

    public init(keysym: UInt32, isDown: Bool, keyCode: UInt16? = nil) {
        self.keysym = keysym
        self.isDown = isDown
        self.keyCode = keyCode
    }

    /// The same key, released.
    var released: KeyTransition {
        KeyTransition(keysym: keysym, isDown: false, keyCode: keyCode)
    }
}

/// One of the eight modifier keys on a keyboard.
public enum ModifierKey: Hashable, Sendable, CaseIterable {
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand

    public var modifier: KeyModifiers {
        switch self {
        case .leftShift, .rightShift: .shift
        case .leftControl, .rightControl: .control
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        }
    }

    /// The key's X11 keysym before any remapping for the remote system:
    /// Option is Alt and Command is Super.
    public var keysym: UInt32 {
        switch self {
        case .leftShift: Keysym.shiftLeft
        case .rightShift: Keysym.shiftRight
        case .leftControl: Keysym.controlLeft
        case .rightControl: Keysym.controlRight
        case .leftOption: Keysym.altLeft
        case .rightOption: Keysym.altRight
        case .leftCommand: Keysym.superLeft
        case .rightCommand: Keysym.superRight
        }
    }

    /// The key's macOS virtual key code.
    public var macKeyCode: UInt16 {
        switch self {
        case .leftShift: 56
        case .rightShift: 60
        case .leftControl: 59
        case .rightControl: 62
        case .leftOption: 58
        case .rightOption: 61
        case .leftCommand: 55
        case .rightCommand: 54
        }
    }

    public init?(macKeyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.macKeyCode == macKeyCode }) else { return nil }
        self = key
    }

    /// A modifier key from its USB HID keyboard usage (`0xE0`–`0xE7`).
    public init?(hidUsage: Int) {
        switch hidUsage {
        case 0xE0: self = .leftControl
        case 0xE1: self = .leftShift
        case 0xE2: self = .leftOption
        case 0xE3: self = .leftCommand
        case 0xE4: self = .rightControl
        case 0xE5: self = .rightShift
        case 0xE6: self = .rightOption
        case 0xE7: self = .rightCommand
        default: return nil
        }
    }
}

/// A key pressed on a physical keyboard, described by what it types on the
/// keyboard layout in use.
public struct KeyStroke: Equatable, Sendable {
    /// Identifies the physical key until it is released.
    public var key: Int
    /// The key's macOS virtual key code, when known.
    public var macKeyCode: UInt16?
    /// The keysym of a key that does not type a character — an arrow, a
    /// function key, Return. `nil` for character keys.
    public var special: UInt32?
    /// What the key types with the Shift, Option and Caps Lock state it was
    /// pressed in, after combining with a pending dead key. Empty when the
    /// key is itself a dead key waiting for its letter.
    public var text: String
    /// What the key types with Shift and Caps Lock alone.
    public var textWithoutOption: String
    /// The character the key stands for in a Command shortcut. Layouts that
    /// do not type Latin letters answer with the Latin key here.
    public var shortcutText: String

    public init(
        key: Int,
        macKeyCode: UInt16? = nil,
        special: UInt32? = nil,
        text: String = "",
        textWithoutOption: String = "",
        shortcutText: String = ""
    ) {
        self.key = key
        self.macKeyCode = macKeyCode
        self.special = special
        self.text = text
        self.textWithoutOption = textWithoutOption
        self.shortcutText = shortcutText
    }
}

/// Turns what happens on a physical keyboard into key events for the remote
/// computer.
///
/// The two kinds of remote computer want different things.
///
/// **A Mac** types exactly the character it is asked for. Its server finds
/// the key that produces the character on the remote keyboard layout and
/// presses it with whatever Shift and Option that takes — adding them, and
/// cancelling them if they are held but would change the character. So a Mac
/// is sent the finished character: `Ω`, not Option and `z`. That arrives as
/// the same key press it was locally when the layouts match, and as the same
/// character when they do not. With Command held the server leaves the held
/// modifiers alone, and is sent the key the shortcut names.
///
/// **Anything else** follows the plain RFB convention: modifiers are held,
/// and the keysym names the key with Shift applied. Option is Alt there, but
/// on many keyboard layouts Option is also the only way to type `@`, `{` or
/// `\`. So Option is not sent when it goes down; it is sent once something
/// needs Alt, and never if it was only used to type such a symbol.
///
/// When a Mac takes key codes and the user asks for it, keys are sent by
/// position instead and the remote layout decides what they mean.
public struct HardwareKeyboard: Sendable {

    public struct Configuration: Equatable, Sendable {
        /// The remote computer is a Mac running Apple's server.
        public var remoteIsMac: Bool
        /// The server posts a key code as given (see `KeyTransition.keyCode`).
        public var takesKeyCodes: Bool
        public var mode: KeyboardInputMode
        /// How modifier keys are named for the remote system.
        public var convention: ModifierConvention

        public init(
            remoteIsMac: Bool,
            takesKeyCodes: Bool = false,
            mode: KeyboardInputMode = .automatic,
            convention: ModifierConvention
        ) {
            self.remoteIsMac = remoteIsMac
            self.takesKeyCodes = takesKeyCodes
            self.mode = mode
            self.convention = convention
        }
    }

    public var configuration: Configuration

    /// Modifier keys physically held.
    private var held: Set<ModifierKey> = []
    /// Modifier keys the remote computer has been told are down, with the
    /// event that will release each.
    private var sent: [ModifierKey: KeyTransition] = [:]
    /// Whether anything happened while Option has been held.
    private var optionWasUsed = false
    /// What to send when each pressed key is released.
    private var pressed: [Int: [KeyTransition]] = [:]
    private var capsLockIsDown = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Keys go out by position.
    private var sendsKeyCodes: Bool {
        configuration.mode == .keystrokes && configuration.remoteIsMac && configuration.takesKeyCodes
    }

    /// Option is held back until it is known whether it means Alt.
    private var defersOption: Bool {
        !configuration.remoteIsMac && configuration.mode != .keystrokes
    }

    private var heldModifiers: KeyModifiers {
        held.reduce(into: KeyModifiers()) { $0.insert($1.modifier) }
    }

    // MARK: Modifier keys

    public mutating func modifierChanged(_ key: ModifierKey, isDown: Bool) -> [KeyTransition] {
        if isDown {
            guard held.insert(key).inserted else { return [] }
            if key.modifier == .option, defersOption {
                if held.filter({ $0.modifier == .option }).count == 1 {
                    optionWasUsed = false
                }
                return []
            }
            return [press(key)]
        }

        guard held.remove(key) != nil else { return [] }
        if let release = sent.removeValue(forKey: key) {
            return [release]
        }
        // Option pressed and let go with nothing in between is a tap of Alt.
        if key.modifier == .option, defersOption, !optionWasUsed {
            let down = press(key)
            sent[key] = nil
            return [down, down.released]
        }
        return []
    }

    private mutating func press(_ key: ModifierKey) -> KeyTransition {
        let down = KeyTransition(
            keysym: configuration.convention.translate(modifierKeysym: key.keysym),
            isDown: true,
            keyCode: sendsKeyCodes ? key.macKeyCode : nil)
        sent[key] = down.released
        return down
    }

    /// Sends Option keys that are held but have not been sent yet.
    private mutating func sendDeferredOption() -> [KeyTransition] {
        let waiting = held.filter { $0.modifier == .option && sent[$0] == nil }
        guard !waiting.isEmpty else { return [] }
        optionWasUsed = true
        return waiting.sorted { $0.macKeyCode < $1.macKeyCode }.map { press($0) }
    }

    /// Lets go of Option on the remote computer while it stays held here.
    private mutating func withdrawOption() -> [KeyTransition] {
        optionWasUsed = true
        return held
            .filter { $0.modifier == .option }
            .sorted { $0.macKeyCode < $1.macKeyCode }
            .compactMap { sent.removeValue(forKey: $0) }
    }

    /// Caps Lock changed state. Only a remote computer that takes keys by
    /// position needs to know: everywhere else the characters sent already
    /// carry their case.
    public mutating func capsLockChanged(isOn: Bool) -> [KeyTransition] {
        guard sendsKeyCodes, isOn != capsLockIsDown else { return [] }
        capsLockIsDown = isOn
        // A Mac's Caps Lock is on for as long as the key is reported down.
        return [KeyTransition(keysym: Keysym.capsLock, isDown: isOn, keyCode: 57)]
    }

    /// A mouse button is about to go down. Option held at that moment is a
    /// modifier for the click.
    public mutating func pointerButtonWillPress() -> [KeyTransition] {
        defersOption ? sendDeferredOption() : []
    }

    // MARK: Keys

    public mutating func keyDown(_ stroke: KeyStroke) -> [KeyTransition] {
        var output: [KeyTransition] = []
        let keysyms = resolve(stroke, into: &output)
        let keyCode = sendsKeyCodes ? stroke.macKeyCode : nil

        guard keysyms.count == 1, let keysym = keysyms.first else {
            // Nothing to hold: either a dead key waiting for its letter, or
            // several characters that are typed in one go.
            output += releaseKey(stroke.key)
            for keysym in keysyms {
                let down = KeyTransition(keysym: keysym, isDown: true)
                output += [down, down.released]
            }
            pressed[stroke.key] = []
            return output
        }

        let down = KeyTransition(keysym: keysym, isDown: true, keyCode: keyCode)
        if let previous = pressed[stroke.key], previous != [down.released] {
            // The key now means something else — a modifier changed while it
            // was held. Let go of what it was first.
            output += previous
        }
        // A key that is already down and goes down again is repeating; the
        // remote computer is told so the same way.
        pressed[stroke.key] = [down.released]
        output.append(down)
        return output
    }

    public mutating func keyUp(key: Int) -> [KeyTransition] {
        releaseKey(key)
    }

    private mutating func releaseKey(_ key: Int) -> [KeyTransition] {
        pressed.removeValue(forKey: key) ?? []
    }

    /// Releases every key that is down, leaving modifiers as they are.
    public mutating func releaseKeys() -> [KeyTransition] {
        let output = pressed.keys.sorted().flatMap { pressed[$0] ?? [] }
        pressed.removeAll()
        return output
    }

    /// Releases everything, for when the keyboard stops being ours.
    public mutating func releaseAll() -> [KeyTransition] {
        var output = releaseKeys()
        output += sent.keys.sorted { $0.macKeyCode < $1.macKeyCode }.compactMap { sent[$0] }
        sent.removeAll()
        held.removeAll()
        optionWasUsed = false
        return output
    }

    // MARK: What a key press means

    /// The keysyms a key press sends, adding to `output` whatever has to
    /// happen to the modifiers first.
    private mutating func resolve(_ stroke: KeyStroke, into output: inout [KeyTransition]) -> [UInt32] {
        if let special = stroke.special {
            output += sendDeferredOption()
            return [special]
        }

        let modifiers = heldModifiers
        let command = modifiers.contains(.command)

        if sendsKeyCodes, stroke.macKeyCode != nil {
            // The key code decides; the keysym only labels it.
            let label = [stroke.text, stroke.textWithoutOption, stroke.shortcutText]
                .lazy.compactMap { Keysym.keysyms(for: $0).first }.first
            return [label ?? Keysym.space]
        }

        if configuration.remoteIsMac {
            return Keysym.keysyms(for: command ? Self.shortcutText(for: stroke) : stroke.text)
        }

        if command || modifiers.contains(.control) {
            output += sendDeferredOption()
            return Keysym.keysyms(for: command ? Self.shortcutText(for: stroke) : stroke.textWithoutOption)
        }

        guard modifiers.contains(.option), defersOption else {
            let text = modifiers.contains(.option) ? stroke.textWithoutOption : stroke.text
            return Keysym.keysyms(for: text)
        }

        if optionTypesText(stroke) {
            output += withdrawOption()
            return Keysym.keysyms(for: stroke.text)
        }
        output += sendDeferredOption()
        return Keysym.keysyms(for: stroke.textWithoutOption)
    }

    /// Whether Option, held with this key, is typing a character rather than
    /// acting as Alt.
    private func optionTypesText(_ stroke: KeyStroke) -> Bool {
        if configuration.mode == .unicode {
            // Always the character — including nothing yet, for a dead key.
            return stroke.text != stroke.textWithoutOption
        }
        guard stroke.text != stroke.textWithoutOption,
              stroke.text.unicodeScalars.count == 1,
              let scalar = stroke.text.unicodeScalars.first else { return false }
        // The symbols many layouts keep behind Option. Letters and the more
        // exotic glyphs stay Alt shortcuts.
        if scalar == "€" { return true }
        return scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F
            && !CharacterSet.alphanumerics.contains(scalar)
    }

    /// The key a Command shortcut names.
    ///
    /// Shortcuts are written in Latin letters. A key whose own character is
    /// not one — `ı` on a Turkish keyboard, any letter on a Greek one — goes
    /// by the letter in its place on a US keyboard, which is also how macOS
    /// matches it against menus.
    private static func shortcutText(for stroke: KeyStroke) -> String {
        let text = [stroke.shortcutText, stroke.textWithoutOption, stroke.text].first { !$0.isEmpty } ?? ""
        if !text.unicodeScalars.allSatisfy(\.isASCII),
           let keyCode = stroke.macKeyCode,
           let character = KeyCodes.usCharacter(forMacKeyCode: keyCode) {
            return String(character)
        }
        return text
    }
}

// MARK: - Keys pressed for the user

/// Key events for input that does not come from a physical keyboard: toolbar
/// shortcuts, the key bar above the on-screen keyboard, typed text.
public enum SyntheticKeys {

    /// The events that press a key with modifiers held, and the events that
    /// let everything go again.
    ///
    /// A Mac cancels held Shift and Option when they would change the
    /// character it was asked for, so there a combination has to be put the
    /// way the Mac will keep it: an upper-case letter for Shift, and the key
    /// by position for Option.
    public static func combination(
        keysym: UInt32,
        modifiers: KeyModifiers,
        remoteIsMac: Bool,
        takesKeyCodes: Bool,
        convention: ModifierConvention
    ) -> (press: [KeyTransition], release: [KeyTransition]) {
        var modifiers = modifiers
        var key = KeyTransition(keysym: keysym, isDown: true)

        let isCharacter = keysym < 0xFF00 || keysym >= 0x0100_0000
        if isCharacter, modifiers.contains(.shift), let upper = uppercased(keysym) {
            // Shift and a letter is the capital letter, everywhere.
            key.keysym = upper
        } else if remoteIsMac, isCharacter, !modifiers.contains(.command),
                  !modifiers.isDisjoint(with: [.shift, .option]),
                  takesKeyCodes, let macKey = KeyCodes.macKey(forKeysym: keysym) {
            key.keyCode = macKey.code
            if macKey.needsShift {
                modifiers.insert(.shift)
            }
        }

        let modifierKeys = convention.keysyms(for: modifiers).map {
            KeyTransition(
                keysym: $0, isDown: true,
                keyCode: key.keyCode == nil ? nil : KeyCodes.macKey(forKeysym: $0)?.code)
        }
        return (
            press: modifierKeys + [key],
            release: [key.released] + modifierKeys.reversed().map(\.released))
    }

    private static func uppercased(_ keysym: UInt32) -> UInt32? {
        let value = keysym >= 0x0100_0000 ? keysym & 0x00FF_FFFF : keysym
        guard let scalar = Unicode.Scalar(value), scalar.properties.isAlphabetic else { return nil }
        let upper = String(scalar).uppercased()
        guard upper.unicodeScalars.count == 1, let result = upper.unicodeScalars.first else { return nil }
        return Keysym.scalar(result)
    }
}

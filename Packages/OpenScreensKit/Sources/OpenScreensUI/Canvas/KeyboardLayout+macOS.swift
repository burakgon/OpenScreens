#if os(macOS)
import AppKit
import Carbon.HIToolbox
import OpenScreensCore

/// Answers what a key types on the keyboard layout in use.
///
/// `NSEvent` reports the characters of a key press, but not what the same key
/// would have typed with other modifiers, and it leaves dead keys — the
/// accent that waits for its letter — to the text system. A remote session
/// needs both: the finished character to send, and the key a shortcut names.
/// This asks the layout directly and keeps the dead-key state itself.
@MainActor
final class KeyboardLayoutTranslator {
    private var deadKeyState: UInt32 = 0

    struct Modifiers: OptionSet {
        let rawValue: UInt32

        // Carbon modifier bits, as `UCKeyTranslate` takes them.
        static let command = Modifiers(rawValue: UInt32(cmdKey >> 8))
        static let shift = Modifiers(rawValue: UInt32(shiftKey >> 8))
        static let capsLock = Modifiers(rawValue: UInt32(alphaLock >> 8))
        static let option = Modifiers(rawValue: UInt32(optionKey >> 8))
    }

    /// Describes a key press for the remote keyboard.
    ///
    /// Returns `nil` when the current input source has no key layout to ask,
    /// which leaves the caller with what the event itself says.
    func stroke(for event: NSEvent) -> KeyStroke? {
        guard let layout = currentLayout() else { return nil }
        let flags = event.modifierFlags
        var typing: Modifiers = []
        if flags.contains(.shift) { typing.insert(.shift) }
        if flags.contains(.capsLock) { typing.insert(.capsLock) }
        var composing = typing
        if flags.contains(.option) { composing.insert(.option) }

        // Shortcuts do not take part in dead-key composition, and should not
        // disturb an accent that is waiting.
        let isShortcut = !flags.intersection([.command, .control]).isEmpty
        let text = translate(
            event.keyCode, composing, layout: layout, composesDeadKeys: !isShortcut)
        return KeyStroke(
            key: Int(event.keyCode),
            macKeyCode: event.keyCode,
            text: text,
            textWithoutOption: translate(event.keyCode, typing, layout: layout),
            shortcutText: translate(event.keyCode, .command, layout: layout))
    }

    /// Forgets a pending dead key, as any key that is not a character does.
    func reset() {
        deadKeyState = 0
    }

    private func translate(
        _ keyCode: UInt16,
        _ modifiers: Modifiers,
        layout: Data,
        composesDeadKeys: Bool = false
    ) -> String {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        var state: UInt32 = composesDeadKeys ? deadKeyState : 0
        let options = composesDeadKeys ? 0 : OptionBits(kUCKeyTranslateNoDeadKeysMask)
        let status = layout.withUnsafeBytes { buffer -> OSStatus in
            guard let pointer = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                pointer,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifiers.rawValue,
                UInt32(LMGetKbdType()),
                options,
                &state,
                characters.count,
                &length,
                &characters)
        }
        if composesDeadKeys {
            deadKeyState = state
        }
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// The layout behind the current input source. An input method — for
    /// Japanese or Chinese, say — types through an ordinary key layout too,
    /// and that is the one returned for it.
    private func currentLayout() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    }
}
#endif

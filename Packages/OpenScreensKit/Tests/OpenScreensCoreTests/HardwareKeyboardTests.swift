import Testing
@testable import OpenScreensCore

// What a Mac does with key events was measured against macOS's own Screen
// Sharing server; the comments on the Mac tests say what it was seen to do.

private func down(_ keysym: UInt32, code: UInt16? = nil) -> KeyTransition {
    KeyTransition(keysym: keysym, isDown: true, keyCode: code)
}

private func up(_ keysym: UInt32, code: UInt16? = nil) -> KeyTransition {
    KeyTransition(keysym: keysym, isDown: false, keyCode: code)
}

private func keysym(_ character: Character) -> UInt32 {
    Keysym.character(character)
}

/// A character key as a US keyboard reports it.
private func letter(_ plain: String, key: Int = 0, code: UInt16? = nil, option: String? = nil) -> KeyStroke {
    KeyStroke(
        key: key, macKeyCode: code,
        text: option ?? plain, textWithoutOption: plain, shortcutText: plain.lowercased())
}

@Suite("Hardware keyboard, Mac remote")
struct HardwareKeyboardMacTests {
    private func keyboard(
        _ mode: KeyboardInputMode = .automatic, takesKeyCodes: Bool = true
    ) -> HardwareKeyboard {
        HardwareKeyboard(configuration: .init(
            remoteIsMac: true, takesKeyCodes: takesKeyCodes, mode: mode, convention: .apple))
    }

    @Test func aLetterGoesDownAndUpAsItsCharacter() {
        var keyboard = keyboard()
        #expect(keyboard.keyDown(letter("a", key: 0)) == [down(keysym("a"))])
        #expect(keyboard.keyUp(key: 0) == [up(keysym("a"))])
        #expect(keyboard.keyUp(key: 0).isEmpty)
    }

    /// Sent Option and a plain `z`, the Mac cancels Option to type `z`. Sent
    /// `Ω` it presses Z with Option, exactly as the local keyboard did.
    @Test func optionSendsTheCharacterItTypes() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftOption, isDown: true) == [down(Keysym.metaLeft)])
        #expect(keyboard.keyDown(letter("z", key: 6, option: "Ω")) == [down(keysym("Ω"))])
        #expect(keyboard.keyUp(key: 6) == [up(keysym("Ω"))])
        #expect(keyboard.modifierChanged(.leftOption, isDown: false) == [up(Keysym.metaLeft)])
    }

    @Test func aDeadKeySendsNothingUntilItsLetterArrives() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        #expect(keyboard.keyDown(letter("e", key: 14, option: "")).isEmpty)
        #expect(keyboard.keyUp(key: 14).isEmpty)
        _ = keyboard.modifierChanged(.leftOption, isDown: false)
        #expect(keyboard.keyDown(letter("e", key: 14, option: "é")) == [down(0xE9)])
    }

    /// A character the layout types in two pieces — an accent that found no
    /// letter to sit on — is typed out; there is no one key to hold.
    @Test func severalCharactersAreTypedAtOnce() {
        var keyboard = keyboard()
        let stroke = KeyStroke(key: 7, text: "´x", textWithoutOption: "x", shortcutText: "x")
        #expect(keyboard.keyDown(stroke) == [
            down(0xB4), up(0xB4), down(keysym("x")), up(keysym("x")),
        ])
        #expect(keyboard.keyUp(key: 7).isEmpty)
    }

    /// With Command held the Mac leaves the held modifiers alone, so it is
    /// sent the key the shortcut names. A Cyrillic layout names the Latin key.
    @Test func aCommandShortcutSendsTheKeyItNames() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftCommand, isDown: true) == [down(Keysym.superLeft)])
        let stroke = KeyStroke(key: 8, text: "с", textWithoutOption: "с", shortcutText: "c")
        #expect(keyboard.keyDown(stroke) == [down(keysym("c"))])
    }

    /// The Turkish `ı` sits where a US keyboard has `i`; ⌘ with it is ⌘I.
    @Test func aShortcutOnAKeyThatIsNotLatinGoesByItsUSLetter() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftCommand, isDown: true)
        let stroke = KeyStroke(key: 34, macKeyCode: 34, text: "ı", textWithoutOption: "ı", shortcutText: "ı")
        #expect(keyboard.keyDown(stroke) == [down(keysym("i"))])
        // Without a key code there is nothing better to go by.
        let unknown = KeyStroke(key: 99, text: "ı", textWithoutOption: "ı", shortcutText: "ı")
        #expect(keyboard.keyDown(unknown) == [down(keysym("ı"))])
    }

    @Test func commandWithOptionStillSendsThePlainKey() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftCommand, isDown: true)
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        #expect(keyboard.keyDown(letter("i", key: 34, option: "ˆ")) == [down(keysym("i"))])
    }

    /// Control with Option is not a shortcut the Mac protects: it would
    /// cancel Option for a plain letter, so the Option character is sent.
    @Test func controlWithOptionSendsTheOptionCharacter() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftControl, isDown: true)
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        #expect(keyboard.keyDown(letter("f", key: 3, option: "ƒ")) == [down(keysym("ƒ"))])
    }

    @Test func aHeldKeyRepeatsWithoutBeingReleased() {
        var keyboard = keyboard()
        #expect(keyboard.keyDown(letter("a")) == [down(keysym("a"))])
        #expect(keyboard.keyDown(letter("a")) == [down(keysym("a"))])
        #expect(keyboard.keyUp(key: 0) == [up(keysym("a"))])
    }

    @Test func aKeyThatChangesMeaningWhileHeldLetsGoOfTheOldOne() {
        var keyboard = keyboard()
        _ = keyboard.keyDown(letter("a"))
        _ = keyboard.modifierChanged(.leftShift, isDown: true)
        #expect(keyboard.keyDown(letter("A")) == [up(keysym("a")), down(keysym("A"))])
        #expect(keyboard.keyUp(key: 0) == [up(keysym("A"))])
    }

    @Test func keysThatTypeNothingSendTheirKeysym() {
        var keyboard = keyboard()
        let arrow = KeyStroke(key: 123, macKeyCode: 123, special: Keysym.left)
        #expect(keyboard.keyDown(arrow) == [down(Keysym.left)])
        #expect(keyboard.keyUp(key: 123) == [up(Keysym.left)])
    }

    /// The characters sent already carry their case.
    @Test func capsLockIsNotForwardedWhenCharactersAreSent() {
        var keyboard = keyboard()
        #expect(keyboard.capsLockChanged(isOn: true).isEmpty)
        #expect(keyboard.keyDown(letter("A")) == [down(keysym("A"))])
    }

    @Test func keystrokeModeSendsKeysByPosition() {
        var keyboard = keyboard(.keystrokes)
        #expect(keyboard.modifierChanged(.rightOption, isDown: true) == [down(Keysym.metaRight, code: 61)])
        // A dead key is just a key here; the remote layout does the rest.
        #expect(keyboard.keyDown(letter("e", key: 14, code: 14, option: "")) == [down(keysym("e"), code: 14)])
        #expect(keyboard.keyUp(key: 14) == [up(keysym("e"), code: 14)])
        #expect(keyboard.modifierChanged(.rightOption, isDown: false) == [up(Keysym.metaRight, code: 61)])
    }

    /// A Mac's Caps Lock is on for as long as its key is reported down.
    @Test func keystrokeModeForwardsCapsLockAsAHeldKey() {
        var keyboard = keyboard(.keystrokes)
        #expect(keyboard.capsLockChanged(isOn: true) == [down(Keysym.capsLock, code: 57)])
        #expect(keyboard.capsLockChanged(isOn: true).isEmpty)
        #expect(keyboard.capsLockChanged(isOn: false) == [up(Keysym.capsLock, code: 57)])
    }

    @Test func keystrokeModeFallsBackToCharactersWithoutKeyCodes() {
        var keyboard = keyboard(.keystrokes, takesKeyCodes: false)
        #expect(keyboard.modifierChanged(.leftOption, isDown: true) == [down(Keysym.metaLeft)])
        #expect(keyboard.keyDown(letter("z", key: 6, code: 6, option: "Ω")) == [down(keysym("Ω"))])
    }

    @Test func releasingEverythingLetsGoOfKeysBeforeModifiers() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftShift, isDown: true)
        _ = keyboard.keyDown(letter("A"))
        #expect(keyboard.releaseAll() == [up(keysym("A")), up(Keysym.shiftLeft)])
        #expect(keyboard.releaseAll().isEmpty)
        // The modifier is no longer considered held.
        #expect(keyboard.modifierChanged(.leftShift, isDown: false).isEmpty)
    }

    @Test func releasingTheKeysLeavesModifiersDown() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftCommand, isDown: true)
        _ = keyboard.keyDown(letter("c", key: 8))
        #expect(keyboard.releaseKeys() == [up(keysym("c"))])
        #expect(keyboard.modifierChanged(.leftCommand, isDown: false) == [up(Keysym.superLeft)])
    }
}

@Suite("Hardware keyboard, other remotes")
struct HardwareKeyboardStandardTests {
    private func keyboard(
        _ mode: KeyboardInputMode = .automatic, swapsCommandAndControl: Bool = false
    ) -> HardwareKeyboard {
        HardwareKeyboard(configuration: .init(
            remoteIsMac: false, mode: mode,
            convention: ModifierConvention(
                optionIsMeta: false, swapsCommandAndControl: swapsCommandAndControl)))
    }

    @Test func shiftIsHeldAndTheKeysymCarriesTheShiftedCharacter() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftShift, isDown: true) == [down(Keysym.shiftLeft)])
        #expect(keyboard.keyDown(letter("A")) == [down(keysym("A"))])
    }

    @Test func optionWithALetterIsAlt() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftOption, isDown: true).isEmpty)
        #expect(keyboard.keyDown(letter("a", option: "å")) == [down(Keysym.altLeft), down(keysym("a"))])
        #expect(keyboard.keyUp(key: 0) == [up(keysym("a"))])
        #expect(keyboard.modifierChanged(.leftOption, isDown: false) == [up(Keysym.altLeft)])
    }

    /// On a Turkish keyboard `@` is Option-Q. Alt never reaches the remote
    /// computer, where it would turn the symbol into a shortcut.
    @Test func optionThatTypesASymbolIsNotSent() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftOption, isDown: true).isEmpty)
        #expect(keyboard.keyDown(letter("q", key: 12, option: "@")) == [down(keysym("@"))])
        #expect(keyboard.keyUp(key: 12) == [up(keysym("@"))])
        #expect(keyboard.modifierChanged(.leftOption, isDown: false).isEmpty)
    }

    @Test func theEuroSignIsTypedToo() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.rightOption, isDown: true)
        #expect(keyboard.keyDown(letter("e", key: 14, option: "€")) == [down(keysym("€"))])
    }

    @Test func optionTappedByItselfIsATapOfAlt() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftOption, isDown: true).isEmpty)
        #expect(keyboard.modifierChanged(.leftOption, isDown: false) == [
            down(Keysym.altLeft), up(Keysym.altLeft),
        ])
    }

    @Test func optionIsAltForKeysThatTypeNothing() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        let tab = KeyStroke(key: 48, special: Keysym.tab)
        #expect(keyboard.keyDown(tab) == [down(Keysym.altLeft), down(Keysym.tab)])
    }

    @Test func optionIsAltForAClick() {
        var keyboard = keyboard()
        #expect(keyboard.pointerButtonWillPress().isEmpty)
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        #expect(keyboard.pointerButtonWillPress() == [down(Keysym.altLeft)])
        #expect(keyboard.pointerButtonWillPress().isEmpty)
        #expect(keyboard.modifierChanged(.leftOption, isDown: false) == [up(Keysym.altLeft)])
    }

    @Test func altIsLetGoBeforeASymbolAndComesBackForTheNextShortcut() {
        var keyboard = keyboard()
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        _ = keyboard.keyDown(letter("a", key: 0, option: "å"))
        _ = keyboard.keyUp(key: 0)
        #expect(keyboard.keyDown(letter("q", key: 12, option: "@")) == [up(Keysym.altLeft), down(keysym("@"))])
        _ = keyboard.keyUp(key: 12)
        #expect(keyboard.keyDown(letter("f", key: 3, option: "ƒ")) == [down(Keysym.altLeft), down(keysym("f"))])
        _ = keyboard.keyUp(key: 3)
        #expect(keyboard.modifierChanged(.leftOption, isDown: false) == [up(Keysym.altLeft)])
    }

    @Test func controlWithOptionIsAShortcut() {
        var keyboard = keyboard()
        #expect(keyboard.modifierChanged(.leftControl, isDown: true) == [down(Keysym.controlLeft)])
        #expect(keyboard.modifierChanged(.leftOption, isDown: true).isEmpty)
        #expect(keyboard.keyDown(letter("t", key: 17, option: "†")) == [down(Keysym.altLeft), down(keysym("t"))])
    }

    @Test func unicodeModeAlwaysTypesWhatOptionProduces() {
        var keyboard = keyboard(.unicode)
        _ = keyboard.modifierChanged(.leftOption, isDown: true)
        #expect(keyboard.keyDown(letter("a", option: "å")) == [down(keysym("å"))])
        _ = keyboard.keyUp(key: 0)
        // A dead key waits for its letter.
        #expect(keyboard.keyDown(letter("e", key: 14, option: "")).isEmpty)
        #expect(keyboard.modifierChanged(.leftOption, isDown: false).isEmpty)
    }

    @Test func keystrokeModeMakesOptionAlwaysAlt() {
        var keyboard = keyboard(.keystrokes)
        #expect(keyboard.modifierChanged(.leftOption, isDown: true) == [down(Keysym.altLeft)])
        #expect(keyboard.keyDown(letter("q", key: 12, code: 12, option: "@")) == [down(keysym("q"))])
    }

    @Test func commandBecomesControlWhenTheTwoAreSwapped() {
        var keyboard = keyboard(swapsCommandAndControl: true)
        #expect(keyboard.modifierChanged(.leftCommand, isDown: true) == [down(Keysym.controlLeft)])
        #expect(keyboard.keyDown(letter("c", key: 8)) == [down(keysym("c"))])
        #expect(keyboard.modifierChanged(.leftCommand, isDown: false) == [up(Keysym.controlLeft)])
    }

    @Test func capsLockIsNeverForwarded() {
        var keyboard = keyboard(.keystrokes)
        #expect(keyboard.capsLockChanged(isOn: true).isEmpty)
    }
}

@Suite("Keys pressed for the user")
struct SyntheticKeysTests {
    private func mac(
        _ character: Character, _ modifiers: KeyModifiers, takesKeyCodes: Bool = true
    ) -> (press: [KeyTransition], release: [KeyTransition]) {
        SyntheticKeys.combination(
            keysym: keysym(character), modifiers: modifiers,
            remoteIsMac: true, takesKeyCodes: takesKeyCodes, convention: .apple)
    }

    @Test func aCommandShortcutHoldsCommandAroundTheKey() {
        let combination = mac("c", .command)
        #expect(combination.press == [down(Keysym.superLeft), down(keysym("c"))])
        #expect(combination.release == [up(keysym("c")), up(Keysym.superLeft)])
    }

    /// A Mac sent Shift and `a` cancels Shift and types `a`.
    @Test func shiftWithALetterSendsTheCapital() {
        #expect(mac("a", .shift).press == [down(Keysym.shiftLeft), down(keysym("A"))])
        #expect(mac("ş", .shift).press == [down(Keysym.shiftLeft), down(keysym("Ş"))])
    }

    @Test func commandShortcutsKeepTheirDigits() {
        #expect(mac("3", [.command, .shift]).press == [
            down(Keysym.shiftLeft), down(Keysym.superLeft), down(keysym("3")),
        ])
    }

    /// A Mac sent Option and `z` cancels Option. The key goes by position
    /// instead, and the remote layout turns it into whatever Option-Z types.
    @Test func optionSendsTheKeyByPosition() {
        let combination = mac("z", .option)
        #expect(combination.press == [down(Keysym.metaLeft, code: 58), down(keysym("z"), code: 6)])
        #expect(combination.release == [up(keysym("z"), code: 6), up(Keysym.metaLeft, code: 58)])
    }

    @Test func aKeyThatNeedsShiftGetsIt() {
        #expect(mac("@", .option).press == [
            down(Keysym.metaLeft, code: 58), down(Keysym.shiftLeft, code: 56), down(keysym("@"), code: 19),
        ])
    }

    @Test func optionFallsBackToTheCharacterWithoutKeyCodes() {
        #expect(mac("z", .option, takesKeyCodes: false).press == [down(Keysym.metaLeft), down(keysym("z"))])
    }

    @Test func keysThatTypeNothingAreSentAsTheyAre() {
        let combination = SyntheticKeys.combination(
            keysym: Keysym.left, modifiers: .option,
            remoteIsMac: true, takesKeyCodes: true, convention: .apple)
        #expect(combination.press == [down(Keysym.metaLeft), down(Keysym.left)])
    }

    @Test func aPCGetsTheModifiersItWasPromised() {
        let combination = SyntheticKeys.combination(
            keysym: Keysym.delete, modifiers: [.control, .option],
            remoteIsMac: false, takesKeyCodes: false, convention: .standard)
        #expect(combination.press == [down(Keysym.controlLeft), down(Keysym.altLeft), down(Keysym.delete)])
        #expect(combination.release == [up(Keysym.delete), up(Keysym.altLeft), up(Keysym.controlLeft)])
    }
}

@Suite("Text as keysyms")
struct KeysymTextTests {
    @Test func aLetterAndItsAccentBecomeOneKey() {
        #expect(Keysym.keysyms(for: "e\u{301}") == [0xE9])
    }

    @Test func charactersOutsideLatin1UseTheUnicodeRange() {
        #expect(Keysym.keysyms(for: "ş日") == [0x0100_015F, 0x0100_65E5])
    }

    @Test func lineBreaksAndTabsAreKeys() {
        #expect(Keysym.keysyms(for: "a\n\tb") == [0x61, Keysym.returnKey, Keysym.tab, 0x62])
    }

    @Test func charactersThatCannotBeTypedAreDropped() {
        #expect(Keysym.keysyms(for: "a\u{0}b") == [0x61, 0x62])
    }
}

@Suite("Modifier keys")
struct ModifierKeyTests {
    @Test func everyKeyRoundTripsThroughItsKeyCode() {
        for key in ModifierKey.allCases {
            #expect(ModifierKey(macKeyCode: key.macKeyCode) == key)
        }
        #expect(ModifierKey(macKeyCode: 0) == nil)
    }

    @Test func hidUsagesMapToTheSameKeysAsTheirKeyCodes() {
        for usage in 0xE0...0xE7 {
            let key = ModifierKey(hidUsage: usage)
            #expect(key != nil)
            #expect(key?.macKeyCode == KeyCodes.macKeyCode(forHIDUsage: usage))
        }
        #expect(ModifierKey(hidUsage: 0x04) == nil)
    }
}

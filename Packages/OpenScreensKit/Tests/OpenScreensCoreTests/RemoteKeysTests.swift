import Foundation
import Testing
@testable import OpenScreensCore

@Suite("Keysym")
struct KeysymTests {

    @Test func keysHaveTheirX11Values() {
        // The protocol fixes these numbers; a typo here types the wrong key.
        let expected: [(UInt32, UInt32)] = [
            (Keysym.backspace, 0xFF08), (Keysym.tab, 0xFF09), (Keysym.returnKey, 0xFF0D),
            (Keysym.pause, 0xFF13), (Keysym.scrollLock, 0xFF14), (Keysym.escape, 0xFF1B),
            (Keysym.home, 0xFF50), (Keysym.left, 0xFF51), (Keysym.up, 0xFF52),
            (Keysym.right, 0xFF53), (Keysym.down, 0xFF54), (Keysym.pageUp, 0xFF55),
            (Keysym.pageDown, 0xFF56), (Keysym.end, 0xFF57), (Keysym.printScreen, 0xFF61),
            (Keysym.insert, 0xFF63), (Keysym.menu, 0xFF67), (Keysym.numLock, 0xFF7F),
            (Keysym.keypadEnter, 0xFF8D), (Keysym.f1, 0xFFBE),
            (Keysym.shiftLeft, 0xFFE1), (Keysym.shiftRight, 0xFFE2),
            (Keysym.controlLeft, 0xFFE3), (Keysym.controlRight, 0xFFE4),
            (Keysym.capsLock, 0xFFE5), (Keysym.metaLeft, 0xFFE7), (Keysym.metaRight, 0xFFE8),
            (Keysym.altLeft, 0xFFE9), (Keysym.altRight, 0xFFEA),
            (Keysym.superLeft, 0xFFEB), (Keysym.superRight, 0xFFEC),
            (Keysym.delete, 0xFFFF), (Keysym.space, 0x0020),
        ]
        for (actual, value) in expected {
            #expect(actual == value)
        }
    }

    @Test func printableASCIIAndLatin1TypeThemselves() throws {
        for value in Array(UInt32(0x20)...0x7E) + Array(UInt32(0xA0)...0xFF) {
            let character = Character(try #require(Unicode.Scalar(value)))
            #expect(Keysym.character(character) == value)
        }
        #expect(Keysym.character("a") == 0x61)
        #expect(Keysym.character("A") == 0x41)
        #expect(Keysym.character(" ") == Keysym.space)
        #expect(Keysym.character("\u{E9}") == 0xE9)
    }

    @Test func otherCharactersUseTheUnicodeRange() {
        #expect(Keysym.character("\u{100}") == 0x0100_0100)
        #expect(Keysym.character("€") == 0x0100_20AC)
        #expect(Keysym.character("あ") == 0x0100_3042)
        #expect(Keysym.character("😀") == 0x0101_F600)
        // A character built from several code points is typed by its first.
        #expect(Keysym.character("e\u{301}") == 0x65)
    }

    @Test func controlCharactersBecomeTheKeysThatProduceThem() {
        #expect(Keysym.character("\u{8}") == Keysym.backspace)
        #expect(Keysym.character("\t") == Keysym.tab)
        #expect(Keysym.character("\n") == Keysym.returnKey)
        #expect(Keysym.character("\r") == Keysym.returnKey)
        #expect(Keysym.character("\r\n") == Keysym.returnKey)
        #expect(Keysym.character("\u{1B}") == Keysym.escape)
        #expect(Keysym.character("\u{7F}") == Keysym.delete)
    }

    @Test func charactersThatCannotBeTypedHaveNoKeysym() {
        for scalar in ["\u{0}", "\u{7}", "\u{B}", "\u{1F}", "\u{80}", "\u{9F}"] as [Character] {
            #expect(Keysym.character(scalar) == 0)
        }
    }

    @Test func functionKeysRunFromF1ToF24() {
        #expect(Keysym.function(1) == 0xFFBE)
        #expect(Keysym.function(12) == 0xFFC9)
        #expect(Keysym.function(24) == 0xFFD5)
        #expect((1...24).map(Keysym.function) == Array(UInt32(0xFFBE)...0xFFD5))
        for number in [0, -1, 25, 100] {
            #expect(Keysym.function(number) == 0)
        }
    }

    @Test func modifiersAreRecognised() {
        let modifiers = [
            Keysym.shiftLeft, Keysym.shiftRight, Keysym.controlLeft, Keysym.controlRight,
            Keysym.metaLeft, Keysym.metaRight, Keysym.altLeft, Keysym.altRight,
            Keysym.superLeft, Keysym.superRight, Keysym.capsLock,
        ]
        for keysym in modifiers {
            #expect(Keysym.isModifier(keysym))
        }
        let others = [
            Keysym.returnKey, Keysym.space, Keysym.escape, Keysym.delete, Keysym.function(1),
            Keysym.character("a"), 0,
        ]
        for keysym in others {
            #expect(!Keysym.isModifier(keysym))
        }
    }
}

@Suite("Modifier keys")
struct ModifierTests {

    private let everyModifier: KeyModifiers = [.control, .option, .shift, .command]

    /// Every combination of the two switches, including the one no session
    /// uses, so the two ways of producing modifiers can be held to agree.
    private let conventions = [
        ModifierConvention.apple,
        ModifierConvention.standard,
        ModifierConvention(optionIsMeta: false, swapsCommandAndControl: true),
        ModifierConvention(optionIsMeta: true, swapsCommandAndControl: true),
    ]

    @Test func modifiersAreWrittenInTheConventionalOrder() {
        #expect(everyModifier.symbols == "⌃⌥⇧⌘")
        #expect(KeyModifiers([.command, .shift]).symbols == "⇧⌘")
        #expect(KeyModifiers.option.symbols == "⌥")
        #expect(KeyModifiers().symbols == "")
        #expect(KeyModifiers.displayOrder == [.control, .option, .shift, .command])
        #expect(KeyModifiers.displayOrder.map(\.symbols).joined() == everyModifier.symbols)
    }

    @Test func modifiersAreNamedAfterTheRemoteKeyboard() {
        let titles: [(ComputerKind, [String])] = [
            (.mac, ["Control", "Option", "Shift", "Command"]),
            (.windows, ["Control", "Alt", "Shift", "Windows"]),
            (.linux, ["Control", "Alt", "Shift", "Super"]),
            (.raspberryPi, ["Control", "Alt", "Shift", "Super"]),
            (.other, ["Control", "Alt", "Shift", "Super"]),
        ]
        for (kind, expected) in titles {
            #expect(KeyModifiers.displayOrder.map { everyModifier.title(of: $0, on: kind) } == expected)
        }
        // Only single modifiers have a name.
        #expect(everyModifier.title(of: [.control, .shift], on: .mac) == "")
    }

    @Test func modifiersSurviveEncoding() throws {
        for modifiers in [KeyModifiers(), .shift, [.control, .command], everyModifier] {
            let data = try JSONEncoder().encode([modifiers])
            #expect(try JSONDecoder().decode([KeyModifiers].self, from: data) == [modifiers])
        }
    }

    @Test func appleServersTakeOptionAsMeta() {
        #expect(ModifierConvention.apple.keysyms(for: everyModifier)
            == [Keysym.controlLeft, Keysym.metaLeft, Keysym.shiftLeft, Keysym.superLeft])
    }

    @Test func otherServersTakeOptionAsAlt() {
        #expect(ModifierConvention.standard.keysyms(for: everyModifier)
            == [Keysym.controlLeft, Keysym.altLeft, Keysym.shiftLeft, Keysym.superLeft])
    }

    @Test func swappingSendsCommandAsControlAndControlAsSuper() {
        let swapped = ModifierConvention(optionIsMeta: false, swapsCommandAndControl: true)
        #expect(swapped.keysyms(for: everyModifier)
            == [Keysym.superLeft, Keysym.altLeft, Keysym.shiftLeft, Keysym.controlLeft])
        // ⌘C on the Mac keyboard arrives as Ctrl+C.
        #expect(swapped.keysyms(for: .command) == [Keysym.controlLeft])
        #expect(swapped.keysyms(for: .control) == [Keysym.superLeft])
    }

    @Test func onlyTheRequestedModifiersArePressedInDisplayOrder() {
        for convention in conventions {
            #expect(convention.keysyms(for: []).isEmpty)
            #expect(convention.keysyms(for: [.shift]) == [Keysym.shiftLeft])
            let all = convention.keysyms(for: everyModifier)
            #expect(all.count == 4)
            #expect(Set(all).count == 4)
            #expect(all.allSatisfy(Keysym.isModifier))
            #expect(convention.keysyms(for: [.command, .control]) == [all[0], all[3]])
            #expect(convention.keysyms(for: [.shift, .option]) == [all[1], all[2]])
        }
    }

    @Test func physicalModifierKeysAreRewrittenForAppleServers() {
        let apple = ModifierConvention.apple
        #expect(apple.translate(modifierKeysym: Keysym.altLeft) == Keysym.metaLeft)
        #expect(apple.translate(modifierKeysym: Keysym.altRight) == Keysym.metaRight)
        for untouched in [
            Keysym.metaLeft, Keysym.metaRight, Keysym.controlLeft, Keysym.controlRight,
            Keysym.superLeft, Keysym.superRight, Keysym.shiftLeft, Keysym.shiftRight,
            Keysym.capsLock,
        ] {
            #expect(apple.translate(modifierKeysym: untouched) == untouched)
        }
    }

    @Test func physicalModifierKeysAreRewrittenForOtherServers() {
        let standard = ModifierConvention.standard
        #expect(standard.translate(modifierKeysym: Keysym.metaLeft) == Keysym.altLeft)
        #expect(standard.translate(modifierKeysym: Keysym.metaRight) == Keysym.altRight)
        for untouched in [
            Keysym.altLeft, Keysym.altRight, Keysym.controlLeft, Keysym.controlRight,
            Keysym.superLeft, Keysym.superRight, Keysym.shiftLeft, Keysym.shiftRight,
        ] {
            #expect(standard.translate(modifierKeysym: untouched) == untouched)
        }

        let swapped = ModifierConvention(optionIsMeta: false, swapsCommandAndControl: true)
        #expect(swapped.translate(modifierKeysym: Keysym.superLeft) == Keysym.controlLeft)
        #expect(swapped.translate(modifierKeysym: Keysym.superRight) == Keysym.controlRight)
        #expect(swapped.translate(modifierKeysym: Keysym.controlLeft) == Keysym.superLeft)
        #expect(swapped.translate(modifierKeysym: Keysym.controlRight) == Keysym.superRight)
        #expect(swapped.translate(modifierKeysym: Keysym.altLeft) == Keysym.altLeft)
        #expect(swapped.translate(modifierKeysym: Keysym.shiftRight) == Keysym.shiftRight)
    }

    @Test func keysThatAreNotModifiersAreNeverRewritten() {
        for convention in conventions {
            for keysym in [Keysym.returnKey, Keysym.space, Keysym.character("c"), Keysym.function(4), 0] {
                #expect(convention.translate(modifierKeysym: keysym) == keysym)
            }
        }
    }

    @Test func aHeldModifierKeyAndAShortcutSendTheSameKeysym() throws {
        // Holding ⌘ on a hardware keyboard goes through `translate`; a
        // shortcut or a latched modifier goes through `keysyms(for:)`. The
        // remote computer has to see the same key either way.
        let physicalKeys: [(KeyModifiers, UInt16)] = [
            (.control, 59), (.option, 58), (.shift, 56), (.command, 55),
        ]
        for convention in conventions {
            for (modifier, keyCode) in physicalKeys {
                let pressed = try #require(KeyCodes.modifierKeysym(forMacKeyCode: keyCode))
                #expect(convention.translate(modifierKeysym: pressed)
                    == convention.keysyms(for: modifier).first)
            }
        }
    }

    @Test func leftAndRightStayLeftAndRight() throws {
        let pairs: [(UInt16, UInt16)] = [(59, 62), (58, 61), (56, 60), (55, 54)]
        for convention in conventions {
            for (left, right) in pairs {
                let leftKey = convention.translate(
                    modifierKeysym: try #require(KeyCodes.modifierKeysym(forMacKeyCode: left)))
                let rightKey = convention.translate(
                    modifierKeysym: try #require(KeyCodes.modifierKeysym(forMacKeyCode: right)))
                // X11 numbers each right-hand modifier one above its left.
                #expect(rightKey == leftKey + 1)
            }
        }
    }
}

@Suite("Remote keys and shortcuts")
struct RemoteShortcutTests {

    @Test func everySpecialKeyHasItsOwnKeysymAndLabels() {
        let keys = SpecialKey.allCases
        #expect(keys.allSatisfy { $0.keysym != 0 })
        #expect(Set(keys.map(\.keysym)).count == keys.count)
        #expect(keys.allSatisfy { !$0.title.isEmpty && !$0.glyph.isEmpty })
        #expect(Set(keys.map(\.title)).count == keys.count)
        #expect(Set(keys.map(\.glyph)).count == keys.count)
    }

    @Test func deleteMeansBackspaceAndForwardDeleteMeansDelete() {
        // Named as on a Mac keyboard, where ⌫ is "Delete".
        #expect(SpecialKey.delete.keysym == Keysym.backspace)
        #expect(SpecialKey.forwardDelete.keysym == Keysym.delete)
        #expect(SpecialKey.returnKey.keysym == Keysym.returnKey)
        #expect(SpecialKey.space.keysym == Keysym.space)
    }

    @Test func keysThatMoveOrTypeRepeatWhileHeld() {
        let repeating: Set<SpecialKey> = [
            .left, .right, .up, .down, .pageUp, .pageDown, .tab, .returnKey,
            .delete, .forwardDelete, .space,
        ]
        for key in SpecialKey.allCases {
            #expect(key.repeatsWhenHeld == repeating.contains(key))
        }
    }

    @Test func aCharacterKeyIsTheUnshiftedLetter() {
        // Shift is a modifier of its own; the key is the same either way.
        #expect(RemoteKey.character("q").keysym == 0x71)
        #expect(RemoteKey.character("Q").keysym == 0x71)
        #expect(RemoteKey.character("5").keysym == 0x35)
        #expect(RemoteKey.character("q").glyph == "Q")
        #expect(RemoteKey.character("q").title == "Q")
        #expect(RemoteKey.character("").keysym == 0)
    }

    @Test func specialAndFunctionKeysUseTheirOwnKeysyms() {
        #expect(RemoteKey.special(.escape).keysym == Keysym.escape)
        #expect(RemoteKey.special(.escape).glyph == "⎋")
        #expect(RemoteKey.special(.escape).title == "Escape")
        #expect(RemoteKey.function(5).keysym == Keysym.function(5))
        #expect(RemoteKey.function(5).glyph == "F5")
        #expect(RemoteKey.function(5).title == "F5")
        #expect(RemoteKey.function(0).keysym == 0)
        #expect(RemoteKey.function(25).keysym == 0)
    }

    @Test func aShortcutIsWrittenTheMacWay() {
        let lock = RemoteShortcut(name: "Lock", modifiers: [.command, .control], key: .character("q"))
        #expect(lock.keyString == "⌃⌘Q")
        #expect(RemoteShortcut(name: "", modifiers: [.option, .command], key: .special(.escape))
            .keyString == "⌥⌘⎋")
        #expect(RemoteShortcut(name: "", modifiers: [.shift, .command], key: .character("5")).keyString == "⇧⌘5")
        #expect(RemoteShortcut(name: "", key: .function(11)).keyString == "F11")
        #expect(RemoteShortcut(name: "", modifiers: [.command], key: .special(.space)).keyString == "⌘␣")
    }

    @Test func aShortcutIsWrittenThePCWay() {
        let ctrlAltDel = RemoteShortcut(
            name: "", modifiers: [.control, .option], key: .special(.forwardDelete))
        #expect(ctrlAltDel.pcKeyString(for: .windows) == "Ctrl+Alt+Del")
        #expect(ctrlAltDel.pcKeyString(for: .linux) == "Ctrl+Alt+Del")

        let lock = RemoteShortcut(name: "", modifiers: [.command], key: .character("l"))
        #expect(lock.pcKeyString(for: .windows) == "Win+L")
        #expect(lock.pcKeyString(for: .linux) == "Super+L")
        #expect(lock.pcKeyString(for: .raspberryPi) == "Super+L")

        #expect(RemoteShortcut(name: "", modifiers: [.control, .shift], key: .special(.escape))
            .pcKeyString(for: .windows) == "Ctrl+Shift+Esc")
        #expect(RemoteShortcut(name: "", modifiers: [.option], key: .function(4))
            .pcKeyString(for: .windows) == "Alt+F4")
        #expect(RemoteShortcut(name: "", modifiers: [.option], key: .special(.tab))
            .pcKeyString(for: .windows) == "Alt+Tab")
        #expect(RemoteShortcut(name: "", key: .special(.printScreen))
            .pcKeyString(for: .windows) == "Print Screen")
        #expect(RemoteShortcut(
            name: "", modifiers: [.control, .option, .shift, .command], key: .character("k"))
            .pcKeyString(for: .windows) == "Ctrl+Alt+Shift+Win+K")
    }

    @Test func aShortcutIsDisplayedInTheRemoteComputersTerms() {
        let shortcut = RemoteShortcut(name: "", modifiers: [.command], key: .character("l"))
        #expect(shortcut.displayString(for: .mac) == "⌘L")
        #expect(shortcut.displayString(for: .windows) == "Win+L")
        #expect(shortcut.displayString(for: .linux) == "Super+L")
        #expect(shortcut.displayString(for: .other) == "Super+L")
    }

    @Test func shortcutsSurviveEncoding() throws {
        let shortcuts = [
            RemoteShortcut(name: "Lock", modifiers: [.control, .command], key: .character("q"), symbolName: "lock"),
            RemoteShortcut(name: "Escape", key: .special(.escape)),
            RemoteShortcut(name: "Console", modifiers: [.control, .option], key: .function(7)),
        ]
        let data = try JSONEncoder().encode(shortcuts)
        #expect(try JSONDecoder().decode([RemoteShortcut].self, from: data) == shortcuts)
    }

    // MARK: Built-in catalogs

    @Test func everyKindOfComputerHasBuiltInShortcuts() {
        for kind in ComputerKind.allCases {
            #expect(!RemoteShortcut.builtIn(for: kind).isEmpty)
        }
        #expect(RemoteShortcut.builtIn(for: .mac) != RemoteShortcut.builtIn(for: .windows))
        #expect(RemoteShortcut.builtIn(for: .windows) != RemoteShortcut.builtIn(for: .linux))
        // Everything that is neither a Mac nor Windows is treated as Linux.
        #expect(RemoteShortcut.builtIn(for: .raspberryPi) == RemoteShortcut.builtIn(for: .linux))
        #expect(RemoteShortcut.builtIn(for: .other) == RemoteShortcut.builtIn(for: .linux))
    }

    @Test func builtInShortcutsHaveUniqueStableIdentifiers() {
        let catalogs = [ComputerKind.mac, .windows, .linux].map(RemoteShortcut.builtIn(for:))
        let all = catalogs.flatMap { $0 }

        // Unique across every catalog, so one can never be mistaken for another…
        #expect(Set(all.map(\.id)).count == all.count)
        // …and fixed, not minted at launch: a random identifier would not
        // carry the reserved prefix.
        #expect(all.allSatisfy { $0.id.uuidString.hasPrefix("0F5C0000-0000-4000-8000-0000000") })
        #expect(catalogs[0].first?.id == UUID(uuidString: "0F5C0000-0000-4000-8000-000000000101"))
        #expect(catalogs[1].first?.id == UUID(uuidString: "0F5C0000-0000-4000-8000-000000000201"))
        #expect(catalogs[2].first?.id == UUID(uuidString: "0F5C0000-0000-4000-8000-000000000301"))
        #expect(catalogs[0].last?.id == UUID(uuidString: "0F5C0000-0000-4000-8000-00000000010F"))
        // Asking again gives the very same shortcuts.
        #expect([ComputerKind.mac, .windows, .linux].map(RemoteShortcut.builtIn(for:)) == catalogs)
    }

    @Test func builtInShortcutsCanAllBeSentAndToldApart() {
        for kind in [ComputerKind.mac, .windows, .linux] {
            let catalog = RemoteShortcut.builtIn(for: kind)
            for shortcut in catalog {
                #expect(shortcut.key.keysym != 0, "\(shortcut.name)")
                #expect(!shortcut.name.isEmpty)
                #expect(!shortcut.symbolName.isEmpty, "\(shortcut.name)")
                #expect(!shortcut.displayString(for: kind).isEmpty, "\(shortcut.name)")
            }
            #expect(Set(catalog.map(\.name)).count == catalog.count)
            // No two entries send the same combination.
            #expect(Set(catalog.map(\.keyString)).count == catalog.count)
        }
    }

    @Test func shortcutsNamedAfterTheirKeysMatchThoseKeys() throws {
        let windows = RemoteShortcut.builtIn(for: .windows)
        let ctrlAltDel = try #require(windows.first { $0.name == "Ctrl+Alt+Del" })
        #expect(ctrlAltDel.displayString(for: .windows) == "Ctrl+Alt+Del")
        let printScreen = try #require(windows.first { $0.name == "Print Screen" })
        #expect(printScreen.displayString(for: .windows) == "Print Screen")

        let linux = RemoteShortcut.builtIn(for: .linux)
        #expect(try #require(linux.first { $0.name == "Ctrl+Alt+Del" }).displayString(for: .linux) == "Ctrl+Alt+Del")
    }

    @Test func builtInPCShortcutsAreLiteralPCKeyCombinations() throws {
        // The PC catalogs are written in PC terms — `.control` is the Ctrl
        // key, `.command` the Windows key, exactly as `pcKeyString` labels
        // them. Sent without swapping ⌘ and ⌃, they press the keys their
        // labels name.
        let windows = RemoteShortcut.builtIn(for: .windows)
        let literal = ModifierConvention.standard

        let ctrlAltDel = try #require(windows.first { $0.name == "Ctrl+Alt+Del" })
        #expect(literal.keysyms(for: ctrlAltDel.modifiers) == [Keysym.controlLeft, Keysym.altLeft])
        #expect(ctrlAltDel.key.keysym == Keysym.delete)

        let lock = try #require(windows.first { $0.name == "Lock" })
        #expect(literal.keysyms(for: lock.modifiers) == [Keysym.superLeft])
        #expect(lock.key.keysym == Keysym.character("l"))

        let taskManager = try #require(windows.first { $0.name == "Task Manager" })
        #expect(literal.keysyms(for: taskManager.modifiers) == [Keysym.controlLeft, Keysym.shiftLeft])
        #expect(taskManager.key.keysym == Keysym.escape)
    }

    @Test func builtInMacShortcutsPressTheKeysAMacExpects() throws {
        let mac = RemoteShortcut.builtIn(for: .mac)

        let spotlight = try #require(mac.first { $0.name == "Spotlight" })
        #expect(spotlight.keyString == "⌘␣")
        #expect(ModifierConvention.apple.keysyms(for: spotlight.modifiers) == [Keysym.superLeft])
        #expect(spotlight.key.keysym == Keysym.space)

        let forceQuit = try #require(mac.first { $0.name == "Force Quit" })
        #expect(forceQuit.keyString == "⌥⌘⎋")
        #expect(ModifierConvention.apple.keysyms(for: forceQuit.modifiers)
            == [Keysym.metaLeft, Keysym.superLeft])
        #expect(forceQuit.key.keysym == Keysym.escape)
    }

    /// The Mac's Delete key sends BackSpace. A PC keyboard calls that key
    /// Backspace, and means the forward delete key by "Delete".
    @Test func theMacDeleteKeyIsCalledBackspaceOnAPC() {
        let shortcut = RemoteShortcut(
            name: "Delete word", modifiers: [.control], key: .special(.delete))
        #expect(shortcut.key.keysym == Keysym.backspace)

        #expect(shortcut.pcKeyString(for: .windows) == "Ctrl+Backspace")
        #expect(shortcut.displayString(for: .linux) == "Ctrl+Backspace")
    }
}

@Suite("KeyCodes")
struct KeyCodesTests {

    /// macOS virtual key codes of F1…F20, in order.
    private let macFunctionKeys: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    @Test func macNavigationAndEditingKeysAreRecognisedByPosition() {
        let expected: [(UInt16, UInt32)] = [
            (36, Keysym.returnKey), (48, Keysym.tab), (51, Keysym.backspace), (53, Keysym.escape),
            (71, 0xFF0B), (76, Keysym.keypadEnter), (114, Keysym.insert), (115, Keysym.home),
            (116, Keysym.pageUp), (117, Keysym.delete), (119, Keysym.end), (121, Keysym.pageDown),
            (123, Keysym.left), (124, Keysym.right), (125, Keysym.down), (126, Keysym.up),
        ]
        for (keyCode, keysym) in expected {
            #expect(KeyCodes.keysym(forMacKeyCode: keyCode) == keysym, "key code \(keyCode)")
        }
    }

    @Test func macFunctionKeysAreRecognisedByPosition() {
        for (index, keyCode) in macFunctionKeys.enumerated() {
            #expect(KeyCodes.keysym(forMacKeyCode: keyCode) == Keysym.function(index + 1), "F\(index + 1)")
        }
    }

    @Test func macKeysThatTypeSomethingAreLeftToTheirCharacters() {
        // A, S, 1, space, grave, keypad 0, and a code no keyboard sends.
        for keyCode in [0, 1, 18, 49, 50, 82, 127] as [UInt16] {
            #expect(KeyCodes.keysym(forMacKeyCode: keyCode) == nil, "key code \(keyCode)")
        }
    }

    @Test func macModifierKeysAreRecognisedLeftAndRight() {
        let expected: [(UInt16, UInt32)] = [
            (56, Keysym.shiftLeft), (60, Keysym.shiftRight),
            (59, Keysym.controlLeft), (62, Keysym.controlRight),
            (58, Keysym.altLeft), (61, Keysym.altRight),
            (55, Keysym.superLeft), (54, Keysym.superRight),
            (57, Keysym.capsLock),
        ]
        for (keyCode, keysym) in expected {
            #expect(KeyCodes.modifierKeysym(forMacKeyCode: keyCode) == keysym, "key code \(keyCode)")
            #expect(Keysym.isModifier(keysym))
            // A modifier is not also reported as an ordinary key.
            #expect(KeyCodes.keysym(forMacKeyCode: keyCode) == nil, "key code \(keyCode)")
        }
        for keyCode in [0, 36, 49, 122] as [UInt16] {
            #expect(KeyCodes.modifierKeysym(forMacKeyCode: keyCode) == nil)
        }
    }

    @Test func hidNavigationAndEditingKeysAreRecognised() {
        let expected: [(Int, UInt32)] = [
            (0x28, Keysym.returnKey), (0x29, Keysym.escape), (0x2A, Keysym.backspace),
            (0x2B, Keysym.tab), (0x39, Keysym.capsLock), (0x46, Keysym.printScreen),
            (0x47, Keysym.scrollLock), (0x48, Keysym.pause), (0x49, Keysym.insert),
            (0x4A, Keysym.home), (0x4B, Keysym.pageUp), (0x4C, Keysym.delete),
            (0x4D, Keysym.end), (0x4E, Keysym.pageDown), (0x4F, Keysym.right),
            (0x50, Keysym.left), (0x51, Keysym.down), (0x52, Keysym.up),
            (0x53, Keysym.numLock), (0x58, Keysym.keypadEnter), (0x65, Keysym.menu),
        ]
        for (usage, keysym) in expected {
            #expect(KeyCodes.keysym(forHIDUsage: usage) == keysym, "usage \(usage)")
        }
    }

    @Test func hidFunctionKeysCoverBothBlocks() {
        // F1…F12 and F13…F24 sit in two separate runs of usages.
        #expect((0x3A...0x45).compactMap(KeyCodes.keysym(forHIDUsage:)) == (1...12).map(Keysym.function))
        #expect((0x68...0x73).compactMap(KeyCodes.keysym(forHIDUsage:)) == (13...24).map(Keysym.function))
    }

    @Test func hidModifiersAreTheEightModifierKeys() {
        let expected: [(Int, UInt32)] = [
            (0xE0, Keysym.controlLeft), (0xE1, Keysym.shiftLeft),
            (0xE2, Keysym.altLeft), (0xE3, Keysym.superLeft),
            (0xE4, Keysym.controlRight), (0xE5, Keysym.shiftRight),
            (0xE6, Keysym.altRight), (0xE7, Keysym.superRight),
        ]
        for (usage, keysym) in expected {
            #expect(KeyCodes.keysym(forHIDUsage: usage) == keysym, "usage \(usage)")
            #expect(KeyCodes.isModifier(hidUsage: usage))
        }
        for usage in [0xDF, 0xE8, 0x39, 0x28, 0, -1] {
            #expect(!KeyCodes.isModifier(hidUsage: usage))
        }
    }

    @Test func hidKeysThatTypeSomethingAreLeftToTheirCharacters() {
        // A, 1, space, keypad 1, and values outside the table.
        for usage in [0x04, 0x1E, 0x2C, 0x59, 0x74, 0xE8, 0, -1, 10_000] {
            #expect(KeyCodes.keysym(forHIDUsage: usage) == nil, "usage \(usage)")
        }
    }

    @Test func noKeyInEitherTableMapsToNothingOrToAnotherKeysKeysym() {
        let mac = (UInt16(0)..<256).compactMap(KeyCodes.keysym(forMacKeyCode:))
        #expect(mac.count == 36)
        #expect(!mac.contains(0))
        #expect(Set(mac).count == mac.count)

        let macModifiers = (UInt16(0)..<256).compactMap(KeyCodes.modifierKeysym(forMacKeyCode:))
        #expect(macModifiers.count == 9)
        #expect(Set(macModifiers).count == macModifiers.count)

        let hid = (0..<0x100).compactMap(KeyCodes.keysym(forHIDUsage:))
        #expect(hid.count == 53)
        #expect(!hid.contains(0))
        #expect(Set(hid).count == hid.count)
    }

    @Test func aMacKeyboardAndAnExternalKeyboardSendTheSameKeysyms() {
        // The same physical key, as AppKit and as UIKit report it.
        var samePhysicalKey: [(mac: UInt16, hid: Int)] = [
            (36, 0x28), (48, 0x2B), (51, 0x2A), (53, 0x29), (76, 0x58), (114, 0x49),
            (115, 0x4A), (116, 0x4B), (117, 0x4C), (119, 0x4D), (121, 0x4E),
            (123, 0x50), (124, 0x4F), (125, 0x51), (126, 0x52),
        ]
        for (index, keyCode) in macFunctionKeys.enumerated() {
            samePhysicalKey.append((keyCode, index < 12 ? 0x3A + index : 0x68 + index - 12))
        }
        for key in samePhysicalKey {
            #expect(KeyCodes.keysym(forMacKeyCode: key.mac) == KeyCodes.keysym(forHIDUsage: key.hid),
                    "key code \(key.mac)")
        }

        let sameModifier: [(mac: UInt16, hid: Int)] = [
            (59, 0xE0), (56, 0xE1), (58, 0xE2), (55, 0xE3),
            (62, 0xE4), (60, 0xE5), (61, 0xE6), (54, 0xE7), (57, 0x39),
        ]
        for key in sameModifier {
            #expect(KeyCodes.modifierKeysym(forMacKeyCode: key.mac) == KeyCodes.keysym(forHIDUsage: key.hid),
                    "key code \(key.mac)")
        }
    }
}

#if os(iOS)
import OpenScreensCore
import QuartzCore
import SwiftUI
import UIKit

/// The lower half of a foldable stood up half open, made into the lower half
/// of a MacBook: a keyboard laid out the way a Mac's is, and a trackpad
/// under it.
///
/// Away from the fold the whole screen is the trackpad and a second one only
/// takes room from the picture, which is why ``ControlDeck`` has none. Half
/// open is different. The picture has already stopped above the crease, the
/// half lying on the table has nothing of the desktop on it, and a hand
/// resting there is where a laptop puts its keyboard and trackpad.
struct LaptopDeck: View {
    let session: RemoteSession

    /// What the keys are holding down on the remote computer.
    @State private var input: LaptopKeyboardInput

    init(session: RemoteSession) {
        self.session = session
        _input = State(initialValue: LaptopKeyboardInput(session: session))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Clear of the crease, which is no place for a key: the screen
            // bends there, and a finger reaching for it lands on the other
            // half as often as not.
            let creaseMargin = max(size.height * 0.07, 28)
            // Keys about as tall as they are wide, as on a MacBook, and the
            // keyboard centred when the screen is wider than that.
            let availableWidth = max(size.width - 24, 0)
            let keyboardHeight = min(size.height * 0.5, availableWidth / 2.8)
            let keyboardWidth = min(availableWidth, keyboardHeight * 4)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                    .frame(height: creaseMargin)
                LaptopKeyboard(session: session, input: input)
                    .frame(width: keyboardWidth, height: keyboardHeight)
                // Everything under the keys is the trackpad, from one edge to
                // the other and down to the bottom of the screen, though only
                // the middle of it is drawn as one: a thumb that wanders off
                // the drawn pad should not stop moving the pointer.
                LaptopTrackpad(width: keyboardWidth * 0.5)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        LaptopTrackpadSurface(session: session)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(alignment: .top) {
            LaptopBody()
                .ignoresSafeArea(edges: .bottom)
        }
        .environment(\.colorScheme, .dark)
        // A key held as the deck goes away would stay down on the Mac.
        .onDisappear { input.releaseAll() }
    }
}

// MARK: - The body

/// The aluminium of the lower half, with the lip a lid closes onto.
private struct LaptopBody: View {
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.24), Color(white: 0.17)],
                startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                // The edge catching the light along the hinge.
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - The keyboard

/// One key of the laptop keyboard: what it does and how wide it is.
private struct LaptopKey: Identifiable {
    enum Action {
        case character(String)
        case special(SpecialKey)
        /// fn swaps it for a key of its own, as Delete and the arrows do.
        case layered(SpecialKey, fn: SpecialKey)
        case modifier(ModifierKey)
        case fn
        case capsLock
    }

    enum Legend {
        /// A key with a single label.
        case single(String)
        /// A key with its shifted character over its own, like 1 and !.
        case pair(shifted: String, plain: String)
        /// A key whose label is a symbol, with small text under it.
        case symbol(String, caption: String?)
    }

    let id: String
    let legend: Legend
    let action: Action
    /// How wide the key is, against an ordinary letter key.
    var width: CGFloat = 1
    /// Where a wide key's label sits, as on a Mac.
    var alignment: Alignment = .center

    var repeatsWhenHeld: Bool {
        switch action {
        case .layered: true
        case .character(let character): character != " " || SpecialKey.space.repeatsWhenHeld
        case .special(let key): key.repeatsWhenHeld
        default: false
        }
    }

    static func letter(_ letter: String) -> LaptopKey {
        LaptopKey(id: letter, legend: .single(letter.uppercased()), action: .character(letter))
    }

    static func pair(_ plain: String, _ shifted: String) -> LaptopKey {
        LaptopKey(id: plain, legend: .pair(shifted: shifted, plain: plain), action: .character(plain))
    }

    static func modifier(
        _ id: String, _ modifier: ModifierKey, _ symbol: String, _ name: String,
        width: CGFloat, alignment: Alignment
    ) -> LaptopKey {
        LaptopKey(
            id: id, legend: .symbol(symbol, caption: name), action: .modifier(modifier),
            width: width, alignment: alignment)
    }
}

/// The keyboard's side of a connection: which keys are down, and what the
/// remote computer has been told about them.
///
/// The keys go through the same path a keyboard plugged into the phone does,
/// as presses and releases of keys in their places on a Mac keyboard. A
/// modifier is down on the Mac for exactly as long as a finger is on it, so
/// ⌘ held while C is tapped is ⌘C, and ⌘ held while Tab is tapped and
/// tapped again walks the app switcher, as it does on a MacBook. A key stays
/// down for as long as it is touched, which is what a Mac needs to see to
/// take a combination as one.
///
/// One hand is often busy with the trackpad, so a modifier tapped and let go
/// by itself holds on for the next key, and tapped twice stays on until it is
/// tapped again. Those are the latched modifiers the other key rows share.
@MainActor
@Observable
private final class LaptopKeyboardInput {
    private let session: RemoteSession

    /// Modifier keys a finger is on.
    private(set) var heldModifiers: Set<ModifierKey> = []
    /// Whether a finger is on fn.
    private(set) var fnIsHeld = false
    /// Whether fn was tapped by itself, and so holds on for the next key.
    private(set) var fnIsLatched = false
    private(set) var capsLockIsOn = false

    /// When each held modifier went down, and whether a key has been pressed
    /// with it since. A modifier let go soon and unused was a tap.
    @ObservationIgnored private var modifierPresses: [ModifierKey: (start: Date, used: Bool)] = [:]
    @ObservationIgnored private var fnPress: (start: Date, used: Bool)?
    /// The latched modifiers pressed for a key, to let go of with it.
    @ObservationIgnored private var latchedForKey: [Int: [ModifierKey]] = [:]
    @ObservationIgnored private var lastTap: (key: ModifierKey, time: Date)?

    /// Held for longer than this, a modifier was being held for something,
    /// a ⌘-click on the trackpad perhaps, and not tapped.
    private static let longestTap: TimeInterval = 0.35

    init(session: RemoteSession) {
        self.session = session
    }

    /// Whether the fn layer is in force.
    var fnIsOn: Bool { fnIsHeld || fnIsLatched }

    var modifiersAreLocked: Bool { session.modifiersAreLocked }

    /// Whether a modifier key is to be shown as on: held, or latched.
    func isOn(_ key: ModifierKey) -> Bool {
        heldModifiers.contains(key) || session.latchedModifiers.contains(key.modifier)
    }

    // MARK: Modifiers

    func modifierDown(_ key: ModifierKey) {
        guard heldModifiers.insert(key).inserted else { return }
        modifierPresses[key] = (.now, false)
        session.hardwareModifier(key, down: true)
    }

    func modifierUp(_ key: ModifierKey) {
        guard heldModifiers.remove(key) != nil else { return }
        session.hardwareModifier(key, down: false)
        guard let press = modifierPresses.removeValue(forKey: key),
              !press.used, Date.now.timeIntervalSince(press.start) < Self.longestTap else { return }
        tapped(key)
    }

    /// A modifier tapped by itself latches for the next key; tapped again
    /// straight away it locks; tapped once more it lets go.
    private func tapped(_ key: ModifierKey) {
        let modifier = key.modifier
        let now = Date.now
        defer { lastTap = (key, now) }
        if session.latchedModifiers.contains(modifier) {
            if !session.modifiersAreLocked, let lastTap, lastTap.key.modifier == modifier,
               now.timeIntervalSince(lastTap.time) < Self.longestTap {
                session.modifiersAreLocked = true
            } else {
                session.toggleLatched(modifier)
            }
        } else {
            session.toggleLatched(modifier)
        }
    }

    func fnDown() {
        guard !fnIsHeld else { return }
        fnIsHeld = true
        fnPress = (.now, false)
    }

    func fnUp() {
        guard fnIsHeld else { return }
        fnIsHeld = false
        guard let press = fnPress, !press.used,
              Date.now.timeIntervalSince(press.start) < Self.longestTap else { return }
        fnIsLatched.toggle()
    }

    func toggleCapsLock() {
        capsLockIsOn.toggle()
        session.hardwareCapsLock(isOn: capsLockIsOn)
    }

    // MARK: Keys

    /// Presses a key, and says what was pressed, so that holding it repeats
    /// the same key and letting go releases it, whatever has changed since.
    func keyDown(_ key: LaptopKey) -> KeyStroke? {
        let latched = session.latchedModifiers
        let shift = latched.contains(.shift) || heldModifiers.contains { $0.modifier == .shift }
        guard let stroke = Self.stroke(for: key, fn: fnIsOn, shift: shift, capsLock: capsLockIsOn)
        else { return nil }

        for held in heldModifiers {
            modifierPresses[held]?.used = true
        }
        fnPress?.used = true

        // Latched modifiers go down with the key and up with it, unless a
        // finger is already holding one of the same kind.
        let pressedForKey = KeyModifiers.displayOrder
            .filter { modifier in
                latched.contains(modifier) && !heldModifiers.contains { $0.modifier == modifier }
            }
            .map(Self.leftKey(for:))
        for modifier in pressedForKey {
            session.hardwareModifier(modifier, down: true)
        }
        latchedForKey[stroke.key] = pressedForKey
        session.hardwareKeyDown(stroke)

        if !session.modifiersAreLocked {
            if !latched.isEmpty {
                session.latchedModifiers = []
            }
            fnIsLatched = false
        }
        return stroke
    }

    /// The key is still down and repeating.
    func keyRepeat(_ stroke: KeyStroke) {
        session.hardwareKeyDown(stroke)
    }

    func keyUp(_ stroke: KeyStroke) {
        session.hardwareKeyUp(key: stroke.key)
        for modifier in latchedForKey.removeValue(forKey: stroke.key) ?? [] {
            session.hardwareModifier(modifier, down: false)
        }
    }

    // MARK: Touches

    /// The keys a finger is on, for drawing them pressed.
    private(set) var pressedKeys: Set<String> = []
    /// Every key and where it is on the keyboard, to find the one a finger
    /// came down on.
    @ObservationIgnored private var keys: [String: (key: LaptopKey, frame: CGRect)] = [:]
    /// What each pressed key sent, to repeat and release.
    @ObservationIgnored private var strokes: [String: KeyStroke] = [:]
    @ObservationIgnored private var repeats: [String: Task<Void, Never>] = [:]

    var hapticsEnabled: Bool { session.hapticsEnabled }

    func setFrame(_ frame: CGRect, for key: LaptopKey) {
        keys[key.id] = (key, frame)
    }

    /// The key under a finger: the one it landed on, or else the nearest,
    /// for a finger that came down in the gap between two.
    func key(at point: CGPoint) -> String? {
        if let hit = keys.first(where: { $0.value.frame.contains(point) }) {
            return hit.key
        }
        let near = keys.min { distance(from: point, to: $0.value.frame) < distance(from: point, to: $1.value.frame) }
        guard let near, distance(from: point, to: near.value.frame) < 8 else { return nil }
        return near.key
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    /// A finger came down on a key. Says whether that did anything, for the
    /// tap felt under it.
    @discardableResult
    func touchDown(_ id: String) -> Bool {
        guard let key = keys[id]?.key, pressedKeys.insert(id).inserted else { return false }
        switch key.action {
        case .modifier(let modifier):
            modifierDown(modifier)
        case .fn:
            fnDown()
        case .capsLock:
            toggleCapsLock()
        case .character, .special, .layered:
            guard let stroke = keyDown(key) else { return false }
            strokes[id] = stroke
            if key.repeatsWhenHeld {
                repeats[id] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(420))
                    while !Task.isCancelled {
                        self?.keyRepeat(stroke)
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
            }
        }
        return true
    }

    /// The finger on a key came up, or was taken away.
    func touchUp(_ id: String) {
        guard pressedKeys.remove(id) != nil, let key = keys[id]?.key else { return }
        switch key.action {
        case .modifier(let modifier):
            modifierUp(modifier)
        case .fn:
            fnUp()
        case .capsLock:
            break
        case .character, .special, .layered:
            repeats.removeValue(forKey: id)?.cancel()
            if let stroke = strokes.removeValue(forKey: id) {
                keyUp(stroke)
            }
        }
    }

    /// A key pressed and let go at once, for VoiceOver.
    func tap(_ id: String) {
        touchDown(id)
        touchUp(id)
    }

    /// Lets go of everything the keyboard is holding down.
    func releaseAll() {
        for task in repeats.values {
            task.cancel()
        }
        repeats.removeAll()
        for stroke in strokes.values {
            keyUp(stroke)
        }
        strokes.removeAll()
        pressedKeys.removeAll()
        for (key, modifiers) in latchedForKey {
            session.hardwareKeyUp(key: key)
            for modifier in modifiers {
                session.hardwareModifier(modifier, down: false)
            }
        }
        latchedForKey.removeAll()
        for modifier in heldModifiers {
            session.hardwareModifier(modifier, down: false)
        }
        heldModifiers.removeAll()
        modifierPresses.removeAll()
        fnIsHeld = false
        fnPress = nil
    }

    // MARK: Keys and their places

    private static func leftKey(for modifier: KeyModifiers) -> ModifierKey {
        switch modifier {
        case .control: .leftControl
        case .option: .leftOption
        case .shift: .leftShift
        default: .leftCommand
        }
    }

    /// The press of a key, as a keyboard in the US layout would report it.
    static func stroke(for key: LaptopKey, fn: Bool, shift: Bool, capsLock: Bool) -> KeyStroke? {
        switch key.action {
        case .character(let character):
            if fn, let layered = fnLayer[character] {
                return stroke(forUsage: layered)
            }
            guard let usage = characterUsages[character] else { return nil }
            let isLetter = character.first?.isLetter == true
            let text: String = if isLetter {
                shift || capsLock ? character.uppercased() : character
            } else {
                shift ? shiftedCharacters[character] ?? character : character
            }
            return KeyStroke(
                key: usage,
                macKeyCode: KeyCodes.macKeyCode(forHIDUsage: usage),
                text: text,
                textWithoutOption: text,
                shortcutText: character)
        case .special(let special):
            return specialUsages[special].flatMap(stroke(forUsage:))
        case .layered(let special, let layered):
            return specialUsages[fn ? layered : special].flatMap(stroke(forUsage:))
        case .modifier, .fn, .capsLock:
            return nil
        }
    }

    /// A key that types no character: an arrow, Return, a function key.
    private static func stroke(forUsage usage: Int) -> KeyStroke? {
        guard let special = KeyCodes.keysym(forHIDUsage: usage) else { return nil }
        return KeyStroke(key: usage, macKeyCode: KeyCodes.macKeyCode(forHIDUsage: usage), special: special)
    }

    /// What the number row sends with fn down, standing in for the
    /// function row the keyboard leaves out to give the trackpad its room:
    /// Escape, then F1 to F12.
    private static let fnLayer: [String: Int] = {
        var layer: [String: Int] = ["`": 0x29, "-": 0x44, "=": 0x45]
        for (index, digit) in "1234567890".enumerated() {
            layer[String(digit)] = 0x3A + index
        }
        return layer
    }()

    /// Where each character's key is, as a USB keyboard usage.
    private static let characterUsages: [String: Int] = {
        var usages: [String: Int] = [
            "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22,
            "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
            " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31,
            ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
        ]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            usages[String(letter)] = 0x04 + index
        }
        return usages
    }()

    private static let shiftedCharacters: [String: String] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
        "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    ]

    private static let specialUsages: [SpecialKey: Int] = [
        .returnKey: 0x28, .escape: 0x29, .delete: 0x2A, .tab: 0x2B,
        .home: 0x4A, .pageUp: 0x4B, .forwardDelete: 0x4C, .end: 0x4D, .pageDown: 0x4E,
        .right: 0x4F, .left: 0x50, .down: 0x51, .up: 0x52,
    ]
}

/// A MacBook's ANSI keyboard.
private struct LaptopKeyboard: View {
    let session: RemoteSession
    let input: LaptopKeyboardInput

    private static let gap: CGFloat = 5
    /// Where the keys report their places, in the terms of the view over
    /// them that takes the touches.
    nonisolated private static let space = "LaptopKeys"

    var body: some View {
        GeometryReader { geometry in
            let rows = Self.rows
            let height = (geometry.size.height - Self.gap * CGFloat(rows.count - 1))
                / CGFloat(rows.count)

            VStack(spacing: Self.gap) {
                ForEach(rows.indices, id: \.self) { index in
                    if index == rows.count - 1 {
                        bottomRow(rows[index], width: geometry.size.width, height: height)
                    } else {
                        row(rows[index], width: geometry.size.width, height: height)
                    }
                }
            }
            .coordinateSpace(.named(Self.space))
            .overlay {
                LaptopKeyTouches(input: input)
            }
        }
        .padding(6)
        .background {
            // The keys sit in a well cut a little into the body.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard")
    }

    private func row(_ keys: [LaptopKey], width: CGFloat, height: CGFloat) -> some View {
        let unit = Self.unitWidth(for: keys, in: width)
        return HStack(spacing: Self.gap) {
            ForEach(keys) { key in
                keyView(key)
                    .frame(width: unit * key.width, height: height)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The last row, which ends in the arrows with Up and Down sharing one
    /// key's height between them.
    private func bottomRow(_ keys: [LaptopKey], width: CGFloat, height: CGFloat) -> some View {
        // Three arrow keys wide, made of Left, a column of Up over Down, and
        // Right.
        let arrowColumns: CGFloat = 3
        let unit = Self.unitWidth(for: keys, extra: arrowColumns, extraGaps: 3, in: width)
        let half = (height - 2) / 2
        return HStack(spacing: Self.gap) {
            ForEach(keys) { key in
                keyView(key)
                    .frame(width: unit * key.width, height: height)
            }
            HStack(alignment: .bottom, spacing: Self.gap) {
                keyView(Self.left)
                    .frame(width: unit, height: half)
                VStack(spacing: 2) {
                    keyView(Self.up)
                        .frame(width: unit, height: half)
                    keyView(Self.down)
                        .frame(width: unit, height: half)
                }
                keyView(Self.right)
                    .frame(width: unit, height: half)
            }
            .frame(height: height, alignment: .bottom)
        }
        .frame(width: width, alignment: .leading)
    }

    /// The width of an ordinary key, so that the keys of a row and the gaps
    /// between them fill it end to end.
    private static func unitWidth(
        for keys: [LaptopKey], extra: CGFloat = 0, extraGaps: Int = 0, in width: CGFloat
    ) -> CGFloat {
        let weights = keys.reduce(extra) { $0 + $1.width }
        let gaps = CGFloat(keys.count - 1 + extraGaps)
        return max((width - gap * gaps) / weights, 1)
    }

    /// A key as it is drawn. Touches go to the view over all of them, which
    /// finds the key from the place each one reports here.
    private func keyView(_ key: LaptopKey) -> some View {
        let isPressed = input.pressedKeys.contains(key.id)
        let lit: (isLit: Bool, isLocked: Bool, title: String) = switch key.action {
        case .modifier(let modifier):
            (input.isOn(modifier),
             input.isOn(modifier) && input.modifiersAreLocked
                && session.latchedModifiers.contains(modifier.modifier),
             modifier.modifier.title(of: modifier.modifier, on: session.computer.kind))
        case .fn: (input.fnIsOn, false, "Function")
        case .capsLock: (input.capsLockIsOn, false, "Caps Lock")
        default: (false, false, title(of: key))
        }
        return LaptopKeyCap(key: key, isPressed: isPressed, isLit: lit.isLit, isLocked: lit.isLocked)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.space))
            } action: { frame in
                input.setFrame(frame, for: key)
            }
            .accessibilityElement()
            .accessibilityLabel(lit.title)
            .accessibilityAddTraits(lit.isLit ? [.isKeyboardKey, .isSelected] : .isKeyboardKey)
            .accessibilityAction {
                input.tap(key.id)
            }
    }

    private func title(of key: LaptopKey) -> String {
        guard let stroke = LaptopKeyboardInput.stroke(
            for: key, fn: input.fnIsOn, shift: false, capsLock: false) else { return "" }
        if let special = stroke.special,
           let named = SpecialKey.allCases.first(where: { $0.keysym == special }) {
            return named.title
        }
        if let special = stroke.special, special >= Keysym.function(1), special <= Keysym.function(12) {
            return "F\(special - Keysym.function(1) + 1)"
        }
        return stroke.text == " " ? SpecialKey.space.title : RemoteKey.character(stroke.text).title
    }

    // MARK: Layout

    private static let left = LaptopKey(
        id: "left", legend: .single("◀︎"), action: .layered(.left, fn: .home))
    private static let right = LaptopKey(
        id: "right", legend: .single("▶︎"), action: .layered(.right, fn: .end))
    private static let up = LaptopKey(
        id: "up", legend: .single("▲"), action: .layered(.up, fn: .pageUp))
    private static let down = LaptopKey(
        id: "down", legend: .single("▼"), action: .layered(.down, fn: .pageDown))

    private static let rows: [[LaptopKey]] = [
        [.pair("`", "~"), .pair("1", "!"), .pair("2", "@"), .pair("3", "#"), .pair("4", "$"),
         .pair("5", "%"), .pair("6", "^"), .pair("7", "&"), .pair("8", "*"), .pair("9", "("),
         .pair("0", ")"), .pair("-", "_"), .pair("=", "+"),
         LaptopKey(
            id: "delete", legend: .single("delete"), action: .layered(.delete, fn: .forwardDelete),
            width: 1.5, alignment: .bottomTrailing)],
        [LaptopKey(id: "tab", legend: .single("tab"), action: .special(.tab), width: 1.5, alignment: .bottomLeading)]
            + "qwertyuiop".map { .letter(String($0)) }
            + [.pair("[", "{"), .pair("]", "}"), .pair("\\", "|")],
        [LaptopKey(
            id: "caps", legend: .single("caps lock"), action: .capsLock,
            width: 1.8, alignment: .bottomLeading)]
            + "asdfghjkl".map { .letter(String($0)) }
            + [.pair(";", ":"), .pair("'", "\""),
               LaptopKey(
                id: "return", legend: .single("return"), action: .special(.returnKey),
                width: 1.7, alignment: .bottomTrailing)],
        [.modifier("shiftLeft", .leftShift, "⇧", "shift", width: 2.3, alignment: .bottomLeading)]
            + "zxcvbnm".map { .letter(String($0)) }
            + [.pair(",", "<"), .pair(".", ">"), .pair("/", "?"),
               .modifier("shiftRight", .rightShift, "⇧", "shift", width: 2.2, alignment: .bottomTrailing)],
        [LaptopKey(id: "fn", legend: .symbol("globe", caption: "fn"), action: .fn),
         .modifier("controlLeft", .leftControl, "⌃", "control", width: 1, alignment: .center),
         .modifier("optionLeft", .leftOption, "⌥", "option", width: 1, alignment: .center),
         .modifier("commandLeft", .leftCommand, "⌘", "command", width: 1.25, alignment: .center),
         LaptopKey(id: "space", legend: .single(""), action: .character(" "), width: 5),
         .modifier("commandRight", .rightCommand, "⌘", "command", width: 1.25, alignment: .center),
         .modifier("optionRight", .rightOption, "⌥", "option", width: 1, alignment: .center)],
    ]
}

/// The view over the keys that every finger on the keyboard goes to.
///
/// One view for all of them, in UIKit, rather than a gesture on each key:
/// a gesture on one view is not reliably told about a second finger on
/// another while the first is still down, and that second finger is the
/// whole of a shortcut. ⌘ held under one finger and C tapped with another
/// were two gestures, one of which could end the other; here they are two
/// touches on the same view, each followed to its key and back.
private struct LaptopKeyTouches: UIViewRepresentable {
    let input: LaptopKeyboardInput

    func makeUIView(context: Context) -> LaptopKeyTouchView {
        LaptopKeyTouchView(input: input)
    }

    func updateUIView(_ view: LaptopKeyTouchView, context: Context) {}
}

private final class LaptopKeyTouchView: UIView {
    private let input: LaptopKeyboardInput
    /// The key each finger came down on. A finger that slides off its key
    /// keeps it down, as on a real keyboard, until it is lifted.
    private var touchedKeys: [ObjectIdentifier: String] = [:]
    private let feedback = UIImpactFeedbackGenerator(style: .rigid)

    init(input: LaptopKeyboardInput) {
        self.input = input
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        // VoiceOver goes to the keys drawn underneath.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = input.key(at: touch.location(in: self)) else { continue }
            touchedKeys[ObjectIdentifier(touch)] = id
            if input.touchDown(id), input.hapticsEnabled {
                feedback.impactOccurred(intensity: 0.5)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            if let id = touchedKeys.removeValue(forKey: ObjectIdentifier(touch)) {
                input.touchUp(id)
            }
        }
    }
}

/// How a key looks: black, with its legend in white.
private struct LaptopKeyCap: View {
    let key: LaptopKey
    let isPressed: Bool
    var isLit = false
    var isLocked = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            legend(height: height)
                .foregroundStyle(isLit ? Color.accentColor : Color.white.opacity(0.88))
                .padding(.horizontal, max(height * 0.14, 3))
                .padding(.vertical, max(height * 0.1, 2))
                .frame(width: geometry.size.width, height: height, alignment: key.alignment)
        }
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(white: isPressed ? 0.16 : 0.07))
                .overlay {
                    // A highlight along the top, as the light catches the
                    // edge of a key.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.14), Color.white.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(isPressed ? 0 : 0.5), radius: 0.5, y: 1)
        }
        .overlay(alignment: .topLeading) {
            if isLit {
                // The light a MacBook has in its Caps Lock key, used here to
                // say that a modifier is held for the next key.
                Capsule()
                    .fill(isLocked ? Color.orange : Color.green)
                    .frame(width: 5, height: 2.5)
                    .padding(4)
            }
        }
        .scaleEffect(isPressed ? 0.96 : 1)
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    @ViewBuilder
    private func legend(height: CGFloat) -> some View {
        switch key.legend {
        case .single(let text):
            // Letters are printed larger than the names of wide keys.
            let isWord = text.count > 1 && key.width > 1
            Text(text)
                .font(.system(size: isWord ? height * 0.26 : height * 0.36, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        case .pair(let shifted, let plain):
            VStack(spacing: 0) {
                Text(shifted)
                Text(plain)
            }
            .font(.system(size: height * 0.27))
            .minimumScaleFactor(0.5)
        case .symbol(let symbol, let caption):
            VStack(spacing: height * 0.04) {
                if key.width > 1 {
                    // A wide modifier says its name in the corner and its
                    // symbol above it.
                    Text(symbol).font(.system(size: height * 0.24))
                } else if symbol.count == 1 {
                    Text(symbol).font(.system(size: height * 0.3))
                } else {
                    Image(systemName: symbol).font(.system(size: height * 0.3))
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: height * 0.2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment(for: key.alignment))
        }
    }

    private func alignment(for alignment: Alignment) -> Alignment {
        switch alignment {
        case .bottomLeading: .leading
        case .bottomTrailing: .trailing
        default: .center
        }
    }
}

// MARK: - The trackpad

/// The trackpad as it is drawn, in the middle under the keyboard. It only
/// shows where the trackpad is: what is touched is the whole of the lower
/// part of the deck, behind it.
private struct LaptopTrackpad: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.27), Color(white: 0.22)],
                startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
            }
            .frame(width: width)
            .frame(maxHeight: width * 0.7)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LaptopTrackpadSurface: UIViewRepresentable {
    let session: RemoteSession

    func makeUIView(context: Context) -> LaptopTrackpadView {
        LaptopTrackpadView(session: session)
    }

    func updateUIView(_ view: LaptopTrackpadView, context: Context) {}
}

/// The touch-sensitive part of the trackpad, answering fingers the way a
/// Mac's trackpad does.
///
/// - One finger moves the pointer and taps to click; a tap then a press, or
///   a press held still, drags.
/// - Two fingers scroll, and keep scrolling when let go while moving; they
///   tap to right-click, and pinch to zoom.
/// - Three or four fingers swipe up for Mission Control, down for App
///   Exposé, and left and right between spaces; three tap to look up.
///
/// Screen Sharing carries scrolling but no other gesture of a trackpad's, so
/// the rest are sent as the keys a Mac has for them, the same keys the
/// three-finger swipes on the picture send.
final class LaptopTrackpadView: UIView, UIGestureRecognizerDelegate {
    private let session: RemoteSession
    private var bridge: CanvasBridge { session.canvasBridge }
    private var lastPoint = CGPoint.zero
    private var lastTime: CFTimeInterval = 0
    private var isDragging = false
    private var isScrolling = false
    /// How many steps of zoom the pinch under way has sent, in or out.
    private var pinchSteps = 0
    private var isPinching = false

    /// How far apart the fingers go, as a factor, for each step of zoom.
    private static let pinchStep: CGFloat = 1.25

    init(session: RemoteSession) {
        self.session = session
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Drag to move the pointer. Tap to click. Use two fingers to scroll."

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap))
        threeFingerTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeFingerTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 4
        addGestureRecognizer(swipe)

        // Tap, then press and move: drag with the button held.
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.numberOfTapsRequired = 1
        drag.minimumPressDuration = 0.06
        addGestureRecognizer(drag)

        // Or press and hold, then move.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 10
        addGestureRecognizer(hold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Two fingers both scroll and pinch, and which of the two they are
    /// doing is only clear once they have moved.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard session.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: One finger

    @objc private func handleTap() {
        bridge.deckClicked(.left)
    }

    private func track(_ point: CGPoint, began: Bool) {
        let now = CACurrentMediaTime()
        if began {
            bridge.noteWorkOnRemoteScreen()
        } else {
            bridge.deckMoved(
                by: CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y),
                interval: now - lastTime)
        }
        lastPoint = point
        lastTime = now
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard !isDragging else { return }
        switch recognizer.state {
        case .began: track(recognizer.location(in: self), began: true)
        case .changed: track(recognizer.location(in: self), began: false)
        default: break
        }
    }

    @objc private func handleDrag(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isDragging = true
            track(recognizer.location(in: self), began: true)
            bridge.deckDrag(began: true)
        case .changed:
            track(recognizer.location(in: self), began: false)
        case .ended, .cancelled, .failed:
            guard isDragging else { return }
            isDragging = false
            bridge.deckDrag(began: false)
        default:
            break
        }
    }

    // MARK: Two fingers

    @objc private func handleTwoFingerTap() {
        bridge.deckClicked(.right)
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            recognizer.setTranslation(.zero, in: self)
            guard !isPinching else { return }
            isScrolling = true
            bridge.noteWorkOnRemoteScreen()
            bridge.deckScrolled(by: .zero, phase: .began)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            guard isScrolling else { return }
            bridge.deckScrolled(by: CGSize(width: translation.x, height: translation.y), phase: .changed)
        case .ended:
            guard isScrolling else { return }
            isScrolling = false
            let velocity = recognizer.velocity(in: self)
            bridge.deckScrolled(
                by: .zero, phase: .ended,
                releaseVelocity: CGSize(width: velocity.x, height: velocity.y))
        case .cancelled, .failed:
            guard isScrolling else { return }
            isScrolling = false
            bridge.deckScrolled(by: .zero, phase: .cancelled)
        default:
            break
        }
    }

    /// Fingers drawn apart zoom in, as ⌘+ does in most apps, and drawn
    /// together zoom out, a step each time they have gone a little further.
    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchSteps = 0
        case .changed:
            let scale = max(recognizer.scale, 0.01)
            if !isPinching, abs(log(scale)) > log(1.12) {
                // A pinch, not a scroll: the fingers are moving apart or
                // together more than they are moving across.
                isPinching = true
                if isScrolling {
                    isScrolling = false
                    bridge.deckScrolled(by: .zero, phase: .cancelled)
                }
            }
            guard isPinching else { return }
            let steps = Int(log(scale) / log(Self.pinchStep))
            while pinchSteps < steps {
                pinchSteps += 1
                zoom(in: true)
            }
            while pinchSteps > steps {
                pinchSteps -= 1
                zoom(in: false)
            }
        default:
            isPinching = false
            pinchSteps = 0
        }
    }

    private func zoom(in zoomsIn: Bool) {
        let modifier: KeyModifiers = session.computer.kind.isApple ? .command : .control
        haptic()
        session.tap(.character(zoomsIn ? "=" : "-"), modifiers: modifier)
    }

    // MARK: Three and four fingers

    @objc private func handleThreeFingerTap() {
        guard session.computer.kind.isApple else { return }
        haptic()
        session.send(Self.lookUp)
    }

    /// Sent on the swipe's end only: the same fingers that meant Mission
    /// Control can stop halfway, and a Mac answers every swipe it is given.
    @objc private func handleSwipe(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended, session.computer.kind.isApple else { return }
        let translation = recognizer.translation(in: self)
        guard let swipe = SwipeDirection.resolve(translation: translation),
              let shortcut = RemoteShortcut.macSystemGesture(for: swipe) else { return }
        haptic(.medium)
        session.send(shortcut)
    }

    /// What a three-finger tap does on a Mac: looks up the word under the
    /// pointer.
    private static let lookUp = RemoteShortcut(
        name: "Look Up", modifiers: [.control, .command], key: .character("d"))
}
#endif

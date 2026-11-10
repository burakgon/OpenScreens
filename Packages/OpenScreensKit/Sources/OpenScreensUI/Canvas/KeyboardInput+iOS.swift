#if os(iOS)
import GameController
import OpenScreensCore
import SwiftUI
import UIKit

// Keyboard input on iPhone and iPad.
//
// The canvas is always the first responder while a session is live. A
// hardware keyboard reaches it through the press events below; the on-screen
// keyboard reaches it through `UIKeyInput`. Whether the on-screen keyboard is
// visible is controlled by swapping the input view: an empty view keeps focus
// (so hardware keys keep working) without showing any keys.

extension RemoteCanvasView: UIKeyInput, UITextInputTraits {

    public override var canBecomeFirstResponder: Bool { true }

    public override var inputView: UIView? {
        showsSoftwareKeyboard ? nil : emptyInputView
    }

    public override var inputAccessoryView: UIView? {
        showsSoftwareKeyboard ? keyboardAccessory : nil
    }

    func claimFocus() {
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    func setSoftwareKeyboardVisible(_ visible: Bool) {
        guard visible != showsSoftwareKeyboard else { return }
        showsSoftwareKeyboard = visible
        if visible, keyboardAccessory == nil {
            keyboardAccessory = makeKeyboardAccessory()
        }
        claimFocus()
        reloadInputViews()
        session.canvasBridge.isKeyboardVisible = visible
        onKeyboardVisibilityChange?(visible)
    }

    private func makeKeyboardAccessory() -> UIView {
        let host = UIHostingController(rootView: KeyboardAccessoryBar(session: session, bridge: session.canvasBridge))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        let container = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardAccessoryBar.height),
            inputViewStyle: .keyboard)
        container.allowsSelfSizing = true
        container.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: KeyboardAccessoryBar.height),
        ])
        return container
    }

    // MARK: On-screen keyboard

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        guard session.canSendInput else { return }
        // Modifiers latched from the key bar wrap the next character, which
        // is what turns "c" into ⌘C.
        session.type(text)
    }

    public func deleteBackward() {
        guard session.canSendInput else { return }
        session.tap(.special(.delete))
    }

    // Remote text fields have their own ideas about correction and
    // capitalisation; the local keyboard should not second-guess them.
    public var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    public var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    public var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    public var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    public var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    public var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    public var keyboardAppearance: UIKeyboardAppearance {
        get { .dark }
        set {}
    }

    // MARK: Hardware keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard session.canSendInput, let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = key.keyCode
            if let modifier = ModifierKey(hidUsage: usage.rawValue) {
                pressedKeys.insert(usage)
                session.hardwareModifier(modifier, down: true)
            } else if usage == .keyboardCapsLock {
                // Reported as a press; the flags say which state it left
                // Caps Lock in.
                session.hardwareCapsLock(isOn: key.modifierFlags.contains(.alphaShift))
            } else if let stroke = stroke(for: key) {
                pressedKeys.insert(usage)
                session.hardwareKeyDown(stroke)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, event: event, forward: super.pressesEnded)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, event: event, forward: super.pressesCancelled)
    }

    private func release(
        _ presses: Set<UIPress>,
        event: UIPressesEvent?,
        forward: (Set<UIPress>, UIPressesEvent?) -> Void
    ) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let usage = press.key?.keyCode, pressedKeys.remove(usage) != nil else {
                unhandled.insert(press)
                continue
            }
            if let modifier = ModifierKey(hidUsage: usage.rawValue) {
                session.hardwareModifier(modifier, down: false)
            } else {
                session.hardwareKeyUp(key: usage.rawValue)
            }
        }
        if !unhandled.isEmpty {
            forward(unhandled, event)
        }
    }

    /// Describes a key press by what it types on the keyboard's layout.
    private func stroke(for key: UIKey) -> KeyStroke? {
        let usage = key.keyCode.rawValue
        let keyCode = KeyCodes.macKeyCode(forHIDUsage: usage)
        if let special = KeyCodes.keysym(forHIDUsage: usage) {
            return KeyStroke(key: usage, macKeyCode: keyCode, special: special)
        }
        let plain = Self.typedText(key.charactersIgnoringModifiers)
        let composed = Self.typedText(key.characters)
        guard !plain.isEmpty || !composed.isEmpty else { return nil }
        // With Control held the system reports a control code, and a dead
        // key reports nothing it types by itself; both fall back to the
        // key's own character.
        let isShortcut = !key.modifierFlags.intersection([.command, .control]).isEmpty
        return KeyStroke(
            key: usage,
            macKeyCode: keyCode,
            text: isShortcut || composed.isEmpty ? plain : composed,
            textWithoutOption: plain.isEmpty ? composed : plain,
            shortcutText: plain.lowercased())
    }

    /// The text a key reports, without the placeholders UIKit uses for keys
    /// that type nothing.
    private static func typedText(_ text: String) -> String {
        guard let first = text.unicodeScalars.first,
              first.value >= 0x20, first.value != 0x7F,
              !text.hasPrefix("UIKeyInput"), text != "Dead" else { return "" }
        return text
    }

    func releaseAllKeys() {
        session.releaseHardwareKeys()
        pressedKeys.removeAll()
    }
}

// MARK: - Key bar above the on-screen keyboard

/// The row of keys the on-screen keyboard does not have: modifiers, Escape,
/// Tab and arrows.
struct KeyboardAccessoryBar: View {
    static let height: CGFloat = 52

    let session: RemoteSession
    let bridge: CanvasBridge

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ModifierKeys(session: session)
                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 2)
                ForEach(Self.keys, id: \.self) { key in
                    RepeatingKeyButton(key: key, session: session)
                }
                Menu {
                    ForEach(1...12, id: \.self) { number in
                        Button("F\(number)") {
                            session.tap(.function(number))
                        }
                    }
                } label: {
                    AccessoryKeyLabel(text: "F1–12")
                }
                Button {
                    bridge.hideKeyboard()
                } label: {
                    AccessoryKeyLabel(symbol: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel("Hide Keyboard")
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private static let keys: [SpecialKey] = [
        .escape, .tab, .left, .down, .up, .right, .forwardDelete, .home, .end, .pageUp, .pageDown,
    ]
}

/// The four modifier keys. Tap to apply to the next key; double-tap to lock.
struct ModifierKeys: View {
    let session: RemoteSession

    var body: some View {
        ForEach(KeyModifiers.displayOrder, id: \.rawValue) { modifier in
            let isOn = session.latchedModifiers.contains(modifier)
            Button {
                session.toggleLatched(modifier)
            } label: {
                AccessoryKeyLabel(
                    text: modifier.symbols,
                    isHighlighted: isOn,
                    isLocked: isOn && session.modifiersAreLocked)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                session.latchedModifiers.insert(modifier)
                session.modifiersAreLocked = true
            })
            .accessibilityLabel(modifier.title(of: modifier, on: session.computer.kind))
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: isOn)
        }
    }
}

/// A key that repeats while held, for arrows and delete.
struct RepeatingKeyButton: View {
    let key: SpecialKey
    let session: RemoteSession
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        AccessoryKeyLabel(text: key.glyph)
            .contentShape(.rect)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30) {
                // Recognised: the key is being held. Repeat until released.
            } onPressingChanged: { isPressing in
                if isPressing {
                    session.tap(.special(key))
                    guard key.repeatsWhenHeld else { return }
                    repeatTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled {
                            session.tap(.special(key))
                            try? await Task.sleep(for: .milliseconds(55))
                        }
                    }
                } else {
                    repeatTask?.cancel()
                    repeatTask = nil
                }
            }
            .accessibilityLabel(key.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                session.tap(.special(key))
            }
    }
}

struct AccessoryKeyLabel: View {
    var text: String?
    var symbol: String?
    var isHighlighted = false
    var isLocked = false

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Text(text ?? "")
            }
        }
        .font(.system(size: 17, weight: .medium, design: .rounded))
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .frame(minWidth: 40, minHeight: 38)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
        }
        .overlay(alignment: .topTrailing) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
    }
}

/// Watches for hardware keyboards coming and going.
@Observable
final class HardwareKeyboardMonitor {
    private(set) var isAttached = GCKeyboard.coalesced != nil
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isAttached = GCKeyboard.coalesced != nil
                }
            })
        }
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif

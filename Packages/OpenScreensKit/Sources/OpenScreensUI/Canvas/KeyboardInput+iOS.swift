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
        for character in text {
            if character == "\n" {
                session.tap(.special(.returnKey))
            } else if character == "\t" {
                session.tap(.special(.tab))
            } else {
                // Modifiers latched from the key bar wrap the next character,
                // which is what turns "c" into ⌘C.
                session.tap(keysym: Keysym.character(character))
            }
        }
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
            let keysym = keysym(for: key)
            guard keysym != 0 else {
                unhandled.insert(press)
                continue
            }
            if let previous = pressedKeys[key.keyCode], previous != keysym {
                session.hardwareKey(previous, down: false)
            }
            pressedKeys[key.keyCode] = keysym
            session.hardwareKey(keysym, down: true)
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
            if let key = press.key, let keysym = pressedKeys.removeValue(forKey: key.keyCode) {
                session.hardwareKey(keysym, down: false)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            forward(unhandled, event)
        }
    }

    /// The keysym a key press should send.
    ///
    /// Modifier keys travel as their own events, so a character key sends its
    /// own character — with Shift applied, but without Option's alternate
    /// glyphs or Control's control codes — and the remote computer combines
    /// the two, as it would for a keyboard plugged into it.
    private func keysym(for key: UIKey) -> UInt32 {
        if let special = KeyCodes.keysym(forHIDUsage: key.keyCode.rawValue) {
            return special
        }
        let modified = key.modifierFlags.intersection([.command, .control, .alternate])
        let wantsComposedText = session.settings.keyboardInput == .unicode
            && modified.subtracting(.alternate).isEmpty
        let text = modified.isEmpty || wantsComposedText ? key.characters : key.charactersIgnoringModifiers
        guard let character = (text.isEmpty ? key.charactersIgnoringModifiers : text).first else { return 0 }
        return Keysym.character(character)
    }

    func releaseAllKeys() {
        for (_, keysym) in pressedKeys {
            session.hardwareKey(keysym, down: false)
        }
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

#if os(iOS)
import OpenScreensCore
import SwiftUI

/// A row of keys docked under the picture.
///
/// The deck used to carry a trackpad of its own as well. It does not. In
/// trackpad mode the whole screen already is one — a tap clicks where the
/// pointer is and a two-finger tap right-clicks — so a second trackpad
/// underneath only took room away from the desktop to say the same thing more
/// quietly, and the Click and Right Click buttons beneath it repeated two
/// gestures people already know. What the deck has that the picture does not
/// is the keys: the modifiers and the arrows, out without the on-screen
/// keyboard having to come up.
///
/// On a foldable stood up half open, the row sits at the bottom of the half
/// facing the table and the desktop keeps the half standing up, clear of the
/// crease between them. That is the arrangement a laptop has.
struct ControlDeck: View {
    /// How tall the deck is, and all the room it wants: the row, the glass it
    /// stands in, and the space below it.
    static let height: CGFloat = KeyboardAccessoryBar.height + 16

    let session: RemoteSession

    private var bridge: CanvasBridge { session.canvasBridge }

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
                Button {
                    bridge.toggleKeyboard()
                } label: {
                    AccessoryKeyLabel(symbol: "keyboard")
                }
                .accessibilityLabel("Keyboard")
            }
            .padding(.horizontal, 10)
            .frame(height: KeyboardAccessoryBar.height)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    /// The keys worth a tap when nothing is being typed. The on-screen
    /// keyboard's own accessory bar has the same modifiers and a longer list
    /// for moving about; these are the ones wanted on their own.
    private static let keys: [SpecialKey] = [
        .escape, .tab, .left, .down, .up, .right, .delete, .returnKey,
    ]
}
#endif

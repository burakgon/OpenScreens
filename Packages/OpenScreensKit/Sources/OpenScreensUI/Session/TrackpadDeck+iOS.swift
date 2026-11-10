#if os(iOS)
import OpenScreensCore
import QuartzCore
import SwiftUI
import UIKit

/// A trackpad and key row below the picture.
///
/// The deck turns the lower part of the screen into a laptop-style control
/// surface: the remote screen stays fully visible above it, and nothing you
/// do with your fingers covers what you are pointing at. On a foldable held
/// half open it fills the lower half by itself.
struct TrackpadDeck: View {
    let session: RemoteSession

    private var bridge: CanvasBridge { session.canvasBridge }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ModifierKeys(session: session)
                    Divider()
                        .frame(height: 24)
                        .padding(.horizontal, 2)
                    ForEach([SpecialKey.escape, .tab, .left, .down, .up, .right, .delete, .returnKey], id: \.self) { key in
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
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            DeckSurface(bridge: bridge)
                .overlay {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 20, style: .continuous))
                .clipShape(.rect(cornerRadius: 20, style: .continuous))
                .accessibilityLabel("Trackpad")
                .accessibilityHint("Drag to move the pointer. Tap to click. Use two fingers to scroll.")

            HStack(spacing: 8) {
                DeckButton(title: "Click") {
                    bridge.deckClicked(.left)
                }
                DeckButton(title: "Right Click") {
                    bridge.deckClicked(.right)
                }
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

private struct DeckButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
        .sensoryFeedback(.impact(weight: .light), trigger: UUID())
    }
}

/// The touch-sensitive area of the deck.
private struct DeckSurface: UIViewRepresentable {
    let bridge: CanvasBridge

    func makeUIView(context: Context) -> DeckSurfaceView {
        DeckSurfaceView(bridge: bridge)
    }

    func updateUIView(_ view: DeckSurfaceView, context: Context) {}
}

final class DeckSurfaceView: UIView {
    private let bridge: CanvasBridge
    private var lastPoint = CGPoint.zero
    private var lastTime: CFTimeInterval = 0
    private var isDragging = false

    init(bridge: CanvasBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        addGestureRecognizer(scroll)

        // Tap, then press and move: drag with the button held.
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.numberOfTapsRequired = 1
        drag.minimumPressDuration = 0.06
        addGestureRecognizer(drag)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 10
        addGestureRecognizer(hold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        bridge.deckClicked(.left)
    }

    @objc private func handleTwoFingerTap() {
        bridge.deckClicked(.right)
    }

    private func track(_ point: CGPoint, began: Bool) {
        let now = CACurrentMediaTime()
        if !began {
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

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            recognizer.setTranslation(.zero, in: self)
            bridge.deckScrolled(by: .zero, phase: .began)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            bridge.deckScrolled(by: CGSize(width: translation.x, height: translation.y), phase: .changed)
        case .ended:
            bridge.deckScrolled(by: .zero, phase: .ended)
        case .cancelled, .failed:
            bridge.deckScrolled(by: .zero, phase: .cancelled)
        default:
            break
        }
    }
}
#endif

#if os(iOS)
import OpenScreensCore
import QuartzCore
import RFBProtocol
import SwiftUI
import UIKit
import rootshellVNC

/// The remote screen, drawn and driven with UIKit.
public struct RemoteCanvas: UIViewRepresentable {
    private let session: RemoteSession

    public init(session: RemoteSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> RemoteCanvasView {
        RemoteCanvasView(session: session)
    }

    public func updateUIView(_ view: RemoteCanvasView, context: Context) {}
}

/// Hosts the engine's picture layers and turns touches, Apple Pencil, mouse,
/// trackpad and keyboard input into remote input.
///
/// The view is split across three files: this one owns the picture, layout
/// and the locally drawn pointer; `TouchInput+iOS` owns gestures; and
/// `KeyboardInput+iOS` owns hardware and on-screen keyboards.
public final class RemoteCanvasView: UIView {
    let session: RemoteSession

    /// Standard-mode framebuffer. High Performance video lives in the
    /// engine's own layers, hosted alongside this one.
    /// Holds everything that is part of the picture, and keeps it to the
    /// part of the screen the picture has: a picture zoomed in, or slid up
    /// from under a keyboard, would otherwise run on under the status bar.
    private let pictureLayer = CALayer()
    private let imageLayer = CALayer()
    /// The pointer, drawn locally so it moves without waiting for the network.
    private let cursorLayer = CALayer()
    private var isTracking = false

    // MARK: Pointer state (shared with the touch extension)

    /// Where the remote pointer is, in remote pixels.
    var pointerLocation = CGPoint.zero
    var hasPlacedPointer = false
    var buttons: PointerButtons = []
    /// Whether a mouse, trackpad or Pencil is currently hovering. The system
    /// pointer is hidden over the picture and ours is drawn instead.
    var isHoveringWithPointer = false

    var touchState = TouchState()
    var momentumLink: CADisplayLink?
    var momentum: ScrollMomentum?
    var momentumTimestamp: CFTimeInterval = 0
    var edgePanLink: CADisplayLink?
    var lastDragViewPoint: CGPoint?

    // MARK: Keyboard state (shared with the keyboard extension)

    /// Hardware keys that are down and were sent to the remote computer.
    var pressedKeys: Set<UIKeyboardHIDUsage> = []
    var showsSoftwareKeyboard = false
    let emptyInputView = UIView(frame: .zero)
    var keyboardAccessory: UIView?

    /// Whether a drag of files from another app is over the picture.
    var isReceivingFileDrag = false

    /// Tells the SwiftUI layer when the on-screen keyboard is shown or hidden.
    var onKeyboardVisibilityChange: ((Bool) -> Void)?

    public init(session: RemoteSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true

        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        pictureLayer.masksToBounds = true
        pictureLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(pictureLayer)
        pictureLayer.addSublayer(imageLayer)
        pictureLayer.addSublayer(session.engine.videoBandRenderer.containerLayer)
        pictureLayer.addSublayer(session.engine.secondaryVideoBandRenderer.containerLayer)

        cursorLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
        ]
        cursorLayer.zPosition = 10
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.35
        cursorLayer.shadowRadius = 1.5
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        pictureLayer.addSublayer(cursorLayer)

        installGestures()
        addInteraction(UIDropInteraction(delegate: self))
        installHingeObserver()
        observeKeyboardFrame()
        session.canvasBridge.attach(self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if !isTracking {
                isTracking = true
                track(.layout)
                track(.frame)
                track(.cursor)
                track(.focus)
            }
        } else {
            isTracking = false
            releaseAllInput()
            stopMomentum()
            stopEdgePan()
        }
    }

    private enum Tracked: Sendable {
        case layout, frame, cursor, focus
    }

    /// Re-runs one of the update passes whenever something it read changes.
    private func track(_ subject: Tracked) {
        guard isTracking else { return }
        withObservationTracking {
            switch subject {
            case .layout: applyLayout()
            case .frame: applyFrame()
            case .cursor: applyCursor()
            case .focus: applyFocus()
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.track(subject)
            }
        }
    }

    /// Takes keyboard focus as soon as the session is live, so a hardware
    /// keyboard types into the remote computer without a tap first.
    private func applyFocus() {
        _ = session.focusRequests
        guard session.isConnected, window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    // MARK: - Layout

    private var displayScale: CGFloat {
        window?.screen.scale ?? traitCollection.displayScale
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateViewportGeometry()
        applyLayout()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Pushes the view's size and the space to keep clear into the viewport.
    func updateViewportGeometry() {
        let scale = displayScale
        if session.viewport.viewSize != bounds.size {
            session.viewport.viewSize = bounds.size
        }
        if session.viewport.backingScale != scale {
            session.viewport.backingScale = scale
        }
        let layout = chromeLayout()
        if session.canvasBridge.chromeLayout != layout {
            session.canvasBridge.chromeLayout = layout
        }
        let insets = layout.pictureInsets
        // The desktop is sized for the screen with nothing covering it. A
        // keyboard or trackpad deck neither resizes the remote desktop,
        // which would be slow and would rearrange the user's windows, nor
        // shrinks the picture, which would make it too small to read: the
        // picture slides up as far as it takes to show where the pointer is.
        let uncovered = CGSize(
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom))
        if session.viewport.insets != insets {
            session.viewport.insets = insets
        }
        let cover = max(0, session.canvasBridge.bottomObstruction - insets.bottom)
        if session.viewport.bottomCover != cover {
            session.viewport.bottomCover = cover
            if cover > 0, hasPlacedPointer {
                session.viewport.reveal(pointerLocation, margin: 36)
            }
        }
        session.viewDidResize(to: uncovered, displayScale: scale)
    }

    /// Where the picture and the controls go on this screen as it is now.
    private func chromeLayout() -> SessionChromeLayout {
        let scene = window?.windowScene
        var statusBar = CGRect.zero
        if let window, let frame = scene?.statusBarManager?.statusBarFrame, !frame.isEmpty {
            statusBar = convert(frame, from: window)
        }
        let sensorSide: SessionChromeLayout.Side? = switch scene?.effectiveGeometry.interfaceOrientation {
        // Named for where the home indicator is; the sensors are opposite.
        case .landscapeRight: .left
        case .landscapeLeft: .right
        default: nil
        }
        return SessionChromeLayout(
            size: bounds.size,
            safeArea: Viewport.Insets(
                top: safeAreaInsets.top,
                left: safeAreaInsets.left,
                bottom: safeAreaInsets.bottom,
                right: safeAreaInsets.right),
            statusBar: statusBar,
            sensorSide: sensorSide)
    }

    private func applyLayout() {
        let engine = session.engine
        _ = session.canvasBridge.bottomObstruction
        let arrangement = session.arrangement
        let pictureSize = arrangement.size
        let isANewPicture = session.viewport.contentSize != pictureSize
        if isANewPicture {
            session.viewport.contentSize = pictureSize
        }
        if pictureSize.width > 0 {
            if !hasPlacedPointer {
                pointerLocation = CGPoint(x: pictureSize.width / 2, y: pictureSize.height / 2)
                hasPlacedPointer = true
            } else {
                // The picture can change shape under the pointer, when the
                // desktop is resized or two displays are rearranged.
                pointerLocation = CGPoint(
                    x: min(max(0, pointerLocation.x), max(0, pictureSize.width - 1)),
                    y: min(max(0, pointerLocation.y), max(0, pictureSize.height - 1)))
            }
        }
        if isANewPicture, session.viewport.bottomCover > 0 {
            // A picture of another size, with part of the view covered:
            // where the last one had been slid to means nothing for this
            // one. From its top, then as far as it takes to show the pointer.
            session.viewport.pan(by: CGSize(width: 0, height: bounds.height * 100))
            session.viewport.reveal(pointerLocation, margin: 36)
        }
        let content = session.viewport.contentRect
        let area = session.viewport.usableRect
        let isVideo = engine.isHighPerformanceMode
        let frames = arrangement.frames
        let scale = displayScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The same coordinates inside as outside: everything in the picture
        // is placed in the view's own terms, and only cut to the area.
        pictureLayer.bounds = area
        pictureLayer.position = CGPoint(x: area.midX, y: area.midY)
        imageLayer.isHidden = isVideo
        imageLayer.contentsScale = scale
        imageLayer.frame = content

        let primary = engine.videoBandRenderer
        let secondary = engine.secondaryVideoBandRenderer
        primary.containerLayer.isHidden = !isVideo
        secondary.containerLayer.isHidden = !isVideo || frames.count < 2
        if isVideo, pictureSize.width > 0, pictureSize.height > 0 {
            primary.setPixelScale(scale)
            secondary.setPixelScale(scale)
            let unit = content.width / pictureSize.width
            func place(_ frame: CGRect) -> CGRect {
                CGRect(
                    x: content.minX + frame.minX * unit,
                    y: content.minY + frame.minY * unit,
                    width: frame.width * unit,
                    height: frame.height * unit)
            }
            if frames.count >= 2 {
                primary.setViewBounds(place(frames[0]))
                secondary.setViewBounds(place(frames[1]))
            } else {
                primary.setViewBounds(content)
            }
        }
        CATransaction.commit()
        positionCursor()
    }

    private func applyFrame() {
        let engine = session.engine
        guard let image = engine.currentImage else {
            if imageLayer.contents != nil, !engine.isHighPerformanceMode {
                imageLayer.contents = nil
            }
            return
        }
        var presented = image
        if let region = engine.presentedFramebufferRegion {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let crop = region.integral.intersection(bounds)
            if !crop.isEmpty, crop != bounds, let cropped = image.cropping(to: crop) {
                presented = cropped
            }
        }
        imageLayer.contents = presented
    }

    // MARK: - Pointer drawing

    private var cursorHotspot = CGPoint.zero

    /// Whether the pointer should be drawn here rather than by the remote
    /// computer or by nobody.
    private var drawsCursor: Bool {
        guard session.isConnected, !session.settings.observeOnly,
              session.engine.activeCursorRendering == .client,
              session.engine.remoteCursorPresence != .hidden else { return false }
        // In touch mode the finger is the pointer; drawing one as well only
        // helps when something is hovering or a relative mode is in use.
        return session.settings.touchInput == .trackpad
            || isHoveringWithPointer
            || session.canvasBridge.isDeckVisible
    }

    private func applyCursor() {
        let engine = session.engine
        _ = session.viewport.scale
        _ = session.settings.touchInput
        _ = session.canvasBridge.isDeckVisible
        guard drawsCursor else {
            cursorLayer.isHidden = true
            return
        }
        let image: CGImage
        let hotspot: CGPoint
        if let cursor = engine.remoteCursor {
            image = cursor.image
            hotspot = CGPoint(x: cursor.hotspotX, y: cursor.hotspotY)
        } else {
            image = Self.fallbackArrow
            hotspot = CGPoint(x: 4, y: 3)
        }
        // Draw the pointer at its size on the remote screen, but keep it big
        // enough to follow when the desktop is scaled down to a phone.
        let natural = CGFloat(image.height) * session.viewport.scale
        let height = min(max(natural, 20), 72)
        let factor = height / CGFloat(max(1, image.height))
        cursorHotspot = CGPoint(x: hotspot.x * factor, y: hotspot.y * factor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        cursorLayer.contentsScale = displayScale
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) * factor, height: height)
        cursorLayer.anchorPoint = .zero
        cursorLayer.isHidden = false
        CATransaction.commit()
        positionCursor()
    }

    func positionCursor() {
        guard !cursorLayer.isHidden else { return }
        let point = session.viewport.viewPoint(for: pointerLocation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = CGPoint(x: point.x - cursorHotspot.x, y: point.y - cursorHotspot.y)
        CATransaction.commit()
    }

    func refreshCursorVisibility() {
        applyCursor()
    }

    /// A plain arrow used until the remote computer has described its pointer.
    private static let fallbackArrow: CGImage = {
        let size = CGSize(width: 28, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 4, y: 3))
            path.addLine(to: CGPoint(x: 4, y: 31))
            path.addLine(to: CGPoint(x: 11, y: 25))
            path.addLine(to: CGPoint(x: 16, y: 36))
            path.addLine(to: CGPoint(x: 20.5, y: 34))
            path.addLine(to: CGPoint(x: 15.5, y: 23.5))
            path.addLine(to: CGPoint(x: 24, y: 23.5))
            path.close()
            context.cgContext.setLineJoin(.round)
            UIColor.white.setStroke()
            path.lineWidth = 3
            path.stroke()
            UIColor.black.setFill()
            path.fill()
        }
        return image.cgImage!
    }()

    // MARK: - Keyboard frame

    /// Tracks how much of the view the on-screen keyboard covers, so the
    /// picture can move out from under it.
    private func observeKeyboardFrame() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil)
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard let window,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // The frame is in screen coordinates; a floating or undocked keyboard
        // does not reach the bottom edge and should not push the picture.
        let local = convert(frame, from: window.screen.coordinateSpace)
        let isDocked = local.maxY >= bounds.maxY - 1 && local.width >= bounds.width - 1
        let covered = isDocked ? max(0, bounds.maxY - local.minY) : 0
        setKeyboardInset(covered, notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        setKeyboardInset(0, notification: notification)
    }

    private func setKeyboardInset(_ inset: CGFloat, notification: Notification) {
        guard session.canvasBridge.keyboardInset != inset else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        session.canvasBridge.keyboardInset = inset
        UIView.animate(withDuration: duration) {
            self.updateViewportGeometry()
            self.layoutIfNeeded()
        }
    }

    // MARK: - Foldables

    /// On a foldable held half open, the lower half of the screen becomes a
    /// trackpad deck and the picture moves to the upper half.
    private func installHingeObserver() {
        guard #available(iOS 27.1, *) else { return }
        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            let isHalfOpen = update.hinge.map {
                HingePosture.isLaptopLike(isPartiallyOpen: $0.status == .partiallyOpen, angle: $0.angle)
            } ?? false
            if self.session.canvasBridge.hingeIsPartiallyOpen != isHalfOpen {
                self.session.canvasBridge.hingeIsPartiallyOpen = isHalfOpen
            }
            self.setNeedsLayout()
        }
        addInteraction(interaction)
    }
}

/// The channel between a session's SwiftUI chrome and its UIKit canvas.
///
/// The toolbar needs to ask the canvas to show the keyboard, and the canvas
/// needs to know how much of itself the chrome is covering. Both sides talk
/// to this object instead of to each other.
@Observable
public final class CanvasBridge {
    /// Height at the bottom of the canvas covered by the on-screen keyboard.
    public internal(set) var keyboardInset: CGFloat = 0
    /// Height at the bottom of the canvas covered by the trackpad deck.
    public var deckInset: CGFloat = 0
    /// Height at the bottom of the canvas that the picture should stay above.
    public var bottomObstruction: CGFloat { max(keyboardInset, deckInset) }
    /// Whether the on-screen keyboard is up.
    public internal(set) var isKeyboardVisible = false
    /// Whether a hardware keyboard is attached.
    public internal(set) var hasHardwareKeyboard = false
    /// Whether a foldable device is being held half open like a laptop,
    /// with one half of the screen flat and the other standing.
    public internal(set) var hingeIsPartiallyOpen = false
    /// Where the picture and the controls go on the screen the canvas is
    /// on. Nil until the canvas has been laid out.
    public internal(set) var chromeLayout: SessionChromeLayout?
    /// Counts touches on the remote screen, so that controls that are out
    /// only while they are wanted know when to go.
    public internal(set) var canvasTouches = 0
    /// Whether the trackpad deck is showing under the picture.
    public var isDeckVisible = false

    @ObservationIgnored weak var canvas: RemoteCanvasView?

    public init() {}

    func attach(_ canvas: RemoteCanvasView) {
        self.canvas = canvas
    }

    public func showKeyboard() {
        canvas?.setSoftwareKeyboardVisible(true)
    }

    public func hideKeyboard() {
        canvas?.setSoftwareKeyboardVisible(false)
    }

    public func toggleKeyboard() {
        canvas?.setSoftwareKeyboardVisible(!isKeyboardVisible)
    }

    /// Moves the pointer by a finger movement made on the trackpad deck.
    public func deckMoved(by delta: CGSize, interval: TimeInterval) {
        canvas?.movePointerRelatively(by: delta, interval: interval)
    }

    /// Says that the remote screen is being worked on from somewhere other
    /// than the canvas: the trackpad deck moves its pointer too.
    public func noteWorkOnRemoteScreen() {
        canvasTouches &+= 1
    }

    public func deckClicked(_ button: PointerButtons = .left) {
        noteWorkOnRemoteScreen()
        canvas?.clickAtPointer(button)
    }

    public func deckScrolled(by delta: CGSize, phase: AppleScrollEvent.Phase) {
        canvas?.scrollAtPointer(by: delta, phase: phase)
    }

    public func deckDrag(began: Bool) {
        canvas?.setDragAtPointer(began)
    }
}
#endif

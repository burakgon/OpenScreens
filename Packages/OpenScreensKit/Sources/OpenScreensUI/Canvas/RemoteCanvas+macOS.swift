#if os(macOS)
import AppKit
import OpenScreensCore
import QuartzCore
import RFBProtocol
import SwiftUI
import rootshellVNC

/// The remote screen, drawn and driven with AppKit.
public struct RemoteCanvas: NSViewRepresentable {
    private let session: RemoteSession

    public init(session: RemoteSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> RemoteCanvasView {
        RemoteCanvasView(session: session)
    }

    public func updateNSView(_ view: RemoteCanvasView, context: Context) {}
}

/// Hosts the engine's picture layers and turns mouse, trackpad and keyboard
/// events into remote input.
public final class RemoteCanvasView: NSView {
    private let session: RemoteSession

    /// Standard-mode framebuffer. High Performance video lives in the
    /// engine's own layers, which are hosted alongside this one.
    private let imageLayer = CALayer()

    private var isTracking = false
    private var trackingArea: NSTrackingArea?

    // Pointer
    private var buttons: PointerButtons = []
    private var lastRemotePoint: CGPoint?
    private var scrollGestureActive = false
    private var remoteCursor: NSCursor?
    private var remoteCursorKey: CursorKey?
    private var edgePanTimer: Timer?
    private var edgePanVelocity = CGSize.zero

    // Keyboard: what was sent on key-down, so key-up always releases the same
    // keysym even if modifiers changed in between.
    private var pressedKeys: [UInt16: UInt32] = [:]
    private var pressedModifiers: [UInt16: UInt32] = [:]

    public init(session: RemoteSession) {
        self.session = session
        super.init(frame: .zero)

        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        wantsLayer = true

        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(imageLayer)
        root.addSublayer(session.engine.videoBandRenderer.containerLayer)
        root.addSublayer(session.engine.secondaryVideoBandRenderer.containerLayer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.acceptsMouseMovedEvents = true
            if !isTracking {
                isTracking = true
                track(.layout)
                track(.frame)
                track(.cursor)
                track(.focus)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: window)
        } else {
            isTracking = false
            NotificationCenter.default.removeObserver(self)
            releaseAllInput()
            stopEdgePan()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    @objc private func windowDidResignKey() {
        releaseAllInput()
    }

    public override func resignFirstResponder() -> Bool {
        releaseAllInput()
        return super.resignFirstResponder()
    }

    // MARK: - Observation

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

    /// Takes keyboard focus as soon as the session is live, so typing goes to
    /// the remote computer without a click first. Not before: while
    /// connecting, the sign-in form needs the focus.
    private func applyFocus() {
        _ = session.focusRequests
        guard session.isConnected, let window, window.firstResponder !== self,
              window.attachedSheet == nil else { return }
        window.makeFirstResponder(self)
    }

    // MARK: - Layout

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    public override func layout() {
        super.layout()
        let scale = backingScale
        if session.viewport.viewSize != bounds.size {
            session.viewport.viewSize = bounds.size
        }
        if session.viewport.backingScale != scale {
            session.viewport.backingScale = scale
        }
        session.viewDidResize(to: bounds.size, displayScale: scale)
        applyLayout()
    }

    /// Converts a rectangle in the viewport's top-left coordinates to this
    /// view's layer coordinates, which start at the bottom left.
    private func layerRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func applyLayout() {
        let engine = session.engine
        let remoteSize = session.remoteSize
        if session.viewport.contentSize != remoteSize {
            session.viewport.contentSize = remoteSize
        }
        let content = session.viewport.contentRect
        let isVideo = engine.isHighPerformanceMode
        let regions = engine.presentedVideoDisplayRegions
        let scale = backingScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.isHidden = isVideo
        imageLayer.contentsScale = scale
        imageLayer.frame = layerRect(content)

        let primary = engine.videoBandRenderer
        let secondary = engine.secondaryVideoBandRenderer
        primary.containerLayer.isHidden = !isVideo
        secondary.containerLayer.isHidden = !isVideo || regions.count < 2
        if isVideo, remoteSize.width > 0, remoteSize.height > 0 {
            primary.setPixelScale(scale)
            secondary.setPixelScale(scale)
            // Each display occupies its share of the picture.
            let union = regions.dropFirst().reduce(regions.first ?? CGRect(origin: .zero, size: remoteSize)) {
                $0.union($1)
            }
            let unit = union.width > 0 ? content.width / union.width : 1
            func frame(for region: CGRect) -> CGRect {
                CGRect(
                    x: content.minX + (region.minX - union.minX) * unit,
                    y: content.minY + (region.minY - union.minY) * unit,
                    width: region.width * unit,
                    height: region.height * unit)
            }
            if regions.count >= 2 {
                primary.setViewBounds(layerRect(frame(for: regions[0])))
                secondary.setViewBounds(layerRect(frame(for: regions[1])))
            } else {
                primary.setViewBounds(layerRect(content))
            }
        }
        CATransaction.commit()

        window?.invalidateCursorRects(for: self)
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

    // MARK: - Cursor

    private struct CursorKey: Equatable {
        let image: ObjectIdentifier
        let height: Int
    }

    private func applyCursor() {
        let engine = session.engine
        _ = engine.remoteCursorPresence
        _ = engine.activeCursorRendering
        _ = session.viewport.scale
        _ = session.isConnected
        guard session.isConnected, engine.activeCursorRendering == .client,
              let cursor = engine.remoteCursor else {
            remoteCursor = nil
            remoteCursorKey = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        // Draw the pointer at the size it has on the remote screen, but never
        // so small that it gets lost when the picture is scaled far down.
        let natural = CGFloat(cursor.height) * session.viewport.scale
        let height = min(max(natural, 14), 96).rounded()
        let key = CursorKey(image: ObjectIdentifier(cursor.image), height: Int(height))
        if key != remoteCursorKey {
            let factor = height / CGFloat(max(1, cursor.height))
            let size = NSSize(width: CGFloat(cursor.width) * factor, height: height)
            let image = NSImage(cgImage: cursor.image, size: size)
            remoteCursor = NSCursor(
                image: image,
                hotSpot: NSPoint(
                    x: CGFloat(cursor.hotspotX) * factor,
                    y: CGFloat(cursor.hotspotY) * factor))
            remoteCursorKey = key
        }
        window?.invalidateCursorRects(for: self)
    }

    private static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    public override func resetCursorRects() {
        guard session.isConnected, session.viewport.isReady else { return }
        let rect = layerRect(session.viewport.contentRect).intersection(bounds)
        guard !rect.isEmpty else { return }
        let engine = session.engine
        let cursor: NSCursor
        if session.settings.observeOnly {
            cursor = .arrow
        } else if engine.activeCursorRendering == .server {
            // The remote computer paints its own pointer into the picture.
            cursor = Self.hiddenCursor
        } else if let remoteCursor {
            cursor = remoteCursor
        } else if engine.remoteCursorPresence == .hidden {
            cursor = Self.hiddenCursor
        } else {
            cursor = .arrow
        }
        addCursorRect(rect, cursor: cursor)
    }

    // MARK: - Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func remotePoint(_ event: NSEvent) -> CGPoint? {
        session.viewport.remotePoint(for: viewPoint(event), clamped: true)
    }

    private func sendPointer(_ event: NSEvent) {
        guard let point = remotePoint(event) else { return }
        lastRemotePoint = point
        session.pointer(buttons: buttons, at: point)
        updateEdgePan(for: viewPoint(event))
    }

    private func press(_ button: PointerButtons, _ event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        buttons.insert(button)
        sendPointer(event)
    }

    private func release(_ button: PointerButtons, _ event: NSEvent) {
        buttons.remove(button)
        sendPointer(event)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendPointer(event)
    }

    public override func mouseExited(with event: NSEvent) {
        stopEdgePan()
    }

    public override func mouseDown(with event: NSEvent) { press(.left, event) }
    public override func mouseUp(with event: NSEvent) { release(.left, event) }
    public override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    public override func rightMouseDown(with event: NSEvent) { press(.right, event) }
    public override func rightMouseUp(with event: NSEvent) { release(.right, event) }
    public override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        press(.middle, event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        release(.middle, event)
    }

    public override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(event) else { return }
        guard event.hasPreciseScrollingDeltas else {
            // A notched mouse wheel: whole clicks.
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let steps = Int((delta > 0 ? delta.rounded(.up) : delta.rounded(.down)))
            session.scrollWheel(steps: max(-8, min(8, steps)), at: point)
            return
        }

        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if event.momentumPhase != [] {
            let momentum: AppleScrollEvent.MomentumPhase = switch event.momentumPhase {
            case .began: .began
            case .ended, .cancelled: .ended
            default: .changed
            }
            session.scroll(by: delta, at: point, momentum: momentum)
            return
        }

        switch event.phase {
        case .began:
            // A Mac hit-tests the scroll against its own pointer, so put the
            // pointer there before opening the gesture.
            session.pointer(buttons: buttons, at: point)
            session.gesture(.began, at: point)
            scrollGestureActive = true
            session.scroll(by: delta, at: point, phase: .began)
        case .changed:
            session.scroll(by: delta, at: point, phase: .changed)
        case .ended, .cancelled:
            session.scroll(by: delta, at: point, phase: event.phase == .ended ? .ended : .cancelled)
            if scrollGestureActive {
                session.gesture(.ended, at: point)
                scrollGestureActive = false
            }
        case .mayBegin, .stationary:
            break
        default:
            // Continuous device without phases (some third-party mice).
            session.scroll(by: delta, at: point)
        }
    }

    public override func magnify(with event: NSEvent) {
        session.viewport.magnify(by: 1 + event.magnification, around: viewPoint(event))
    }

    public override func smartMagnify(with event: NSEvent) {
        let anchor = viewPoint(event)
        NSAnimationContext.runAnimationGroup { _ in
            if session.viewport.isTransformed {
                session.viewport.reset()
            } else {
                session.viewport.magnify(by: 2, around: anchor)
            }
        }
    }

    // MARK: - Edge panning

    /// When the picture is larger than the window, moving the pointer to an
    /// edge slides more of it into view.
    private func updateEdgePan(for point: CGPoint) {
        guard session.viewport.isCropped else {
            stopEdgePan()
            return
        }
        let margin: CGFloat = 28
        let maximumSpeed: CGFloat = 900
        func speed(_ distance: CGFloat) -> CGFloat {
            guard distance < margin else { return 0 }
            let depth = (margin - max(0, distance)) / margin
            return depth * depth * maximumSpeed
        }
        var velocity = CGSize.zero
        velocity.width = speed(point.x) - speed(bounds.width - point.x)
        velocity.height = speed(point.y) - speed(bounds.height - point.y)
        edgePanVelocity = velocity
        if velocity == .zero {
            stopEdgePan()
        } else if edgePanTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stepEdgePan()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            edgePanTimer = timer
        }
    }

    private func stepEdgePan() {
        let before = session.viewport.offset
        session.viewport.pan(by: CGSize(
            width: edgePanVelocity.width / 60, height: edgePanVelocity.height / 60))
        guard session.viewport.offset != before else {
            stopEdgePan()
            return
        }
        // The picture moved under a stationary pointer; tell the remote
        // computer where the pointer now is.
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let point = CGPoint(x: location.x, y: bounds.height - location.y)
        if let remote = session.viewport.remotePoint(for: point) {
            lastRemotePoint = remote
            session.pointer(buttons: buttons, at: remote)
        }
    }

    private func stopEdgePan() {
        edgePanTimer?.invalidate()
        edgePanTimer = nil
        edgePanVelocity = .zero
    }

    // MARK: - Keyboard

    /// Menu shortcuts reach the first responder before the menu bar. Taking
    /// them here is what lets ⌘Q, ⌘W, ⌘H and friends act on the remote
    /// computer instead of on OpenScreens.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              session.canSendInput,
              session.settings.captureSystemShortcuts,
              event.type == .keyDown,
              pointerIsInside else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    public override func keyDown(with event: NSEvent) {
        guard session.canSendInput else { return }
        let keysym = keysym(for: event)
        guard keysym != 0 else { return }
        if let previous = pressedKeys[event.keyCode], previous != keysym {
            session.hardwareKey(previous, down: false)
        }
        pressedKeys[event.keyCode] = keysym
        session.hardwareKey(keysym, down: true)
    }

    public override func keyUp(with event: NSEvent) {
        guard let keysym = pressedKeys.removeValue(forKey: event.keyCode) else { return }
        session.hardwareKey(keysym, down: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard session.canSendInput,
              let keysym = KeyCodes.modifierKeysym(forMacKeyCode: event.keyCode) else { return }

        if keysym == Keysym.capsLock {
            // Caps Lock reports state changes, not presses: send a full tap.
            session.hardwareKey(keysym, down: true)
            session.hardwareKey(keysym, down: false)
            return
        }

        let flag: NSEvent.ModifierFlags = switch keysym {
        case Keysym.shiftLeft, Keysym.shiftRight: .shift
        case Keysym.controlLeft, Keysym.controlRight: .control
        case Keysym.altLeft, Keysym.altRight: .option
        default: .command
        }
        let isDown = event.modifierFlags.contains(flag) && pressedModifiers[event.keyCode] == nil
        if isDown {
            pressedModifiers[event.keyCode] = keysym
            session.hardwareKey(keysym, down: true)
        } else if let pressed = pressedModifiers.removeValue(forKey: event.keyCode) {
            session.hardwareKey(pressed, down: false)
        }
    }

    /// The keysym a key press should send.
    ///
    /// Modifier keys travel as their own key events, so the character sent
    /// here is the key's own — with Shift and Caps Lock applied, but without
    /// Option's alternate characters or Control's control codes. The remote
    /// computer combines the two, exactly as it would for a local keyboard.
    private func keysym(for event: NSEvent) -> UInt32 {
        if let special = KeyCodes.keysym(forMacKeyCode: event.keyCode) {
            return special
        }
        let wantsComposedText = session.settings.keyboardInput == .unicode
            && event.modifierFlags.intersection([.command, .control]).isEmpty
        let characters = wantsComposedText
            ? event.characters
            : event.characters(byApplyingModifiers: event.modifierFlags.intersection([.shift, .capsLock]))
        guard let character = (characters ?? event.charactersIgnoringModifiers)?.first else { return 0 }
        return Keysym.character(character)
    }

    /// Releases everything that is held down. Called whenever the view stops
    /// receiving events, so a key or button can never be left stuck.
    private func releaseAllInput() {
        for (_, keysym) in pressedKeys {
            session.hardwareKey(keysym, down: false)
        }
        pressedKeys.removeAll()
        for (_, keysym) in pressedModifiers {
            session.hardwareKey(keysym, down: false)
        }
        pressedModifiers.removeAll()
        if !buttons.isEmpty, let point = lastRemotePoint {
            buttons = []
            session.pointer(buttons: [], at: point)
        }
        if scrollGestureActive, let point = lastRemotePoint {
            session.gesture(.ended, at: point)
            scrollGestureActive = false
        }
    }
}
#endif

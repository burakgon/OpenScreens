#if os(iOS)
import OpenScreensCore
import QuartzCore
import RFBProtocol
import UIKit
import rootshellVNC

/// Bookkeeping for gestures in progress.
struct TouchState {
    enum TwoFingerMode {
        case undecided, scroll, zoom
    }

    /// A tap, by how many fingers made it and where.
    struct Tap {
        var fingers: Int
        var viewPoint: CGPoint
        var time: TimeInterval
    }

    var lastTapTime: TimeInterval = 0
    var lastTapViewPoint = CGPoint.zero
    var lastTapRemotePoint = CGPoint.zero

    /// A tap UIKit has asked about and not delivered yet.
    var awaitedTap: Tap?
    /// The last tap made without waiting for UIKit to deliver it.
    var undeliveredTap: Tap?

    var isDragging = false
    var dragButton: PointerButtons = .left

    var twoFingerMode = TwoFingerMode.undecided
    var twoFingerStartSpan: CGFloat = 0
    var twoFingerLastCentroid = CGPoint.zero
    var twoFingerTravel: CGFloat = 0

    var scrollIsActive = false
    var scrollPoint = CGPoint.zero
    var lastPanTime: TimeInterval = 0
    var velocity = ReleaseVelocityTracker()
    var scrollTravel = CGPoint.zero
}

// MARK: - Gestures

extension RemoteCanvasView: UIGestureRecognizerDelegate {

    private var isTrackpadMode: Bool {
        session.settings.touchInput == .trackpad
    }

    private static let directTouch = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

    func installGestures() {
        func add<Recognizer: UIGestureRecognizer>(_ recognizer: Recognizer, direct: Bool = true) -> Recognizer {
            recognizer.delegate = self
            if direct {
                recognizer.allowedTouchTypes = Self.directTouch
            }
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
            return recognizer
        }

        let tap = add(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        tap.numberOfTouchesRequired = 1

        let twoFingerTap = add(UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:))))
        twoFingerTap.numberOfTouchesRequired = 2

        let threeFingerTap = add(UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:))))
        threeFingerTap.numberOfTouchesRequired = 3

        // Press and hold, then move: a drag with the left button.
        let hold = add(UILongPressGestureRecognizer(target: self, action: #selector(handleHoldDrag(_:))))
        hold.minimumPressDuration = 0.32
        hold.allowableMovement = 12

        // Tap, then press again and move: the trackpad "tap and a half" drag.
        let tapThenHold = add(UILongPressGestureRecognizer(target: self, action: #selector(handleHoldDrag(_:))))
        tapThenHold.numberOfTapsRequired = 1
        tapThenHold.minimumPressDuration = 0.06
        tapThenHold.allowableMovement = 12

        // Two fingers held, then moved: a drag with the right button.
        let twoFingerHold = add(UILongPressGestureRecognizer(target: self, action: #selector(handleTwoFingerHoldDrag(_:))))
        twoFingerHold.numberOfTouchesRequired = 2
        twoFingerHold.minimumPressDuration = 0.4

        let pan = add(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1

        let twoFingerPan = add(UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:))))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2

        let threeFingerPan = add(UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:))))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3

        // Pinching with a trackpad arrives without touches, so this one is
        // not limited to direct touches.
        _ = add(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))), direct: false)

        // Trackpad and Magic Mouse scrolling.
        let smoothScroll = add(UIPanGestureRecognizer(target: self, action: #selector(handlePointerScroll(_:))), direct: false)
        smoothScroll.allowedScrollTypesMask = .continuous
        smoothScroll.allowedTouchTypes = []

        // A notched mouse wheel.
        let wheel = add(UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:))), direct: false)
        wheel.allowedScrollTypesMask = .discrete
        wheel.allowedTouchTypes = []

        _ = add(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))), direct: false)

        addInteraction(UIPointerInteraction(delegate: self))
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Two fingers can be scrolling or zooming; both recognisers run and
        // the handlers decide which the gesture is.
        let pair = (gestureRecognizer, other)
        switch pair {
        case (is UIPinchGestureRecognizer, is UIPanGestureRecognizer),
             (is UIPanGestureRecognizer, is UIPinchGestureRecognizer):
            return true
        default:
            return false
        }
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard session.isConnected else { return false }
        if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.view === self {
            expectDelivery(of: tap)
        }
        return true
    }

    // MARK: Taps the system holds back

    /// How long a tap's handler may take to follow the question about it.
    /// It normally follows in the same turn of the run loop.
    private static let tapDeliveryAllowance: Duration = .milliseconds(60)

    /// Notes a tap UIKit is about to deliver, and makes it if UIKit then
    /// does not.
    ///
    /// The system keeps strips of some screens for gestures of its own. On
    /// most, a tap in one is still delivered. Along the top of an unfolded
    /// iPhone Duo, as its simulator has it, it is not: the touches arrive,
    /// UIKit asks whether the tap may begin, and the handler never runs. A
    /// remote Mac's menu bar is drawn in exactly that strip, so a tap that
    /// was asked about and not delivered is made here instead.
    private func expectDelivery(of recognizer: UITapGestureRecognizer) {
        let tap = TouchState.Tap(
            fingers: recognizer.numberOfTouchesRequired,
            viewPoint: recognizer.location(in: self),
            time: CACurrentMediaTime())
        touchState.awaitedTap = tap
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.tapDeliveryAllowance)
            guard let self, let awaited = self.touchState.awaitedTap, awaited.time == tap.time else { return }
            self.touchState.awaitedTap = nil
            self.touchState.undeliveredTap = TouchState.Tap(
                fingers: tap.fingers, viewPoint: tap.viewPoint, time: CACurrentMediaTime())
            self.tap(fingers: tap.fingers, at: tap.viewPoint)
        }
    }

    /// Called as UIKit delivers a tap. False when that tap was already made
    /// without waiting, so that a late delivery is not a second tap.
    private func takeDelivery(of recognizer: UITapGestureRecognizer) -> Bool {
        let fingers = recognizer.numberOfTouchesRequired
        if touchState.awaitedTap?.fingers == fingers {
            touchState.awaitedTap = nil
        }
        guard let made = touchState.undeliveredTap, made.fingers == fingers else { return true }
        let point = recognizer.location(in: self)
        let isTheSameTap = CACurrentMediaTime() - made.time < 1.5
            && hypot(point.x - made.viewPoint.x, point.y - made.viewPoint.y) < 6
        if isTheSameTap {
            touchState.undeliveredTap = nil
        }
        return !isTheSameTap
    }

    /// What a tap with that many fingers does.
    private func tap(fingers: Int, at viewPoint: CGPoint) {
        switch fingers {
        case 1: click(at: viewPoint)
        case 2: secondaryClick(at: viewPoint)
        default: middleClick(at: viewPoint)
        }
    }

    // MARK: Coordinates

    private func remotePoint(at viewPoint: CGPoint) -> CGPoint? {
        session.viewport.remotePoint(for: viewPoint, clamped: true)
    }

    /// Points on the remote screen per remote pixel, used so the virtual
    /// pointer covers the same physical distance at any zoom level.
    private var remotePixelsPerPoint: CGFloat {
        session.remotePixelsPerPoint
    }

    func setPointer(_ remote: CGPoint, send: Bool = true) {
        let size = session.arrangement.size
        pointerLocation = CGPoint(
            x: min(max(0, remote.x), max(0, size.width - 1)),
            y: min(max(0, remote.y), max(0, size.height - 1)))
        hasPlacedPointer = true
        positionCursor()
        if send {
            session.pointer(buttons: buttons, at: pointerLocation)
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard session.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: Taps

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard takeDelivery(of: recognizer) else { return }
        tap(fingers: 1, at: recognizer.location(in: self))
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard takeDelivery(of: recognizer) else { return }
        tap(fingers: 2, at: recognizer.location(in: self))
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard takeDelivery(of: recognizer) else { return }
        tap(fingers: 3, at: recognizer.location(in: self))
    }

    private func click(at viewPoint: CGPoint) {
        guard session.canSendInput else { return }
        claimFocus()
        stopMomentum()
        if isTrackpadMode {
            session.click(.left, at: pointerLocation)
            return
        }
        guard var remote = remotePoint(at: viewPoint) else { return }
        // A second tap that lands close to the first is a double-click; send
        // it at exactly the same pixel so the remote computer agrees.
        let now = CACurrentMediaTime()
        if now - touchState.lastTapTime < 0.45,
           hypot(viewPoint.x - touchState.lastTapViewPoint.x, viewPoint.y - touchState.lastTapViewPoint.y) < 28 {
            remote = touchState.lastTapRemotePoint
        }
        touchState.lastTapTime = now
        touchState.lastTapViewPoint = viewPoint
        touchState.lastTapRemotePoint = remote
        setPointer(remote, send: false)
        session.click(.left, at: remote)
    }

    private func secondaryClick(at viewPoint: CGPoint) {
        guard session.canSendInput else { return }
        claimFocus()
        if !isTrackpadMode, let remote = remotePoint(at: viewPoint) {
            setPointer(remote, send: false)
        }
        haptic()
        session.click(.right, at: pointerLocation)
    }

    private func middleClick(at viewPoint: CGPoint) {
        guard session.canSendInput else { return }
        if !isTrackpadMode, let remote = remotePoint(at: viewPoint) {
            setPointer(remote, send: false)
        }
        session.click(.middle, at: pointerLocation)
    }

    // MARK: Drags

    @objc private func handleHoldDrag(_ recognizer: UILongPressGestureRecognizer) {
        drag(recognizer, button: .left)
    }

    @objc private func handleTwoFingerHoldDrag(_ recognizer: UILongPressGestureRecognizer) {
        drag(recognizer, button: .right)
    }

    private func drag(_ recognizer: UILongPressGestureRecognizer, button: PointerButtons) {
        guard session.canSendInput else { return }
        let viewPoint = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            claimFocus()
            stopMomentum()
            if !isTrackpadMode, let remote = remotePoint(at: viewPoint) {
                setPointer(remote)
            }
            touchState.isDragging = true
            touchState.dragButton = button
            lastDragViewPoint = viewPoint
            touchState.lastPanTime = CACurrentMediaTime()
            buttons.insert(button)
            session.pointer(buttons: buttons, at: pointerLocation)
            haptic(.medium)
        case .changed:
            movePointer(to: viewPoint)
            updateEdgePan(for: viewPoint)
        case .ended, .cancelled, .failed:
            guard touchState.isDragging else { return }
            touchState.isDragging = false
            lastDragViewPoint = nil
            stopEdgePan()
            buttons.remove(touchState.dragButton)
            session.pointer(buttons: buttons, at: pointerLocation)
        default:
            break
        }
    }

    /// Moves the pointer for a finger now at `viewPoint`: straight to the
    /// finger in touch mode, by the distance travelled in trackpad mode.
    private func movePointer(to viewPoint: CGPoint) {
        if isTrackpadMode {
            let now = CACurrentMediaTime()
            if let last = lastDragViewPoint {
                movePointerRelatively(
                    by: CGSize(width: viewPoint.x - last.x, height: viewPoint.y - last.y),
                    interval: now - touchState.lastPanTime)
            }
            lastDragViewPoint = viewPoint
            touchState.lastPanTime = now
        } else if let remote = remotePoint(at: viewPoint) {
            setPointer(remote)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard session.canSendInput, !touchState.isDragging else { return }
        let viewPoint = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            claimFocus()
            stopMomentum()
            lastDragViewPoint = viewPoint
            touchState.lastPanTime = CACurrentMediaTime()
            if !isTrackpadMode, let remote = remotePoint(at: viewPoint) {
                setPointer(remote)
            }
        case .changed:
            movePointer(to: viewPoint)
            if !isTrackpadMode {
                updateEdgePan(for: viewPoint)
            }
        default:
            lastDragViewPoint = nil
            stopEdgePan()
        }
    }

    /// Moves the virtual pointer by a finger movement, with acceleration, and
    /// keeps it on screen when the picture is zoomed.
    func movePointerRelatively(by delta: CGSize, interval: TimeInterval) {
        guard session.canSendInput, session.viewport.isReady else { return }
        let motion = PointerAcceleration(speed: session.settings.pointerSpeed)
            .movement(for: delta, interval: interval)
        let scale = remotePixelsPerPoint
        setPointer(CGPoint(
            x: pointerLocation.x + motion.width * scale,
            y: pointerLocation.y + motion.height * scale))
        if session.viewport.reveal(pointerLocation, margin: 36) {
            positionCursor()
        }
    }

    func clickAtPointer(_ button: PointerButtons) {
        guard session.canSendInput else { return }
        session.click(button, at: pointerLocation)
    }

    func setDragAtPointer(_ isDown: Bool) {
        guard session.canSendInput else { return }
        if isDown {
            buttons.insert(.left)
            haptic(.medium)
        } else {
            buttons.remove(.left)
        }
        session.pointer(buttons: buttons, at: pointerLocation)
    }

    // MARK: Two fingers: scroll or zoom

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard session.isConnected else { return }
        let centroid = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            stopMomentum()
            touchState.twoFingerMode = .undecided
            touchState.twoFingerTravel = 0
            touchState.twoFingerLastCentroid = centroid
            touchState.scrollTravel = .zero
            touchState.velocity.reset()
            recognizer.setTranslation(.zero, in: self)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            touchState.twoFingerTravel += hypot(translation.x, translation.y)
            if touchState.twoFingerMode == .undecided, touchState.twoFingerTravel > 10 {
                touchState.twoFingerMode = .scroll
                beginScroll(at: centroid)
            }
            guard touchState.twoFingerMode == .scroll else { return }
            touchState.scrollTravel.x += translation.x
            touchState.scrollTravel.y += translation.y
            touchState.velocity.record(touchState.scrollTravel, at: CACurrentMediaTime())
            session.scroll(
                by: CGSize(width: translation.x, height: translation.y),
                at: touchState.scrollPoint,
                phase: .changed)
        case .ended, .cancelled, .failed:
            guard touchState.twoFingerMode == .scroll else {
                touchState.twoFingerMode = .undecided
                return
            }
            touchState.twoFingerMode = .undecided
            let velocity = touchState.velocity.velocity(at: CACurrentMediaTime())
            endScroll(cancelled: recognizer.state != .ended)
            if recognizer.state == .ended {
                startMomentum(velocity: velocity)
            }
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard session.isConnected else { return }
        let centroid = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            touchState.twoFingerLastCentroid = centroid
            if recognizer.numberOfTouches < 2 {
                // A trackpad pinch: nothing else competes for it.
                touchState.twoFingerMode = .zoom
            }
        case .changed:
            if touchState.twoFingerMode == .undecided, abs(recognizer.scale - 1) > 0.07 {
                touchState.twoFingerMode = .zoom
            }
            guard touchState.twoFingerMode == .zoom else {
                recognizer.scale = 1
                return
            }
            session.viewport.magnify(by: recognizer.scale, around: centroid)
            recognizer.scale = 1
            // Fingers that travel while pinching carry the picture with them.
            if recognizer.numberOfTouches >= 2 {
                session.viewport.pan(by: CGSize(
                    width: centroid.x - touchState.twoFingerLastCentroid.x,
                    height: centroid.y - touchState.twoFingerLastCentroid.y))
            }
            touchState.twoFingerLastCentroid = centroid
        default:
            if touchState.twoFingerMode == .zoom {
                touchState.twoFingerMode = .undecided
            }
        }
    }

    @objc private func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
        // Three fingers slide the zoomed picture around without touching the
        // remote computer.
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        session.viewport.pan(by: CGSize(width: translation.x, height: translation.y))
    }

    // MARK: Scrolling

    private func beginScroll(at viewPoint: CGPoint) {
        guard session.canSendInput else { return }
        if !isTrackpadMode, let remote = remotePoint(at: viewPoint) {
            setPointer(remote, send: false)
        }
        touchState.scrollPoint = pointerLocation
        touchState.scrollIsActive = true
        // A Mac hit-tests a scroll against its own pointer, so place the
        // pointer before opening the gesture.
        session.pointer(buttons: buttons, at: touchState.scrollPoint)
        session.gesture(.began, at: touchState.scrollPoint)
        session.scroll(by: .zero, at: touchState.scrollPoint, phase: .began)
    }

    private func endScroll(cancelled: Bool) {
        guard touchState.scrollIsActive else { return }
        touchState.scrollIsActive = false
        session.scroll(by: .zero, at: touchState.scrollPoint, phase: cancelled ? .cancelled : .ended)
        session.gesture(.ended, at: touchState.scrollPoint)
    }

    func scrollAtPointer(by delta: CGSize, phase: AppleScrollEvent.Phase) {
        switch phase {
        case .began:
            stopMomentum()
            touchState.scrollPoint = pointerLocation
            touchState.scrollIsActive = true
            session.pointer(buttons: buttons, at: pointerLocation)
            session.gesture(.began, at: pointerLocation)
            session.scroll(by: delta, at: pointerLocation, phase: .began)
        case .ended, .cancelled:
            endScroll(cancelled: phase == .cancelled)
        default:
            session.scroll(by: delta, at: touchState.scrollPoint, phase: .changed)
        }
    }

    private func startMomentum(velocity: CGSize) {
        guard session.canSendInput, var momentum = ScrollMomentum(releaseVelocity: velocity) else { return }
        _ = momentum.advance(by: 0)
        self.momentum = momentum
        momentumTimestamp = 0
        session.scroll(by: .zero, at: touchState.scrollPoint, momentum: .began)
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        guard var momentum, session.isConnected else {
            stopMomentum()
            return
        }
        let interval = momentumTimestamp == 0 ? link.duration : link.timestamp - momentumTimestamp
        momentumTimestamp = link.timestamp
        let distance = momentum.advance(by: interval)
        self.momentum = momentum
        session.scroll(by: distance, at: touchState.scrollPoint, momentum: .changed)
        if momentum.isFinished {
            stopMomentum()
        }
    }

    func stopMomentum() {
        guard momentumLink != nil else { return }
        momentumLink?.invalidate()
        momentumLink = nil
        momentum = nil
        session.scroll(by: .zero, at: touchState.scrollPoint, momentum: .ended)
    }

    @objc private func handlePointerScroll(_ recognizer: UIPanGestureRecognizer) {
        guard session.canSendInput else { return }
        switch recognizer.state {
        case .began:
            stopMomentum()
            touchState.scrollTravel = .zero
            touchState.velocity.reset()
            recognizer.setTranslation(.zero, in: self)
            touchState.scrollPoint = pointerLocation
            touchState.scrollIsActive = true
            session.gesture(.began, at: pointerLocation)
            session.scroll(by: .zero, at: pointerLocation, phase: .began)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            touchState.scrollTravel.x += translation.x
            touchState.scrollTravel.y += translation.y
            touchState.velocity.record(touchState.scrollTravel, at: CACurrentMediaTime())
            session.scroll(
                by: CGSize(width: translation.x, height: translation.y),
                at: touchState.scrollPoint,
                phase: .changed)
        case .ended, .cancelled, .failed:
            let velocity = touchState.velocity.velocity(at: CACurrentMediaTime())
            endScroll(cancelled: recognizer.state != .ended)
            if recognizer.state == .ended {
                startMomentum(velocity: velocity)
            }
        default:
            break
        }
    }

    @objc private func handleWheel(_ recognizer: UIPanGestureRecognizer) {
        guard session.canSendInput, recognizer.state == .changed else {
            recognizer.setTranslation(.zero, in: self)
            return
        }
        let translation = recognizer.translation(in: self)
        // One wheel notch arrives as a jump of several points.
        let steps = Int((translation.y / 12).rounded(.towardZero))
        guard steps != 0 else { return }
        recognizer.setTranslation(.zero, in: self)
        session.scrollWheel(steps: max(-8, min(8, steps)), at: pointerLocation)
    }

    // MARK: Mouse, trackpad and Apple Pencil

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            if !isHoveringWithPointer {
                isHoveringWithPointer = true
                refreshCursorVisibility()
            }
            guard session.canSendInput, let remote = remotePoint(at: recognizer.location(in: self)) else { return }
            stopMomentum()
            setPointer(remote)
        default:
            if isHoveringWithPointer {
                isHoveringWithPointer = false
                refreshCursorVisibility()
            }
        }
    }

    private func pointerButtons(for event: UIEvent?) -> PointerButtons {
        guard let mask = event?.buttonMask else { return .left }
        var result: PointerButtons = []
        if mask.contains(.primary) { result.insert(.left) }
        if mask.contains(.secondary) { result.insert(.right) }
        if mask.contains(.button(3)) { result.insert(.middle) }
        return result.isEmpty ? .left : result
    }

    /// The touch among `touches` that is a pointing device or a Pencil.
    /// Finger touches are left to the gesture recognisers.
    private func precisionTouch(in touches: Set<UITouch>) -> UITouch? {
        touches.first { $0.type == .indirectPointer || $0.type == .pencil }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Whatever the touch turns out to be, it is on the remote screen.
        session.canvasBridge.canvasTouches &+= 1
        guard session.canSendInput, let touch = precisionTouch(in: touches) else {
            super.touchesBegan(touches, with: event)
            return
        }
        claimFocus()
        stopMomentum()
        guard let remote = remotePoint(at: touch.location(in: self)) else { return }
        buttons = touch.type == .pencil ? .left : pointerButtons(for: event)
        setPointer(remote)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard session.canSendInput, let touch = precisionTouch(in: touches) else {
            super.touchesMoved(touches, with: event)
            return
        }
        // Coalesced touches carry the Pencil's full sampling rate; the last
        // one is enough for a pointer position.
        let latest = event?.coalescedTouches(for: touch)?.last ?? touch
        guard let remote = remotePoint(at: latest.location(in: self)) else { return }
        if touch.type != .pencil {
            buttons = pointerButtons(for: event)
        }
        setPointer(remote)
        updateEdgePan(for: latest.location(in: self))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = precisionTouch(in: touches) else {
            super.touchesEnded(touches, with: event)
            return
        }
        finishPrecisionTouch(touch)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = precisionTouch(in: touches) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        finishPrecisionTouch(touch)
    }

    private func finishPrecisionTouch(_ touch: UITouch) {
        stopEdgePan()
        buttons = []
        guard session.canSendInput else { return }
        if let remote = remotePoint(at: touch.location(in: self)) {
            setPointer(remote)
        } else {
            session.pointer(buttons: [], at: pointerLocation)
        }
    }

    // MARK: Edge panning

    /// While something is being dragged near an edge of a zoomed picture,
    /// slide more of the picture into view.
    private func updateEdgePan(for viewPoint: CGPoint) {
        guard session.viewport.isCropped else {
            stopEdgePan()
            return
        }
        lastDragViewPoint = viewPoint
        let usable = session.viewport.usableRect
        let margin: CGFloat = 36
        let nearEdge = viewPoint.x < usable.minX + margin || viewPoint.x > usable.maxX - margin
            || viewPoint.y < usable.minY + margin || viewPoint.y > usable.maxY - margin
        if nearEdge, edgePanLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepEdgePan(_:)))
            link.add(to: .main, forMode: .common)
            edgePanLink = link
        } else if !nearEdge {
            stopEdgePan()
        }
    }

    @objc private func stepEdgePan(_ link: CADisplayLink) {
        guard let viewPoint = lastDragViewPoint else {
            stopEdgePan()
            return
        }
        let usable = session.viewport.usableRect
        let margin: CGFloat = 36
        let maximumSpeed: CGFloat = 700
        func speed(_ distance: CGFloat) -> CGFloat {
            guard distance < margin else { return 0 }
            let depth = (margin - max(0, distance)) / margin
            return depth * depth * maximumSpeed
        }
        let velocity = CGSize(
            width: speed(viewPoint.x - usable.minX) - speed(usable.maxX - viewPoint.x),
            height: speed(viewPoint.y - usable.minY) - speed(usable.maxY - viewPoint.y))
        let before = session.viewport.offset
        session.viewport.pan(by: CGSize(
            width: velocity.width * link.duration, height: velocity.height * link.duration))
        guard session.viewport.offset != before else {
            stopEdgePan()
            return
        }
        // The picture moved under a stationary finger.
        if !isTrackpadMode, let remote = remotePoint(at: viewPoint) {
            setPointer(remote)
        } else {
            positionCursor()
        }
    }

    func stopEdgePan() {
        edgePanLink?.invalidate()
        edgePanLink = nil
    }

    // MARK: Cleanup

    /// Releases anything held down, so nothing stays stuck when the view
    /// stops receiving events.
    func releaseAllInput() {
        if !buttons.isEmpty {
            buttons = []
            session.pointer(buttons: [], at: pointerLocation)
        }
        if touchState.scrollIsActive {
            endScroll(cancelled: true)
        }
        touchState.isDragging = false
        releaseAllKeys()
    }
}

// MARK: - System pointer

extension RemoteCanvasView: UIPointerInteractionDelegate {
    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        // The pointer is drawn by this view with the remote computer's own
        // artwork, so the system's is hidden while it is over the picture.
        guard session.isConnected, !session.settings.observeOnly,
              session.engine.activeCursorRendering == .client else { return nil }
        return .hidden()
    }
}

// MARK: - Files dropped on the picture

/// Files dragged in from another app, the Files app beside this one for
/// instance, are copied to the Mac the picture shows: into whatever the drop
/// lands on there. While the drag is over the picture the Mac shows a drag of
/// its own under it.
extension RemoteCanvasView: UIDropInteractionDelegate {
    private func picturePoint(of drop: UIDropSession) -> CGPoint? {
        session.viewport.remotePoint(for: drop.location(in: self), clamped: true)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        self.session.canDropFiles && session.items.contains {
            VNCFileTransferController.fileType(for: $0.itemProvider) != nil
        }
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        guard !isReceivingFileDrag, let point = picturePoint(of: session) else { return }
        let names = session.items.compactMap {
            VNCFileTransferController.suggestedName(for: $0.itemProvider)
        }
        guard !names.isEmpty else { return }
        isReceivingFileDrag = self.session.beginFileDrag(names: names, at: point)
    }

    public func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        guard isReceivingFileDrag, let point = picturePoint(of: session) else {
            return UIDropProposal(operation: .cancel)
        }
        self.session.moveFileDrag(to: point)
        return UIDropProposal(operation: .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        endFileDrag()
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard isReceivingFileDrag, let point = picturePoint(of: session) else { return }
        isReceivingFileDrag = false
        self.session.dropFiles(session.items.map(\.itemProvider), at: point)
        // The Mac's pointer is where the files landed; keep ours with it.
        setPointer(point, send: false)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        endFileDrag()
    }

    private func endFileDrag() {
        guard isReceivingFileDrag else { return }
        isReceivingFileDrag = false
        session.cancelFileDrag()
    }
}
#endif

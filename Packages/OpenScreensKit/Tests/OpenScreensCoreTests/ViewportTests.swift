import CoreGraphics
import Foundation
import Testing
@testable import OpenScreensCore

@Suite("Viewport")
struct ViewportTests {

    // MARK: Helpers

    private func close(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 1e-6) -> Bool {
        abs(a - b) <= tolerance
    }

    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat = 1e-6) -> Bool {
        close(a.x, b.x, within: tolerance) && close(a.y, b.y, within: tolerance)
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        close(a.minX, b.minX) && close(a.minY, b.minY)
            && close(a.width, b.width) && close(a.height, b.height)
    }

    /// The picture can never be dragged away from the view: along an axis
    /// where it fits it is centred, and along one where it does not it
    /// leaves no gap at either edge.
    private func staysInBounds(_ viewport: Viewport) -> Bool {
        let usable = viewport.usableRect
        let picture = viewport.contentRect
        func holds(_ low: CGFloat, _ high: CGFloat, within usableLow: CGFloat, _ usableHigh: CGFloat) -> Bool {
            if high - low <= usableHigh - usableLow + 1e-6 {
                return close((low + high) / 2, (usableLow + usableHigh) / 2)
            }
            return low <= usableLow + 1e-6 && high >= usableHigh - 1e-6
        }
        return holds(picture.minX, picture.maxX, within: usable.minX, usable.maxX)
            && holds(picture.minY, picture.maxY, within: usable.minY, usable.maxY)
    }

    /// An 800 × 600 view on a 1600 × 1200 screen, zoomed to twice the fit
    /// size about its centre: one point per remote pixel, with the middle
    /// quarter of the screen showing.
    private func zoomedViewport() -> Viewport {
        var viewport = Viewport(
            viewSize: CGSize(width: 800, height: 600),
            contentSize: CGSize(width: 1600, height: 1200))
        viewport.magnify(by: 2, around: CGPoint(x: 400, y: 300))
        return viewport
    }

    private func randomViewport(using random: inout ReplayableRandom) -> Viewport {
        var viewport = Viewport(
            viewSize: CGSize(
                width: CGFloat.random(in: 200...2000, using: &random),
                height: CGFloat.random(in: 200...2000, using: &random)),
            contentSize: CGSize(
                width: CGFloat.random(in: 100...6000, using: &random).rounded(),
                height: CGFloat.random(in: 100...6000, using: &random).rounded()),
            backingScale: [1, 2, 3].randomElement(using: &random)!,
            scaling: ScalingMode.allCases.randomElement(using: &random)!,
            insets: Viewport.Insets(
                top: CGFloat.random(in: 0...60, using: &random),
                left: CGFloat.random(in: 0...60, using: &random),
                bottom: CGFloat.random(in: 0...60, using: &random),
                right: CGFloat.random(in: 0...60, using: &random)))
        for _ in 0..<Int.random(in: 0...4, using: &random) {
            if random.chance(0.5) {
                viewport.magnify(
                    by: CGFloat.random(in: 0.3...4, using: &random),
                    around: CGPoint(
                        x: CGFloat.random(in: 0...viewport.viewSize.width, using: &random),
                        y: CGFloat.random(in: 0...viewport.viewSize.height, using: &random)))
            } else {
                viewport.pan(by: CGSize(
                    width: CGFloat.random(in: -800...800, using: &random),
                    height: CGFloat.random(in: -800...800, using: &random)))
            }
        }
        return viewport
    }

    // MARK: Layout

    @Test func nothingIsLaidOutUntilBothSizesAreKnown() {
        var viewport = Viewport()
        #expect(!viewport.isReady)
        #expect(viewport.contentRect == .zero)
        #expect(viewport.scale == 1)
        #expect(viewport.minimumMagnification == 1)
        #expect(viewport.maximumMagnification == 1)
        #expect(viewport.remotePoint(for: CGPoint(x: 10, y: 10)) == nil)
        #expect(!viewport.isCropped)

        viewport.viewSize = CGSize(width: 800, height: 600)
        #expect(!viewport.isReady)

        // Zooming, panning and revealing wait for something to act on.
        viewport.magnify(by: 2, around: CGPoint(x: 100, y: 100))
        viewport.pan(by: CGSize(width: 50, height: 50))
        #expect(viewport.reveal(CGPoint(x: 5, y: 5)) == false)
        #expect(viewport.magnification == 1)
        #expect(viewport.offset == .zero)

        viewport.contentSize = CGSize(width: 1600, height: 1200)
        #expect(viewport.isReady)
    }

    @Test func fitShowsTheWholeScreenCentred() {
        // A square screen in a wide view: bars left and right.
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))
        #expect(viewport.scale == 0.25)
        #expect(close(viewport.contentRect, CGRect(x: 250, y: 0, width: 500, height: 500)))
        #expect(!viewport.isCropped)
        #expect(!viewport.isTransformed)

        // A wide screen in the same view: bars above and below.
        viewport.contentSize = CGSize(width: 4000, height: 1000)
        #expect(close(viewport.contentRect, CGRect(x: 0, y: 125, width: 1000, height: 250)))
        #expect(!viewport.isCropped)
    }

    @Test func fillCoversTheViewAndCropsTheRest() {
        let viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000),
            scaling: .fill)

        #expect(viewport.scale == 0.5)
        #expect(close(viewport.contentRect, CGRect(x: 0, y: -250, width: 1000, height: 1000)))
        #expect(viewport.isCropped)
        #expect(!viewport.isTransformed)
    }

    @Test func fitAndFillAgreeWhenTheShapesMatch() {
        var viewport = Viewport(
            viewSize: CGSize(width: 800, height: 600),
            contentSize: CGSize(width: 1600, height: 1200))
        let fitted = viewport.contentRect
        viewport.scaling = .fill

        #expect(close(viewport.contentRect, fitted))
        #expect(close(fitted, CGRect(x: 0, y: 0, width: 800, height: 600)))
        #expect(!viewport.isCropped)
    }

    @Test func actualSizeShowsOneRemotePixelPerLocalPixel() {
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 800, height: 600),
            backingScale: 2,
            scaling: .actualSize)

        // On a 2× display a remote pixel is half a point.
        #expect(viewport.scale == 0.5)
        #expect(close(viewport.contentRect, CGRect(x: 300, y: 100, width: 400, height: 300)))
        #expect(!viewport.isCropped)

        viewport.backingScale = 1
        #expect(viewport.scale == 1)
        #expect(close(viewport.contentRect, CGRect(x: 100, y: -50, width: 800, height: 600)))
        #expect(viewport.isCropped)

        viewport.backingScale = 3
        #expect(close(viewport.scale, 1.0 / 3))

        // A backing scale below one makes no sense and is treated as one.
        viewport.backingScale = 0.5
        #expect(viewport.scale == 1)
    }

    // MARK: Converting points

    @Test func cornersOfThePictureAreCornersOfTheRemoteScreen() throws {
        let viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))

        #expect(try #require(viewport.remotePoint(for: CGPoint(x: 250, y: 0))) == CGPoint(x: 0, y: 0))
        #expect(try #require(viewport.remotePoint(for: CGPoint(x: 500, y: 250))) == CGPoint(x: 1000, y: 1000))
        // The far corner is the last pixel, not one past it.
        #expect(try #require(viewport.remotePoint(for: CGPoint(x: 750, y: 500))) == CGPoint(x: 1999, y: 1999))
        #expect(try #require(viewport.remotePoint(for: CGPoint(x: 750, y: 500), clamped: false))
            == CGPoint(x: 1999, y: 1999))

        #expect(viewport.viewPoint(for: CGPoint(x: 0, y: 0)) == CGPoint(x: 250, y: 0))
        #expect(viewport.viewPoint(for: CGPoint(x: 1000, y: 1000)) == CGPoint(x: 500, y: 250))
    }

    @Test func pointsBesideThePictureClampToItsEdgeOrAreRejected() throws {
        let viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))
        let leftOfPicture = CGPoint(x: 10, y: 250)
        let rightOfPicture = CGPoint(x: 990, y: 125)

        // A drag that leaves the picture keeps tracking along its border.
        #expect(try #require(viewport.remotePoint(for: leftOfPicture)) == CGPoint(x: 0, y: 1000))
        #expect(try #require(viewport.remotePoint(for: rightOfPicture)) == CGPoint(x: 1999, y: 500))
        // A click there is not a click on the remote screen.
        #expect(viewport.remotePoint(for: leftOfPicture, clamped: false) == nil)
        #expect(viewport.remotePoint(for: rightOfPicture, clamped: false) == nil)
        #expect(viewport.remotePoint(for: CGPoint(x: 500, y: -1), clamped: false) == nil)
        #expect(viewport.remotePoint(for: CGPoint(x: 500, y: 501), clamped: false) == nil)
    }

    @Test func remoteAndViewPointsAreInversesAtAnyZoomAndPan() throws {
        for seed in UInt64(0)..<400 {
            var random = ReplayableRandom(seed: seed)
            let viewport = randomViewport(using: &random)
            let remote = CGPoint(
                x: CGFloat.random(in: 0...(viewport.contentSize.width - 1), using: &random),
                y: CGFloat.random(in: 0...(viewport.contentSize.height - 1), using: &random))

            let inView = viewport.viewPoint(for: remote)
            let back = try #require(viewport.remotePoint(for: inView), "seed \(seed)")
            guard close(back, remote), close(viewport.viewPoint(for: back), inView) else {
                Issue.record("converting there and back moved the point for seed \(seed)")
                return
            }
            // What is drawn at a point is what a click there reaches.
            guard viewport.contentRect.insetBy(dx: -1e-6, dy: -1e-6).contains(inView) else {
                Issue.record("a remote pixel was placed outside the picture for seed \(seed)")
                return
            }
        }
    }

    // MARK: Zoom

    @Test func zoomingKeepsThePixelUnderTheAnchorWhereItIs() throws {
        var viewport = Viewport(
            viewSize: CGSize(width: 800, height: 600),
            contentSize: CGSize(width: 1600, height: 1200))
        let anchor = CGPoint(x: 200, y: 150)
        #expect(try #require(viewport.remotePoint(for: anchor)) == CGPoint(x: 400, y: 300))

        viewport.magnify(by: 2, around: anchor)

        #expect(viewport.magnification == 2)
        #expect(viewport.scale == 1)
        #expect(close(try #require(viewport.remotePoint(for: anchor)), CGPoint(x: 400, y: 300)))
        #expect(viewport.isTransformed)
        #expect(viewport.isCropped)

        // And again, about a different point.
        let second = CGPoint(x: 600, y: 100)
        let pinned = try #require(viewport.remotePoint(for: second))
        viewport.magnify(by: 1.5, around: second)
        #expect(viewport.magnification == 3)
        #expect(close(try #require(viewport.remotePoint(for: second)), pinned))
    }

    @Test func zoomingInNeverMovesTheAnchoredPixel() throws {
        // In Fill the picture covers the view from the start, so no amount
        // of zooming in can force it to be re-centred.
        for seed in UInt64(0)..<400 {
            var random = ReplayableRandom(seed: seed)
            var viewport = Viewport(
                viewSize: CGSize(
                    width: CGFloat.random(in: 200...2000, using: &random),
                    height: CGFloat.random(in: 200...2000, using: &random)),
                contentSize: CGSize(
                    width: CGFloat.random(in: 100...6000, using: &random).rounded(),
                    height: CGFloat.random(in: 100...6000, using: &random).rounded()),
                scaling: .fill)

            for _ in 0..<3 {
                let anchor = CGPoint(
                    x: CGFloat.random(in: 0...viewport.viewSize.width, using: &random),
                    y: CGFloat.random(in: 0...viewport.viewSize.height, using: &random))
                let pinned = try #require(viewport.remotePoint(for: anchor), "seed \(seed)")
                viewport.magnify(by: CGFloat.random(in: 1...3, using: &random), around: anchor)
                let after = try #require(viewport.remotePoint(for: anchor), "seed \(seed)")
                guard close(after, pinned, within: 1e-5), staysInBounds(viewport) else {
                    Issue.record("the anchored pixel moved while zooming in for seed \(seed)")
                    return
                }
            }
        }
    }

    @Test func zoomingAboutAPointBesideThePictureZoomsAboutTheCentre() throws {
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))
        let centre = CGPoint(x: 500, y: 250)

        viewport.magnify(by: 2, around: CGPoint(x: 10, y: 250))

        #expect(viewport.magnification == 2)
        #expect(close(try #require(viewport.remotePoint(for: centre)), CGPoint(x: 1000, y: 1000)))
        #expect(close(viewport.contentRect, CGRect(x: 0, y: -250, width: 1000, height: 1000)))
    }

    @Test func anAxisThatStillFitsStaysCentredWhileTheOtherFollowsTheAnchor() {
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))

        // Zoom about the picture's top-left corner. At 1.5× it is 750 points
        // square: still narrower than the view, taller than it.
        viewport.magnify(by: 1.5, around: CGPoint(x: 250, y: 0))

        #expect(close(viewport.contentRect, CGRect(x: 125, y: 0, width: 750, height: 750)))
    }

    @Test func zoomStopsAtTheWholeScreenAndAtEightPointsPerPixel() {
        var viewport = Viewport(
            viewSize: CGSize(width: 800, height: 600),
            contentSize: CGSize(width: 1600, height: 1200))
        let centre = CGPoint(x: 400, y: 300)
        #expect(viewport.minimumMagnification == 1)
        #expect(viewport.maximumMagnification == 16)

        viewport.magnify(by: 0.01, around: centre)
        #expect(viewport.magnification == 1)
        #expect(!viewport.isTransformed)

        viewport.magnify(by: 1000, around: centre)
        #expect(viewport.magnification == 16)
        #expect(viewport.scale == Viewport.maximumScale)

        viewport.setMagnification(4, around: centre)
        #expect(viewport.magnification == 4)
        viewport.setMagnification(0.2, around: centre)
        #expect(viewport.magnification == 1)
        viewport.setMagnification(10_000, around: centre)
        #expect(viewport.magnification == 16)
    }

    @Test func fillAndActualSizeCanZoomOutToTheWholeScreen() {
        var filled = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000),
            scaling: .fill)
        #expect(filled.minimumMagnification == 0.5)
        filled.magnify(by: 0.01, around: CGPoint(x: 500, y: 250))
        #expect(filled.magnification == 0.5)
        #expect(!filled.isCropped)
        #expect(close(filled.contentRect, CGRect(x: 250, y: 0, width: 500, height: 500)))

        var actual = Viewport(
            viewSize: CGSize(width: 400, height: 300),
            contentSize: CGSize(width: 1600, height: 1200),
            backingScale: 1,
            scaling: .actualSize)
        #expect(actual.minimumMagnification == 0.25)
        actual.magnify(by: 0.01, around: CGPoint(x: 200, y: 150))
        #expect(close(actual.contentRect, CGRect(x: 0, y: 0, width: 400, height: 300)))

        // A screen smaller than the view is never shown below actual size.
        let small = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 800, height: 600),
            backingScale: 2,
            scaling: .actualSize)
        #expect(small.minimumMagnification == 1)
    }

    @Test func thereIsAlwaysRoomToZoomIn() {
        // A tiny screen fitted into a large view is already drawn at twenty
        // points per pixel, far past the usual cap.
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 1000),
            contentSize: CGSize(width: 50, height: 50))
        #expect(viewport.scale == 20)
        #expect(viewport.maximumMagnification == 2)

        viewport.magnify(by: 100, around: CGPoint(x: 500, y: 500))
        #expect(viewport.magnification == 2)
    }

    @Test func zoomFactorsThatMakeNoSenseAreIgnored() {
        var viewport = zoomedViewport()
        let before = viewport

        for factor in [0, -1, CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            viewport.magnify(by: factor, around: CGPoint(x: 100, y: 100))
            viewport.setMagnification(factor, around: CGPoint(x: 100, y: 100))
            #expect(viewport == before, "factor \(factor)")
        }
    }

    // MARK: Pan

    @Test func panningMovesThePictureUntilItsEdgeReachesTheView() {
        var viewport = zoomedViewport()
        #expect(close(viewport.contentRect, CGRect(x: -400, y: -300, width: 1600, height: 1200)))

        viewport.pan(by: CGSize(width: 50, height: -20))
        #expect(viewport.offset == CGSize(width: 50, height: -20))
        #expect(close(viewport.contentRect, CGRect(x: -350, y: -320, width: 1600, height: 1200)))

        // Far past the top-left corner: the corner stops at the view's corner.
        viewport.pan(by: CGSize(width: 10_000, height: 10_000))
        #expect(close(viewport.contentRect, CGRect(x: 0, y: 0, width: 1600, height: 1200)))

        viewport.pan(by: CGSize(width: -10_000, height: -10_000))
        #expect(close(viewport.contentRect, CGRect(x: -800, y: -600, width: 1600, height: 1200)))
    }

    @Test func aPictureThatFitsCannotBePanned() {
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))
        let before = viewport.contentRect

        viewport.pan(by: CGSize(width: 120, height: -80))

        #expect(viewport.offset == .zero)
        #expect(viewport.contentRect == before)
        #expect(!viewport.isTransformed)
    }

    @Test func thePictureNeverLeavesAGapHoweverItIsZoomedAndPanned() {
        for seed in UInt64(0)..<600 {
            var random = ReplayableRandom(seed: seed)
            var viewport = randomViewport(using: &random)
            guard staysInBounds(viewport) else {
                Issue.record("the picture was out of bounds for seed \(seed)")
                return
            }
            guard viewport.magnification >= viewport.minimumMagnification - 1e-9,
                  viewport.magnification <= viewport.maximumMagnification + 1e-9 else {
                Issue.record("the zoom was outside its limits for seed \(seed)")
                return
            }

            // The same holds after whatever the surroundings do next.
            switch Int.random(in: 0..<3, using: &random) {
            case 0:
                viewport.viewSize = CGSize(
                    width: CGFloat.random(in: 200...2000, using: &random),
                    height: CGFloat.random(in: 200...2000, using: &random))
            case 1:
                viewport.contentSize = CGSize(
                    width: CGFloat.random(in: 100...6000, using: &random).rounded(),
                    height: CGFloat.random(in: 100...6000, using: &random).rounded())
            default:
                viewport.insets = Viewport.Insets(
                    top: CGFloat.random(in: 0...90, using: &random),
                    bottom: CGFloat.random(in: 0...90, using: &random))
            }
            guard staysInBounds(viewport),
                  viewport.magnification >= viewport.minimumMagnification - 1e-9,
                  viewport.magnification <= viewport.maximumMagnification + 1e-9 else {
                Issue.record("the picture went out of bounds after a change for seed \(seed)")
                return
            }
        }
    }

    // MARK: Insets

    @Test func insetsKeepThePictureClearOfWhatCoversTheView() {
        // An on-screen keyboard takes the bottom 300 points.
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 800),
            contentSize: CGSize(width: 2000, height: 1000),
            insets: Viewport.Insets(bottom: 300))
        #expect(viewport.usableRect == CGRect(x: 0, y: 0, width: 1000, height: 500))
        #expect(close(viewport.contentRect, CGRect(x: 0, y: 0, width: 1000, height: 500)))

        // The keyboard goes away: the picture settles in the middle again.
        viewport.insets = .zero
        #expect(close(viewport.contentRect, CGRect(x: 0, y: 150, width: 1000, height: 500)))

        viewport.insets = Viewport.Insets(top: 100, left: 50, bottom: 200, right: 150)
        viewport.contentSize = CGSize(width: 1600, height: 1000)
        #expect(viewport.usableRect == CGRect(x: 50, y: 100, width: 800, height: 500))
        #expect(close(viewport.contentRect, CGRect(x: 50, y: 100, width: 800, height: 500)))
    }

    @Test func pointsAreConvertedRelativeToTheInsetPicture() throws {
        let viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 800),
            contentSize: CGSize(width: 1600, height: 1000),
            insets: Viewport.Insets(top: 100, left: 50, bottom: 200, right: 150))

        #expect(try #require(viewport.remotePoint(for: CGPoint(x: 50, y: 100))) == .zero)
        #expect(try #require(viewport.remotePoint(for: CGPoint(x: 450, y: 350))) == CGPoint(x: 800, y: 500))
        // Under the keyboard is not on the remote screen.
        #expect(viewport.remotePoint(for: CGPoint(x: 450, y: 700), clamped: false) == nil)
    }

    @Test func aPanIsPulledBackWhenInsetsShrinkTheRoom() {
        var viewport = zoomedViewport()
        viewport.pan(by: CGSize(width: -10_000, height: -10_000))
        #expect(staysInBounds(viewport))

        viewport.insets = Viewport.Insets(top: 40, bottom: 260)

        #expect(viewport.usableRect == CGRect(x: 0, y: 40, width: 800, height: 300))
        #expect(staysInBounds(viewport))
        // Still showing the bottom-right corner, now above the keyboard.
        #expect(close(viewport.contentRect.maxX, 800))
        #expect(close(viewport.contentRect.maxY, 340))
    }

    @Test func insetsThatSwallowTheViewLeaveNothingToShow() {
        let viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 800),
            contentSize: CGSize(width: 1600, height: 1000),
            insets: Viewport.Insets(left: 600, right: 600))

        #expect(viewport.usableRect.width == 0)
        #expect(!viewport.isReady)
        #expect(viewport.contentRect == .zero)
        #expect(viewport.remotePoint(for: CGPoint(x: 500, y: 400)) == nil)
    }

    // MARK: Reveal

    @Test func revealPansJustFarEnoughToShowAPixel() {
        var viewport = zoomedViewport()
        // The view shows remote x 400…1200, y 300…900.
        let hidden = CGPoint(x: 100, y: 450)
        #expect(viewport.viewPoint(for: hidden) == CGPoint(x: -300, y: 150))

        #expect(viewport.reveal(hidden) == true)

        // Brought to the left edge; vertically it was in view and stays put.
        #expect(viewport.viewPoint(for: hidden) == CGPoint(x: 0, y: 150))
        #expect(viewport.offset == CGSize(width: 300, height: 0))
    }

    @Test func revealKeepsAMarginWhenThereIsRoom() {
        var viewport = zoomedViewport()
        let hidden = CGPoint(x: 100, y: 450)

        #expect(viewport.reveal(hidden, margin: 50) == true)
        #expect(viewport.viewPoint(for: hidden) == CGPoint(x: 50, y: 150))

        // The corner of the screen cannot be moved inwards: the picture ends
        // there, so it stops at the corner of the view.
        #expect(viewport.reveal(.zero, margin: 50) == true)
        #expect(viewport.viewPoint(for: .zero) == .zero)
        #expect(viewport.reveal(.zero, margin: 50) == false)
    }

    @Test func revealingAPixelAlreadyInViewDoesNothing() {
        var viewport = zoomedViewport()
        let before = viewport

        #expect(viewport.reveal(CGPoint(x: 800, y: 600)) == false)
        #expect(viewport.reveal(CGPoint(x: 800, y: 600), margin: 50) == false)
        // A margin larger than the view is cut down to a third of its
        // shorter side, so the middle always counts as visible.
        #expect(viewport.reveal(CGPoint(x: 800, y: 600), margin: 10_000) == false)
        #expect(viewport == before)

        var fitted = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000))
        #expect(fitted.reveal(CGPoint(x: 0, y: 0), margin: 40) == false)
        #expect(fitted.offset == .zero)
    }

    // MARK: Changes around the viewport

    @Test func changingTheScalingModeStartsFromItsDefaultLayout() {
        var viewport = zoomedViewport()
        viewport.pan(by: CGSize(width: 100, height: 50))
        let transformed = viewport

        // Setting the mode it already has is not a change.
        viewport.scaling = .fit
        #expect(viewport == transformed)

        viewport.scaling = .fill
        #expect(viewport.magnification == 1)
        #expect(viewport.offset == .zero)
        #expect(!viewport.isTransformed)
    }

    @Test func resetReturnsToTheDefaultLayout() {
        var viewport = zoomedViewport()
        viewport.pan(by: CGSize(width: 100, height: 50))
        #expect(viewport.isTransformed)

        viewport.reset()

        #expect(!viewport.isTransformed)
        #expect(close(viewport.contentRect, CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    @Test func aPanAloneCountsAsTransformed() {
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000),
            scaling: .fill)
        #expect(!viewport.isTransformed)

        viewport.pan(by: CGSize(width: 0, height: 30))

        #expect(viewport.magnification == 1)
        #expect(viewport.isTransformed)
    }

    @Test func growingTheViewRecentresAPictureThatNowFits() {
        // At actual size the picture does not grow with the window.
        var viewport = Viewport(
            viewSize: CGSize(width: 400, height: 300),
            contentSize: CGSize(width: 800, height: 600),
            backingScale: 1,
            scaling: .actualSize)
        viewport.pan(by: CGSize(width: -10_000, height: -10_000))
        #expect(close(viewport.contentRect, CGRect(x: -400, y: -300, width: 800, height: 600)))

        viewport.viewSize = CGSize(width: 1600, height: 1200)

        #expect(viewport.offset == .zero)
        #expect(close(viewport.contentRect, CGRect(x: 400, y: 300, width: 800, height: 600)))
        #expect(!viewport.isCropped)
    }

    @Test func theZoomIsPulledBackIntoRangeWhenTheViewChangesShape() {
        var viewport = Viewport(
            viewSize: CGSize(width: 1000, height: 500),
            contentSize: CGSize(width: 2000, height: 2000),
            scaling: .fill)
        viewport.magnify(by: 0.01, around: CGPoint(x: 500, y: 250))
        #expect(viewport.magnification == 0.5)

        // In a square view, filling and fitting are the same thing, so
        // there is no longer anything to zoom out to.
        viewport.viewSize = CGSize(width: 1000, height: 1000)

        #expect(viewport.minimumMagnification == 1)
        #expect(viewport.magnification == 1)
        #expect(close(viewport.contentRect, CGRect(x: 0, y: 0, width: 1000, height: 1000)))
    }

    @Test func aNewRemoteResolutionKeepsThePictureInBounds() {
        var viewport = zoomedViewport()
        viewport.pan(by: CGSize(width: -10_000, height: -10_000))

        // The remote desktop shrinks to a quarter of its size.
        viewport.contentSize = CGSize(width: 800, height: 600)

        #expect(staysInBounds(viewport))
        #expect(close(viewport.contentRect.maxX, 800))
        #expect(close(viewport.contentRect.maxY, 600))
    }

    /// In Actual Size the backing scale decides how large the picture is, so
    /// moving between a standard and a Retina display has to re-check the
    /// pan like any other change of size.
    @Test func changingTheBackingScaleKeepsThePictureInBounds() {
        var viewport = Viewport(
            viewSize: CGSize(width: 400, height: 300),
            contentSize: CGSize(width: 800, height: 600),
            backingScale: 1,
            scaling: .actualSize)
        viewport.pan(by: CGSize(width: -10_000, height: -10_000))
        #expect(viewport.contentRect == CGRect(x: -400, y: -300, width: 800, height: 600))

        viewport.backingScale = 2

        #expect(viewport.contentRect == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(viewport.offset == .zero)
    }

    // MARK: Something covering the bottom of the view

    /// A phone held upright, showing a desktop made to fit it: 402 × 812
    /// points for a picture of 1440 × 2912 pixels.
    private func phone() -> Viewport {
        Viewport(
            viewSize: CGSize(width: 402, height: 812),
            contentSize: CGSize(width: 1440, height: 2912),
            backingScale: 3)
    }

    @Test func aKeyboardDoesNotMakeThePictureSmaller() {
        var viewport = phone()
        let before = viewport.contentRect
        #expect(close(before.width, 401.538, within: 0.01))

        // A keyboard comes up over the bottom 336 points.
        viewport.bottomCover = 336
        #expect(viewport.visibleRect == CGRect(x: 0, y: 0, width: 402, height: 476))
        #expect(viewport.usableRect == CGRect(x: 0, y: 0, width: 402, height: 812))
        #expect(close(viewport.contentRect.size.width, before.width))
        #expect(close(viewport.contentRect.size.height, before.height))
        #expect(close(viewport.scale, viewport.fitScale))
        // It starts where it was, its top at the top.
        #expect(close(viewport.contentRect.minY, 0))
        #expect(viewport.isCropped)

        // And settles back when the keyboard goes.
        viewport.bottomCover = 0
        #expect(close(viewport.contentRect, before))
        #expect(!viewport.isCropped)
        #expect(!viewport.isTransformed)
    }

    @Test func underACoverThePicturePansUntilItsLastLineClearsIt() {
        var viewport = phone()
        viewport.bottomCover = 336

        viewport.pan(by: CGSize(width: 0, height: -10_000))
        #expect(close(viewport.contentRect.maxY, 476))
        // No further, and not sideways: across, the picture fits.
        viewport.pan(by: CGSize(width: -500, height: -50))
        #expect(close(viewport.contentRect.maxY, 476))
        #expect(close(viewport.contentRect.midX, 201))

        viewport.pan(by: CGSize(width: 0, height: 10_000))
        #expect(close(viewport.contentRect.minY, 0))
    }

    @Test func revealBringsAPixelUnderTheCoverIntoWhatCanBeSeen() throws {
        var viewport = phone()
        viewport.bottomCover = 336
        // The Dock, at the bottom of the desktop: behind the keyboard.
        let dock = CGPoint(x: 720, y: 2880)
        #expect(viewport.viewPoint(for: dock).y > 476)

        let moved = viewport.reveal(dock, margin: 36)
        #expect(moved)
        let shown = viewport.viewPoint(for: dock)
        #expect(shown.y <= 476 - 36 + 1e-6 || close(viewport.contentRect.maxY, 476))
        #expect(shown.y < 476)
        // The same pixel is still under the same point of the picture.
        let back = try #require(viewport.remotePoint(for: shown))
        #expect(close(back, dock, within: 1e-6))

        // Something already in view is left where it is.
        let offset = viewport.offset
        let movedAgain = viewport.reveal(dock, margin: 36)
        #expect(!movedAgain)
        #expect(viewport.offset == offset)
    }

    @Test func aPictureThatFitsAboveTheCoverIsCentredThere() {
        // A wide desktop on the same phone: short enough to clear a keyboard.
        var viewport = Viewport(
            viewSize: CGSize(width: 402, height: 812),
            contentSize: CGSize(width: 1600, height: 1200))
        viewport.bottomCover = 336
        let picture = viewport.contentRect
        #expect(close(picture.height, 301.5))
        #expect(close(picture.midY, 238))
        #expect(!viewport.isCropped)
        viewport.pan(by: CGSize(width: 0, height: -200))
        #expect(close(viewport.contentRect.midY, 238))
    }

    @Test func aCoverTallerThanTheViewLeavesNothingToSee() {
        var viewport = phone()
        viewport.bottomCover = 5_000
        #expect(viewport.visibleRect == CGRect(x: 0, y: 0, width: 402, height: 0))
        // The picture keeps its size all the same.
        #expect(close(viewport.contentRect.height, 812))
        viewport.bottomCover = -40
        #expect(viewport.visibleRect == viewport.usableRect)
    }

    @Test func zoomingUnderACoverStillPansToEveryEdge() {
        var viewport = phone()
        viewport.bottomCover = 336
        viewport.magnify(by: 2, around: CGPoint(x: 201, y: 200))
        #expect(close(viewport.contentRect.width, 2 * 401.538, within: 0.01))

        viewport.pan(by: CGSize(width: 10_000, height: 10_000))
        #expect(close(viewport.contentRect.minX, 0))
        #expect(close(viewport.contentRect.minY, 0))
        viewport.pan(by: CGSize(width: -10_000, height: -10_000))
        #expect(close(viewport.contentRect.maxX, 402))
        #expect(close(viewport.contentRect.maxY, 476))
    }
}

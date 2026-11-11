import CoreGraphics
import Testing
@testable import OpenScreensCore

@Suite("Session chrome layout")
struct SessionChromeLayoutTests {
    private func insets(_ top: CGFloat, _ left: CGFloat, _ bottom: CGFloat, _ right: CGFloat) -> Viewport.Insets {
        Viewport.Insets(top: top, left: left, bottom: bottom, right: right)
    }

    // MARK: The picture

    @Test func thePictureGoesDownToTheBottomOfTheScreen() {
        // An iPhone upright: a sensor housing at the top, the home indicator
        // at the bottom.
        let layout = SessionChromeLayout(size: CGSize(width: 402, height: 874), safeArea: insets(62, 0, 34, 0))
        #expect(layout.pictureInsets == insets(62, 0, 0, 0))
        #expect(layout.safeArea == insets(62, 0, 34, 0))
    }

    @Test func aStatusBarAloneIsNotStayedClearOf() {
        // An iPad: nothing at the top but the status bar, which is hidden.
        // Staying clear of it would mean one desktop for the screen with
        // the bar and another, a moment later, for the screen without.
        let layout = SessionChromeLayout(size: CGSize(width: 1032, height: 1376), safeArea: insets(24, 0, 20, 0))
        #expect(layout.pictureInsets == .zero)
        #expect(layout.controls == .floating)
    }

    @Test func aScreenWithNothingInItsWayIsAllPicture() {
        // An iPhone Duo's inner display.
        let layout = SessionChromeLayout(size: CGSize(width: 951, height: 669), safeArea: insets(0, 0, 34, 0))
        #expect(layout.pictureInsets == .zero)
        #expect(layout.controls == .floating)
    }

    @Test func thePictureStartsBelowWhatTheScreensCornersCutInto() {
        // An iPhone Duo's inner display: nothing in the way at the top, but
        // corners that would take the Apple menu and the clock.
        let inner = SessionChromeLayout(
            size: CGSize(width: 951, height: 669), safeArea: insets(0, 0, 34, 0), cornerTop: 16)
        #expect(inner.pictureInsets == insets(16, 0, 0, 0))

        // Its cover display, with the strip down its side as well.
        let cover = SessionChromeLayout(
            size: CGSize(width: 466, height: 678), safeArea: insets(0, 0, 34, 84), cornerTop: 17.5)
        #expect(cover.pictureInsets == insets(17.5, 0, 0, 84))

        // A sensor housing is deeper than any corner: nothing changes.
        let phone = SessionChromeLayout(
            size: CGSize(width: 402, height: 874), safeArea: insets(62, 0, 34, 0), cornerTop: 62)
        #expect(phone.pictureInsets == insets(62, 0, 0, 0))
    }

    @Test func cornersAlreadyClearedByAStatusBarAskForNothingMore() {
        // An iPad whose status bar is still showing: the bar clears the
        // corners, and is about to be hidden. Not a reason to make a
        // desktop for the screen with the bar.
        let layout = SessionChromeLayout(
            size: CGSize(width: 1032, height: 1376), safeArea: insets(24, 0, 20, 0), cornerTop: 24)
        #expect(layout.pictureInsets == .zero)

        // Once it is hidden the corners are what is left.
        let hidden = SessionChromeLayout(
            size: CGSize(width: 1032, height: 1376), safeArea: insets(0, 0, 20, 0), cornerTop: 9.5)
        #expect(hidden.pictureInsets == insets(9.5, 0, 0, 0))
    }

    // MARK: Nothing the layout changes

    /// Version 1.1.0 showed the status bar where there was room for it. On
    /// a device where showing it changed what the screen kept clear, each
    /// layout undid the other and the app never came to rest. A session
    /// hides the bar whatever the screen, and so the layout has nothing to
    /// say about it: the same screen always gives the same layout.
    @Test func theSameScreenAlwaysGivesTheSameLayout() {
        let screens: [(CGSize, Viewport.Insets, CGFloat)] = [
            (CGSize(width: 402, height: 874), insets(62, 0, 34, 0), 62),
            (CGSize(width: 874, height: 402), insets(0, 62, 20, 62), 0),
            (CGSize(width: 466, height: 678), insets(0, 0, 34, 84), 17.5),
            (CGSize(width: 951, height: 669), insets(0, 0, 34, 0), 16),
            (CGSize(width: 1032, height: 1376), insets(0, 0, 20, 0), 9.5),
        ]
        for (size, safeArea, cornerTop) in screens {
            let first = SessionChromeLayout(size: size, safeArea: safeArea, cornerTop: cornerTop)
            let again = SessionChromeLayout(size: size, safeArea: safeArea, cornerTop: cornerTop)
            #expect(first == again)
            // And the picture never takes less room than the safe area
            // would have given it below the top.
            #expect(first.pictureInsets.bottom == 0)
            #expect(first.pictureInsets.left == safeArea.left)
            #expect(first.pictureInsets.right == safeArea.right)
        }
    }

    // MARK: The controls

    @Test func theControlsStandInAStripThePictureCannotUse() {
        // An iPhone Duo's cover display keeps a strip clear down its right.
        let layout = SessionChromeLayout(size: CGSize(width: 466, height: 678), safeArea: insets(0, 0, 34, 84))
        #expect(layout.controls == .strip(CGRect(x: 382, y: 0, width: 84, height: 678)))
        #expect(layout.pictureInsets == insets(0, 0, 0, 84))
    }

    @Test func aStripOnTheLeftIsFoundToo() {
        let layout = SessionChromeLayout(size: CGSize(width: 466, height: 678), safeArea: insets(0, 84, 34, 0))
        #expect(layout.controls == .strip(CGRect(x: 0, y: 0, width: 84, height: 678)))
    }

    @Test func onItsSideThePhonesControlsTakeTheSideWithoutTheSensors() {
        let size = CGSize(width: 874, height: 402)
        let safeArea = insets(0, 62, 20, 62)
        let sensorsLeft = SessionChromeLayout(size: size, safeArea: safeArea, sensorSide: .left)
        #expect(sensorsLeft.controls == .strip(CGRect(x: 812, y: 0, width: 62, height: 402)))

        let sensorsRight = SessionChromeLayout(size: size, safeArea: safeArea, sensorSide: .right)
        #expect(sensorsRight.controls == .strip(CGRect(x: 0, y: 0, width: 62, height: 402)))

        // Not knowing which side they are on is no reason to cover the
        // picture.
        let unknown = SessionChromeLayout(size: size, safeArea: safeArea)
        #expect(unknown.controls == .strip(CGRect(x: 812, y: 0, width: 62, height: 402)))
        #expect(unknown.pictureInsets == insets(0, 62, 0, 62))
    }

    @Test func aStripTooNarrowOrTooShortIsNotUsed() {
        // The margins of an older phone on its side.
        let narrow = SessionChromeLayout(size: CGSize(width: 844, height: 390), safeArea: insets(0, 47, 21, 47))
        #expect(narrow.controls == .floating)

        let short = SessionChromeLayout(
            size: CGSize(width: 466, height: 200), safeArea: insets(0, 0, 34, 84))
        #expect(short.controls == .floating)
    }
}

@Suite("Hinge posture")
struct HingePostureTests {
    @Test func aClosedOrFlatDeviceIsNotALaptop() {
        #expect(!HingePosture.isLaptopLike(isPartiallyOpen: false, angle: 0))
        #expect(!HingePosture.isLaptopLike(isPartiallyOpen: false, angle: 100))
        #expect(!HingePosture.isLaptopLike(isPartiallyOpen: false, angle: 180))
    }

    @Test(arguments: [60.0, 75, 90, 110, 135])
    func halfOpenIsALaptop(degrees: Double) {
        #expect(HingePosture.isLaptopLike(isPartiallyOpen: true, angle: degrees))
    }

    @Test(arguments: [12.0, 40, 59, 136, 150, 165, 179])
    func nearlyShutOrNearlyFlatIsNot(degrees: Double) {
        // Held open with a slight bend, a device reports itself partially
        // open; that is someone holding a tablet, not using a laptop.
        #expect(!HingePosture.isLaptopLike(isPartiallyOpen: true, angle: degrees))
    }

    @Test func anAngleInRadiansIsUnderstood() {
        let upright = CGFloat.pi / 2
        let nearlyFlat = CGFloat.pi * 0.95
        #expect(HingePosture.isLaptopLike(isPartiallyOpen: true, angle: upright))
        #expect(!HingePosture.isLaptopLike(isPartiallyOpen: true, angle: nearlyFlat))
    }

    @Test func withoutAnAngleTheStatusDecides() {
        #expect(HingePosture.isLaptopLike(isPartiallyOpen: true, angle: 0))
        #expect(HingePosture.isLaptopLike(isPartiallyOpen: true, angle: .nan))
        #expect(HingePosture.isLaptopLike(isPartiallyOpen: true, angle: -1))
    }
}

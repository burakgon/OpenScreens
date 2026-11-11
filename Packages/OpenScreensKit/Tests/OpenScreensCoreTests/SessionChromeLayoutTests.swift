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
        #expect(!layout.showsStatusBar)
        #expect(layout.controls == .floating)
    }

    @Test func aScreenWithNothingInItsWayIsAllPicture() {
        // An iPhone Duo's inner display.
        let layout = SessionChromeLayout(size: CGSize(width: 951, height: 669), safeArea: insets(0, 0, 34, 0))
        #expect(layout.pictureInsets == .zero)
        #expect(layout.controls == .floating)
        #expect(!layout.showsStatusBar)
    }

    // MARK: The status bar

    @Test func theStatusBarIsShownWhereItHasAPlaceOfItsOwn() {
        let upright = SessionChromeLayout(size: CGSize(width: 402, height: 874), safeArea: insets(62, 0, 34, 0))
        #expect(upright.showsStatusBar)
        #expect(upright.controls == .floating)

        let cover = SessionChromeLayout(size: CGSize(width: 466, height: 678), safeArea: insets(0, 0, 34, 84))
        #expect(cover.showsStatusBar)

        // On its side, a phone keeps both sides clear and shows no status
        // bar in either.
        let sideways = SessionChromeLayout(size: CGSize(width: 874, height: 402), safeArea: insets(0, 62, 20, 62))
        #expect(!sideways.showsStatusBar)
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

    @Test func aStatusBarInTheStripKeepsItsPlace() {
        let layout = SessionChromeLayout(
            size: CGSize(width: 466, height: 678), safeArea: insets(0, 0, 34, 84),
            statusBar: CGRect(x: 382, y: 60, width: 84, height: 100))
        #expect(layout.controls == .strip(CGRect(x: 382, y: 160, width: 84, height: 518)))

        // One at the far end leaves the part above it.
        let low = SessionChromeLayout(
            size: CGSize(width: 466, height: 678), safeArea: insets(0, 0, 34, 84),
            statusBar: CGRect(x: 382, y: 600, width: 84, height: 78))
        #expect(low.controls == .strip(CGRect(x: 382, y: 0, width: 84, height: 600)))

        // One somewhere else on the screen changes nothing.
        let elsewhere = SessionChromeLayout(
            size: CGSize(width: 466, height: 678), safeArea: insets(0, 0, 34, 84),
            statusBar: CGRect(x: 0, y: 0, width: 300, height: 40))
        #expect(elsewhere.controls == .strip(CGRect(x: 382, y: 0, width: 84, height: 678)))
    }

    @Test func aStripTooNarrowOrTooShortIsNotUsed() {
        // The margins of an older phone on its side.
        let narrow = SessionChromeLayout(size: CGSize(width: 844, height: 390), safeArea: insets(0, 47, 21, 47))
        #expect(narrow.controls == .floating)

        let short = SessionChromeLayout(
            size: CGSize(width: 466, height: 300), safeArea: insets(0, 0, 34, 84),
            statusBar: CGRect(x: 382, y: 0, width: 84, height: 120))
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

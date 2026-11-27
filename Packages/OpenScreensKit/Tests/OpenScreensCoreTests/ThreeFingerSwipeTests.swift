import CoreGraphics
import Foundation
import Testing
@testable import OpenScreensCore

@Suite("Swipe direction")
struct SwipeDirectionTests {

    @Test func aFlickUpTheScreenIsUp() {
        // A view's own coordinates, where going up the screen is negative.
        #expect(SwipeDirection.resolve(translation: CGPoint(x: 4, y: -120)) == .up)
        #expect(SwipeDirection.resolve(translation: CGPoint(x: -4, y: 120)) == .down)
        #expect(SwipeDirection.resolve(translation: CGPoint(x: 120, y: 4)) == .right)
        #expect(SwipeDirection.resolve(translation: CGPoint(x: -120, y: -4)) == .left)
    }

    @Test func aMovementTooShortToHaveMeantAnythingIsNotASwipe() {
        #expect(SwipeDirection.resolve(translation: CGPoint(x: 0, y: -30)) == nil)
        #expect(SwipeDirection.resolve(translation: .zero) == nil)
    }

    @Test func aMovementNearTheDiagonalIsNotASwipeEither() {
        // Three fingers that went up and to the side said neither.
        #expect(SwipeDirection.resolve(translation: CGPoint(x: -90, y: -90)) == nil)
        #expect(SwipeDirection.resolve(translation: CGPoint(x: 70, y: -100)) == nil)
        // Past the ratio, and the longer way decides.
        #expect(SwipeDirection.resolve(translation: CGPoint(x: 60, y: -100)) == .up)
    }

    @Test func theRatioCanBeAskedFor() {
        let translation = CGPoint(x: 70, y: -100)
        #expect(SwipeDirection.resolve(translation: translation) == nil)
        #expect(SwipeDirection.resolve(translation: translation, straightness: 1.2) == .up)
    }
}

@Suite("Three-finger swipes")
struct ThreeFingerSwipeTests {

    @Test func movingThePictureSendsNothingToTheComputer() {
        for swipe in SwipeDirection.allCases {
            #expect(ThreeFingerSwipeAction.panPicture.shortcut(for: swipe, on: .mac) == nil)
        }
    }

    /// The four answers are the Mac's own defaults, and they are the same
    /// shortcuts the shortcut list already offers, so a swipe and a tap on
    /// the button for Mission Control cannot do two different things.
    @Test(arguments: [
        (SwipeDirection.up, "Mission Control"),
        (.down, "App Exposé"),
        (.left, "Next Space"),
        (.right, "Previous Space"),
    ])
    func aSwipeDoesWhatThreeFingersDoOnATrackpad(swipe: SwipeDirection, name: String) {
        let shortcut = ThreeFingerSwipeAction.macGestures.shortcut(for: swipe, on: .mac)
        #expect(shortcut?.name == name)
        #expect(shortcut?.modifiers == [.control])
        #expect(RemoteShortcut.builtIn(for: .mac).contains(where: { $0.id == shortcut?.id }))
    }

    @Test func aSwipeSendsNothingToAComputerThatIsNotAMac() {
        // What these keys mean somewhere else is not something to guess at.
        for kind in [ComputerKind.windows, .linux, .raspberryPi, .other] {
            #expect(ThreeFingerSwipeAction.macGestures.shortcut(for: .up, on: kind) == nil)
        }
    }

    @Test func anActionThisVersionDoesNotKnowStillMovesThePicture() throws {
        let decoded = try JSONDecoder().decode(
            [ThreeFingerSwipeAction].self,
            from: Data(#"["fourFingerPointers","macGestures"]"#.utf8))
        #expect(decoded == [.panPicture, .macGestures])
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import OpenScreensCore

@Suite("Device posture")
struct DevicePostureTests {

    @Test func aDeviceWithNothingToReportIsOpen() {
        #expect(DevicePosture.resolve(hingeIsClosed: false, hingeIsLaptopLike: false) == .open)
    }

    @Test func aHingeHeldLikeALaptopDecidesEvenAgainstBeingShut() {
        // The two are never both true in a real reading, but the answer must
        // not depend on which way a caller got there: half open is the
        // posture with something to do about the screen, so it wins.
        #expect(DevicePosture.resolve(hingeIsClosed: true, hingeIsLaptopLike: true) == .halfOpen)
        #expect(DevicePosture.resolve(hingeIsClosed: false, hingeIsLaptopLike: true) == .halfOpen)
    }

    @Test func aShutHingeIsFolded() {
        #expect(DevicePosture.resolve(hingeIsClosed: true, hingeIsLaptopLike: false) == .folded)
    }

    @Test func everyPostureIsNamedForASettingsScreen() {
        // Title case, because these are the words of a control.
        #expect(DevicePosture.allCases.map(\.title) == ["Folded", "Half Open", "Open"])
    }

    @Test func aPostureThisVersionDoesNotKnowIsReadAsOpen() throws {
        let decoded = try JSONDecoder().decode(
            [DevicePosture].self, from: Data(#"["tent","folded"]"#.utf8))
        #expect(decoded == [.open, .folded])
    }
}

@Suite("Waiting for a size to come to rest")
struct ResizeSettlerTests {

    @Test func theFirstSizeIsWaitedOnForTheSettlingTime() {
        var settler = ResizeSettler<CGSize>(settle: 0.3, deadline: 2)
        let delay = settler.delay(for: CGSize(width: 400, height: 800), at: 5)
        #expect(delay == 0.3)
    }

    @Test func theSameSizeAgainDoesNotStartAnotherWait() {
        var settler = ResizeSettler<CGSize>(settle: 0.3, deadline: 2)
        let size = CGSize(width: 400, height: 800)
        #expect(settler.delay(for: size, at: 5) == 0.3)
        // The canvas reports its size at every layout, most of them of a size
        // it has already reported.
        #expect(settler.delay(for: size, at: 5.05) == nil)
        #expect(settler.waitingFor == size)
    }

    @Test func aSizeThatChangesAgainIsWaitedOnFromThen() {
        var settler = ResizeSettler<CGSize>(settle: 0.3, deadline: 2)
        _ = settler.delay(for: CGSize(width: 400, height: 800), at: 5)
        let delay = settler.delay(for: CGSize(width: 500, height: 800), at: 5.1)
        #expect(delay == 0.3)
        #expect(settler.waitingFor == CGSize(width: 500, height: 800))
    }

    @Test func aSizeThatNeverHoldsStillIsStillAskedFor() {
        // Someone folding a device back and forth would otherwise never get a
        // desktop at all.
        var settler = ResizeSettler<CGSize>(settle: 0.3, deadline: 2)
        var time: TimeInterval = 0
        var changes = 0
        while let delay = settler.delay(
                for: CGSize(width: 400 + CGFloat(changes * 10), height: 800), at: time),
            delay > 0 {
            time += delay
            changes += 1
        }
        // A little past the deadline, by the last wait that had begun.
        #expect(time <= 2.3)
        #expect(changes >= 2)
    }

    @Test func aRunOfChangesThatEndsLeavesTheDeadlineForTheNextOne() {
        var settler = ResizeSettler<CGSize>(settle: 0.3, deadline: 1)
        _ = settler.delay(for: CGSize(width: 400, height: 800), at: 0)
        _ = settler.delay(for: CGSize(width: 500, height: 800), at: 0.9)
        // Past the deadline, so the next change is not waited on at all.
        #expect(settler.delay(for: CGSize(width: 600, height: 800), at: 1.2) == 0)
        settler.stopWaiting()
        #expect(settler.delay(for: CGSize(width: 700, height: 800), at: 1.4) == 0.3)
    }

    @Test func aRotateIsNotAFold() {
        // A rotation is one change of size, and it is worth waiting out: the
        // Mac rebuilds its display for that too.
        var settler = ResizeSettler<CGSize>(settle: 0.3, deadline: 2)
        #expect(settler.delay(for: CGSize(width: 400, height: 800), at: 0) == 0.3)
        settler.stopWaiting()
        #expect(settler.delay(for: CGSize(width: 800, height: 400), at: 0.3) == 0.3)
    }
}

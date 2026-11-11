import CoreGraphics
import Testing
@testable import OpenScreensCore

@Suite("Display arrangement")
struct DisplayArrangementTests {
    private let left = CGRect(x: 0, y: 0, width: 2048, height: 2400)
    private let right = CGRect(x: 2048, y: 0, width: 2048, height: 2400)

    // MARK: One display

    @Test func oneDisplayIsThePicture() {
        let arrangement = DisplayArrangement(size: CGSize(width: 2560, height: 1600))
        #expect(arrangement.size == CGSize(width: 2560, height: 1600))
        #expect(arrangement.frames == [CGRect(x: 0, y: 0, width: 2560, height: 1600)])
        #expect(arrangement.remotePoint(for: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 0))
        #expect(arrangement.remotePoint(for: CGPoint(x: 1234.5, y: 999.25)) == CGPoint(x: 1234.5, y: 999.25))
        #expect(arrangement.remotePoint(for: CGPoint(x: 2560, y: 1600)) == CGPoint(x: 2560, y: 1600))
    }

    @Test func aPointPastTheEdgeOfOneDisplayIsBroughtBackToIt() {
        let arrangement = DisplayArrangement(size: CGSize(width: 2560, height: 1600))
        #expect(arrangement.remotePoint(for: CGPoint(x: -40, y: 800)) == CGPoint(x: 0, y: 800))
        #expect(arrangement.remotePoint(for: CGPoint(x: 3000, y: 1700)) == CGPoint(x: 2560, y: 1600))
    }

    @Test func nothingToShowLeavesPointsAlone() {
        let arrangement = DisplayArrangement(remote: [])
        #expect(arrangement.size == .zero)
        #expect(arrangement.frames.isEmpty)
        #expect(arrangement.index(at: CGPoint(x: 5, y: 5)) == nil)
        #expect(arrangement.remotePoint(for: CGPoint(x: 5, y: 5)) == CGPoint(x: 5, y: 5))
    }

    // MARK: Side by side

    @Test func sideBySideIsTheRemoteDesktopAsItIs() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .sideBySide)
        #expect(arrangement.size == CGSize(width: 4096, height: 2400))
        #expect(arrangement.frames == [left, right])
        for point in [CGPoint(x: 10, y: 20), CGPoint(x: 2047.5, y: 2399), CGPoint(x: 2048, y: 0),
                      CGPoint(x: 3072, y: 1200), CGPoint(x: 4096, y: 2400)] {
            #expect(arrangement.remotePoint(for: point) == point)
        }
    }

    @Test func theSeamBelongsToTheDisplayThatStartsThere() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .sideBySide)
        #expect(arrangement.index(at: CGPoint(x: 2047.999, y: 100)) == 0)
        #expect(arrangement.index(at: CGPoint(x: 2048, y: 100)) == 1)
        #expect(arrangement.index(at: CGPoint(x: 4096, y: 100)) == 1)
    }

    /// The engine may report displays where the remote desktop has them,
    /// away from its origin. The picture still starts at its own corner.
    @Test func aDesktopThatDoesNotStartAtZeroIsShownFromItsCorner() {
        let first = CGRect(x: 100, y: 50, width: 800, height: 600)
        let second = CGRect(x: 900, y: 50, width: 800, height: 600)
        let arrangement = DisplayArrangement(remote: [first, second], axis: .sideBySide)
        #expect(arrangement.size == CGSize(width: 1600, height: 600))
        #expect(arrangement.frames == [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600),
        ])
        #expect(arrangement.remotePoint(for: CGPoint(x: 10, y: 10)) == CGPoint(x: 110, y: 60))
        #expect(arrangement.remotePoint(for: CGPoint(x: 810, y: 10)) == CGPoint(x: 910, y: 60))
    }

    // MARK: Stacked

    @Test func stackedPutsTheSecondDisplayBelowTheFirst() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        #expect(arrangement.size == CGSize(width: 2048, height: 4800))
        #expect(arrangement.frames == [
            CGRect(x: 0, y: 0, width: 2048, height: 2400),
            CGRect(x: 0, y: 2400, width: 2048, height: 2400),
        ])
    }

    @Test func aPointInTheUpperDisplayIsItself() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        #expect(arrangement.remotePoint(for: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 0))
        #expect(arrangement.remotePoint(for: CGPoint(x: 1024, y: 1200)) == CGPoint(x: 1024, y: 1200))
        #expect(arrangement.remotePoint(for: CGPoint(x: 2047, y: 2399.5)) == CGPoint(x: 2047, y: 2399.5))
    }

    /// The lower display is the one the remote Mac has on the right.
    @Test func aPointInTheLowerDisplayIsSentToTheDisplayOnTheRight() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        #expect(arrangement.remotePoint(for: CGPoint(x: 0, y: 2400)) == CGPoint(x: 2048, y: 0))
        #expect(arrangement.remotePoint(for: CGPoint(x: 1024, y: 3600)) == CGPoint(x: 3072, y: 1200))
        #expect(arrangement.remotePoint(for: CGPoint(x: 2047, y: 4799)) == CGPoint(x: 4095, y: 2399))
    }

    @Test func theBottomEdgeOfThePictureIsTheBottomOfTheLowerDisplay() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        #expect(arrangement.index(at: CGPoint(x: 100, y: 4800)) == 1)
        #expect(arrangement.remotePoint(for: CGPoint(x: 100, y: 4800)) == CGPoint(x: 2148, y: 2400))
        #expect(arrangement.remotePoint(for: CGPoint(x: 100, y: 9999)) == CGPoint(x: 2148, y: 2400))
    }

    /// Dragging off the right edge of the upper display must not land in
    /// the other one, which the remote Mac has right there.
    @Test func aPointBesideADisplayStaysInThatDisplay() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        #expect(arrangement.remotePoint(for: CGPoint(x: 2500, y: 1000)) == CGPoint(x: 2048, y: 1000))
        #expect(arrangement.remotePoint(for: CGPoint(x: -30, y: 3000)) == CGPoint(x: 2048, y: 600))
    }

    @Test func aNarrowerDisplayIsCentredInItsRow() {
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let narrow = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let arrangement = DisplayArrangement(remote: [wide, narrow], axis: .stacked)
        #expect(arrangement.size == CGSize(width: 2000, height: 1800))
        #expect(arrangement.frames[1] == CGRect(x: 500, y: 1000, width: 1000, height: 800))
        // Inside it.
        #expect(arrangement.remotePoint(for: CGPoint(x: 600, y: 1100)) == CGPoint(x: 2100, y: 100))
        // In the margin beside it, the nearest display decides: just below
        // the wide one that is its bottom edge,
        #expect(arrangement.remotePoint(for: CGPoint(x: 200, y: 1100)) == CGPoint(x: 200, y: 1000))
        // and further down it is the narrow one's side.
        #expect(arrangement.remotePoint(for: CGPoint(x: 200, y: 1700)) == CGPoint(x: 2000, y: 700))
        #expect(arrangement.remotePoint(for: CGPoint(x: 1900, y: 1700)) == CGPoint(x: 3000, y: 700))
    }

    // MARK: Rectangles

    @Test func aRectangleInOneDisplayIsItself() {
        let arrangement = DisplayArrangement(size: CGSize(width: 2560, height: 1600))
        let rect = CGRect(x: 1000, y: 40, width: 560, height: 120)
        #expect(arrangement.remoteRect(for: rect) == rect)
    }

    @Test func aRectangleInTheLowerDisplayIsInTheDisplayOnTheRight() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        let rect = CGRect(x: 700, y: 2500, width: 600, height: 100)
        #expect(arrangement.remoteRect(for: rect) == CGRect(x: 2748, y: 100, width: 600, height: 100))
    }

    /// Across the seam of two stacked displays there is no one rectangle of
    /// the remote desktop; what is kept is the part in the display that
    /// holds the middle.
    @Test func aRectangleOverTwoDisplaysIsCutToTheOneItsMiddleIsIn() {
        let arrangement = DisplayArrangement(remote: [left, right], axis: .stacked)
        let mostlyUpper = CGRect(x: 100, y: 2300, width: 400, height: 150)
        #expect(arrangement.remoteRect(for: mostlyUpper) == CGRect(x: 100, y: 2300, width: 400, height: 100))
        let mostlyLower = CGRect(x: 100, y: 2350, width: 400, height: 150)
        #expect(arrangement.remoteRect(for: mostlyLower) == CGRect(x: 2148, y: 0, width: 400, height: 100))
    }

    @Test func aRectangleOffThePictureIsCutToWhatIsShown() {
        let arrangement = DisplayArrangement(size: CGSize(width: 2560, height: 1600))
        #expect(arrangement.remoteRect(for: CGRect(x: -100, y: -50, width: 300, height: 200))
            == CGRect(x: 0, y: 0, width: 200, height: 150))
        #expect(arrangement.remoteRect(for: CGRect(x: 3000, y: 100, width: 50, height: 50)) == nil)
        #expect(DisplayArrangement(remote: []).remoteRect(for: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
    }

    /// Every point of the picture that is inside a display comes back inside
    /// that display's part of the remote desktop.
    @Test func everyPointLandsInTheDisplayItWasIn() {
        for axis in [DisplayArrangement.Axis.sideBySide, .stacked] {
            let arrangement = DisplayArrangement(remote: [left, right], axis: axis)
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<500 {
                let point = CGPoint(
                    x: CGFloat.random(in: 0..<arrangement.size.width, using: &generator),
                    y: CGFloat.random(in: 0..<arrangement.size.height, using: &generator))
                guard let index = arrangement.index(at: point) else {
                    Issue.record("no display at \(point)")
                    continue
                }
                let remote = arrangement.remotePoint(for: point)
                let region = arrangement.remote[index]
                #expect(region.minX <= remote.x && remote.x <= region.maxX)
                #expect(region.minY <= remote.y && remote.y <= region.maxY)
                // The offset inside the display is kept.
                let frame = arrangement.frames[index]
                #expect(abs((remote.x - region.minX) - (point.x - frame.minX)) < 1e-9)
                #expect(abs((remote.y - region.minY) - (point.y - frame.minY)) < 1e-9)
            }
        }
    }
}

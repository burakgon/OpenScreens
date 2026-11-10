import CoreGraphics
import Foundation
import Testing
@testable import OpenScreensCore

@Suite("Display layout")
struct DisplayLayoutTests {

    @Test func oneDisplayIsSizedForTheWholeView() {
        let view = CGSize(width: 1280, height: 748)
        #expect(DisplayLayout.single.room(forOneDisplayIn: view) == view)
        #expect(DisplayLayout.allCombined.room(forOneDisplayIn: view) == view)
    }

    /// Side by side, two displays of half the width fill a wide view exactly.
    @Test func twoDisplaysShareAWideView() {
        let room = DisplayLayout.twoVirtual.room(forOneDisplayIn: CGSize(width: 1280, height: 748))
        #expect(room == CGSize(width: 640, height: 748))
    }

    @Test func anOddWidthIsRoundedDownSoTheTwoStillFit() {
        let room = DisplayLayout.twoVirtual.room(forOneDisplayIn: CGSize(width: 1281, height: 748))
        #expect(room == CGSize(width: 640, height: 748))
        #expect(room.width * 2 <= 1281)
    }

    /// Half of a phone held upright is too narrow to be a desktop; each
    /// display takes the whole view and zooming in shows one at a time.
    @Test func twoDisplaysEachGetAllOfATallView() {
        let view = CGSize(width: 402, height: 874)
        #expect(DisplayLayout.twoVirtual.room(forOneDisplayIn: view) == view)
    }

    @Test func aSquareViewCountsAsWide() {
        let room = DisplayLayout.twoVirtual.room(forOneDisplayIn: CGSize(width: 900, height: 900))
        #expect(room == CGSize(width: 450, height: 900))
    }

    @Test func aLayoutThisVersionDoesNotKnowIsReadAsOneDisplay() throws {
        let decoded = try JSONDecoder().decode([DisplayLayout].self, from: Data(#"["threeVirtual","twoVirtual"]"#.utf8))
        #expect(decoded == [.single, .twoVirtual])
    }
}

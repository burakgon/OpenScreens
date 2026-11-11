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

    /// Halves of a phone held upright would be two slivers side by side.
    /// One above the other, each display is the full width.
    @Test func twoDisplaysShareATallViewOneAboveTheOther() {
        let view = CGSize(width: 402, height: 875)
        #expect(DisplayLayout.twoVirtual.axis(in: view) == .stacked)
        #expect(DisplayLayout.twoVirtual.room(forOneDisplayIn: view) == CGSize(width: 402, height: 437))
    }

    @Test func onlyTwoVirtualDisplaysAreEverStacked() {
        let view = CGSize(width: 402, height: 874)
        #expect(DisplayLayout.single.axis(in: view) == .sideBySide)
        #expect(DisplayLayout.allCombined.axis(in: view) == .sideBySide)
        #expect(DisplayLayout.twoVirtual.axis(in: CGSize(width: 1280, height: 748)) == .sideBySide)
    }

    @Test func aSquareViewCountsAsWide() {
        let view = CGSize(width: 900, height: 900)
        #expect(DisplayLayout.twoVirtual.axis(in: view) == .sideBySide)
        #expect(DisplayLayout.twoVirtual.room(forOneDisplayIn: view) == CGSize(width: 450, height: 900))
    }

    @Test func aLayoutThisVersionDoesNotKnowIsReadAsOneDisplay() throws {
        let decoded = try JSONDecoder().decode([DisplayLayout].self, from: Data(#"["threeVirtual","twoVirtual"]"#.utf8))
        #expect(decoded == [.single, .twoVirtual])
    }
}

@Suite("Desktop size on a small screen")
struct DesktopSizeTests {

    @Test func aDesktopIsSizedForTheScreenUnlessMoreSpaceIsAskedFor() {
        // Wide enough for the widest window that cannot be made narrower,
        // and no wider: on a phone every extra point is smaller text and
        // more to send.
        #expect(ConnectionSettings().minimumDesktopSize == CGSize(width: 720, height: 600))
        #expect(!ConnectionSettings().moreSpace)
        #expect(ConnectionSettings(moreSpace: true).minimumDesktopSize == CGSize(width: 1024, height: 600))
    }

    @Test func theChoiceIsKeptWithTheComputer() throws {
        var settings = ConnectionSettings()
        settings.moreSpace = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ConnectionSettings.self, from: data).moreSpace)
    }

    @Test func aRecordFromBeforeTheChoiceExistedMeansTheDefault() throws {
        let old = Data(#"{"quality":"highPerformance","resolution":"matchWindow","displays":"single"}"#.utf8)
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: old)
        #expect(!settings.moreSpace)
        #expect(settings.minimumDesktopSize == CGSize(width: 720, height: 600))
    }
}

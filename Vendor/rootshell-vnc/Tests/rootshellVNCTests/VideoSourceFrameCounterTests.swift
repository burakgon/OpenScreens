import XCTest
@testable import rootshellVNC

final class VideoSourceFrameCounterTests: XCTestCase {
    /// A picture's tiles are separate sources and only the changed ones are
    /// sent, so a display's frame count is what its busiest source gained.
    func testFramesAreTheMostAnyOneSourceGained() {
        let earlier: [[UInt32: UInt64]] = [[1: 100, 2: 100, 3: 100, 4: 100], [9: 40]]
        let later: [[UInt32: UInt64]] = [[1: 160, 2: 130, 3: 100, 4: 115], [9: 70]]
        XCTAssertEqual(VideoSourceFrameCounter.frames(from: earlier, to: later), [60, 30])
    }

    func testASourceThatAppearedBetweenSnapshotsCountsFromNothing() {
        let earlier: [[UInt32: UInt64]] = [[1: 500], [:]]
        let later: [[UInt32: UInt64]] = [[7: 25], [8: 12]]
        XCTAssertEqual(VideoSourceFrameCounter.frames(from: earlier, to: later), [25, 12])
    }

    func testNothingDecodedIsNoFrames() {
        XCTAssertEqual(VideoSourceFrameCounter.frames(from: [[:], [:]], to: [[:], [:]]), [0, 0])
        XCTAssertEqual(VideoSourceFrameCounter.frames(from: [], to: [[3: 4], [:]]), [4, 0])
    }

    func testRecordsByDisplayAndSource() {
        let counter = VideoSourceFrameCounter()
        counter.record(1, display: 0)
        counter.record(1, display: 0)
        counter.record(2, display: 0)
        counter.record(5, display: 1)
        counter.record(5, display: 7) // no such display
        XCTAssertEqual(counter.snapshot(), [[1: 2, 2: 1], [5: 1]])
    }
}

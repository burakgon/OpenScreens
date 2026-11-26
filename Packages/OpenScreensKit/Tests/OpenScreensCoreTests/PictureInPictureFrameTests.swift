import CoreGraphics
import Testing
@testable import OpenScreensCore

/// What the remote screen is drawn at for Picture in Picture.
struct PictureInPictureFrameTests {
    @Test func aLargeDesktopIsScaledDownToFit() throws {
        let size = try #require(PictureInPictureFrame.pixelSize(for: CGSize(width: 3024, height: 1964)))
        #expect(size == CGSize(width: 1280, height: 832))
    }

    @Test func aTallScreenIsBoundedByItsHeight() throws {
        let size = try #require(PictureInPictureFrame.pixelSize(for: CGSize(width: 1080, height: 1920)))
        #expect(size == CGSize(width: 720, height: 1280))
    }

    @Test func aSmallScreenIsNeverScaledUp() throws {
        let size = try #require(PictureInPictureFrame.pixelSize(for: CGSize(width: 800, height: 600)))
        #expect(size == CGSize(width: 800, height: 600))
    }

    @Test func dimensionsComeOutEven() throws {
        let size = try #require(PictureInPictureFrame.pixelSize(for: CGSize(width: 1023, height: 767)))
        #expect(size.width.truncatingRemainder(dividingBy: 2) == 0)
        #expect(size.height.truncatingRemainder(dividingBy: 2) == 0)
    }

    @Test func aScreenWithNoPictureHasNoFrame() {
        #expect(PictureInPictureFrame.pixelSize(for: .zero) == nil)
        #expect(PictureInPictureFrame.pixelSize(for: CGSize(width: 1280, height: 0)) == nil)
    }
}

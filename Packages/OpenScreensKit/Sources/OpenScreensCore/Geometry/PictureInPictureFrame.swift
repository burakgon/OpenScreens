import CoreGraphics

/// The size the remote screen is drawn at for Picture in Picture.
///
/// The window it is shown in is a small one, so a desktop is scaled down
/// to fit a bounded frame first: there is no use in converting five million
/// pixels a frame for a window a few hundred points wide. A screen already
/// smaller than that is kept as it is, and never scaled up.
public enum PictureInPictureFrame {
    /// The longest side of a frame, in pixels.
    public static let longestSide: CGFloat = 1280

    /// The size, in whole pixels, to draw a screen of `size` at. Nil for a
    /// screen with no picture yet.
    public static func pixelSize(for size: CGSize, longestSide: CGFloat = longestSide) -> CGSize? {
        guard size.width >= 1, size.height >= 1, longestSide >= 1 else { return nil }
        let scale = min(1, longestSide / max(size.width, size.height))
        // Video surfaces want even dimensions.
        func even(_ length: CGFloat) -> CGFloat {
            max(2, (length * scale / 2).rounded() * 2)
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

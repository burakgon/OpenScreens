import CoreGraphics
import Foundation

/// Maps between a local view and the remote screen shown inside it.
///
/// The viewport owns zoom and pan. Both remote canvases — AppKit and UIKit —
/// lay the picture out with ``contentRect`` and translate input with
/// ``remotePoint(for:)``, so what the user points at is always what gets
/// clicked, at any zoom level and in every scaling mode.
public struct Viewport: Equatable, Sendable {

    /// Space inside the view that the picture should stay clear of, such as
    /// the on-screen keyboard.
    public struct Insets: Equatable, Sendable {
        public var top: CGFloat
        public var left: CGFloat
        public var bottom: CGFloat
        public var right: CGFloat

        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public static let zero = Insets()
    }

    /// Size of the local view, in points.
    public var viewSize: CGSize {
        didSet { if viewSize != oldValue { clampOffset() } }
    }

    /// Size of the remote screen, in remote pixels.
    public var contentSize: CGSize {
        didSet { if contentSize != oldValue { clampOffset() } }
    }

    /// Local pixels per point.
    public var backingScale: CGFloat {
        didSet { if backingScale != oldValue { clampOffset() } }
    }

    public var scaling: ScalingMode {
        didSet {
            guard scaling != oldValue else { return }
            magnification = 1
            offset = .zero
        }
    }

    public var insets: Insets {
        didSet { if insets != oldValue { clampOffset() } }
    }

    /// How much of the bottom of the usable area something has come to
    /// cover for a while: an on-screen keyboard, a trackpad deck.
    ///
    /// The picture is not made smaller for it. A desktop shrunk to what is
    /// left above a keyboard is too small to read what is being typed. It
    /// keeps the size it has with nothing in the way, and moves so that any
    /// part of it can be brought into what is left: ``visibleRect``.
    public var bottomCover: CGFloat = 0 {
        didSet { if bottomCover != oldValue { clampOffset() } }
    }

    /// Zoom applied on top of the scaling mode. 1 means "as the mode lays it out".
    public private(set) var magnification: CGFloat = 1

    /// How far the centre of the picture sits from the centre of the usable
    /// area, in points.
    public private(set) var offset: CGSize = .zero

    public static let maximumScale: CGFloat = 8

    public init(
        viewSize: CGSize = .zero,
        contentSize: CGSize = .zero,
        backingScale: CGFloat = 2,
        scaling: ScalingMode = .fit,
        insets: Insets = .zero
    ) {
        self.viewSize = viewSize
        self.contentSize = contentSize
        self.backingScale = backingScale
        self.scaling = scaling
        self.insets = insets
    }

    // MARK: - Layout

    public var isReady: Bool {
        usableRect.width > 0 && usableRect.height > 0
            && contentSize.width > 0 && contentSize.height > 0
    }

    /// The part of the view the picture is laid out in.
    public var usableRect: CGRect {
        CGRect(
            x: insets.left,
            y: insets.top,
            width: max(0, viewSize.width - insets.left - insets.right),
            height: max(0, viewSize.height - insets.top - insets.bottom))
    }

    /// The part of the usable area that nothing covers.
    public var visibleRect: CGRect {
        let usable = usableRect
        let cover = min(max(0, bottomCover), usable.height)
        return CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: usable.height - cover)
    }

    /// Points per remote pixel when the whole screen is visible.
    public var fitScale: CGFloat {
        guard isReady else { return 1 }
        return min(usableRect.width / contentSize.width, usableRect.height / contentSize.height)
    }

    /// Points per remote pixel for the scaling mode, before any zoom.
    public var baseScale: CGFloat {
        guard isReady else { return 1 }
        switch scaling {
        case .fit:
            return fitScale
        case .fill:
            return max(usableRect.width / contentSize.width, usableRect.height / contentSize.height)
        case .actualSize:
            return 1 / max(1, backingScale)
        }
    }

    /// Points per remote pixel as currently displayed.
    public var scale: CGFloat {
        baseScale * magnification
    }

    /// The smallest zoom allowed: never smaller than the whole screen.
    public var minimumMagnification: CGFloat {
        guard isReady, baseScale > 0 else { return 1 }
        return min(1, fitScale / baseScale)
    }

    public var maximumMagnification: CGFloat {
        guard isReady, baseScale > 0 else { return 1 }
        // Always leave room to zoom in, even on a display already above the cap.
        return max(1, Viewport.maximumScale / baseScale, 2 * minimumMagnification)
    }

    /// Where the remote screen is drawn, in view coordinates.
    public var contentRect: CGRect {
        guard isReady else { return .zero }
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let usable = usableRect
        return CGRect(
            x: usable.midX - size.width / 2 + offset.width,
            y: usable.midY - size.height / 2 + offset.height,
            width: size.width,
            height: size.height)
    }

    /// Whether the user has zoomed or panned away from the default layout.
    public var isTransformed: Bool {
        abs(magnification - 1) > 0.001 || abs(offset.width) > 0.5 || abs(offset.height) > 0.5
    }

    /// Whether part of the remote screen is outside what can be seen of
    /// the view.
    public var isCropped: Bool {
        guard isReady else { return false }
        let rect = contentRect
        let visible = visibleRect
        return rect.width > visible.width + 0.5 || rect.height > visible.height + 0.5
    }

    // MARK: - Coordinate conversion

    /// The remote pixel under a point in the view.
    ///
    /// - Parameter clamped: Pin points outside the picture to its nearest
    ///   edge instead of returning `nil`. Drags that leave the picture should
    ///   keep tracking along its border.
    public func remotePoint(for viewPoint: CGPoint, clamped: Bool = true) -> CGPoint? {
        guard isReady else { return nil }
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        var x = (viewPoint.x - rect.minX) / scale
        var y = (viewPoint.y - rect.minY) / scale
        let maxX = contentSize.width - 1
        let maxY = contentSize.height - 1
        if clamped {
            x = min(max(0, x), maxX)
            y = min(max(0, y), maxY)
        } else if x < 0 || y < 0 || x > contentSize.width || y > contentSize.height {
            return nil
        }
        return CGPoint(x: min(x, maxX), y: min(y, maxY))
    }

    /// Where a remote pixel is drawn in the view.
    public func viewPoint(for remotePoint: CGPoint) -> CGPoint {
        let rect = contentRect
        return CGPoint(x: rect.minX + remotePoint.x * scale, y: rect.minY + remotePoint.y * scale)
    }

    // MARK: - Zoom and pan

    /// Zooms by `factor`, keeping the remote pixel under `anchor` where it is.
    public mutating func magnify(by factor: CGFloat, around anchor: CGPoint) {
        guard isReady, factor.isFinite, factor > 0 else { return }
        let target = min(max(magnification * factor, minimumMagnification), maximumMagnification)
        setMagnification(target, around: anchor)
    }

    public mutating func setMagnification(_ value: CGFloat, around anchor: CGPoint) {
        guard isReady, value.isFinite, value > 0 else { return }
        let clampedValue = min(max(value, minimumMagnification), maximumMagnification)
        guard let pinned = remotePoint(for: anchor, clamped: false)
                ?? remotePoint(for: CGPoint(x: usableRect.midX, y: usableRect.midY)) else { return }
        let reference = remotePoint(for: anchor, clamped: false) == nil
            ? CGPoint(x: usableRect.midX, y: usableRect.midY)
            : anchor
        magnification = clampedValue
        // Move the picture so the pinned pixel lands back under the anchor.
        let moved = viewPoint(for: pinned)
        offset.width += reference.x - moved.x
        offset.height += reference.y - moved.y
        clampOffset()
    }

    public mutating func pan(by translation: CGSize) {
        guard isReady else { return }
        offset.width += translation.width
        offset.height += translation.height
        clampOffset()
    }

    /// Returns to the scaling mode's default layout.
    public mutating func reset() {
        magnification = 1
        offset = .zero
    }

    /// Pans as little as needed to bring a remote pixel into view, keeping
    /// `margin` points between it and the edge when there is room.
    /// - Returns: `true` when the viewport moved.
    @discardableResult
    public mutating func reveal(_ remotePoint: CGPoint, margin: CGFloat = 0) -> Bool {
        guard isReady else { return false }
        let visible = visibleRect
        let inset = min(margin, min(visible.width, visible.height) / 3)
        let target = visible.insetBy(dx: inset, dy: inset)
        let point = viewPoint(for: remotePoint)
        var delta = CGSize.zero
        if point.x < target.minX {
            delta.width = target.minX - point.x
        } else if point.x > target.maxX {
            delta.width = target.maxX - point.x
        }
        if point.y < target.minY {
            delta.height = target.minY - point.y
        } else if point.y > target.maxY {
            delta.height = target.maxY - point.y
        }
        guard delta != .zero else { return false }
        let before = offset
        pan(by: delta)
        return offset != before
    }

    /// Keeps the picture from being dragged away from the view: an axis that
    /// fits is centred, and one that does not can only pan as far as its edges.
    ///
    /// Down the screen, "fits" means fits in what nothing covers. A picture
    /// taller than that pans until its last line clears the cover, however
    /// well it fits the view when the cover is gone.
    public mutating func clampOffset() {
        guard isReady else {
            offset = .zero
            return
        }
        magnification = min(max(magnification, minimumMagnification), maximumMagnification)
        let usable = usableRect
        let visible = visibleRect
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        let limitX = max(0, (width - usable.width) / 2)
        offset.width = min(max(offset.width, -limitX), limitX)
        // The offset is counted from the middle of the usable area.
        if height <= visible.height {
            offset.height = visible.midY - usable.midY
        } else {
            let bottomAtTheCover = visible.maxY - (usable.midY + height / 2)
            let topAtTheTop = visible.minY - (usable.midY - height / 2)
            offset.height = min(max(offset.height, bottomAtTheCover), topAtTheTop)
        }
    }
}

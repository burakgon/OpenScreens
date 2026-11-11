import CoreGraphics

/// Where each remote display is drawn in the picture, and which remote pixel
/// a point of the picture stands for.
///
/// A remote Mac puts a second virtual display to the right of the first. A
/// wide view shows them that way. A tall one shows the second below the
/// first instead, so both are large enough to work in; the remote desktop is
/// unchanged, and a point in the lower display is sent as the point it is in
/// the display to the right.
public struct DisplayArrangement: Equatable, Sendable {
    public enum Axis: Equatable, Sendable {
        /// Beside each other, as the remote computer has them.
        case sideBySide
        /// One above the other.
        case stacked
    }

    /// Each display's place in the remote desktop, in remote pixels.
    public let remote: [CGRect]
    /// Each display's place in the picture, in the same units.
    public let frames: [CGRect]
    /// Size of the picture: the smallest rectangle that holds every frame.
    public let size: CGSize

    public init(remote: [CGRect], axis: Axis = .sideBySide) {
        self.remote = remote
        guard let first = remote.first else {
            frames = []
            size = .zero
            return
        }
        switch axis {
        case .sideBySide:
            let union = remote.dropFirst().reduce(first) { $0.union($1) }
            frames = remote.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
            size = union.size
        case .stacked:
            let width = remote.reduce(0) { max($0, $1.width) }
            var placed: [CGRect] = []
            var top: CGFloat = 0
            for region in remote {
                // A narrower display sits in the middle of its row.
                placed.append(CGRect(
                    x: ((width - region.width) / 2).rounded(.down), y: top,
                    width: region.width, height: region.height))
                top += region.height
            }
            frames = placed
            size = CGSize(width: width, height: top)
        }
    }

    /// One display filling the picture.
    public init(size: CGSize) {
        self.init(remote: [CGRect(origin: .zero, size: size)])
    }

    /// The remote pixel shown at a point of the picture.
    ///
    /// A point outside every display, in the margin beside a narrower one or
    /// past the picture's edge, counts as the nearest point of the nearest
    /// display.
    public func remotePoint(for point: CGPoint) -> CGPoint {
        guard let index = index(at: point) else { return point }
        let frame = frames[index]
        let region = remote[index]
        return CGPoint(
            x: region.minX + min(max(0, point.x - frame.minX), frame.width),
            y: region.minY + min(max(0, point.y - frame.minY), frame.height))
    }

    /// The part of the remote desktop shown in a rectangle of the picture.
    ///
    /// A rectangle that lies over two displays is cut down to the one its
    /// middle is in: beside each other in the picture is not always beside
    /// each other on the remote desktop, so nothing wider would be one
    /// rectangle there. Nil when none of it is over a display.
    public func remoteRect(for rect: CGRect) -> CGRect? {
        guard let index = index(at: CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        let frame = frames[index]
        let shown = rect.intersection(frame)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return nil }
        let region = remote[index]
        return CGRect(
            x: region.minX + shown.minX - frame.minX,
            y: region.minY + shown.minY - frame.minY,
            width: shown.width, height: shown.height)
    }

    /// Which display a point of the picture belongs to. Where two meet, the
    /// edge belongs to the one that starts there.
    public func index(at point: CGPoint) -> Int? {
        if let inside = frames.firstIndex(where: {
            $0.minX <= point.x && point.x < $0.maxX && $0.minY <= point.y && point.y < $0.maxY
        }) {
            return inside
        }
        var nearest: Int?
        var shortest = CGFloat.infinity
        for (index, frame) in frames.enumerated() {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            // On a tie the later display wins: a point on the picture's far
            // edge is then in the display that ends there.
            if distance <= shortest {
                shortest = distance
                nearest = index
            }
        }
        return nearest
    }
}

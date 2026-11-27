import CoreGraphics

/// Which way a movement of the fingers across the screen went.
public enum SwipeDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case up, down, left, right

    public var id: Self { self }

    /// The direction a movement counts as, when it counts as one at all.
    ///
    /// A swipe is what someone meant when the hand went one way a good deal
    /// more than the other, so a movement near the diagonal is not a swipe in
    /// any direction, and neither is one too short to have been anything but
    /// a slip.
    ///
    /// - Parameter translation: How far the fingers travelled, in a view's own
    ///   coordinates, where a negative y is a movement up the screen.
    public static func resolve(
        translation: CGPoint,
        minimumTravel: CGFloat = 40,
        straightness: CGFloat = 1.5
    ) -> SwipeDirection? {
        let x = abs(translation.x)
        let y = abs(translation.y)
        guard max(x, y) >= minimumTravel else { return nil }
        guard max(x, y) >= min(x, y) * straightness else { return nil }
        if x > y { return translation.x > 0 ? .right : .left }
        return translation.y > 0 ? .down : .up
    }
}

/// What a three-finger swipe over the remote screen does.
///
/// Three fingers are the one gesture with nothing else asking for them: a
/// finger taps and clicks, two fingers scroll and zoom. So they are either
/// left to moving the picture about, or given to the Mac, which answers three
/// fingers on its own trackpad with a system gesture.
public enum ThreeFingerSwipeAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Slide the picture around, which is what it has always done.
    case panPicture
    /// Do on the Mac what three fingers do on a Mac's trackpad.
    case macGestures

    public var id: Self { self }

    public var title: String {
        switch self {
        case .panPicture: "Move the Picture"
        case .macGestures: "Mac Gestures"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreeFingerSwipeAction(rawValue: raw) ?? .panPicture
    }

    /// The key combination a swipe stands for, or nil when the swipe is not
    /// something to send.
    ///
    /// A Mac answers these with its own settings, which is why they are keys
    /// and not a gesture of their own: Screen Sharing has no way to say
    /// "Mission Control" to a Mac that has moved it off ⌃↑.
    public func shortcut(for swipe: SwipeDirection, on kind: ComputerKind) -> RemoteShortcut? {
        guard self == .macGestures, kind.isApple else { return nil }
        return RemoteShortcut.macSystemGesture(for: swipe)
    }
}

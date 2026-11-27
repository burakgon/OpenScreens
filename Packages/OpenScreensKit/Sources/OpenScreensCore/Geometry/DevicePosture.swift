import CoreGraphics

/// How a folding phone is being held, which is what the shape of the desktop
/// and the place of the controls are chosen from.
///
/// A posture is not the hinge. A hinge reports an angle that moves with every
/// shift of a hand, and on a system before iOS 27.1 reports nothing at all,
/// while what the interface wants is one of three ways of holding the device
/// that a person would name out loud.
public enum DevicePosture: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    /// Shut, with the session on the screen outside: half a phone's worth of
    /// picture, held in one hand.
    case folded
    /// Open the way a laptop is, one half of the screen flat and the other
    /// standing. The half that lies flat can be given to the controls.
    case halfOpen
    /// Open flat, and every phone and tablet that does not fold.
    case open

    public var id: Self { self }

    public var title: String {
        switch self {
        case .folded: "Folded"
        case .halfOpen: "Half Open"
        case .open: "Open"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DevicePosture(rawValue: raw) ?? .open
    }

    /// The posture a device is in, from what its hinge says.
    ///
    /// Only the hinge answers this. The shape of a window does not: a folded
    /// phone's outer screen and the same phone held upright are sizes the app
    /// cannot tell apart from a small window on any other device. Where there
    /// is no hinge to ask, the device is taken to be open, which is what it
    /// has been treated as since before there were folding phones.
    ///
    /// - Parameters:
    ///   - hingeIsClosed: Whether the hinge reports being shut.
    ///   - hingeIsLaptopLike: Whether it reports being half open the way a
    ///     laptop is, from
    ///     ``HingePosture/isLaptopLike(isPartiallyOpen:angle:wasLaptopLike:)``.
    ///     The steadying of a hinge held at the edge of its range belongs with
    ///     the reading, not here.
    public static func resolve(hingeIsClosed: Bool, hingeIsLaptopLike: Bool) -> DevicePosture {
        if hingeIsLaptopLike { return .halfOpen }
        if hingeIsClosed { return .folded }
        return .open
    }
}

import CoreGraphics

/// Where the picture and the controls of a session go on a touch screen.
///
/// A screen has parts the system keeps content out of: beside a sensor
/// housing, under a status bar, around the home indicator. The picture is a
/// desktop someone has to reach every corner of, so it stays clear of
/// whatever would hide part of it, and takes everything else. The controls
/// then go, where they can, in a part the picture is not using.
///
/// Nothing here is allowed to depend on anything the layout itself changes.
/// Version 1.1.0 showed the status bar where the screen had room for it,
/// and what the screen keeps clear depends on whether the bar is showing:
/// on a device where the two disagreed, each answer undid the other, the
/// interface never came to rest and the system ended the app. The status
/// bar is hidden throughout a session, whatever the screen.
public struct SessionChromeLayout: Equatable, Sendable {
    /// Which side of a screen something is on.
    public enum Side: Equatable, Sendable {
        case left, right
    }

    public enum ControlsPlacement: Equatable, Sendable {
        /// In a strip beside the picture that the picture cannot use. The
        /// controls stand there one above the other and are always in view.
        /// The rectangle is in the screen's coordinates.
        case strip(CGRect)
        /// Over the picture at its top or bottom edge, brought out when
        /// asked for.
        case floating
    }

    /// What the system keeps content out of, at each edge.
    public var safeArea: Viewport.Insets
    /// How far the picture stays from each edge of the screen.
    public var pictureInsets: Viewport.Insets
    public var controls: ControlsPlacement

    /// The least the system keeps clear at the top of a screen with a
    /// sensor housing there. A status bar alone is 20 to 32 points.
    public static let shallowestHousing: CGFloat = 40
    /// The narrowest strip the controls fit in.
    public static let narrowestStrip: CGFloat = 56
    /// The shortest strip worth standing the controls in.
    public static let shortestStrip: CGFloat = 220

    /// - Parameters:
    ///   - size: The whole screen, or window.
    ///   - safeArea: What the system keeps content out of, at each edge.
    ///   - cornerTop: How far from the top the system would start content
    ///     that the screen's rounded corners must not cut into; no more
    ///     than the safe area's own top where that already clears them.
    ///   - sensorSide: The side the sensor housing is on when the screen is
    ///     on its side, if that is known. The system keeps both sides clear
    ///     then, and only one of them has something in it.
    public init(
        size: CGSize,
        safeArea: Viewport.Insets,
        cornerTop: CGFloat = 0,
        sensorSide: Side? = nil
    ) {
        self.safeArea = safeArea
        // The home indicator hides itself during a session, and nothing else
        // is at the bottom: the picture goes all the way down. At the top,
        // a sensor housing is something to stay clear of and a status bar
        // by itself is not: it is hidden for as long as a session is on
        // the screen, and staying clear of it would mean a desktop made
        // once for the screen with the bar and again for the screen
        // without.
        //
        // The top of a Mac's screen is its menu bar, with the Apple menu in
        // one corner and the clock in the other, and a screen with rounded
        // corners cuts into both. The picture starts as far down as the
        // system would start anything that has to be seen whole.
        let housing = safeArea.top >= Self.shallowestHousing ? safeArea.top : 0
        let corners = cornerTop > safeArea.top ? cornerTop : 0
        pictureInsets = Viewport.Insets(
            top: max(housing, corners),
            left: safeArea.left, bottom: 0, right: safeArea.right)

        let widest = max(safeArea.left, safeArea.right)
        var strip: CGRect?
        if widest >= Self.narrowestStrip {
            let side: Side
            if abs(safeArea.left - safeArea.right) > 1 {
                side = safeArea.left > safeArea.right ? .left : .right
            } else {
                // Both sides are kept clear and one has the sensors in it.
                side = sensorSide == .right ? .left : .right
            }
            let rect = CGRect(
                x: side == .left ? 0 : size.width - safeArea.right,
                y: 0,
                width: side == .left ? safeArea.left : safeArea.right,
                height: size.height)
            if rect.height >= Self.shortestStrip {
                strip = rect
            }
        }
        controls = strip.map(ControlsPlacement.strip) ?? .floating
    }
}

/// How a folding device is being held.
public enum HingePosture {
    /// Whether a hinge is open the way a laptop's is, with one half of the
    /// screen to lay flat and the other to stand up.
    ///
    /// "Partially open" by itself is not that: it is also what a hinge
    /// reports when the device is held open with the slightest bend in it,
    /// which is how most people hold one.
    ///
    /// - Parameters:
    ///   - isPartiallyOpen: Whether the hinge reports being between closed
    ///     and fully open.
    ///   - angle: The angle between the halves, 0 when closed. Degrees by
    ///     every sign; a reading no larger than a full turn in radians is
    ///     taken to be radians. Zero or less means the angle is not known,
    ///     and then the status is all there is to go by.
    ///   - wasLaptopLike: What the answer was for the reading before this
    ///     one. A hinge held at the edge of the range reads a little to
    ///     either side of it from one moment to the next, and the answer
    ///     must not change with every reading: once open like a laptop, it
    ///     stays that until it is clearly not.
    public static func isLaptopLike(
        isPartiallyOpen: Bool, angle: CGFloat, wasLaptopLike: Bool = false
    ) -> Bool {
        guard isPartiallyOpen else { return false }
        guard angle.isFinite, angle > 0 else { return true }
        let degrees = angle <= 2 * .pi ? angle * 180 / .pi : angle
        let range: ClosedRange<CGFloat> = wasLaptopLike ? 50...145 : 60...135
        return range.contains(degrees)
    }
}

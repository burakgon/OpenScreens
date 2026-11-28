/// What to change about a connection for each way a folding phone is held.
///
/// A phone folded shut has half a screen and is worked with one hand, and how
/// a person wants to drive a desktop changes with that: touch where the screen
/// is small, a trackpad where it is not. The settings a device is left in are
/// kept as the defaults, and a posture says only what it has an opinion about,
/// so a fold never undoes something chosen by hand.
public struct PosturePresets: Codable, Hashable, Sendable {
    /// One posture's opinion. Nothing in it is required, and nothing in it is
    /// a default: a posture that says nothing leaves the connection alone.
    public struct Preset: Codable, Hashable, Sendable {
        /// How touches are read.
        public var touchInput: TouchInputMode?
        /// Whether to ask for a desktop wide enough for any Mac window,
        /// rather than one sized for the screen.
        public var moreSpace: Bool?
        /// Whether the deck of keys is out, when nobody has asked for it to
        /// be put away or brought out themselves.
        public var showsDeck: Bool?

        public init(
            touchInput: TouchInputMode? = nil,
            moreSpace: Bool? = nil,
            showsDeck: Bool? = nil
        ) {
            self.touchInput = touchInput
            self.moreSpace = moreSpace
            self.showsDeck = showsDeck
        }

        public var isEmpty: Bool {
            touchInput == nil && moreSpace == nil && showsDeck == nil
        }

        /// Lays what this posture says over `settings`, in place.
        public func apply(to settings: inout ConnectionSettings) {
            if let touchInput { settings.touchInput = touchInput }
            if let moreSpace { settings.moreSpace = moreSpace }
        }
    }

    public var folded: Preset
    public var halfOpen: Preset
    public var open: Preset

    public init(folded: Preset = Preset(), halfOpen: Preset = Preset(), open: Preset = Preset()) {
        self.folded = folded
        self.halfOpen = halfOpen
        self.open = open
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PosturePresets()
        folded = try c.decodeIfPresent(Preset.self, forKey: .folded) ?? d.folded
        halfOpen = try c.decodeIfPresent(Preset.self, forKey: .halfOpen) ?? d.halfOpen
        open = try c.decodeIfPresent(Preset.self, forKey: .open) ?? d.open
    }

    public subscript(posture: DevicePosture) -> Preset {
        get {
            switch posture {
            case .folded: folded
            case .halfOpen: halfOpen
            case .open: open
            }
        }
        set {
            switch posture {
            case .folded: folded = newValue
            case .halfOpen: halfOpen = newValue
            case .open: open = newValue
            }
        }
    }

    /// Whether no posture has an opinion about anything.
    public var isEmpty: Bool {
        folded.isEmpty && halfOpen.isEmpty && open.isEmpty
    }

    /// The starting point for a folding phone: touch and the whole of a small
    /// screen's worth of room when it is shut, a trackpad and a desktop with
    /// room for any window when it is open, and the keys under the hands when
    /// it is stood up half open like a laptop.
    public static let foldableDefaults = PosturePresets(
        folded: Preset(touchInput: .touch, moreSpace: false, showsDeck: false),
        halfOpen: Preset(showsDeck: true),
        open: Preset(touchInput: .trackpad, moreSpace: true, showsDeck: false)
    )
}

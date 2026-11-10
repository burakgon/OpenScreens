import Foundation

/// Everything that can be tuned for one computer's connections.
///
/// A new computer starts from the app-wide defaults and keeps its own copy, so
/// changing how one computer behaves never affects another.
public struct ConnectionSettings: Codable, Hashable, Sendable {

    // MARK: Picture

    public var quality: QualityMode
    public var resolution: ResolutionMode
    public var displays: DisplayLayout
    public var scaling: ScalingMode
    public var colorDepth: ColorDepth
    /// Frames per second requested from the remote computer.
    public var frameRate: Int
    /// Brightness multiplier applied to the picture on HDR-capable screens.
    public var brightnessBoost: Double

    // MARK: Sound

    public var remoteAudio: Bool
    /// Hold video back so it stays in step with remote sound.
    public var syncVideoToAudio: Bool

    // MARK: Control

    /// Watch without sending any keyboard, pointer or clipboard input.
    public var observeOnly: Bool
    public var cursor: CursorMode
    /// How touches are interpreted on iPhone and iPad.
    public var touchInput: TouchInputMode
    public var naturalScrolling: Bool
    public var scrollSpeed: Double
    /// Tracking speed of the virtual pointer in trackpad mode.
    public var pointerSpeed: Double
    public var keyboardInput: KeyboardInputMode
    /// Send system shortcuts (⌘Tab, ⌘Space, Mission Control…) to the remote
    /// computer while its window is focused.
    public var captureSystemShortcuts: Bool
    /// Swap ⌘ and ⌃ for computers that are not Macs.
    public var swapCommandAndControl: Bool

    // MARK: Clipboard and privacy

    public var sharedClipboard: Bool
    public var curtainOnConnect: Bool
    public var curtainMessage: String
    public var lockOnDisconnect: Bool
    /// Offer to type the saved password when the remote Mac shows its login window.
    public var offerPasswordAtLoginWindow: Bool

    // MARK: Reliability

    public var reconnectAutomatically: Bool
    /// Fall back to Standard when High Performance cannot be established.
    public var fallBackToStandard: Bool

    public init(
        quality: QualityMode = .highPerformance,
        resolution: ResolutionMode = .matchWindow,
        displays: DisplayLayout = .single,
        scaling: ScalingMode = .fit,
        colorDepth: ColorDepth = .full,
        frameRate: Int = 60,
        brightnessBoost: Double = 1.0,
        remoteAudio: Bool = true,
        syncVideoToAudio: Bool = false,
        observeOnly: Bool = false,
        cursor: CursorMode = .local,
        touchInput: TouchInputMode = .trackpad,
        naturalScrolling: Bool = true,
        scrollSpeed: Double = 1.0,
        pointerSpeed: Double = 1.0,
        keyboardInput: KeyboardInputMode = .automatic,
        captureSystemShortcuts: Bool = true,
        swapCommandAndControl: Bool = true,
        sharedClipboard: Bool = true,
        curtainOnConnect: Bool = false,
        curtainMessage: String = "",
        lockOnDisconnect: Bool = false,
        offerPasswordAtLoginWindow: Bool = true,
        reconnectAutomatically: Bool = true,
        fallBackToStandard: Bool = true
    ) {
        self.quality = quality
        self.resolution = resolution
        self.displays = displays
        self.scaling = scaling
        self.colorDepth = colorDepth
        self.frameRate = frameRate
        self.brightnessBoost = brightnessBoost
        self.remoteAudio = remoteAudio
        self.syncVideoToAudio = syncVideoToAudio
        self.observeOnly = observeOnly
        self.cursor = cursor
        self.touchInput = touchInput
        self.naturalScrolling = naturalScrolling
        self.scrollSpeed = scrollSpeed
        self.pointerSpeed = pointerSpeed
        self.keyboardInput = keyboardInput
        self.captureSystemShortcuts = captureSystemShortcuts
        self.swapCommandAndControl = swapCommandAndControl
        self.sharedClipboard = sharedClipboard
        self.curtainOnConnect = curtainOnConnect
        self.curtainMessage = curtainMessage
        self.lockOnDisconnect = lockOnDisconnect
        self.offerPasswordAtLoginWindow = offerPasswordAtLoginWindow
        self.reconnectAutomatically = reconnectAutomatically
        self.fallBackToStandard = fallBackToStandard
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectionSettings()
        quality = try c.decodeIfPresent(QualityMode.self, forKey: .quality) ?? d.quality
        resolution = try c.decodeIfPresent(ResolutionMode.self, forKey: .resolution) ?? d.resolution
        displays = try c.decodeIfPresent(DisplayLayout.self, forKey: .displays) ?? d.displays
        scaling = try c.decodeIfPresent(ScalingMode.self, forKey: .scaling) ?? d.scaling
        colorDepth = try c.decodeIfPresent(ColorDepth.self, forKey: .colorDepth) ?? d.colorDepth
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        brightnessBoost = try c.decodeIfPresent(Double.self, forKey: .brightnessBoost) ?? d.brightnessBoost
        remoteAudio = try c.decodeIfPresent(Bool.self, forKey: .remoteAudio) ?? d.remoteAudio
        syncVideoToAudio = try c.decodeIfPresent(Bool.self, forKey: .syncVideoToAudio) ?? d.syncVideoToAudio
        observeOnly = try c.decodeIfPresent(Bool.self, forKey: .observeOnly) ?? d.observeOnly
        cursor = try c.decodeIfPresent(CursorMode.self, forKey: .cursor) ?? d.cursor
        touchInput = try c.decodeIfPresent(TouchInputMode.self, forKey: .touchInput) ?? d.touchInput
        naturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .naturalScrolling) ?? d.naturalScrolling
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? d.scrollSpeed
        pointerSpeed = try c.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? d.pointerSpeed
        keyboardInput = try c.decodeIfPresent(KeyboardInputMode.self, forKey: .keyboardInput) ?? d.keyboardInput
        captureSystemShortcuts = try c.decodeIfPresent(Bool.self, forKey: .captureSystemShortcuts) ?? d.captureSystemShortcuts
        swapCommandAndControl = try c.decodeIfPresent(Bool.self, forKey: .swapCommandAndControl) ?? d.swapCommandAndControl
        sharedClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharedClipboard) ?? d.sharedClipboard
        curtainOnConnect = try c.decodeIfPresent(Bool.self, forKey: .curtainOnConnect) ?? d.curtainOnConnect
        curtainMessage = try c.decodeIfPresent(String.self, forKey: .curtainMessage) ?? d.curtainMessage
        lockOnDisconnect = try c.decodeIfPresent(Bool.self, forKey: .lockOnDisconnect) ?? d.lockOnDisconnect
        offerPasswordAtLoginWindow = try c.decodeIfPresent(Bool.self, forKey: .offerPasswordAtLoginWindow) ?? d.offerPasswordAtLoginWindow
        reconnectAutomatically = try c.decodeIfPresent(Bool.self, forKey: .reconnectAutomatically) ?? d.reconnectAutomatically
        fallBackToStandard = try c.decodeIfPresent(Bool.self, forKey: .fallBackToStandard) ?? d.fallBackToStandard
    }

    /// Sensible starting settings for a kind of computer. Only Macs can use
    /// High Performance, so everything else starts in Standard.
    public static func defaults(for kind: ComputerKind) -> ConnectionSettings {
        var settings = ConnectionSettings()
        if !kind.isApple {
            settings.quality = .standard
            settings.resolution = .remote
            settings.remoteAudio = false
        }
        return settings
    }
}

// MARK: - Option types

/// How the picture travels from the remote computer.
public enum QualityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple's low-latency HEVC stream over UDP. Macs with Apple silicon only.
    case highPerformance
    /// Adaptive compressed updates over TCP. Works everywhere, including
    /// through SSH tunnels and on slow or lossy links.
    case standard
    /// Lossless updates. Best on a fast local network.
    case fullQuality

    public var id: Self { self }

    public var title: String {
        switch self {
        case .highPerformance: "High Performance"
        case .standard: "Standard"
        case .fullQuality: "Full Quality"
        }
    }

    public var summary: String {
        switch self {
        case .highPerformance:
            "Low-latency video with sound, HDR and a desktop that resizes to fit. Needs a Mac with Apple silicon and a fast connection."
        case .standard:
            "Reliable adaptive picture over any connection, including SSH tunnels and VPNs."
        case .fullQuality:
            "Pixel-perfect lossless picture. Uses more bandwidth."
        }
    }

    public var symbolName: String {
        switch self {
        case .highPerformance: "bolt.fill"
        case .standard: "dial.medium"
        case .fullQuality: "sparkles"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QualityMode(rawValue: raw) ?? .standard
    }
}

/// Who decides the size of the remote desktop.
public enum ResolutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Resize the remote desktop to fit this window or screen, and keep it
    /// fitted as the window resizes, the device rotates or a foldable opens.
    case matchWindow
    /// Leave the remote computer's own display resolution alone.
    case remote

    public var id: Self { self }

    public var title: String {
        switch self {
        case .matchWindow: "Fit This Display"
        case .remote: "Remote Display"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResolutionMode(rawValue: raw) ?? .remote
    }
}

/// Which of the remote computer's displays are shown.
public enum DisplayLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case single
    /// Every physical display side by side as one wide desktop.
    case allCombined
    /// Two virtual displays, each sized to fit and streamed independently.
    case twoVirtual

    public var id: Self { self }

    public var title: String {
        switch self {
        case .single: "One Display"
        case .allCombined: "All Displays"
        case .twoVirtual: "Two Virtual Displays"
        }
    }

    public var symbolName: String {
        switch self {
        case .single: "display"
        case .allCombined: "display.2"
        case .twoVirtual: "rectangle.split.2x1"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DisplayLayout(rawValue: raw) ?? .single
    }
}

/// How the remote picture is fitted into the local window.
public enum ScalingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Show the whole desktop, letterboxed if the shapes differ.
    case fit
    /// Fill the window, cropping whatever does not fit.
    case fill
    /// One remote pixel per local pixel; pan to see the rest.
    case actualSize

    public var id: Self { self }

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .actualSize: "Actual Size"
        }
    }

    public var symbolName: String {
        switch self {
        case .fit: "arrow.down.right.and.arrow.up.left"
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .actualSize: "1.magnifyingglass"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScalingMode(rawValue: raw) ?? .fit
    }
}

public enum ColorDepth: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 24-bit colour.
    case full
    /// 15-bit colour. Roughly halves the bandwidth of Standard connections.
    case thousands

    public var id: Self { self }

    public var title: String {
        switch self {
        case .full: "Millions of Colours"
        case .thousands: "Thousands of Colours"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ColorDepth(rawValue: raw) ?? .full
    }
}

/// Who draws the pointer.
public enum CursorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Draw the remote pointer's shape locally, so it moves without lag.
    case local
    /// Show the pointer exactly as the remote computer draws it.
    case remote

    public var id: Self { self }

    public var title: String {
        switch self {
        case .local: "Instant (Drawn Locally)"
        case .remote: "Exact (Drawn Remotely)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CursorMode(rawValue: raw) ?? .local
    }
}

public enum TouchInputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The screen is a trackpad: drag to move the pointer, tap to click.
    case trackpad
    /// Touch the thing you want to click.
    case touch

    public var id: Self { self }

    public var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .touch: "Touch"
        }
    }

    public var symbolName: String {
        switch self {
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .touch: "hand.tap"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TouchInputMode(rawValue: raw) ?? .trackpad
    }
}

/// How typed text reaches the remote computer.
public enum KeyboardInputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Physical keys for Macs, characters for everything else.
    case automatic
    /// Send the physical key that was pressed and let the remote keyboard
    /// layout decide what it means. Best when both sides use the same layout.
    case keystrokes
    /// Send the character that was typed. Best for non-Latin text and when
    /// the two keyboard layouts differ.
    case unicode

    public var id: Self { self }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .keystrokes: "Keystrokes"
        case .unicode: "Unicode"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KeyboardInputMode(rawValue: raw) ?? .automatic
    }
}

// MARK: - SSH

/// Secure-tunnel configuration for a computer. When enabled, the screen
/// sharing connection travels inside an SSH session instead of directly.
public struct SSHSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// SSH server address. Empty means the computer's own address.
    public var host: String
    public var port: Int
    /// Empty means the computer's own username.
    public var username: String
    public var authentication: SSHAuthentication
    /// The key to sign in with when ``authentication`` is `.key`.
    public var keyID: UUID?

    public init(
        isEnabled: Bool = false,
        host: String = "",
        port: Int = 22,
        username: String = "",
        authentication: SSHAuthentication = .password,
        keyID: UUID? = nil
    ) {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.keyID = keyID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authentication = try c.decodeIfPresent(SSHAuthentication.self, forKey: .authentication) ?? .password
        keyID = try c.decodeIfPresent(UUID.self, forKey: .keyID)
    }
}

public enum SSHAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case key

    public var id: Self { self }

    public var title: String {
        switch self {
        case .password: "Password"
        case .key: "SSH Key"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SSHAuthentication(rawValue: raw) ?? .password
    }
}

import Foundation

/// One mode in Apple's negotiated virtual-display configuration command.
/// All dimensions are explicit: pixels select the framebuffer while points
/// select the remote UI scale (for example 2732×2048 pixels at 1366×1024
/// points is a 2× HiDPI display).
public struct AppleVirtualDisplayMode: Sendable, Equatable {
    public static let wireSize = 28

    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let pointWidth: UInt32
    public let pointHeight: UInt32
    public let refreshRate: Double
    public let flags: UInt32

    public init(
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        pointWidth: UInt32,
        pointHeight: UInt32,
        refreshRate: Double = 60,
        flags: UInt32 = 0
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshRate = refreshRate
        self.flags = flags
    }
}

/// One display record in Apple's display-configuration command, encoded using
/// the fixed wire layout defined below.
public struct AppleVirtualDisplay: Sendable, Equatable {
    public static let nameByteCount = 120
    public static let fixedWireSize = 156

    /// The server flag used by Screen Sharing to make the virtual display's
    /// resolution follow subsequent display-configuration requests.
    public static let dynamicResolutionFlag: UInt32 = 1

    public let name: String
    public let flags: UInt32
    public let attributes: UInt32
    public let widthInMillimeters: Float
    public let heightInMillimeters: Float
    public let maximumPixelWidth: UInt32
    public let maximumPixelHeight: UInt32
    /// Which of `modes` the display starts in.
    ///
    /// The server reads the two 16-bit fields after the maximum size as mode
    /// indexes and refuses the whole display when either is out of range
    /// ("N is not a valid current display mode index"); the session then
    /// stops receiving video. They are not a position: the server arranges
    /// the displays itself and reports where they are in DisplayInfo2.
    public let currentModeIndex: UInt16
    /// The mode the display calls its native one.
    public let preferredModeIndex: UInt16
    public let identifier: UInt32
    public let modes: [AppleVirtualDisplayMode]

    public init(
        name: String,
        flags: UInt32 = Self.dynamicResolutionFlag,
        attributes: UInt32 = 0,
        widthInMillimeters: Float,
        heightInMillimeters: Float,
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32,
        currentModeIndex: UInt16 = 0,
        preferredModeIndex: UInt16 = 0,
        identifier: UInt32 = 7,
        modes: [AppleVirtualDisplayMode]
    ) {
        precondition(!modes.isEmpty && modes.count <= Int(UInt16.max))
        precondition(
            Int(currentModeIndex) < modes.count
                && Int(preferredModeIndex) < modes.count)
        self.name = name
        self.flags = flags
        self.attributes = attributes
        self.widthInMillimeters = widthInMillimeters
        self.heightInMillimeters = heightInMillimeters
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
        self.currentModeIndex = currentModeIndex
        self.preferredModeIndex = preferredModeIndex
        self.identifier = identifier
        self.modes = modes
    }

    public var wireSize: Int {
        Self.fixedWireSize + modes.count * AppleVirtualDisplayMode.wireSize
    }
}

/// Apple RFB client command 29, advertised through the ServerInit command
/// bitmap. This is the mechanism behind Screen Sharing's virtual-display
/// dynamic resolution, rather than the standard SetDesktopSize extension.
public struct AppleDisplayConfiguration: Sendable, Equatable {
    public static let messageType: UInt8 = 29
    public static let version: UInt16 = 1
    public static let headerWireSize = 12

    public let displays: [AppleVirtualDisplay]

    public init(displays: [AppleVirtualDisplay]) {
        precondition(!displays.isEmpty && displays.count <= 2)
        self.displays = displays
    }
}

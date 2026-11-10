import Foundation
import Observation

/// App-wide preferences, stored in user defaults.
@MainActor
@Observable
public final class AppSettings {

    // MARK: Connection defaults

    /// Starting settings for newly added computers and for quick connections.
    public var defaultConnection: ConnectionSettings {
        didSet { writeCodable(defaultConnection, Key.defaultConnection) }
    }

    // MARK: Library

    public var libraryLayout: LibraryLayout {
        didSet { defaults.set(libraryLayout.rawValue, forKey: Key.libraryLayout) }
    }

    public var librarySort: LibrarySort {
        didSet { defaults.set(librarySort.rawValue, forKey: Key.librarySort) }
    }

    public var showsNearbyComputers: Bool {
        didSet { defaults.set(showsNearbyComputers, forKey: Key.showsNearby) }
    }

    /// Keep a picture of each computer's screen from its last session to show
    /// on its card. Turn off to never store remote screen contents.
    public var savesSessionPreviews: Bool {
        didSet { defaults.set(savesSessionPreviews, forKey: Key.savesPreviews) }
    }

    // MARK: Sessions

    public var showsStatisticsOverlay: Bool {
        didSet { defaults.set(showsStatisticsOverlay, forKey: Key.showsStatistics) }
    }

    /// Keep this device awake while a session is open.
    public var keepsDisplayAwake: Bool {
        didSet { defaults.set(keepsDisplayAwake, forKey: Key.keepsAwake) }
    }

    public var confirmsDisconnect: Bool {
        didSet { defaults.set(confirmsDisconnect, forKey: Key.confirmsDisconnect) }
    }

    public var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: Key.haptics) }
    }

    /// Buttons shown on the session toolbar, in order.
    public var toolbarItems: [ToolbarItemKind] {
        didSet { defaults.set(toolbarItems.map(\.rawValue), forKey: Key.toolbarItems) }
    }

    /// User-defined key combinations offered in the shortcuts menu.
    public var customShortcuts: [RemoteShortcut] {
        didSet { writeCodable(customShortcuts, Key.customShortcuts) }
    }

    // MARK: Privacy

    /// Require Face ID, Touch ID or the device passcode to open the app.
    public var requiresAuthentication: Bool {
        didSet { defaults.set(requiresAuthentication, forKey: Key.requiresAuthentication) }
    }

    public var syncsWithICloud: Bool {
        didSet { defaults.set(syncsWithICloud, forKey: Key.syncsWithICloud) }
    }

    // MARK: Tailscale

    public var tailscaleEnabled: Bool {
        didSet { defaults.set(tailscaleEnabled, forKey: Key.tailscaleEnabled) }
    }

    /// Tailnet to list devices from. `-` means the token's own tailnet.
    public var tailnet: String {
        didSet { defaults.set(tailnet, forKey: Key.tailnet) }
    }

    public var hidesOfflineTailscaleDevices: Bool {
        didSet { defaults.set(hidesOfflineTailscaleDevices, forKey: Key.hidesOfflineTailscale) }
    }

    // MARK: Storage

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = StorageLocation.defaults) {
        self.defaults = defaults
        defaultConnection = Self.readCodable(defaults, Key.defaultConnection) ?? ConnectionSettings()
        libraryLayout = LibraryLayout(rawValue: defaults.string(forKey: Key.libraryLayout) ?? "") ?? .grid
        librarySort = LibrarySort(rawValue: defaults.string(forKey: Key.librarySort) ?? "") ?? .manual
        showsNearbyComputers = defaults.object(forKey: Key.showsNearby) as? Bool ?? true
        savesSessionPreviews = defaults.object(forKey: Key.savesPreviews) as? Bool ?? true
        showsStatisticsOverlay = defaults.bool(forKey: Key.showsStatistics)
        keepsDisplayAwake = defaults.object(forKey: Key.keepsAwake) as? Bool ?? true
        confirmsDisconnect = defaults.bool(forKey: Key.confirmsDisconnect)
        hapticFeedback = defaults.object(forKey: Key.haptics) as? Bool ?? true
        toolbarItems = (defaults.stringArray(forKey: Key.toolbarItems))?
            .compactMap(ToolbarItemKind.init(rawValue:)) ?? ToolbarItemKind.defaultItems
        customShortcuts = Self.readCodable(defaults, Key.customShortcuts) ?? []
        requiresAuthentication = defaults.bool(forKey: Key.requiresAuthentication)
        syncsWithICloud = defaults.object(forKey: Key.syncsWithICloud) as? Bool ?? true
        tailscaleEnabled = defaults.object(forKey: Key.tailscaleEnabled) as? Bool ?? true
        tailnet = defaults.string(forKey: Key.tailnet) ?? "-"
        hidesOfflineTailscaleDevices = defaults.bool(forKey: Key.hidesOfflineTailscale)
    }

    /// Restores every preference to its default value.
    public func reset() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        let fresh = AppSettings(defaults: defaults)
        defaultConnection = fresh.defaultConnection
        libraryLayout = fresh.libraryLayout
        librarySort = fresh.librarySort
        showsNearbyComputers = fresh.showsNearbyComputers
        savesSessionPreviews = fresh.savesSessionPreviews
        showsStatisticsOverlay = fresh.showsStatisticsOverlay
        keepsDisplayAwake = fresh.keepsDisplayAwake
        confirmsDisconnect = fresh.confirmsDisconnect
        hapticFeedback = fresh.hapticFeedback
        toolbarItems = fresh.toolbarItems
        customShortcuts = fresh.customShortcuts
        requiresAuthentication = fresh.requiresAuthentication
        syncsWithICloud = fresh.syncsWithICloud
        tailscaleEnabled = fresh.tailscaleEnabled
        tailnet = fresh.tailnet
        hidesOfflineTailscaleDevices = fresh.hidesOfflineTailscaleDevices
    }

    private func writeCodable<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func readCodable<Value: Decodable>(_ defaults: UserDefaults, _ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private enum Key {
        static let defaultConnection = "defaultConnection"
        static let libraryLayout = "libraryLayout"
        static let librarySort = "librarySort"
        static let showsNearby = "showsNearbyComputers"
        static let savesPreviews = "savesSessionPreviews"
        static let showsStatistics = "showsStatisticsOverlay"
        static let keepsAwake = "keepsDisplayAwake"
        static let confirmsDisconnect = "confirmsDisconnect"
        static let haptics = "hapticFeedback"
        static let toolbarItems = "toolbarItems"
        static let customShortcuts = "customShortcuts"
        static let requiresAuthentication = "requiresAuthentication"
        static let syncsWithICloud = "syncsWithICloud"
        static let tailscaleEnabled = "tailscaleEnabled"
        static let tailnet = "tailnet"
        static let hidesOfflineTailscale = "hidesOfflineTailscaleDevices"

        static let all = [
            defaultConnection, libraryLayout, librarySort, showsNearby, savesPreviews,
            showsStatistics, keepsAwake, confirmsDisconnect, haptics, toolbarItems,
            customShortcuts, requiresAuthentication, syncsWithICloud, tailscaleEnabled,
            tailnet, hidesOfflineTailscale,
        ]
    }
}

public enum LibraryLayout: String, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    public var id: Self { self }

    public var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }

    public var symbolName: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case manual
    case name
    case lastConnected
    case kind

    public var id: Self { self }

    public var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .lastConnected: "Last Connected"
        case .kind: "Kind"
        }
    }

    /// Orders computers for display.
    public func sorted(_ computers: [Computer]) -> [Computer] {
        switch self {
        case .manual:
            computers.sorted { $0.sortIndex < $1.sortIndex }
        case .name:
            computers.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .lastConnected:
            computers.sorted {
                ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
            }
        case .kind:
            computers.sorted {
                if $0.kind != $1.kind {
                    return $0.kind.title < $1.kind.title
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }
}

/// A button that can be placed on the session toolbar.
public enum ToolbarItemKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case keyboard
    case modifiers
    case shortcuts
    case inputMode
    case clipboard
    case displays
    case scaling
    case quality
    case curtain
    case audio
    case screenshot
    case files
    case typePassword
    case dictation
    case statistics
    case fullScreen

    public var id: Self { self }

    public static let defaultItems: [ToolbarItemKind] = [
        .keyboard, .modifiers, .shortcuts, .inputMode, .clipboard,
        .displays, .curtain, .screenshot, .files,
    ]

    public var title: String {
        switch self {
        case .keyboard: "Keyboard"
        case .modifiers: "Modifier Keys"
        case .shortcuts: "Shortcuts"
        case .inputMode: "Pointer Mode"
        case .clipboard: "Clipboard"
        case .displays: "Displays"
        case .scaling: "Scaling"
        case .quality: "Quality"
        case .curtain: "Curtain Mode"
        case .audio: "Sound"
        case .screenshot: "Screenshot"
        case .files: "File Transfer"
        case .typePassword: "Type Password"
        case .dictation: "Dictation"
        case .statistics: "Statistics"
        case .fullScreen: "Full Screen"
        }
    }

    public var symbolName: String {
        switch self {
        case .keyboard: "keyboard"
        case .modifiers: "command"
        case .shortcuts: "bolt"
        case .inputMode: "hand.point.up.left"
        case .clipboard: "doc.on.clipboard"
        case .displays: "display.2"
        case .scaling: "arrow.up.left.and.arrow.down.right"
        case .quality: "dial.medium"
        case .curtain: "eye.slash"
        case .audio: "speaker.wave.2"
        case .screenshot: "camera"
        case .files: "folder"
        case .typePassword: "key"
        case .dictation: "mic"
        case .statistics: "chart.bar"
        case .fullScreen: "arrow.up.left.and.arrow.down.right.rectangle"
        }
    }
}

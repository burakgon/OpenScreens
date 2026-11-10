import Foundation
import Testing
@testable import OpenScreensCore

/// A private defaults domain that leaves nothing behind.
///
/// The suite is named by a path inside a temporary directory rather than by
/// a plain name. A named suite becomes a property list in
/// `~/Library/Preferences`, and the preferences daemon writes that file back
/// even after the domain has been removed, so every test run would leave a
/// few more. A path puts the file where it goes away with its directory.
private final class ThrowawayDefaults {
    private let scratch: ScratchDirectory
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        scratch = try ScratchDirectory()
        suiteName = scratch.file("Settings").path
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Every preference at once, so two sets of settings can be compared.
private struct Preferences: Equatable {
    var defaultConnection: ConnectionSettings
    var libraryLayout: LibraryLayout
    var librarySort: LibrarySort
    var showsNearbyComputers: Bool
    var savesSessionPreviews: Bool
    var showsStatisticsOverlay: Bool
    var keepsDisplayAwake: Bool
    var confirmsDisconnect: Bool
    var hapticFeedback: Bool
    var toolbarItems: [ToolbarItemKind]
    var customShortcuts: [RemoteShortcut]
    var requiresAuthentication: Bool
    var syncsWithICloud: Bool
    var tailscaleEnabled: Bool
    var tailnet: String
    var hidesOfflineTailscaleDevices: Bool

    @MainActor
    init(_ settings: AppSettings) {
        defaultConnection = settings.defaultConnection
        libraryLayout = settings.libraryLayout
        librarySort = settings.librarySort
        showsNearbyComputers = settings.showsNearbyComputers
        savesSessionPreviews = settings.savesSessionPreviews
        showsStatisticsOverlay = settings.showsStatisticsOverlay
        keepsDisplayAwake = settings.keepsDisplayAwake
        confirmsDisconnect = settings.confirmsDisconnect
        hapticFeedback = settings.hapticFeedback
        toolbarItems = settings.toolbarItems
        customShortcuts = settings.customShortcuts
        requiresAuthentication = settings.requiresAuthentication
        syncsWithICloud = settings.syncsWithICloud
        tailscaleEnabled = settings.tailscaleEnabled
        tailnet = settings.tailnet
        hidesOfflineTailscaleDevices = settings.hidesOfflineTailscaleDevices
    }
}

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {

    /// Gives every preference a value other than its default.
    private func changeEverything(in settings: AppSettings) {
        var connection = ConnectionSettings()
        connection.quality = .fullQuality
        connection.scaling = .actualSize
        connection.frameRate = 24
        connection.scrollSpeed = 2.5
        connection.curtainMessage = "Back at nine"
        connection.sharedClipboard = false
        settings.defaultConnection = connection
        settings.libraryLayout = .list
        settings.librarySort = .lastConnected
        settings.showsNearbyComputers = false
        settings.savesSessionPreviews = false
        settings.showsStatisticsOverlay = true
        settings.keepsDisplayAwake = false
        settings.confirmsDisconnect = true
        settings.hapticFeedback = false
        settings.toolbarItems = [.files, .keyboard, .statistics]
        settings.customShortcuts = [
            RemoteShortcut(name: "Lock", modifiers: [.control, .command], key: .character("q")),
            RemoteShortcut(name: "Console", modifiers: [.control, .option], key: .function(2)),
        ]
        settings.requiresAuthentication = true
        settings.syncsWithICloud = false
        settings.tailscaleEnabled = false
        settings.tailnet = "example.org"
        settings.hidesOfflineTailscaleDevices = true
    }

    @Test func aFreshInstallStartsWithTheDefaults() throws {
        let scratch = try ThrowawayDefaults()
        let settings = AppSettings(defaults: scratch.defaults)

        #expect(settings.defaultConnection == ConnectionSettings())
        #expect(settings.libraryLayout == .grid)
        #expect(settings.librarySort == .manual)
        #expect(settings.showsNearbyComputers)
        #expect(settings.savesSessionPreviews)
        #expect(!settings.showsStatisticsOverlay)
        #expect(settings.keepsDisplayAwake)
        #expect(!settings.confirmsDisconnect)
        #expect(settings.hapticFeedback)
        #expect(settings.toolbarItems == ToolbarItemKind.defaultItems)
        #expect(settings.customShortcuts.isEmpty)
        #expect(!settings.requiresAuthentication)
        #expect(settings.syncsWithICloud)
        #expect(settings.tailscaleEnabled)
        #expect(settings.tailnet == "-")
        #expect(!settings.hidesOfflineTailscaleDevices)
    }

    @Test func everyPreferenceSurvivesARelaunch() throws {
        let scratch = try ThrowawayDefaults()
        let settings = AppSettings(defaults: scratch.defaults)
        let untouched = Preferences(settings)

        changeEverything(in: settings)
        let changed = Preferences(settings)

        // Every field really did move away from its default…
        #expect(changed.defaultConnection != untouched.defaultConnection)
        #expect(changed.libraryLayout != untouched.libraryLayout)
        #expect(changed.librarySort != untouched.librarySort)
        #expect(changed.showsNearbyComputers != untouched.showsNearbyComputers)
        #expect(changed.savesSessionPreviews != untouched.savesSessionPreviews)
        #expect(changed.showsStatisticsOverlay != untouched.showsStatisticsOverlay)
        #expect(changed.keepsDisplayAwake != untouched.keepsDisplayAwake)
        #expect(changed.confirmsDisconnect != untouched.confirmsDisconnect)
        #expect(changed.hapticFeedback != untouched.hapticFeedback)
        #expect(changed.toolbarItems != untouched.toolbarItems)
        #expect(changed.customShortcuts != untouched.customShortcuts)
        #expect(changed.requiresAuthentication != untouched.requiresAuthentication)
        #expect(changed.syncsWithICloud != untouched.syncsWithICloud)
        #expect(changed.tailscaleEnabled != untouched.tailscaleEnabled)
        #expect(changed.tailnet != untouched.tailnet)
        #expect(changed.hidesOfflineTailscaleDevices != untouched.hidesOfflineTailscaleDevices)

        // …and a new instance on the same defaults reads all of it back.
        #expect(Preferences(AppSettings(defaults: scratch.defaults)) == changed)
    }

    @Test func resetRestoresEveryDefault() throws {
        let scratch = try ThrowawayDefaults()
        let settings = AppSettings(defaults: scratch.defaults)
        let defaults = Preferences(settings)
        changeEverything(in: settings)

        settings.reset()

        #expect(Preferences(settings) == defaults)
        #expect(Preferences(AppSettings(defaults: scratch.defaults)) == defaults)

        // The settings keep working after a reset.
        settings.tailnet = "example.org"
        #expect(AppSettings(defaults: scratch.defaults).tailnet == "example.org")
    }

    @Test func changingOnePreferenceLeavesTheOthersAlone() throws {
        let scratch = try ThrowawayDefaults()
        let settings = AppSettings(defaults: scratch.defaults)
        var expected = Preferences(settings)

        settings.librarySort = .name
        expected.librarySort = .name

        #expect(Preferences(settings) == expected)
        #expect(Preferences(AppSettings(defaults: scratch.defaults)) == expected)
    }

    @Test func aToolbarWithEveryButtonRemovedStaysEmpty() throws {
        let scratch = try ThrowawayDefaults()
        AppSettings(defaults: scratch.defaults).toolbarItems = []

        // Not to be confused with "never customised", which shows the defaults.
        #expect(AppSettings(defaults: scratch.defaults).toolbarItems.isEmpty)
    }

    @Test func theOrderOfToolbarButtonsIsKept() throws {
        let scratch = try ThrowawayDefaults()
        let order: [ToolbarItemKind] = [.screenshot, .keyboard, .fullScreen, .audio]
        AppSettings(defaults: scratch.defaults).toolbarItems = order

        #expect(AppSettings(defaults: scratch.defaults).toolbarItems == order)
    }

    @Test func settingsInDifferentDefaultsDoNotMix() throws {
        let first = try ThrowawayDefaults()
        let second = try ThrowawayDefaults()

        AppSettings(defaults: first.defaults).tailnet = "first.example"

        #expect(AppSettings(defaults: second.defaults).tailnet == "-")
        #expect(AppSettings(defaults: first.defaults).tailnet == "first.example")
    }

    @Test func storedValuesThisVersionDoesNotKnowFallBackToDefaults() throws {
        let scratch = try ThrowawayDefaults()
        let stored = scratch.defaults
        stored.set("carousel", forKey: "libraryLayout")
        stored.set("popularity", forKey: "librarySort")
        stored.set(["keyboard", "teleporter", "files"], forKey: "toolbarItems")
        stored.set(Data("not json".utf8), forKey: "defaultConnection")
        stored.set(Data("[{\"broken\":true}]".utf8), forKey: "customShortcuts")
        stored.set("not a boolean", forKey: "showsNearbyComputers")

        let settings = AppSettings(defaults: stored)

        #expect(settings.libraryLayout == .grid)
        #expect(settings.librarySort == .manual)
        // Buttons this version has are kept, in order; the rest are dropped.
        #expect(settings.toolbarItems == [.keyboard, .files])
        #expect(settings.defaultConnection == ConnectionSettings())
        #expect(settings.customShortcuts.isEmpty)
        #expect(settings.showsNearbyComputers)
    }

    @Test func preferencesAreStoredUnderStableNames() throws {
        // These names are what is on disk on every user's device.
        let scratch = try ThrowawayDefaults()
        changeEverything(in: AppSettings(defaults: scratch.defaults))
        let stored = scratch.defaults

        #expect(stored.string(forKey: "libraryLayout") == "list")
        #expect(stored.string(forKey: "librarySort") == "lastConnected")
        #expect(stored.object(forKey: "showsNearbyComputers") as? Bool == false)
        #expect(stored.object(forKey: "savesSessionPreviews") as? Bool == false)
        #expect(stored.object(forKey: "showsStatisticsOverlay") as? Bool == true)
        #expect(stored.object(forKey: "keepsDisplayAwake") as? Bool == false)
        #expect(stored.object(forKey: "confirmsDisconnect") as? Bool == true)
        #expect(stored.object(forKey: "hapticFeedback") as? Bool == false)
        #expect(stored.stringArray(forKey: "toolbarItems") == ["files", "keyboard", "statistics"])
        #expect(stored.object(forKey: "requiresAuthentication") as? Bool == true)
        #expect(stored.object(forKey: "syncsWithICloud") as? Bool == false)
        #expect(stored.object(forKey: "tailscaleEnabled") as? Bool == false)
        #expect(stored.string(forKey: "tailnet") == "example.org")
        #expect(stored.object(forKey: "hidesOfflineTailscaleDevices") as? Bool == true)
        #expect(stored.data(forKey: "defaultConnection") != nil)
        #expect(stored.data(forKey: "customShortcuts") != nil)
    }
}

@Suite("Library presentation options")
struct LibraryPresentationTests {

    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func computer(
        _ name: String,
        host: String = "host.local",
        kind: ComputerKind = .mac,
        lastConnected: TimeInterval? = nil,
        sortIndex: Int = 0
    ) -> Computer {
        Computer(
            name: name, host: host, kind: kind,
            lastConnectedAt: lastConnected.map(stamp.addingTimeInterval), sortIndex: sortIndex)
    }

    @Test func manualOrderFollowsTheSortIndex() {
        let computers = [
            computer("C", sortIndex: 2), computer("A", sortIndex: 0), computer("B", sortIndex: 1),
        ]
        #expect(LibrarySort.manual.sorted(computers).map(\.name) == ["A", "B", "C"])
    }

    @Test func nameOrderReadsNumbersTheWayPeopleDo() {
        let computers = [
            computer("Mac 10"), computer("mac 2"), computer("Server"),
            computer("", host: "alpha.local"), computer("Mac 1"),
        ]
        // A computer without a name is sorted by the address it is shown as.
        #expect(LibrarySort.name.sorted(computers).map(\.displayName)
            == ["alpha.local", "Mac 1", "mac 2", "Mac 10", "Server"])
    }

    @Test func lastConnectedOrderPutsTheMostRecentFirstAndNeverConnectedLast() {
        let computers = [
            computer("Never"), computer("Yesterday", lastConnected: -86_400),
            computer("Just now", lastConnected: 0), computer("Last week", lastConnected: -604_800),
        ]
        #expect(LibrarySort.lastConnected.sorted(computers).map(\.name)
            == ["Just now", "Yesterday", "Last week", "Never"])
    }

    @Test func kindOrderGroupsByKindThenName() {
        let computers = [
            computer("Zed", kind: .windows), computer("Beta", kind: .mac),
            computer("Alpha", kind: .linux), computer("Alpha", kind: .mac),
            computer("Gamma", kind: .raspberryPi), computer("Delta", kind: .other),
        ]
        let sorted = LibrarySort.kind.sorted(computers)
        // By the kind's title — Linux, Mac, Other, Raspberry Pi, Windows PC.
        #expect(sorted.map(\.kind) == [.linux, .mac, .mac, .other, .raspberryPi, .windows])
        #expect(sorted.map(\.name) == ["Alpha", "Alpha", "Beta", "Delta", "Gamma", "Zed"])
    }

    @Test func sortingDoesNotAddOrDropComputers() {
        let computers = (0..<20).map { index in
            computer("Computer \(index % 7)", kind: ComputerKind.allCases[index % 5],
                     lastConnected: index.isMultiple(of: 3) ? nil : Double(index), sortIndex: index % 4)
        }
        for sort in LibrarySort.allCases {
            #expect(Set(sort.sorted(computers).map(\.id)) == Set(computers.map(\.id)))
            #expect(sort.sorted(computers).count == computers.count)
            #expect(!sort.title.isEmpty)
        }
        #expect(LibrarySort.allCases.map(\.title) == ["Manual", "Name", "Last Connected", "Kind"])
    }

    @Test func layoutsAndToolbarButtonsAreLabelled() {
        #expect(LibraryLayout.allCases.map(\.title) == ["Grid", "List"])
        #expect(LibraryLayout.allCases.allSatisfy { !$0.symbolName.isEmpty })

        let buttons = ToolbarItemKind.allCases
        #expect(buttons.allSatisfy { !$0.title.isEmpty && !$0.symbolName.isEmpty })
        #expect(Set(buttons.map(\.title)).count == buttons.count)

        // The default toolbar offers each of its buttons once.
        let defaults = ToolbarItemKind.defaultItems
        #expect(!defaults.isEmpty)
        #expect(Set(defaults).count == defaults.count)
    }

    @Test func toolbarButtonsAreStoredByName() throws {
        let data = try JSONEncoder().encode(ToolbarItemKind.allCases)
        #expect(try JSONDecoder().decode([ToolbarItemKind].self, from: data) == ToolbarItemKind.allCases)
        #expect(ToolbarItemKind(rawValue: "typePassword") == .typePassword)
        #expect(ToolbarItemKind(rawValue: "teleporter") == nil)
    }
}

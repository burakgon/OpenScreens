import Foundation

/// Where OpenScreens keeps its files.
public enum StorageLocation {
    /// App group shared with the widget and intents on iOS.
    public static let appGroupID = "group.com.burakgon.openscreens"

    /// Root directory for the app's data.
    ///
    /// On iOS this is the shared app-group container when the app is signed
    /// with one, so the widget can read the library. Everywhere else — and on
    /// builds without the entitlement — it is Application Support.
    public static var baseDirectory: URL {
        #if os(iOS)
        if let shared = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) {
            return ensure(shared.appending(path: "OpenScreens", directoryHint: .isDirectory))
        }
        #endif
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ensure(support.appending(path: "OpenScreens", directoryHint: .isDirectory))
    }

    public static var libraryFile: URL {
        baseDirectory.appending(path: "Library.json")
    }

    public static var backupsDirectory: URL {
        ensure(baseDirectory.appending(path: "Backups", directoryHint: .isDirectory))
    }

    /// Last-seen pictures of each computer, shown on its card.
    public static var previewsDirectory: URL {
        ensure(baseDirectory.appending(path: "Previews", directoryHint: .isDirectory))
    }

    public static var knownHostsFile: URL {
        baseDirectory.appending(path: "KnownHosts.json")
    }

    /// Defaults shared with extensions when the app group is available.
    public static var defaults: UserDefaults {
        #if os(iOS)
        if FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) != nil,
           let shared = UserDefaults(suiteName: appGroupID) {
            return shared
        }
        #endif
        return .standard
    }

    @discardableResult
    private static func ensure(_ directory: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

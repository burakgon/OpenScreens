import Foundation

/// Where OpenScreens keeps its files.
public enum StorageLocation {
    /// App group shared with the widget and intents on iOS.
    public static let appGroupID = "group.com.burakgon.openscreens"

    /// Environment variable naming a directory to keep all app data in.
    ///
    /// Setting it gives a run its own private library, preferences and
    /// in-memory secrets, leaving the real ones untouched. Development and
    /// automated checks use it; it is equally handy for trying things out.
    public static let dataDirectoryVariable = "OPENSCREENS_DATA_DIR"

    /// The directory named by ``dataDirectoryVariable``, when set.
    public static var overrideDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment[dataDirectoryVariable],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Whether this run is isolated from the user's real data.
    public static var isIsolated: Bool { overrideDirectory != nil }

    /// Root directory for the app's data.
    ///
    /// On iOS this is the shared app-group container when the app is signed
    /// with one, so the widget can read the library. Everywhere else — and on
    /// builds without the entitlement — it is Application Support.
    public static var baseDirectory: URL {
        if let overrideDirectory {
            return ensure(overrideDirectory)
        }
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
        if isIsolated, let isolated = UserDefaults(suiteName: "com.burakgon.openscreens.isolated") {
            return isolated
        }
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

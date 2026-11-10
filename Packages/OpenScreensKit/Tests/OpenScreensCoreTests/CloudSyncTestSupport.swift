import Foundation
import Testing
@testable import OpenScreensCore

/// A key-value store kept in memory: one device's local copy of what is in
/// iCloud. Like the real one it answers at once and never talks to anyone;
/// tests decide when its contents travel.
final class InMemoryCloudStore: KeyValueCloudStore {
    enum Operation: Equatable, CustomStringConvertible {
        case set(String)
        case remove(String)

        var description: String {
            switch self {
            case .set(let key): "set \(key)"
            case .remove(let key): "remove \(key)"
            }
        }
    }

    private(set) var values: [String: Data] = [:]
    /// Every write made through the protocol, oldest first.
    private(set) var operations: [Operation] = []
    /// How often the protocol was asked for keys or values.
    private(set) var readCount = 0
    private(set) var synchronizeCount = 0
    /// Keys written since the last upload.
    private(set) var pendingKeys: Set<String> = []

    var isAvailable = true
    /// Behave like the store an app without the iCloud entitlement is given:
    /// accept every write and keep none.
    var discardsWrites = false
    /// Called after every write, while the writer is still in the middle of
    /// whatever it is doing.
    var onWrite: (() -> Void)?

    init(values: [String: Data] = [:]) {
        self.values = values
    }

    // MARK: KeyValueCloudStore

    var allKeys: [String] {
        readCount += 1
        return Array(values.keys)
    }

    func data(forKey key: String) -> Data? {
        readCount += 1
        return values[key]
    }

    func set(_ data: Data, forKey key: String) {
        operations.append(.set(key))
        guard !discardsWrites else { return }
        values[key] = data
        pendingKeys.insert(key)
        onWrite?()
    }

    func removeObject(forKey key: String) {
        operations.append(.remove(key))
        guard !discardsWrites else { return }
        values[key] = nil
        pendingKeys.insert(key)
        onWrite?()
    }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCount += 1
        return !discardsWrites
    }

    // MARK: Behind the engine's back

    func forgetOperations() {
        operations = []
    }

    /// Hands over the keys changed since the last upload.
    func takePendingKeys() -> Set<String> {
        defer { pendingKeys = [] }
        return pendingKeys
    }

    /// Changes a value the way a download from iCloud does: without the
    /// engine having asked for it.
    func deliver(_ data: Data?, forKey key: String) {
        values[key] = data
    }

    /// Makes this replica identical to `contents`.
    /// - Returns: The keys whose value changed.
    @discardableResult
    func replaceContents(with contents: [String: Data]) -> [String] {
        let changed = Set(values.keys).union(contents.keys).filter { values[$0] != contents[$0] }
        values = contents
        return changed.sorted()
    }

    func keys(withPrefix prefix: String) -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    // MARK: Reading what was stored

    func computer(_ id: UUID) throws -> Computer? {
        try values["c.\(id.uuidString)"].map {
            try CloudCoding.makeDecoder().decode(Computer.self, from: $0)
        }
    }

    func group(_ id: UUID) throws -> ComputerGroup? {
        try values["g.\(id.uuidString)"].map {
            try CloudCoding.makeDecoder().decode(ComputerGroup.self, from: $0)
        }
    }

    func tombstone(_ id: UUID) throws -> Date? {
        try values["t.\(id.uuidString)"].map {
            try CloudCoding.makeDecoder().decode(Date.self, from: $0)
        }
    }
}

extension NotificationCenter {
    /// Posts what the key-value store posts when its contents were changed
    /// from outside.
    func postCloudStoreChange(reason: Int?, keys: [String] = []) {
        var userInfo: [AnyHashable: Any] = [NSUbiquitousKeyValueStoreChangedKeysKey: keys]
        if let reason {
            userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] = reason
        }
        post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: userInfo)
    }
}

/// One of the user's devices: a library, a local replica of the key-value
/// store and a sync engine, wired together the way the app wires them.
@MainActor
final class SimulatedDevice {
    let library = LibraryStore(fileURL: nil, backupsDirectory: nil)
    let store: InMemoryCloudStore
    let center = NotificationCenter()
    let engine: CloudSyncEngine
    /// How often the library announced a local change.
    private(set) var localChangeCount = 0

    init(
        store: InMemoryCloudStore = InMemoryCloudStore(),
        limits: CloudSyncEngine.Limits = .iCloud,
        syncEnabled: Bool = true
    ) {
        self.store = store
        engine = CloudSyncEngine(
            library: library, store: store, notificationCenter: center, limits: limits)
        library.onChange = { [unowned self] document in
            self.localChangeCount += 1
            self.engine.libraryDidChange(document)
        }
        engine.isEnabled = syncEnabled
    }

    /// Tells the engine that the replica was changed from outside.
    func storeChangedExternally(
        reason: Int = NSUbiquitousKeyValueStoreServerChange,
        keys: [String] = []
    ) {
        center.postCloudStoreChange(reason: reason, keys: keys)
    }

    var lastSync: Date? {
        if case .idle(let lastSync) = engine.status { return lastSync }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = engine.status { return message }
        return nil
    }
}

/// iCloud, reduced to what matters to the engine: every device has its own
/// replica of the key-value store, and nothing moves between replicas until
/// `exchange()` says so. When two devices upload the same key the later
/// upload wins, as it does with the real service.
@MainActor
final class SimulatedCloud {
    private(set) var server: [String: Data] = [:]
    private(set) var devices: [SimulatedDevice] = []

    @discardableResult
    func addDevice(syncEnabled: Bool = true) -> SimulatedDevice {
        let device = SimulatedDevice(syncEnabled: syncEnabled)
        devices.append(device)
        return device
    }

    /// One round trip: every device uploads what it changed, then every
    /// device downloads what is new to it and its engine is told.
    ///
    /// - Parameter uploadOrder: Who uploads first; the last one wins a
    ///   conflict over a key. Defaults to the order the devices were added.
    /// - Returns: How many values travelled, in either direction.
    @discardableResult
    func exchange(uploadOrder: [SimulatedDevice]? = nil) -> Int {
        var travelled = 0
        for device in uploadOrder ?? devices {
            for key in device.store.takePendingKeys().sorted() {
                let value = device.store.values[key]
                if server[key] != value {
                    server[key] = value
                    travelled += 1
                }
            }
        }
        for device in devices {
            let changed = device.store.replaceContents(with: server)
            if !changed.isEmpty {
                travelled += changed.count
                device.storeChangedExternally(keys: changed)
            }
        }
        return travelled
    }

    /// Exchanges until nothing travels any more.
    /// - Returns: The number of rounds in which something travelled.
    @discardableResult
    func settle(
        withinRounds limit: Int = 8,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Int {
        var rounds = 0
        while exchange() > 0 {
            rounds += 1
            if rounds >= limit {
                Issue.record(
                    "the devices were still exchanging changes after \(limit) rounds",
                    sourceLocation: sourceLocation)
                break
            }
        }
        return rounds
    }

    /// Whether every device holds the same library and the same replica.
    var hasConverged: Bool {
        guard let first = devices.first else { return true }
        let library = first.library.document.sortedByID
        return devices.allSatisfy {
            $0.library.document.sortedByID == library && $0.store.values == server
        }
    }
}

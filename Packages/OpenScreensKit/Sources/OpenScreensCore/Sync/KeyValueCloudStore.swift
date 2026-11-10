import Foundation

/// The slice of `NSUbiquitousKeyValueStore` the sync engine needs, so tests
/// can substitute an in-memory store.
///
/// A conforming store behaves like the real one: it is a local replica that
/// answers immediately and never blocks on the network. The system uploads
/// changes and delivers other devices' changes on its own schedule, and
/// announces the latter by posting
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification`.
///
/// ``CloudSyncEngine`` calls its store from the main actor only.
public protocol KeyValueCloudStore: AnyObject {
    /// Whether iCloud can be used right now. The engine asks before every
    /// pass and calls nothing else on the store while this is `false`.
    var isAvailable: Bool { get }

    /// Every key currently in the store, including keys the engine does not
    /// own. Those count towards the same storage limits.
    var allKeys: [String] { get }

    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)

    /// Reconciles the in-memory values with the on-disk cache.
    /// - Returns: `false` when the store cannot be used, for example because
    ///   the app was built without the iCloud key-value entitlement.
    @discardableResult
    func synchronize() -> Bool
}

/// The signed-in user's iCloud key-value store,
/// `NSUbiquitousKeyValueStore.default`.
public final class UbiquitousKeyValueCloudStore: KeyValueCloudStore {

    public init() {}

    /// `false` when nobody is signed in to iCloud on this device.
    ///
    /// This cannot tell whether the app carries the iCloud key-value
    /// entitlement: on macOS the identity token is present for any process of
    /// a signed-in user. A build without the entitlement gets a store that
    /// silently discards every write, which ``CloudSyncEngine`` detects by
    /// reading back the first value it writes.
    public var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    // Looked up on use rather than held, so nothing touches the ubiquitous
    // store until the engine has established that iCloud is available.
    private var store: NSUbiquitousKeyValueStore { .default }

    public var allKeys: [String] {
        Array(store.dictionaryRepresentation.keys)
    }

    public func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    public func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    public func removeObject(forKey key: String) {
        store.removeObject(forKey: key)
    }

    @discardableResult
    public func synchronize() -> Bool {
        store.synchronize()
    }
}

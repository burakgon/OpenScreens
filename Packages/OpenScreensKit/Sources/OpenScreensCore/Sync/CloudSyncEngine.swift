import Foundation
import Observation

/// Keeps the library the same on all of the user's devices through the
/// iCloud key-value store, with no server of our own.
///
/// ## What is stored
///
/// One key per item rather than one blob: `c.<uuid>` holds a computer,
/// `g.<uuid>` a group, `t.<uuid>` the moment an item was deleted, and `meta`
/// the layout version. The store settles conflicts key by key, so two devices
/// editing different computers at the same time never overwrite each other.
/// Passwords are not part of a ``Computer`` and are never written here; they
/// live in the keychain.
///
/// ## How a pass works
///
/// A pass does not rely on any record of earlier passes. It reads the store,
/// merges it with the library using ``LibraryDocument/merge(_:_:now:)`` and
/// writes back only what the merged result has and the store lacks. Because
/// the merge can only move forwards — the newest copy of an item wins, a
/// deletion beats the copies it came after — a pass can be repeated,
/// interrupted or run on stale data without ever replacing something newer
/// with something older.
///
/// - **Pulling** hands the store's copy to ``LibraryStore/merge(_:)``. That
///   keeps each item's own modification date and does not call
///   ``LibraryStore/onChange``, so data that arrives from iCloud is never
///   sent back as if it had been edited here.
/// - **Pushing** uploads items the store has no copy of or an older copy of,
///   records deletions, removes the keys of deleted items, and forgets
///   deletions older than ``LibraryDocument/tombstoneLifetime``. Where the
///   store's copy and the library's are equally recent but differ — the same
///   computer connected to from two devices, or two edits stamped alike — it
///   uploads what the two settle on, which is the same on every device.
///
/// Turning sync on, an announcement from the store that another device
/// changed something, and ``syncNow()`` each pull and then push. A local
/// change, forwarded through ``libraryDidChange(_:)``, only pushes.
///
/// If the library would not fit inside the store's limits nothing at all is
/// uploaded, ``status`` becomes ``Status/failed(_:)``, and the library on
/// this device is left exactly as it is.
///
/// ## Wiring it up
///
/// ``LibraryStore/onChange`` is a single callback that the app may need for
/// other purposes as well, so the engine never assigns it. Forward local
/// changes from whatever handler the app installs:
///
/// ```swift
/// let sync = CloudSyncEngine(library: library)
/// library.onChange = { [weak sync] document in
///     sync?.libraryDidChange(document)
///     // …anything else that follows local changes
/// }
/// sync.isEnabled = settings.syncsWithICloud
/// ```
///
/// Call ``syncNow()`` when the app returns to the foreground.
@MainActor
@Observable
public final class CloudSyncEngine {

    public enum Status: Equatable, Sendable {
        /// Sync is turned off.
        case disabled
        /// Sync is on but iCloud cannot be used: nobody is signed in, or the
        /// app was built without the iCloud entitlement. The library keeps
        /// working on this device.
        case unavailable
        /// In step with the local iCloud store as of `lastSync`, the time of
        /// the last completed pass. The system exchanges that store with
        /// iCloud on its own schedule.
        case idle(lastSync: Date?)
        /// A pass is running. Passes are short and do not wait for the
        /// network, so this is only ever seen by code that runs during one.
        case syncing
        /// The last pass could not finish. The text explains why in words
        /// that can be shown to the user.
        case failed(String)
    }

    /// How much the key-value store can hold.
    public struct Limits: Equatable, Sendable {
        public var maximumKeyCount: Int
        /// Keys and values together, in bytes.
        public var maximumTotalBytes: Int
        public var maximumValueBytes: Int

        public init(maximumKeyCount: Int, maximumTotalBytes: Int, maximumValueBytes: Int) {
            self.maximumKeyCount = maximumKeyCount
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumValueBytes = maximumValueBytes
        }

        /// The documented limits of `NSUbiquitousKeyValueStore`: 1024 keys,
        /// 1 MB in total and 1 MB per value. "1 MB" is read as a million
        /// bytes and key names are counted too, so the engine stops a little
        /// before iCloud would.
        public static let iCloud = Limits(
            maximumKeyCount: 1024,
            maximumTotalBytes: 1_000_000,
            maximumValueBytes: 1_000_000)
    }

    public private(set) var status: Status = .disabled

    /// Whether the library is kept in step with iCloud.
    ///
    /// Turning sync on merges this device's library with the one in iCloud,
    /// in both directions. Turning it off stops listening and uploading;
    /// nothing is deleted, here or in iCloud. The setting is not persisted
    /// by the engine — drive it from ``AppSettings/syncsWithICloud``.
    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    public let limits: Limits

    /// The layout version this build reads and writes.
    static let schemaVersion = LibraryDocument.currentSchemaVersion

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let store: (any KeyValueCloudStore)?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var observations: NotificationObservations?
    @ObservationIgnored private var reader = CloudReader()

    /// True while a pass is on the call stack.
    @ObservationIgnored private var isSynchronizing = false
    /// True until the library has been merged with iCloud since sync was
    /// turned on, which has to wait while iCloud is unavailable.
    @ObservationIgnored private var owesFullPass = false
    /// The library as it was when it was last brought in step with the store.
    @ObservationIgnored private var lastSyncedDocument: LibraryDocument?
    /// A full pass waiting for the next turn of the main actor.
    @ObservationIgnored private var deferredPass: Task<Void, Never>?

    /// - Parameters:
    ///   - library: The library to keep in step.
    ///   - store: The key-value store to sync through; `nil` means iCloud is
    ///     not available at all. Defaults to the user's iCloud store.
    ///   - notificationCenter: Where the store announces changes made by
    ///     other devices.
    ///   - limits: The capacity the engine keeps the library within.
    public init(
        library: LibraryStore,
        store: (any KeyValueCloudStore)? = UbiquitousKeyValueCloudStore(),
        notificationCenter: NotificationCenter = .default,
        limits: Limits = .iCloud
    ) {
        self.library = library
        self.store = store
        self.notificationCenter = notificationCenter
        self.limits = limits
    }

    // MARK: - Triggers

    /// Merges the library with iCloud and uploads whatever iCloud is missing.
    ///
    /// The engine does this by itself when sync is turned on and whenever
    /// another device's changes arrive. Call it when the app comes back to
    /// the foreground. Does nothing while sync is off.
    public func syncNow() {
        guard isEnabled else { return }
        synchronize(.full(refreshingFromDisk: true))
    }

    /// Uploads a local change. Call this from ``LibraryStore/onChange``.
    ///
    /// The engine deliberately does not install itself as the library's
    /// change handler, because that property holds a single callback the app
    /// may also need; see the type's documentation for how to forward to it.
    ///
    /// This only uploads. It never changes the library, so it is safe to
    /// call from inside the library's own change callback; changes made on
    /// other devices are merged in when the store announces them.
    ///
    /// - Parameter document: The library as it was just saved.
    public func libraryDidChange(_ document: LibraryDocument) {
        // A call that arrives during a pass is the echo of that pass.
        guard isEnabled, !isSynchronizing else { return }
        if owesFullPass {
            // The first merge is still outstanding, and merging would change
            // the library from inside its own change callback. Do it on the
            // next turn instead; it uploads this change along with the rest.
            scheduleFullPass()
            return
        }
        guard document != lastSyncedDocument else { return }
        synchronize(.push)
    }

    // MARK: - Lifecycle

    private func start() {
        owesFullPass = true

        let observations = NotificationObservations(center: notificationCenter)
        observations.observe(
            NSUbiquitousKeyValueStore.didChangeExternallyNotification
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            CloudSyncEngine.onMainActor { [weak self] in
                self?.storeDidChangeExternally(reason: reason)
            }
        }
        observations.observe(.NSUbiquityIdentityDidChange) { [weak self] _ in
            CloudSyncEngine.onMainActor { [weak self] in
                self?.accountDidChange()
            }
        }
        self.observations = observations

        synchronize(.full(refreshingFromDisk: true))
    }

    private func stop() {
        observations = nil
        deferredPass?.cancel()
        deferredPass = nil
        owesFullPass = false
        lastSyncedDocument = nil
        status = .disabled
    }

    // MARK: - Changes from outside

    private func storeDidChangeExternally(reason: Int?) {
        guard isEnabled else { return }
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            // iCloud turned down what was uploaded. Take whatever did arrive
            // and say so; uploading resumes with the next local change, which
            // is also how the user makes room.
            synchronize(.pull)
            if case .idle = status {
                status = .failed(Self.quotaMessage)
            }
        case NSUbiquitousKeyValueStoreAccountChange:
            // The store now holds another account's data, so nothing known
            // about the previous one still applies.
            lastSyncedDocument = nil
            synchronize(.full(refreshingFromDisk: false))
        default:
            // Another device changed something, or the first download from
            // iCloud finished and replaced what had been written before it.
            // Either way: merge what is there now and put back what is
            // missing.
            synchronize(.full(refreshingFromDisk: false))
        }
    }

    /// The user signed in to iCloud, signed out, or switched accounts.
    private func accountDidChange() {
        guard isEnabled else { return }
        lastSyncedDocument = nil
        synchronize(.full(refreshingFromDisk: true))
    }

    // MARK: - Passes

    private enum Pass: Equatable {
        /// Merge iCloud into the library, then upload what iCloud lacks.
        case full(refreshingFromDisk: Bool)
        /// Upload local changes; leave the library alone.
        case push
        /// Merge iCloud into the library; upload nothing.
        case pull
    }

    private func synchronize(_ pass: Pass) {
        guard isEnabled else { return }
        guard !isSynchronizing else {
            // Asked for from inside a pass. Passes do not nest: run once
            // more after this one has finished.
            scheduleFullPass()
            return
        }
        isSynchronizing = true
        let outcome = run(pass)
        isSynchronizing = false
        if isEnabled {
            status = outcome
        }
    }

    private func scheduleFullPass() {
        guard deferredPass == nil else { return }
        deferredPass = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.deferredPass = nil
            self.synchronize(.full(refreshingFromDisk: false))
        }
    }

    private func run(_ pass: Pass) -> Status {
        guard let store, store.isAvailable else {
            owesFullPass = true
            lastSyncedDocument = nil
            return .unavailable
        }
        status = .syncing
        if pass == .full(refreshingFromDisk: true) {
            store.synchronize()
        }

        let cloud = reader.read(store)
        let remote = cloud.document
        if pass != .push {
            library.merge(remote)
            owesFullPass = false
        }
        let now = Date.now

        if let version = cloud.schemaVersion, version > Self.schemaVersion {
            // A newer version of the app owns the store now. Its data was
            // merged as far as this version understands it, but writing in
            // the old layout could damage what the newer one stored.
            return .failed(Self.newerVersionMessage)
        }
        guard pass != .pull else { return .idle(lastSync: now) }

        // Plan against the merge of both sides, not against the library
        // alone: that is what keeps a push from overwriting news in the
        // store that has not been merged into the library yet.
        let local = library.document
        let desired = LibraryDocument.merge(local, remote, now: now)
        let plan: CloudSyncPlan
        do {
            plan = try CloudSyncPlan(
                desired: desired, cloud: cloud, schemaVersion: Self.schemaVersion, now: now)
        } catch {
            return .failed(
                "The library could not be prepared for iCloud: \(error.localizedDescription)")
        }
        if let violation = plan.violation(of: limits) {
            return .failed(Self.describe(violation, in: desired))
        }
        guard apply(plan, to: store) else {
            owesFullPass = true
            lastSyncedDocument = nil
            return .unavailable
        }
        lastSyncedDocument = local
        return .idle(lastSync: now)
    }

    /// Carries out a plan.
    /// - Returns: `false` when the store does not keep what is written to it.
    private func apply(_ plan: CloudSyncPlan, to store: any KeyValueCloudStore) -> Bool {
        guard !plan.isEmpty else { return true }
        for (index, write) in plan.writes.enumerated() {
            let key = write.key.rawValue
            store.set(write.data, forKey: key)
            // An app built without the iCloud key-value entitlement is handed
            // a store that accepts every write and keeps none of them. Read
            // the first one back, so that case is reported as iCloud being
            // unavailable instead of as a sync that worked.
            if index == 0, store.data(forKey: key) != write.data {
                return false
            }
        }
        for key in plan.removals {
            store.removeObject(forKey: key.rawValue)
        }
        store.synchronize()
        return true
    }

    // MARK: - Messages

    private static let quotaMessage =
        "iCloud has no room left for the OpenScreens library, so recent changes were not "
        + "uploaded. Nothing on this device was changed."

    private static let newerVersionMessage =
        "The library in iCloud was saved by a newer version of OpenScreens. Update OpenScreens "
        + "on this device to keep it in sync."

    private static func describe(
        _ violation: CloudLimitViolation,
        in document: LibraryDocument
    ) -> String {
        let reassurance = "Nothing was uploaded, and nothing on this device was changed."
        switch violation {
        case .keyCount(let needed, let limit):
            return "The library is too large to sync with iCloud: its computers, groups and "
                + "recent deletions need \(needed) entries, and iCloud allows \(limit). "
                + reassurance
        case .totalBytes(let needed, let limit):
            return "The library is too large to sync with iCloud: it needs "
                + "\(kilobytes(needed)), and iCloud allows \(kilobytes(limit)). " + reassurance
        case .valueBytes(let key, let size, let limit):
            let name: String? = switch key {
            case .computer(let id): document.computers.first { $0.id == id }?.displayName
            case .group(let id): document.groups.first { $0.id == id }?.name
            case .metadata, .tombstone: nil
            }
            let subject = name.map { "“\($0)”" } ?? "One item"
            return "\(subject) is too large to sync with iCloud: it needs \(kilobytes(size)), "
                + "and iCloud allows \(kilobytes(limit)) per item. " + reassurance
        }
    }

    private static func kilobytes(_ bytes: Int) -> String {
        "\((bytes + 999) / 1000) KB"
    }

    // MARK: - Getting to the main actor

    /// Runs `work` on the main actor: at once when already on the main
    /// thread, so a change is dealt with before whoever announced it carries
    /// on, and otherwise on the main actor's next turn. The key-value store
    /// posts its notifications from a thread of its own.
    private nonisolated static func onMainActor(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }
}

/// Holds block-based notification observations and ends them when it is
/// released. Because that happens wherever the last reference goes away, the
/// engine needs no deinitializer of its own that would have to reach into
/// main-actor state.
private final class NotificationObservations {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func observe(
        _ name: Notification.Name,
        using handler: @escaping @Sendable (Notification) -> Void
    ) {
        // No queue: the handler runs on the posting thread and decides for
        // itself how to reach the main actor.
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil, using: handler))
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

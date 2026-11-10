import Foundation

// How the library is represented in the iCloud key-value store.
//
// Everything in this file is plain value logic: it knows nothing about the
// main actor, notifications or which store it is talking to, so the rules
// that decide what gets written can be read — and tested — on their own.

// MARK: - Keys

/// A key the sync engine owns.
///
/// The library is stored as one key per item — `c.<uuid>` for a computer,
/// `g.<uuid>` for a group, `t.<uuid>` for a deletion, plus a single `meta`
/// key — rather than as one blob. The key-value store resolves conflicts per
/// key, so two devices that edit different computers at the same time never
/// overwrite each other.
enum CloudKey: Hashable, Sendable {
    case metadata
    case computer(UUID)
    case group(UUID)
    case tombstone(UUID)

    private static let metadataName = "meta"
    private static let computerPrefix = "c."
    private static let groupPrefix = "g."
    private static let tombstonePrefix = "t."

    /// Recognises a key written by the engine. Anything else in the store,
    /// including near misses such as a lowercase UUID, belongs to someone
    /// else and is left alone.
    init?(_ rawValue: String) {
        if rawValue == Self.metadataName {
            self = .metadata
            return
        }
        let name = String(rawValue.dropFirst(2))
        guard let id = UUID(uuidString: name), id.uuidString == name else { return nil }
        switch String(rawValue.prefix(2)) {
        case Self.computerPrefix: self = .computer(id)
        case Self.groupPrefix: self = .group(id)
        case Self.tombstonePrefix: self = .tombstone(id)
        default: return nil
        }
    }

    /// The key as stored: 38 bytes at most, well inside the store's 64.
    var rawValue: String {
        switch self {
        case .metadata: Self.metadataName
        case .computer(let id): Self.computerPrefix + id.uuidString
        case .group(let id): Self.groupPrefix + id.uuidString
        case .tombstone(let id): Self.tombstonePrefix + id.uuidString
        }
    }
}

// MARK: - Values

/// The value of the `meta` key: which version of this layout the store holds.
struct CloudMetadata: Codable, Equatable, Sendable {
    var schemaVersion: Int
}

enum CloudCoding {
    // Compact JSON with sorted keys, so the same item always produces the
    // same bytes.
    //
    // Dates are written as the exact floating-point value `Date` holds, not
    // as the ISO 8601 text the library file uses. Merging is decided by
    // comparing timestamps, so a copy that comes back from iCloud has to
    // compare equal to the copy that was sent. Rounding to whole seconds
    // would make a device consider its own in-memory copy newer than the
    // identical one it just uploaded, and would turn two edits made within
    // the same second on different devices into a tie that neither side
    // gives up.
    //
    // Non-finite numbers are spelled out rather than rejected: one computer
    // with a broken setting must not stop the whole library from syncing.

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// Whether `rewritten` still says everything `stored` says.
    ///
    /// Both are JSON. Every key in `stored` has to be in `rewritten` with the
    /// same value; `rewritten` may say more. A record written by a later
    /// version of the app does not pass this against what this version would
    /// write in its place: fields this version does not know are dropped when
    /// it decodes the record, and values it does not know become defaults.
    static func keepsEverything(in stored: Data, whenWrittenAs rewritten: Data) -> Bool {
        if stored == rewritten { return true }
        guard let old = try? JSONSerialization.jsonObject(with: stored, options: .fragmentsAllowed),
              let new = try? JSONSerialization.jsonObject(with: rewritten, options: .fragmentsAllowed)
        else { return false }
        return covers(new, everythingIn: old)
    }

    private static func covers(_ new: Any, everythingIn old: Any) -> Bool {
        if let old = old as? [String: Any] {
            guard let new = new as? [String: Any] else { return false }
            return old.allSatisfy { key, value in
                new[key].map { covers($0, everythingIn: value) } ?? false
            }
        }
        if let old = old as? [Any] {
            guard let new = new as? [Any], new.count == old.count else { return false }
            return zip(new, old).allSatisfy { covers($0, everythingIn: $1) }
        }
        // Strings, numbers, booleans and null.
        return (old as AnyObject).isEqual(new)
    }
}

// MARK: - Reading

/// What one pass found in the key-value store.
struct CloudSnapshot: Sendable {
    var computers: [UUID: Computer] = [:]
    var groups: [UUID: ComputerGroup] = [:]
    var tombstones: [UUID: Date] = [:]

    /// The layout version recorded under `meta`, when there is one.
    var schemaVersion: Int?

    /// The stored bytes of every key the engine owns.
    var values: [CloudKey: Data] = [:]

    /// Keys of ours whose value could not be understood: damaged, written in
    /// a format this version does not know, or not data at all.
    var unreadable: Set<CloudKey> = []

    /// Bytes taken by every key in the store — key and value together.
    /// Foreign keys are included because they share the same quota.
    var sizes: [String: Int] = [:]

    /// The cloud's copy of the library, ready to be merged.
    var document: LibraryDocument {
        LibraryDocument(
            computers: computers.values.sorted(by: CloudSnapshot.precedes),
            groups: groups.values.sorted(by: CloudSnapshot.precedes),
            tombstones: Dictionary(
                uniqueKeysWithValues: tombstones.map { ($0.key.uuidString, $0.value) }))
    }

    // Dictionaries have no order. Items new to this device are appended in
    // the order they are handed over, so make that order the same everywhere.
    private static func precedes(_ lhs: Computer, _ rhs: Computer) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func precedes(_ lhs: ComputerGroup, _ rhs: ComputerGroup) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Reads the store into a ``CloudSnapshot``.
///
/// The reader remembers what each value decoded to. A pass runs after every
/// local change, and nearly every value is the same as it was the pass
/// before, so comparing bytes is all an unchanged item costs.
struct CloudReader {
    private enum Record {
        case computer(Computer)
        case group(ComputerGroup)
        case tombstone(Date)
        case metadata(CloudMetadata)
    }

    private var cache: [CloudKey: (data: Data, record: Record?)] = [:]
    private let decoder = CloudCoding.makeDecoder()

    mutating func read(_ store: any KeyValueCloudStore) -> CloudSnapshot {
        var snapshot = CloudSnapshot()
        var decoded: [CloudKey: (data: Data, record: Record?)] = [:]

        for name in store.allKeys {
            let data = store.data(forKey: name)
            snapshot.sizes[name] = name.utf8.count + (data?.count ?? 0)

            guard let key = CloudKey(name) else { continue }
            guard let data else {
                snapshot.unreadable.insert(key)
                continue
            }
            snapshot.values[key] = data

            let record: Record?
            if let known = cache[key], known.data == data {
                record = known.record
            } else {
                record = decode(data, for: key)
            }
            decoded[key] = (data, record)

            switch record {
            case .computer(let computer): snapshot.computers[computer.id] = computer
            case .group(let group): snapshot.groups[group.id] = group
            case .tombstone(let date):
                if case .tombstone(let id) = key { snapshot.tombstones[id] = date }
            case .metadata(let metadata): snapshot.schemaVersion = metadata.schemaVersion
            case nil: snapshot.unreadable.insert(key)
            }
        }

        // Keeping only what was just seen stops the cache from holding on to
        // values that have left the store.
        cache = decoded
        return snapshot
    }

    private func decode(_ data: Data, for key: CloudKey) -> Record? {
        switch key {
        case .metadata:
            return (try? decoder.decode(CloudMetadata.self, from: data)).map(Record.metadata)
        case .computer(let id):
            // An item filed under another item's key is damage, not data.
            guard let computer = try? decoder.decode(Computer.self, from: data),
                  computer.id == id else { return nil }
            return .computer(computer)
        case .group(let id):
            guard let group = try? decoder.decode(ComputerGroup.self, from: data),
                  group.id == id else { return nil }
            return .group(group)
        case .tombstone:
            // A deletion without a real moment in time could never be
            // outlived by a later edit, nor ever expire.
            guard let date = try? decoder.decode(Date.self, from: data),
                  date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return .tombstone(date)
        }
    }
}

// MARK: - Writing

/// A limit of the key-value store that a plan would break.
enum CloudLimitViolation: Equatable, Sendable {
    case keyCount(needed: Int, limit: Int)
    case totalBytes(needed: Int, limit: Int)
    case valueBytes(key: CloudKey, size: Int, limit: Int)
}

/// The changes that bring the key-value store in line with a library.
///
/// `desired` must already be the merge of the local library and the cloud's
/// copy. That is what makes writing safe: the plan can then only ever move
/// the store forward to something every device would agree on, and never
/// replaces a newer value with an older one.
struct CloudSyncPlan: Sendable {
    struct Write: Equatable, Sendable {
        let key: CloudKey
        let data: Data
    }

    /// Values to store, in the order they should be written.
    private(set) var writes: [Write] = []
    /// Keys to delete, after the writes.
    private(set) var removals: [CloudKey] = []
    /// How many keys the store would hold afterwards, foreign ones included.
    private(set) var projectedKeyCount = 0
    /// How many bytes the store would hold afterwards, foreign keys included.
    private(set) var projectedByteCount = 0

    var isEmpty: Bool { writes.isEmpty && removals.isEmpty }

    init(desired: LibraryDocument, cloud: CloudSnapshot, schemaVersion: Int, now: Date) throws {
        let encoder = CloudCoding.makeEncoder()
        var writes: [Write] = []

        func stage(_ value: some Encodable, at key: CloudKey) throws {
            let data = try encoder.encode(value)
            // Bytes that are already in place are never written again.
            if cloud.values[key] != data {
                writes.append(Write(key: key, data: data))
            }
        }

        if cloud.schemaVersion != schemaVersion {
            try stage(CloudMetadata(schemaVersion: schemaVersion), at: .metadata)
        }

        // An item the cloud has no readable copy of is uploaded. For one it
        // has, what goes up is what the two copies settle on —
        // ``Computer/resolve(_:_:)`` and ``ComputerGroup/resolve(_:_:)``: the
        // later edit; when neither is later, the one every device picks; and
        // for a computer the record of connections taken from both — unless
        // the cloud already holds exactly that.
        //
        // Every device arrives at the same result from whichever of the
        // copies it has, so once that result is in the cloud nobody has
        // anything left to write. Devices that held different copies end up
        // with one, without overwriting each other back and forth.
        //
        // Items are compared as this version reads them, not byte for byte:
        // the same item as written by another version of the app is left
        // alone, with whatever else that version stored in it.
        //
        // Groups are written before the computers that refer to them, so a
        // device that receives only the first part of an upload never sees a
        // computer pointing at a group it has not heard of.
        let groups = Self.newest(desired.groups, modifiedAt: \.modifiedAt)
        for group in groups {
            let key = CloudKey.group(group.id)
            guard let existing = cloud.groups[group.id] else {
                try stage(group, at: key)
                continue
            }
            let settled = ComputerGroup.resolve(existing, group)
            if settled != existing {
                try stage(settled, at: key)
            }
        }

        let computers = Self.newest(desired.computers, modifiedAt: \.modifiedAt)
        for computer in computers {
            let key = CloudKey.computer(computer.id)
            guard let existing = cloud.computers[computer.id] else {
                try stage(computer, at: key)
                continue
            }
            let settled = Computer.resolve(existing, computer)
            guard settled != existing else { continue }
            // Connecting is not an edit. A record that says more than this
            // version reads came from a later one, and writing it again
            // would erase the rest — too much to pay for adding when this
            // device last connected.
            if Self.differOnlyInConnections(settled, existing),
               let stored = cloud.values[key],
               !CloudCoding.keepsEverything(in: stored, whenWrittenAs: try encoder.encode(existing)) {
                continue
            }
            try stage(settled, at: key)
        }

        // Deletions, minus the ones that have been remembered long enough.
        let liveComputers = Set(computers.map(\.id))
        let liveGroups = Set(groups.map(\.id))
        var tombstones: [UUID: Date] = [:]
        for (name, date) in desired.tombstones {
            guard let id = UUID(uuidString: name),
                  !liveComputers.contains(id), !liveGroups.contains(id),
                  now.timeIntervalSince(date) < LibraryDocument.tombstoneLifetime else { continue }
            tombstones[id] = max(tombstones[id] ?? date, date)
        }
        for (id, date) in tombstones.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let existing = cloud.tombstones[id], existing >= date { continue }
            try stage(date, at: .tombstone(id))
        }

        // Removals come after every write. A device that sees only part of
        // an upload then finds a deletion next to the item it deletes, rather
        // than an item that has vanished without explanation — which it
        // would answer by uploading its own copy again.
        //
        // An item that is missing from `desired` although the cloud has a
        // readable copy was deleted. One that cannot be read and is not known
        // to be deleted is left exactly as it is: it may be something a
        // newer version of the app understands.
        var removals: [CloudKey] = []
        let owned = Set(cloud.values.keys).union(cloud.unreadable)
        for key in owned.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch key {
            case .metadata:
                break
            case .computer(let id):
                if !liveComputers.contains(id),
                   cloud.computers[id] != nil || tombstones[id] != nil {
                    removals.append(key)
                }
            case .group(let id):
                if !liveGroups.contains(id),
                   cloud.groups[id] != nil || tombstones[id] != nil {
                    removals.append(key)
                }
            case .tombstone(let id):
                // Either a later edit brought the item back, or the deletion
                // is older than it needs to be remembered.
                if tombstones[id] == nil {
                    removals.append(key)
                }
            }
        }

        var sizes = cloud.sizes
        for write in writes {
            sizes[write.key.rawValue] = write.key.rawValue.utf8.count + write.data.count
        }
        for key in removals {
            sizes[key.rawValue] = nil
        }

        self.writes = writes
        self.removals = removals
        self.projectedKeyCount = sizes.count
        self.projectedByteCount = sizes.values.reduce(0, +)
    }

    /// The first limit the plan would break, if any.
    ///
    /// A plan that only deletes is always allowed: it can only make room.
    func violation(of limits: CloudSyncEngine.Limits) -> CloudLimitViolation? {
        guard !writes.isEmpty else { return nil }
        if let largest = writes.max(by: { $0.data.count < $1.data.count }),
           largest.data.count > limits.maximumValueBytes {
            return .valueBytes(
                key: largest.key, size: largest.data.count, limit: limits.maximumValueBytes)
        }
        if projectedKeyCount > limits.maximumKeyCount {
            return .keyCount(needed: projectedKeyCount, limit: limits.maximumKeyCount)
        }
        if projectedByteCount > limits.maximumTotalBytes {
            return .totalBytes(needed: projectedByteCount, limit: limits.maximumTotalBytes)
        }
        return nil
    }

    /// Whether two copies of a computer differ in nothing but when it was
    /// last connected to and when that record was last cleared.
    private static func differOnlyInConnections(_ a: Computer, _ b: Computer) -> Bool {
        var (a, b) = (a, b)
        for field in [\Computer.lastConnectedAt, \Computer.connectionsClearedAt] {
            a[keyPath: field] = nil
            b[keyPath: field] = nil
        }
        return a == b
    }

    /// One entry per ID, in document order. A well-formed library never has
    /// two, but if it does the most recent is the one worth uploading.
    private static func newest<Item: Identifiable>(
        _ items: [Item],
        modifiedAt: KeyPath<Item, Date>
    ) -> [Item] where Item.ID == UUID {
        var positions: [UUID: Int] = [:]
        var result: [Item] = []
        for item in items {
            if let position = positions[item.id] {
                if item[keyPath: modifiedAt] > result[position][keyPath: modifiedAt] {
                    result[position] = item
                }
            } else {
                positions[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }
}

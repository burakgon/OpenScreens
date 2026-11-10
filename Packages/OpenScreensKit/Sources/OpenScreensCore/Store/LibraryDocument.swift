import Foundation

/// The complete saved library: what is written to disk, mirrored to iCloud
/// and exported as a backup.
public struct LibraryDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var computers: [Computer]
    public var groups: [ComputerGroup]
    /// Deleted item IDs and when they were deleted. A deletion has to be
    /// remembered for a while, otherwise a device that has not heard about it
    /// yet would bring the item back on its next sync.
    public var tombstones: [String: Date]

    public init(
        schemaVersion: Int = LibraryDocument.currentSchemaVersion,
        computers: [Computer] = [],
        groups: [ComputerGroup] = [],
        tombstones: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.computers = computers
        self.groups = groups
        self.tombstones = tombstones
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        computers = try c.decodeIfPresent([Computer].self, forKey: .computers) ?? []
        groups = try c.decodeIfPresent([ComputerGroup].self, forKey: .groups) ?? []
        tombstones = try c.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
    }

    // MARK: Coding

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try LibraryDocument.encoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> LibraryDocument {
        try decoder().decode(LibraryDocument.self, from: data)
    }

    // MARK: Merging

    /// How long a deletion is remembered.
    public static let tombstoneLifetime: TimeInterval = 90 * 24 * 60 * 60

    /// Combines two copies of the library into one.
    ///
    /// Each computer and group is resolved on its own: the most recently
    /// modified copy wins, and a deletion wins over any copy that was last
    /// modified before it happened. The operation is commutative and
    /// idempotent, so devices converge regardless of the order they sync in.
    public static func merge(
        _ a: LibraryDocument,
        _ b: LibraryDocument,
        now: Date = .now
    ) -> LibraryDocument {
        var tombstones = a.tombstones
        for (id, date) in b.tombstones {
            tombstones[id] = max(tombstones[id] ?? .distantPast, date)
        }

        func resolve<Item: Identifiable>(
            _ lhs: [Item],
            _ rhs: [Item],
            modifiedAt: (Item) -> Date
        ) -> [Item] where Item.ID == UUID {
            var byID: [UUID: Item] = [:]
            var order: [UUID] = []
            for item in lhs + rhs {
                if let existing = byID[item.id] {
                    if modifiedAt(item) > modifiedAt(existing) {
                        byID[item.id] = item
                    }
                } else {
                    byID[item.id] = item
                    order.append(item.id)
                }
            }
            return order.compactMap { id in
                guard let item = byID[id] else { return nil }
                if let deletedAt = tombstones[id.uuidString], deletedAt >= modifiedAt(item) {
                    return nil
                }
                return item
            }
        }

        let computers = resolve(a.computers, b.computers) { $0.modifiedAt }
        let groups = resolve(a.groups, b.groups) { $0.modifiedAt }

        // A tombstone that lost to a newer edit no longer describes anything,
        // and old ones have done their job.
        let liveIDs = Set(computers.map(\.id.uuidString) + groups.map(\.id.uuidString))
        tombstones = tombstones.filter { id, date in
            !liveIDs.contains(id) && now.timeIntervalSince(date) < tombstoneLifetime
        }

        let groupIDs = Set(groups.map(\.id))
        let repaired = computers.map { computer -> Computer in
            guard let groupID = computer.groupID, !groupIDs.contains(groupID) else {
                return computer
            }
            var copy = computer
            copy.groupID = nil
            return copy
        }

        return LibraryDocument(
            schemaVersion: max(a.schemaVersion, b.schemaVersion),
            computers: repaired,
            groups: groups,
            tombstones: tombstones)
    }
}

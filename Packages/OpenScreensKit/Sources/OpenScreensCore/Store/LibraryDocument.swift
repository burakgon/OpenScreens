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
        // Merging compares timestamps, so a date has to come back exactly as
        // it went out. Formatted dates lose the fraction of a second; the
        // number Foundation keeps a date as loses nothing.
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            // Written out by hand, or by a version that formatted its dates.
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(text) is not a date")
        }
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
    /// modified before it happened. Nothing depends on which copy is which or
    /// on the order copies arrive in, so devices converge however they sync.
    public static func merge(
        _ a: LibraryDocument,
        _ b: LibraryDocument,
        now: Date = .now
    ) -> LibraryDocument {
        var tombstones = a.tombstones
        for (id, date) in b.tombstones {
            tombstones[id] = max(tombstones[id] ?? .distantPast, date)
        }

        func isDeleted(_ id: UUID, modifiedAt: Date) -> Bool {
            guard let deletedAt = tombstones[id.uuidString] else { return false }
            return deletedAt >= modifiedAt
        }

        var computersByID: [UUID: Computer] = [:]
        for computer in a.computers + b.computers {
            computersByID[computer.id] = computersByID[computer.id]
                .map { Computer.resolve($0, computer) } ?? computer
        }
        let computers = computersByID.values
            .filter { !isDeleted($0.id, modifiedAt: $0.modifiedAt) }
            .sorted(by: Computer.precedesInLibrary)

        var groupsByID: [UUID: ComputerGroup] = [:]
        for group in a.groups + b.groups {
            groupsByID[group.id] = groupsByID[group.id]
                .map { ComputerGroup.resolve($0, group) } ?? group
        }
        let groups = groupsByID.values
            .filter { !isDeleted($0.id, modifiedAt: $0.modifiedAt) }
            .sorted(by: ComputerGroup.precedesInLibrary)

        // A tombstone that lost to a newer edit no longer describes anything,
        // and old ones have done their job.
        let liveIDs = Set(computers.map(\.id.uuidString) + groups.map(\.id.uuidString))
        tombstones = tombstones.filter { id, date in
            !liveIDs.contains(id) && now.timeIntervalSince(date) < tombstoneLifetime
        }

        // A computer may name a group that is not here: the two are separate
        // records and need not arrive together. The reference is left alone
        // and read as "no group" until the group turns up.
        return LibraryDocument(
            schemaVersion: max(a.schemaVersion, b.schemaVersion),
            computers: computers,
            groups: groups,
            tombstones: tombstones)
    }

    /// The bytes two devices compare to settle a tie the same way.
    fileprivate static func canonicalBytes(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .deferredToDate
        return (try? encoder.encode(value)) ?? Data()
    }
}

// MARK: - Resolving two copies of one item

extension Computer {
    /// The order computers are kept in: the user's own order first, then age,
    /// then something that never ties.
    public static func precedesInLibrary(_ a: Computer, _ b: Computer) -> Bool {
        (a.sortIndex, a.createdAt, a.id.uuidString) < (b.sortIndex, b.createdAt, b.id.uuidString)
    }

    /// Picks between two copies of the same computer.
    ///
    /// The later edit wins. When a computer was last connected to is not an
    /// edit — connecting does not touch `modifiedAt` — so a connection made
    /// after the winning edit is carried over from the losing copy.
    fileprivate static func resolve(_ a: Computer, _ b: Computer) -> Computer {
        guard a != b else { return a }
        var (winner, loser) = (a, b)
        if b.modifiedAt > a.modifiedAt {
            (winner, loser) = (b, a)
        } else if b.modifiedAt == a.modifiedAt {
            // Neither is newer. Both devices must still pick the same one;
            // the connection time is left out, as it is settled below.
            var (plainA, plainB) = (a, b)
            plainA.lastConnectedAt = nil
            plainB.lastConnectedAt = nil
            let (bytesA, bytesB) = (LibraryDocument.canonicalBytes(plainA), LibraryDocument.canonicalBytes(plainB))
            if bytesA.lexicographicallyPrecedes(bytesB) {
                (winner, loser) = (b, a)
            }
        }
        if let connected = loser.lastConnectedAt,
           connected > winner.modifiedAt,
           connected > winner.lastConnectedAt ?? .distantPast {
            winner.lastConnectedAt = connected
        }
        return winner
    }
}

extension ComputerGroup {
    public static func precedesInLibrary(_ a: ComputerGroup, _ b: ComputerGroup) -> Bool {
        (a.sortIndex, a.id.uuidString) < (b.sortIndex, b.id.uuidString)
    }

    fileprivate static func resolve(_ a: ComputerGroup, _ b: ComputerGroup) -> ComputerGroup {
        if b.modifiedAt != a.modifiedAt {
            return b.modifiedAt > a.modifiedAt ? b : a
        }
        let (bytesA, bytesB) = (LibraryDocument.canonicalBytes(a), LibraryDocument.canonicalBytes(b))
        return bytesA.lexicographicallyPrecedes(bytesB) ? b : a
    }
}

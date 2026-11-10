import Foundation
import Testing
@testable import OpenScreensCore

/// Pseudo-random numbers that can be replayed (SplitMix64). A property test
/// that fails reports its seed, and the same seed reproduces the failure.
struct ReplayableRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }
}

/// A directory that lives as long as the test that created it.
final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "OpenScreensCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name)
    }

    func directory(_ name: String) throws -> URL {
        let directory = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    var contents: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
}

enum LibraryFixtures {
    /// A recent moment on a whole second. The library file stores dates
    /// without fractions, so only whole seconds survive a save unchanged.
    static func recentWholeSecond(secondsAgo: TimeInterval = 3600) -> Date {
        Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 - secondsAgo).rounded(.down))
    }

    static func computer(
        _ name: String,
        id: UUID = UUID(),
        host: String? = nil,
        groupID: UUID? = nil,
        modifiedAt: Date,
        sortIndex: Int = 0
    ) -> Computer {
        Computer(
            id: id,
            name: name,
            host: host ?? "\(name.lowercased()).local",
            groupID: groupID,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            sortIndex: sortIndex)
    }

    static func group(
        _ name: String,
        id: UUID = UUID(),
        modifiedAt: Date,
        sortIndex: Int = 0
    ) -> ComputerGroup {
        ComputerGroup(id: id, name: name, sortIndex: sortIndex, modifiedAt: modifiedAt)
    }

    /// Returns once the wall clock has moved on.
    ///
    /// The library stamps every change with `Date.now`, which ticks in
    /// microseconds: two changes made back to back can carry the very same
    /// timestamp. A test whose outcome depends on which change came later
    /// must not leave that to chance.
    static func letClockAdvance() {
        let start = Date.now
        // The wall clock can be set back; do not wait for it for ever.
        let patience = ContinuousClock.now + .seconds(2)
        while Date.now <= start, ContinuousClock.now < patience {}
    }
}

extension LibraryDocument {
    /// The same library with its items in a fixed order, for comparing what
    /// two documents contain rather than how they happen to be arranged.
    var sortedByID: LibraryDocument {
        var copy = self
        copy.computers.sort { $0.id.uuidString < $1.id.uuidString }
        copy.groups.sort { $0.id.uuidString < $1.id.uuidString }
        return copy
    }
}

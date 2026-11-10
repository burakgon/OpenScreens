import Foundation
import Testing
@testable import OpenScreensCore

@Suite("LibraryDocument merging")
struct LibraryDocumentMergeTests {

    /// The moment the merges in this suite happen at.
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A moment `seconds` before the merge.
    private func ago(_ seconds: TimeInterval) -> Date {
        Self.now.addingTimeInterval(-seconds)
    }

    private func merge(_ a: LibraryDocument, _ b: LibraryDocument) -> LibraryDocument {
        LibraryDocument.merge(a, b, now: Self.now)
    }

    /// The merge both ways round. The two must agree on what the library holds.
    private func bothWays(_ a: LibraryDocument, _ b: LibraryDocument) -> [LibraryDocument] {
        [merge(a, b), merge(b, a)]
    }

    // MARK: Newest wins

    @Test func newestCopyOfAComputerWins() {
        let id = UUID()
        let older = LibraryFixtures.computer("Before", id: id, modifiedAt: ago(200))
        let newer = LibraryFixtures.computer("After", id: id, modifiedAt: ago(100))

        for merged in bothWays(
            LibraryDocument(computers: [older]), LibraryDocument(computers: [newer])) {
            #expect(merged.computers == [newer])
        }
    }

    @Test func newestCopyOfAGroupWins() {
        let id = UUID()
        let older = LibraryFixtures.group("Before", id: id, modifiedAt: ago(200))
        let newer = LibraryFixtures.group("After", id: id, modifiedAt: ago(100))

        for merged in bothWays(LibraryDocument(groups: [older]), LibraryDocument(groups: [newer])) {
            #expect(merged.groups == [newer])
        }
    }

    @Test func everyItemIsResolvedOnItsOwn() {
        // Each side holds the newer copy of one computer and the older copy
        // of the other: the result takes one from each.
        let studio = UUID(), server = UUID()
        let a = LibraryDocument(computers: [
            LibraryFixtures.computer("Studio, renamed", id: studio, modifiedAt: ago(10)),
            LibraryFixtures.computer("Server", id: server, modifiedAt: ago(500)),
        ])
        let b = LibraryDocument(computers: [
            LibraryFixtures.computer("Studio", id: studio, modifiedAt: ago(500)),
            LibraryFixtures.computer("Server, renamed", id: server, modifiedAt: ago(20)),
        ])

        for merged in bothWays(a, b) {
            let names = Set(merged.computers.map(\.name))
            #expect(names == ["Studio, renamed", "Server, renamed"])
        }
    }

    @Test func itemsThatExistOnOnlyOneSideAreKept() {
        let mine = LibraryFixtures.computer("Mine", modifiedAt: ago(300))
        let theirs = LibraryFixtures.computer("Theirs", modifiedAt: ago(200))
        let myGroup = LibraryFixtures.group("Home", modifiedAt: ago(100))
        let theirGroup = LibraryFixtures.group("Work", modifiedAt: ago(50))

        for merged in bothWays(
            LibraryDocument(computers: [mine], groups: [myGroup]),
            LibraryDocument(computers: [theirs], groups: [theirGroup])) {
            #expect(Set(merged.computers) == [mine, theirs])
            #expect(Set(merged.groups) == [myGroup, theirGroup])
            #expect(merged.tombstones.isEmpty)
        }
    }

    @Test func aNewerCopyReplacesEveryFieldNotJustTheChangedOnes() {
        let id = UUID()
        var older = LibraryFixtures.computer("Studio", id: id, modifiedAt: ago(200))
        older.tags = ["work"]
        older.isFavorite = true
        older.settings.quality = .fullQuality
        var newer = LibraryFixtures.computer("Studio", id: id, modifiedAt: ago(100))
        newer.notes = "moved to the back room"

        let merged = merge(LibraryDocument(computers: [older]), LibraryDocument(computers: [newer]))
        #expect(merged.computers == [newer])
    }

    @Test func twoCopiesOfAnItemInOneDocumentCollapseToTheNewest() {
        let id = UUID()
        let older = LibraryFixtures.computer("Before", id: id, modifiedAt: ago(200))
        let newer = LibraryFixtures.computer("After", id: id, modifiedAt: ago(100))

        let merged = merge(LibraryDocument(computers: [older, newer]), LibraryDocument())
        #expect(merged.computers == [newer])
    }

    @Test func schemaVersionIsTheHigherOfTheTwo() {
        for merged in bothWays(LibraryDocument(schemaVersion: 1), LibraryDocument(schemaVersion: 4)) {
            #expect(merged.schemaVersion == 4)
        }
    }

    // MARK: Deletions

    @Test func aDeletionRemovesCopiesLastModifiedBeforeIt() {
        let computer = LibraryFixtures.computer("Studio", modifiedAt: ago(200))
        let group = LibraryFixtures.group("Home", modifiedAt: ago(200))
        let deleted = LibraryDocument(tombstones: [
            computer.id.uuidString: ago(100),
            group.id.uuidString: ago(100),
        ])

        for merged in bothWays(LibraryDocument(computers: [computer], groups: [group]), deleted) {
            #expect(merged.computers.isEmpty)
            #expect(merged.groups.isEmpty)
            // The deletion is remembered for devices that have not heard yet.
            #expect(merged.tombstones == deleted.tombstones)
        }
    }

    @Test func anEditMadeAfterADeletionBringsTheItemBack() {
        let computer = LibraryFixtures.computer("Studio", modifiedAt: ago(100))
        let deleted = LibraryDocument(tombstones: [computer.id.uuidString: ago(200)])

        for merged in bothWays(LibraryDocument(computers: [computer]), deleted) {
            #expect(merged.computers == [computer])
            // A deletion that lost to a later edit no longer describes anything.
            #expect(merged.tombstones.isEmpty)
        }
    }

    @Test func aDeletionAtTheSameInstantAsAnEditWins() {
        let computer = LibraryFixtures.computer("Studio", modifiedAt: ago(100))
        let deleted = LibraryDocument(tombstones: [computer.id.uuidString: ago(100)])

        for merged in bothWays(LibraryDocument(computers: [computer]), deleted) {
            #expect(merged.computers.isEmpty)
            #expect(merged.tombstones == deleted.tombstones)
        }
    }

    @Test func theLatestOfTwoDeletionsIsRemembered() {
        let id = UUID().uuidString
        for merged in bothWays(
            LibraryDocument(tombstones: [id: ago(300)]),
            LibraryDocument(tombstones: [id: ago(100)])) {
            #expect(merged.tombstones == [id: ago(100)])
        }
    }

    @Test func aDeletionOnOneSideDoesNotTouchOtherItems() {
        let kept = LibraryFixtures.computer("Kept", modifiedAt: ago(500))
        let removed = LibraryFixtures.computer("Removed", modifiedAt: ago(500))

        let merged = merge(
            LibraryDocument(computers: [kept, removed]),
            LibraryDocument(tombstones: [removed.id.uuidString: ago(10)]))
        #expect(merged.computers == [kept])
    }

    // MARK: Forgetting deletions

    @Test func deletionsAreForgottenOnceTheyReachTheirLifetime() {
        let lifetime = LibraryDocument.tombstoneLifetime
        let fresh = UUID().uuidString, almostExpired = UUID().uuidString
        let expiredJustNow = UUID().uuidString, longExpired = UUID().uuidString

        let merged = merge(
            LibraryDocument(tombstones: [
                fresh: ago(60),
                almostExpired: ago(lifetime - 1),
            ]),
            LibraryDocument(tombstones: [
                expiredJustNow: ago(lifetime),
                longExpired: ago(lifetime * 2),
            ]))

        #expect(Set(merged.tombstones.keys) == [fresh, almostExpired])
    }

    @Test func aDeletionDueToBeForgottenStillAppliesInTheMergeThatSeesIt() {
        let lifetime = LibraryDocument.tombstoneLifetime
        let computer = LibraryFixtures.computer("Old", modifiedAt: ago(lifetime + 500))
        let deleted = LibraryDocument(tombstones: [computer.id.uuidString: ago(lifetime + 100)])

        for merged in bothWays(LibraryDocument(computers: [computer]), deleted) {
            #expect(merged.computers.isEmpty)
            #expect(merged.tombstones.isEmpty)
        }
    }

    @Test func deletionsAreForgottenRelativeToTheMomentOfTheMerge() {
        let id = UUID().uuidString
        let deletedAt = ago(1000)
        let document = LibraryDocument(tombstones: [id: deletedAt])

        let soonAfter = LibraryDocument.merge(document, LibraryDocument(), now: Self.now)
        #expect(soonAfter.tombstones == [id: deletedAt])

        let muchLater = LibraryDocument.merge(
            document, LibraryDocument(),
            now: deletedAt.addingTimeInterval(LibraryDocument.tombstoneLifetime + 1))
        #expect(muchLater.tombstones.isEmpty)
    }

    // MARK: Group references

    /// Merging never rewrites a computer. Its group may be gone, or simply
    /// not have arrived yet, and from here the two look the same; the store
    /// reads a group that is not there as "no group".
    @Test func deletingAGroupLeavesItsComputersAsTheyAre() throws {
        let doomed = LibraryFixtures.group("Doomed", modifiedAt: ago(500))
        let surviving = LibraryFixtures.group("Surviving", modifiedAt: ago(500))
        let orphan = LibraryFixtures.computer("Orphan", groupID: doomed.id, modifiedAt: ago(400))
        let member = LibraryFixtures.computer("Member", groupID: surviving.id, modifiedAt: ago(400))
        let loner = LibraryFixtures.computer("Loner", modifiedAt: ago(400))

        let library = LibraryDocument(
            computers: [orphan, member, loner], groups: [doomed, surviving])
        let deletion = LibraryDocument(tombstones: [doomed.id.uuidString: ago(100)])

        for merged in bothWays(library, deletion) {
            #expect(merged.groups == [surviving])
            #expect(merged.computers.first { $0.id == orphan.id } == orphan)
            #expect(merged.computers.first { $0.id == member.id } == member)
            #expect(merged.computers.first { $0.id == loner.id } == loner)
        }
    }

    @Test func aReferenceToAGroupThatIsNotHereIsKept() throws {
        let computer = LibraryFixtures.computer("Studio", groupID: UUID(), modifiedAt: ago(100))
        let merged = merge(LibraryDocument(computers: [computer]), LibraryDocument())
        #expect(merged.computers == [computer])
    }

    @Test func aComputerKeepsItsGroupWhenTheGroupArrivesAfterIt() {
        let group = LibraryFixtures.group("Home", modifiedAt: ago(200))
        let computer = LibraryFixtures.computer("Studio", groupID: group.id, modifiedAt: ago(100))
        let complete = LibraryDocument(computers: [computer], groups: [group])

        let computerOnly = merge(LibraryDocument(), LibraryDocument(computers: [computer]))
        let caughtUp = merge(computerOnly, complete)

        #expect(caughtUp.computers.first?.groupID == group.id)
        #expect(caughtUp == merge(LibraryDocument(), complete))
    }

    @Test func aGroupArrivingFromTheOtherSideKeepsItsComputersGrouped() {
        let group = LibraryFixtures.group("Home", modifiedAt: ago(300))
        let computer = LibraryFixtures.computer("Studio", groupID: group.id, modifiedAt: ago(200))

        for merged in bothWays(
            LibraryDocument(computers: [computer]), LibraryDocument(groups: [group])) {
            #expect(merged.computers == [computer])
            #expect(merged.groups == [group])
        }
    }

    // MARK: Order

    /// Both devices have to show the same order, so it cannot depend on
    /// which library was merged into which: the user's own order comes
    /// first, and computers that share a place in it go oldest first.
    @Test func itemsComeOutInTheSameOrderWhicheverWayRound() {
        let second = LibraryFixtures.computer("Second", modifiedAt: ago(400), sortIndex: 1)
        let olderFirst = LibraryFixtures.computer("First, older", modifiedAt: ago(300), sortIndex: 0)
        let newerFirst = LibraryFixtures.computer("First, newer", modifiedAt: ago(200), sortIndex: 0)
        var renamed = second
        renamed.name = "Second, renamed"
        renamed.modifiedAt = ago(50)

        for merged in bothWays(
            LibraryDocument(computers: [second, newerFirst]),
            LibraryDocument(computers: [olderFirst, renamed])) {
            #expect(merged.computers == [olderFirst, newerFirst, renamed])
        }
    }

    @Test func groupsComeOutInTheSameOrderWhicheverWayRound() {
        let work = LibraryFixtures.group("Work", modifiedAt: ago(300), sortIndex: 1)
        let home = LibraryFixtures.group("Home", modifiedAt: ago(200), sortIndex: 0)

        for merged in bothWays(LibraryDocument(groups: [work]), LibraryDocument(groups: [home])) {
            #expect(merged.groups == [home, work])
        }
    }

    // MARK: Ties

    /// Two copies stamped alike that still differ: neither is newer, and
    /// both devices have to end up with the same one.
    @Test func copiesWithTheSameTimestampResolveTheSameWayOnBothDevices() {
        let id = UUID()
        let stamp = ago(100)
        let onMac = LibraryDocument(computers: [
            LibraryFixtures.computer("Renamed on the Mac", id: id, modifiedAt: stamp),
        ])
        let onPhone = LibraryDocument(computers: [
            LibraryFixtures.computer("Renamed on the phone", id: id, modifiedAt: stamp),
        ])
        #expect(merge(onMac, onPhone) == merge(onPhone, onMac))

        let groupID = UUID()
        let groupOnMac = LibraryDocument(groups: [
            LibraryFixtures.group("Named on the Mac", id: groupID, modifiedAt: stamp),
        ])
        let groupOnPhone = LibraryDocument(groups: [
            LibraryFixtures.group("Named on the phone", id: groupID, modifiedAt: stamp),
        ])
        #expect(merge(groupOnMac, groupOnPhone) == merge(groupOnPhone, groupOnMac))
    }

    // MARK: Connections

    /// Connecting is not an edit and does not touch `modifiedAt`, so the
    /// time of the last connection is settled on its own.
    @Test func aConnectionMadeAfterTheWinningEditIsKept() {
        let id = UUID()
        var connectedHere = LibraryFixtures.computer("Studio", id: id, modifiedAt: ago(300))
        connectedHere.lastConnectedAt = ago(100)
        let renamedElsewhere = LibraryFixtures.computer("Studio, renamed", id: id, modifiedAt: ago(200))

        for merged in bothWays(
            LibraryDocument(computers: [connectedHere]), LibraryDocument(computers: [renamedElsewhere])) {
            #expect(merged.computers.map(\.name) == ["Studio, renamed"])
            #expect(merged.computers.first?.lastConnectedAt == ago(100))
            #expect(merged.computers.first?.modifiedAt == ago(200))
        }
    }

    /// Clearing the recents is an edit. A connection from before it does
    /// not come back with a stale copy.
    @Test func aConnectionFromBeforeTheWinningEditIsNotBroughtBack() {
        let id = UUID()
        var connectedBefore = LibraryFixtures.computer("Studio", id: id, modifiedAt: ago(300))
        connectedBefore.lastConnectedAt = ago(250)
        let clearedSince = LibraryFixtures.computer("Studio", id: id, modifiedAt: ago(200))

        for merged in bothWays(
            LibraryDocument(computers: [connectedBefore]), LibraryDocument(computers: [clearedSince])) {
            #expect(merged.computers == [clearedSince])
        }
    }

    @Test func ofTwoConnectionsToTheSameVersionTheLaterIsKept() {
        let id = UUID()
        var onMac = LibraryFixtures.computer("Studio", id: id, modifiedAt: ago(300))
        onMac.lastConnectedAt = ago(100)
        var onPhone = onMac
        onPhone.lastConnectedAt = ago(50)

        for merged in bothWays(
            LibraryDocument(computers: [onMac]), LibraryDocument(computers: [onPhone])) {
            #expect(merged.computers == [onPhone])
        }
    }

    // MARK: Laws

    @Test func mergingWithNothingLeavesAWellFormedLibraryAlone() {
        let group = LibraryFixtures.group("Home", modifiedAt: ago(300))
        let library = LibraryDocument(
            computers: [
                LibraryFixtures.computer("Studio", groupID: group.id, modifiedAt: ago(200)),
                LibraryFixtures.computer("Server", modifiedAt: ago(100)),
            ],
            groups: [group],
            tombstones: [UUID().uuidString: ago(50)])

        #expect(merge(library, LibraryDocument()) == library)
        #expect(merge(LibraryDocument(), library) == library)
        #expect(merge(library, library) == library)
    }

    @Test func mergeAgreesWithItsSpecificationOnGeneratedLibraries() {
        for seed in UInt64(0)..<500 {
            var random = ReplayableRandom(seed: seed)
            let universe = MergeUniverse(now: Self.now, groupsComputers: true, using: &random)
            let a = universe.document(using: &random)
            let b = universe.document(using: &random)

            let expected = universe.specification(of: [a, b])
            guard merge(a, b).sortedByID == expected, merge(b, a).sortedByID == expected else {
                Issue.record("merge disagrees with its specification for seed \(seed)")
                return
            }
        }
    }

    @Test func mergeIsCommutative() {
        for seed in UInt64(0)..<500 {
            var random = ReplayableRandom(seed: seed)
            let universe = MergeUniverse(now: Self.now, groupsComputers: true, using: &random)
            let a = universe.document(using: &random)
            let b = universe.document(using: &random)

            // The same items, in the same order.
            guard merge(a, b) == merge(b, a) else {
                Issue.record("merge(a, b) and merge(b, a) differ for seed \(seed)")
                return
            }
        }
    }

    @Test func mergeIsIdempotent() {
        for seed in UInt64(0)..<500 {
            var random = ReplayableRandom(seed: seed)
            let universe = MergeUniverse(now: Self.now, groupsComputers: true, using: &random)
            let a = universe.document(using: &random)
            let b = universe.document(using: &random)
            let merged = merge(a, b)

            // Merging a result with itself, or with either of the libraries
            // it came from, has nothing left to change.
            guard merge(merged, merged) == merged,
                  merge(merged, a) == merged,
                  merge(merged, b) == merged,
                  merge(a, merged) == merged,
                  merge(b, merged) == merged else {
                Issue.record("merging a result again changed it for seed \(seed)")
                return
            }
        }
    }

    @Test func threeLibrariesConvergeWhateverOrderTheyMeetIn() {
        for seed in UInt64(0)..<500 {
            var random = ReplayableRandom(seed: seed)
            let universe = MergeUniverse(now: Self.now, groupsComputers: true, using: &random)
            let a = universe.document(using: &random)
            let b = universe.document(using: &random)
            let c = universe.document(using: &random)

            let expected = universe.specification(of: [a, b, c])
            let orders = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
            for order in orders {
                let leftFirst = merge(merge(order[0], order[1]), order[2])
                let rightFirst = merge(order[0], merge(order[1], order[2]))
                guard leftFirst.sortedByID == expected, leftFirst == rightFirst else {
                    Issue.record("three libraries did not converge for seed \(seed)")
                    return
                }
            }
        }
    }

    @Test func mergedLibrariesAreAlwaysWellFormed() {
        for seed in UInt64(0)..<500 {
            var random = ReplayableRandom(seed: seed)
            let universe = MergeUniverse(now: Self.now, groupsComputers: true, using: &random)
            let merged = merge(
                universe.document(using: &random), universe.document(using: &random))

            let computerIDs = merged.computers.map(\.id)
            let groupIDs = merged.groups.map(\.id)
            let live = Set(computerIDs + groupIDs)
            let wellFormed =
                Set(computerIDs).count == computerIDs.count
                && Set(groupIDs).count == groupIDs.count
                && merged.tombstones.keys.allSatisfy { key in
                    !live.contains { $0.uuidString == key }
                }
                && merged.computers == merged.computers.sorted(by: Computer.precedesInLibrary)
                && merged.groups == merged.groups.sorted(by: ComputerGroup.precedesInLibrary)
            guard wellFormed else {
                Issue.record("merge produced a malformed library for seed \(seed)")
                return
            }
        }
    }
}

/// A small world of computers and groups, each with a short history of
/// versions, from which random libraries are drawn.
///
/// Every version of an item has its own timestamp, the way successive edits
/// do, and a given version looks the same in every library that holds it.
/// Deletions land on, before and after those timestamps.
private struct MergeUniverse {
    let now: Date
    private var computerHistories: [[Computer]] = []
    private var groupHistories: [[ComputerGroup]] = []

    init(now: Date, groupsComputers: Bool, using random: inout ReplayableRandom) {
        self.now = now
        let groupIDs = (0..<3).map { _ in MergeUniverse.uuid(using: &random) }
        groupHistories = groupIDs.enumerated().map { index, id in
            (0..<4).map { version in
                ComputerGroup(
                    id: id,
                    name: "group \(index) v\(version)",
                    sortIndex: Int.random(in: 0..<3, using: &random),
                    modifiedAt: MergeUniverse.timestamp(ofVersion: version, now: now))
            }
        }
        computerHistories = (0..<6).map { index in
            let id = MergeUniverse.uuid(using: &random)
            return (0..<4).map { version in
                let stamp = MergeUniverse.timestamp(ofVersion: version, now: now)
                return Computer(
                    id: id,
                    name: "computer \(index) v\(version)",
                    host: "host-\(index).local",
                    groupID: groupsComputers && random.chance(0.6) ? groupIDs.randomElement(using: &random) : nil,
                    createdAt: MergeUniverse.timestamp(ofVersion: 0, now: now),
                    modifiedAt: stamp,
                    sortIndex: Int.random(in: 0..<3, using: &random))
            }
        }
    }

    private static func uuid(using random: inout ReplayableRandom) -> UUID {
        var bytes = (random.next(), random.next())
        return withUnsafeBytes(of: &bytes) { raw in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
    }

    private static func timestamp(ofVersion version: Int, now: Date) -> Date {
        now.addingTimeInterval(-3000 + 600 * Double(version))
    }

    /// A library holding one version of some of the items and deletions of
    /// some others, in no particular order.
    func document(using random: inout ReplayableRandom) -> LibraryDocument {
        var document = LibraryDocument()
        for history in computerHistories where random.chance(0.7) {
            document.computers.append(history.randomElement(using: &random)!)
        }
        for history in groupHistories where random.chance(0.7) {
            document.groups.append(history.randomElement(using: &random)!)
        }
        let ids = computerHistories.map { $0[0].id } + groupHistories.map { $0[0].id }
        for id in ids where random.chance(0.3) {
            // Every 300 seconds from before the first version to after the
            // last, so some deletions coincide exactly with an edit.
            let step = Double(Int.random(in: 0..<10, using: &random))
            document.tombstones[id.uuidString] = now.addingTimeInterval(-3300 + 300 * step)
        }
        document.computers.shuffle(using: &random)
        document.groups.shuffle(using: &random)
        return document
    }

    /// What merging the given libraries has to produce, worked out one item
    /// at a time straight from the rules: the newest copy wins, a deletion
    /// beats every copy that is not newer than it, and a deletion is
    /// forgotten when it lost or expired.
    func specification(of documents: [LibraryDocument]) -> LibraryDocument {
        var deletions: [String: Date] = [:]
        for document in documents {
            for (id, date) in document.tombstones {
                deletions[id] = max(deletions[id] ?? date, date)
            }
        }
        func survives(_ id: UUID, modifiedAt: Date) -> Bool {
            deletions[id.uuidString].map { modifiedAt > $0 } ?? true
        }

        var groups: [UUID: ComputerGroup] = [:]
        for group in documents.flatMap(\.groups) {
            if let known = groups[group.id], known.modifiedAt >= group.modifiedAt { continue }
            groups[group.id] = group
        }
        groups = groups.filter { survives($0.key, modifiedAt: $0.value.modifiedAt) }

        var computers: [UUID: Computer] = [:]
        for computer in documents.flatMap(\.computers) {
            if let known = computers[computer.id], known.modifiedAt >= computer.modifiedAt { continue }
            computers[computer.id] = computer
        }
        computers = computers.filter { survives($0.key, modifiedAt: $0.value.modifiedAt) }

        let live = Set(computers.keys.map(\.uuidString) + groups.keys.map(\.uuidString))
        return LibraryDocument(
            schemaVersion: documents.map(\.schemaVersion).max() ?? 1,
            computers: Array(computers.values),
            groups: Array(groups.values),
            tombstones: deletions.filter { id, date in
                !live.contains(id) && now.timeIntervalSince(date) < LibraryDocument.tombstoneLifetime
            }
        ).sortedByID
    }
}

@Suite("Library file format")
struct LibraryDocumentCodingTests {

    @Test func aLibrarySurvivesEncodingExactly() throws {
        // Not a whole second: the file keeps every bit of a date.
        let stamp = Date(timeIntervalSinceReferenceDate: 821_234_567.123_456_7)
        let group = LibraryFixtures.group("Home", modifiedAt: stamp)
        var computer = LibraryFixtures.computer("Studio", groupID: group.id, modifiedAt: stamp)
        computer.username = "me"
        computer.port = 5901
        computer.kind = .linux
        computer.isFavorite = true
        computer.tags = ["work", "render"]
        computer.tint = .teal
        computer.notes = "Under the desk.\nSecond line — with “quotes”."
        computer.settings.quality = .fullQuality
        computer.settings.frameRate = 30
        computer.settings.curtainMessage = "Back soon"
        computer.ssh = SSHSettings(
            isEnabled: true, host: "gateway.example", port: 2222, username: "tunnel",
            authentication: .key, keyID: UUID())
        computer.macAddress = "AA:BB:CC:DD:EE:FF"
        computer.origin = .bonjour(serviceName: "Studio._rfb._tcp.local.")
        computer.lastConnectedAt = stamp.addingTimeInterval(60)
        computer.sortIndex = 3
        let document = LibraryDocument(
            computers: [computer, LibraryFixtures.computer("Plain", modifiedAt: stamp)],
            groups: [group],
            tombstones: [UUID().uuidString: stamp.addingTimeInterval(-60)])

        #expect(try LibraryDocument.decode(document.encoded()) == document)
    }

    @Test func encodingTheSameLibraryTwiceGivesTheSameBytes() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let document = LibraryDocument(
            computers: [
                LibraryFixtures.computer("Studio", modifiedAt: stamp),
                LibraryFixtures.computer("Server", modifiedAt: stamp),
            ],
            tombstones: [UUID().uuidString: stamp, UUID().uuidString: stamp])
        #expect(try document.encoded() == document.encoded())
    }

    @Test func everyKindOfOriginSurvivesEncoding() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let origins: [ComputerOrigin] = [
            .manual,
            .bonjour(serviceName: "Studio._rfb._tcp.local."),
            .tailscale(nodeID: "nodeid:1234abcd"),
        ]
        for origin in origins {
            var computer = LibraryFixtures.computer("Studio", modifiedAt: stamp)
            computer.origin = origin
            let decoded = try LibraryDocument.decode(LibraryDocument(computers: [computer]).encoded())
            #expect(decoded.computers.first?.origin == origin)
        }
        #expect(!ComputerOrigin.manual.isDiscovered)
        #expect(ComputerOrigin.bonjour(serviceName: "x").isDiscovered)
        #expect(ComputerOrigin.tailscale(nodeID: "x").isDiscovered)
    }

    // MARK: Reading files from other versions

    @Test func anEmptyObjectIsAnEmptyLibrary() throws {
        let document = try LibraryDocument.decode(Data("{}".utf8))
        #expect(document == LibraryDocument(schemaVersion: 1))
    }

    @Test func aComputerNeedsOnlyAnIdentifierAndAnAddress() throws {
        let json = #"{"computers":[{"id":"11111111-2222-3333-4444-555555555555","host":"studio.local"}]}"#
        let before = Date.now
        let computer = try #require(try LibraryDocument.decode(Data(json.utf8)).computers.first)

        #expect(computer.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(computer.host == "studio.local")
        #expect(computer.name == "")
        #expect(computer.port == 5900)
        #expect(computer.username == nil)
        #expect(computer.kind == .mac)
        #expect(computer.groupID == nil)
        #expect(computer.isFavorite == false)
        #expect(computer.tags == [])
        #expect(computer.tint == .automatic)
        #expect(computer.notes == "")
        #expect(computer.settings == ConnectionSettings())
        #expect(computer.ssh == SSHSettings())
        #expect(computer.macAddress == nil)
        #expect(computer.origin == .manual)
        #expect(computer.lastConnectedAt == nil)
        #expect(computer.sortIndex == 0)
        #expect(computer.createdAt >= before && computer.createdAt <= .now)
        #expect(computer.modifiedAt >= before && computer.modifiedAt <= .now)
    }

    @Test func aGroupNeedsOnlyAnIdentifier() throws {
        let json = #"{"groups":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}]}"#
        let group = try #require(try LibraryDocument.decode(Data(json.utf8)).groups.first)

        #expect(group.id == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(group.name == "")
        #expect(group.symbolName == "folder")
        #expect(group.sortIndex == 0)
    }

    @Test func settingsThatAreMissingTakeTheirDefaults() throws {
        let json = """
            {"computers":[{
                "id":"11111111-2222-3333-4444-555555555555",
                "host":"studio.local",
                "settings":{"frameRate":30,"observeOnly":true},
                "ssh":{"isEnabled":true}
            }]}
            """
        let computer = try #require(try LibraryDocument.decode(Data(json.utf8)).computers.first)

        var expected = ConnectionSettings()
        expected.frameRate = 30
        expected.observeOnly = true
        #expect(computer.settings == expected)
        #expect(computer.ssh == SSHSettings(isEnabled: true))
    }

    @Test func valuesFromANewerVersionFallBackInsteadOfFailing() throws {
        let json = """
            {
              "schemaVersion": 7,
              "somethingNew": {"nested": [1, 2, 3]},
              "computers": [{
                "id": "11111111-2222-3333-4444-555555555555",
                "host": "studio.local",
                "kind": "mainframe",
                "tint": "ultraviolet",
                "somethingNew": true,
                "settings": {
                  "quality": "holographic",
                  "resolution": "retinal",
                  "displays": "wall",
                  "scaling": "stretch",
                  "colorDepth": "deep",
                  "cursor": "laser",
                  "touchInput": "stylus",
                  "keyboardInput": "telepathy",
                  "somethingNew": 1
                },
                "ssh": {"authentication": "certificate", "somethingNew": "x"}
              }],
              "groups": [{"id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "somethingNew": []}]
            }
            """
        let document = try LibraryDocument.decode(Data(json.utf8))
        let computer = try #require(document.computers.first)

        #expect(document.schemaVersion == 7)
        #expect(document.groups.count == 1)
        #expect(computer.kind == .other)
        #expect(computer.tint == .automatic)
        #expect(computer.settings.quality == .standard)
        #expect(computer.settings.resolution == .remote)
        #expect(computer.settings.displays == .single)
        #expect(computer.settings.scaling == .fit)
        #expect(computer.settings.colorDepth == .full)
        #expect(computer.settings.cursor == .local)
        #expect(computer.settings.touchInput == .trackpad)
        #expect(computer.settings.keyboardInput == .automatic)
        #expect(computer.ssh.authentication == .password)
    }

    /// Merging compares timestamps, so saving must not move them. Two
    /// changes one after the other can be as close as dates get.
    @Test func datesComeBackExactlyAsTheyWereWritten() throws {
        let stamp = Date(timeIntervalSinceReferenceDate: 821_234_567.891_011)
        let justAfter = Date(
            timeIntervalSinceReferenceDate: stamp.timeIntervalSinceReferenceDate.nextUp)
        var computer = LibraryFixtures.computer("Studio", modifiedAt: stamp)
        computer.lastConnectedAt = justAfter
        let document = LibraryDocument(
            computers: [computer], tombstones: [UUID().uuidString: justAfter])

        let reloaded = try LibraryDocument.decode(document.encoded())

        #expect(reloaded == document)
        #expect(try #require(reloaded.computers.first?.lastConnectedAt) > stamp)
    }

    /// A deletion made in the same second as the edit before it has to
    /// still be the later of the two after a relaunch.
    @Test func aDeletionStillAppliesAfterTheLibraryIsSavedAndReloaded() throws {
        let second = LibraryFixtures.recentWholeSecond()
        let computer = LibraryFixtures.computer("Studio", modifiedAt: second.addingTimeInterval(0.25))
        let otherDevice = LibraryDocument(computers: [computer])
        let thisDevice = LibraryDocument(
            tombstones: [computer.id.uuidString: second.addingTimeInterval(0.75)])
        #expect(LibraryDocument.merge(thisDevice, otherDevice).computers.isEmpty)

        let afterRelaunch = try LibraryDocument.decode(thisDevice.encoded())

        #expect(afterRelaunch == thisDevice)
        #expect(LibraryDocument.merge(afterRelaunch, otherDevice).computers.isEmpty)
    }

    /// Dates written as text — by hand, or by a version that formatted
    /// them — are still read.
    @Test func datesWrittenAsISO8601TextAreStillRead() throws {
        let json = """
            {"computers":[{
                "id":"11111111-2222-3333-4444-555555555555",
                "host":"studio.local",
                "createdAt":"2026-05-01T10:00:00Z",
                "modifiedAt":"2026-05-02T11:30:15.250Z",
                "lastConnectedAt":"2026-05-03T00:00:00+02:00"
            }],
            "tombstones":{"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE":"2026-04-01T00:00:00Z"}}
            """
        let document = try LibraryDocument.decode(Data(json.utf8))
        let computer = try #require(document.computers.first)

        #expect(computer.createdAt == Date(timeIntervalSince1970: 1_777_629_600))
        #expect(computer.modifiedAt == Date(timeIntervalSince1970: 1_777_721_415.25))
        #expect(computer.lastConnectedAt == Date(timeIntervalSince1970: 1_777_759_200))
        #expect(document.tombstones == [
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": Date(timeIntervalSince1970: 1_775_001_600),
        ])
    }

    @Test func aDateThatIsNeitherANumberNorADateIsRejected() {
        let json = #"{"computers":[{"id":"11111111-2222-3333-4444-555555555555","host":"a","modifiedAt":"yesterday"}]}"#
        #expect(throws: (any Error).self) {
            try LibraryDocument.decode(Data(json.utf8))
        }
    }

    /// A newer version may know where a computer came from in ways this one
    /// does not. That must not make the library unreadable.
    @Test func aComputerWithAnOriginFromANewerVersionStillLoads() throws {
        let json = """
            {"computers":[
                {"id":"11111111-2222-3333-4444-555555555555","host":"studio.local",
                 "origin":{"directoryService":{"domain":"example.org"}}},
                {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","host":"server.local"}
            ]}
            """

        let document = try LibraryDocument.decode(Data(json.utf8))

        #expect(Set(document.computers.map(\.host)) == ["studio.local", "server.local"])
        #expect(document.computers.allSatisfy { $0.origin == .manual })
    }

    @Test(arguments: [
        #"{"computers":[{"host":"studio.local"}]}"#,
        #"{"computers":[{"id":"11111111-2222-3333-4444-555555555555"}]}"#,
        #"{"computers":[{"id":"not a uuid","host":"studio.local"}]}"#,
        #"{"groups":[{"name":"Home"}]}"#,
        #"{"computers":"none"}"#,
        #"[]"#,
        "",
        "not json at all",
    ])
    func filesThatCannotBeALibraryAreRejected(json: String) {
        #expect(throws: (any Error).self) {
            try LibraryDocument.decode(Data(json.utf8))
        }
    }
}

@Suite("Computer")
struct ComputerTests {

    @Test func displayNameFallsBackToTheAddress() {
        #expect(Computer(name: "Studio", host: "studio.local").displayName == "Studio")
        #expect(Computer(name: "  Studio \n", host: "studio.local").displayName == "Studio")
        #expect(Computer(name: "", host: "studio.local").displayName == "studio.local")
        #expect(Computer(name: "   ", host: "studio.local").displayName == "studio.local")
    }

    @Test func displayAddressShowsThePortOnlyWhenItIsNotTheDefault() {
        #expect(Computer(name: "", host: "studio.local").displayAddress == "studio.local")
        #expect(Computer(name: "", host: "studio.local", port: 5901).displayAddress == "studio.local:5901")
        #expect(Computer(name: "", host: "fe80::1").displayAddress == "fe80::1")
        #expect(Computer(name: "", host: "fe80::1", port: 5901).displayAddress == "[fe80::1]:5901")
    }

    @Test func onlyMacsStartInHighPerformance() {
        let mac = ConnectionSettings.defaults(for: .mac)
        #expect(mac == ConnectionSettings())
        #expect(mac.quality == .highPerformance)

        for kind in ComputerKind.allCases where kind != .mac {
            let settings = ConnectionSettings.defaults(for: kind)
            #expect(!kind.isApple)
            #expect(settings.quality == .standard)
            #expect(settings.resolution == .remote)
            #expect(settings.remoteAudio == false)
        }
        #expect(ComputerKind.mac.isApple)
    }

    @Test func everyOptionHasATitleAndCanBeStoredByItsRawValue() {
        #expect(Set(ComputerKind.allCases.map(\.title)).count == ComputerKind.allCases.count)
        #expect(ComputerKind.allCases.allSatisfy { !$0.symbolName.isEmpty })
        #expect(Set(ComputerTint.allCases.map(\.title)).count == ComputerTint.allCases.count)
        #expect(ComputerTint.automatic.title == "Automatic")
        #expect(ComputerTint.teal.title == "Teal")
        #expect(Set(QualityMode.allCases.map(\.title)).count == QualityMode.allCases.count)
        #expect(QualityMode.allCases.allSatisfy { !$0.summary.isEmpty && !$0.symbolName.isEmpty })
    }
}

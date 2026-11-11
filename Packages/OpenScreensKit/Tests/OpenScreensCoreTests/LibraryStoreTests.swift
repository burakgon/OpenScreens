import Foundation
import Testing
@testable import OpenScreensCore

/// Collects what a store announces through `onChange`.
@MainActor
private final class ChangeLog {
    private(set) var documents: [LibraryDocument] = []

    init(observing store: LibraryStore) {
        store.onChange = { document in
            self.documents.append(document)
        }
    }

    var count: Int { documents.count }
}

@MainActor
@Suite("LibraryStore")
struct LibraryStoreTests {

    private func makeStore() -> LibraryStore {
        LibraryStore(fileURL: nil, backupsDirectory: nil)
    }

    /// A store holding one computer per name, in that order.
    private func makeStore(computers names: [String]) -> (LibraryStore, [Computer]) {
        let store = makeStore()
        let computers = names.map { store.add(Computer(name: $0, host: "\($0).local")) }
        return (store, computers)
    }

    private func names(in store: LibraryStore) -> [String] {
        store.computers.map(\.name)
    }

    // MARK: - Computers

    @Test func addingStampsTheComputerAndPutsItLast() {
        let store = makeStore()
        let before = Date.now

        let first = store.add(Computer(
            name: "Studio", host: "studio.local",
            createdAt: .distantPast, modifiedAt: .distantPast, sortIndex: 42))
        let second = store.add(Computer(name: "Server", host: "server.local"))

        #expect(first.name == "Studio")
        #expect(first.createdAt >= before && first.createdAt <= .now)
        #expect(first.modifiedAt >= before && first.modifiedAt <= .now)
        #expect(first.sortIndex == 0)
        #expect(second.sortIndex == 1)
        #expect(store.computers == [first, second])
        #expect(store.computer(first.id) == first)
        #expect(store.computer(UUID()) == nil)
    }

    @Test func aNewComputerSortsAfterTheHighestIndexInUse() {
        let store = makeStore()
        store.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Synced", modifiedAt: .now, sortIndex: 7),
        ]))

        let added = store.add(Computer(name: "New", host: "new.local"))
        #expect(added.sortIndex == 8)
        #expect(names(in: store) == ["Synced", "New"])
    }

    /// A position can arrive as large as an integer gets: built in memory,
    /// it never passes through the decoder that would have bounded it. The
    /// next computer must still find a place, not crash counting past it.
    @Test func aNewComputerFindsAPlaceAfterTheLargestPositionThereIs() {
        let store = makeStore()
        store.merge(LibraryDocument(
            computers: [LibraryFixtures.computer("Far", modifiedAt: .now, sortIndex: .max)],
            groups: [ComputerGroup(name: "Far group", sortIndex: .max)]))

        let added = store.add(Computer(name: "New", host: "new.local"))
        #expect(added.sortIndex <= 1_000_000_000)
        #expect(store.computers.contains { $0.id == added.id })
        let group = store.addGroup(named: "New group")
        #expect(group.sortIndex <= 1_000_000_000)
    }

    @Test func aPositionSetThroughAnUpdateIsBounded() throws {
        let store = makeStore()
        var computer = store.add(Computer(name: "One", host: "one.local"))
        computer.sortIndex = .max
        store.update(computer)
        #expect(try #require(store.computer(computer.id)).sortIndex == 1_000_000_000)

        computer.sortIndex = .min
        store.update(computer)
        #expect(try #require(store.computer(computer.id)).sortIndex == -1_000_000_000)

        var group = store.addGroup(named: "Group")
        group.sortIndex = .max
        store.update(group)
        #expect(store.groups.first { $0.id == group.id }?.sortIndex == 1_000_000_000)
    }

    @Test func updatingReplacesTheComputerAndStampsIt() throws {
        let store = makeStore()
        let original = store.add(Computer(name: "Studio", host: "studio.local"))
        LibraryFixtures.letClockAdvance()

        var edited = original
        edited.name = "Studio Display"
        edited.settings.quality = .standard
        store.update(edited)

        let saved = try #require(store.computer(original.id))
        #expect(saved.name == "Studio Display")
        #expect(saved.settings.quality == .standard)
        #expect(saved.modifiedAt > original.modifiedAt)
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.sortIndex == original.sortIndex)
        #expect(store.computers.count == 1)
    }

    @Test func updatingWithNothingChangedLeavesTheComputerUntouched() {
        let store = makeStore()
        let original = store.add(Computer(name: "Studio", host: "studio.local"))
        let log = ChangeLog(observing: store)
        LibraryFixtures.letClockAdvance()

        store.update(original)
        store.update(original.id) { _ in }

        #expect(store.computer(original.id) == original)
        #expect(log.count == 0)
    }

    @Test func updatingAComputerThatIsNotInTheLibraryAddsIt() throws {
        let store = makeStore()
        store.add(Computer(name: "Studio", host: "studio.local"))

        let stranger = Computer(name: "Stranger", host: "stranger.local", modifiedAt: .distantPast)
        store.update(stranger)

        let saved = try #require(store.computer(stranger.id))
        #expect(saved.name == "Stranger")
        #expect(saved.sortIndex == 1)
        #expect(saved.modifiedAt > .distantPast)
        #expect(store.computers.count == 2)
    }

    @Test func editingInPlaceChangesOneComputer() throws {
        let (store, computers) = makeStore(computers: ["Studio", "Server"])

        store.update(computers[1].id) { $0.notes = "in the basement" }
        store.update(UUID()) { $0.notes = "nobody" }

        #expect(try #require(store.computer(computers[1].id)).notes == "in the basement")
        #expect(store.computer(computers[0].id) == computers[0])
        #expect(store.computers.count == 2)
    }

    @Test func deletingRemovesComputersAndRemembersWhen() {
        let (store, computers) = makeStore(computers: ["Studio", "Server", "Pi"])
        let before = Date.now

        store.delete([computers[0].id, computers[2].id])

        #expect(names(in: store) == ["Server"])
        let tombstones = store.document.tombstones
        #expect(Set(tombstones.keys) == [computers[0].id.uuidString, computers[2].id.uuidString])
        #expect(tombstones.values.allSatisfy { $0 >= before && $0 <= .now })
        // A deletion has to outrank the copy it deletes on every other device.
        #expect(tombstones[computers[0].id.uuidString]! >= computers[0].modifiedAt)

        store.delete(computers[1].id)
        #expect(store.computers.isEmpty)
        #expect(store.document.tombstones[computers[1].id.uuidString] != nil)
    }

    @Test func deletingSomethingThatIsNotThereLeavesNoTrace() {
        let (store, computers) = makeStore(computers: ["Studio"])

        store.delete(UUID())
        store.delete([])

        #expect(store.computers == computers)
        #expect(store.document.tombstones.isEmpty)
    }

    @Test func addingADeletedComputerAgainForgetsTheDeletion() {
        let (store, computers) = makeStore(computers: ["Studio"])
        store.delete(computers[0].id)
        #expect(store.document.tombstones.count == 1)

        store.add(computers[0])

        #expect(store.computers.map(\.id) == [computers[0].id])
        #expect(store.document.tombstones.isEmpty)
    }

    @Test func duplicatingMakesAFreshCopy() throws {
        let store = makeStore()
        let original = store.add(Computer(
            name: "Studio", host: "studio.local", username: "me", isFavorite: true, tags: ["work"]))
        store.markConnected(original.id)

        let copy = try #require(store.duplicate(original.id))

        #expect(copy.id != original.id)
        #expect(copy.name == "Studio Copy")
        #expect(copy.host == "studio.local")
        #expect(copy.username == "me")
        #expect(copy.tags == ["work"])
        #expect(!copy.isFavorite)
        #expect(copy.lastConnectedAt == nil)
        #expect(store.computers.map(\.id) == [original.id, copy.id])
        #expect(store.duplicate(UUID()) == nil)

        // A computer without a name is known by its address.
        let nameless = store.add(Computer(name: "", host: "10.0.0.5"))
        #expect(store.duplicate(nameless.id)?.name == "10.0.0.5 Copy")
    }

    @Test func favoritesAreTheStarredComputers() {
        let (store, computers) = makeStore(computers: ["Studio", "Server", "Pi"])

        store.toggleFavorite(computers[1].id)
        #expect(store.favorites.map(\.name) == ["Server"])

        store.toggleFavorite(computers[2].id)
        #expect(store.favorites.map(\.name) == ["Server", "Pi"])

        store.toggleFavorite(computers[1].id)
        #expect(store.favorites.map(\.name) == ["Pi"])
    }

    @Test func recentsListConnectedComputersNewestFirst() {
        let (store, computers) = makeStore(computers: ["Studio", "Server", "Pi"])
        #expect(store.recents.isEmpty)

        store.markConnected(computers[0].id)
        LibraryFixtures.letClockAdvance()
        store.markConnected(computers[2].id)
        #expect(store.recents.map(\.name) == ["Pi", "Studio"])

        LibraryFixtures.letClockAdvance()
        store.markConnected(computers[0].id)
        #expect(store.recents.map(\.name) == ["Studio", "Pi"])

        store.clearRecents()
        #expect(store.recents.isEmpty)
        #expect(store.computers.count == 3)
        #expect(store.computers.allSatisfy { $0.lastConnectedAt == nil })
    }

    @Test func aSavedComputerIsFoundByItsAddress() {
        let store = makeStore()
        let studio = store.add(Computer(name: "Studio", host: "Studio.local", port: 5901))

        #expect(store.existingComputer(host: "studio.LOCAL", port: 5901)?.id == studio.id)
        // A fully qualified name with its trailing dot is the same host.
        #expect(store.existingComputer(host: "studio.local.", port: 5901)?.id == studio.id)
        #expect(store.existingComputer(host: "studio.local", port: 5900) == nil)
        #expect(store.existingComputer(host: "studio", port: 5901) == nil)
    }

    @Test func tagsAreListedOnceInAlphabeticalOrder() {
        let store = makeStore()
        store.add(Computer(name: "A", host: "a.local", tags: ["work", "Office"]))
        store.add(Computer(name: "B", host: "b.local", tags: ["home", "work"]))
        store.add(Computer(name: "C", host: "c.local"))

        #expect(store.allTags == ["home", "Office", "work"])
    }

    // MARK: - Reordering

    @Test func movingAComputerDownReordersTheList() {
        let (store, computers) = makeStore(computers: ["A", "B", "C", "D"])

        store.move(computers.map(\.id), fromOffsets: [0], toOffset: 3)

        #expect(names(in: store) == ["B", "C", "A", "D"])
        #expect(store.computers.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test func movingAComputerUpReordersTheList() {
        let (store, computers) = makeStore(computers: ["A", "B", "C", "D"])

        store.move(computers.map(\.id), fromOffsets: [3], toOffset: 0)

        #expect(names(in: store) == ["D", "A", "B", "C"])
    }

    @Test func movingToTheEndOrBeyondPutsTheComputerLast() {
        let (store, computers) = makeStore(computers: ["A", "B", "C", "D"])
        store.move(computers.map(\.id), fromOffsets: [1], toOffset: 4)
        #expect(names(in: store) == ["A", "C", "D", "B"])

        store.move(store.computers.map(\.id), fromOffsets: [0], toOffset: 99)
        #expect(names(in: store) == ["C", "D", "B", "A"])
    }

    @Test func movingSeveralComputersKeepsThemTogetherInOrder() {
        let (store, computers) = makeStore(computers: ["A", "B", "C", "D"])

        store.move(computers.map(\.id), fromOffsets: [0, 2], toOffset: 4)

        #expect(names(in: store) == ["B", "D", "A", "C"])
    }

    @Test func movingWithinAFilteredListLeavesTheOtherComputersInPlace() {
        // The list on screen shows only B and D, say the members of a group.
        let (store, computers) = makeStore(computers: ["A", "B", "C", "D"])

        store.move([computers[1].id, computers[3].id], fromOffsets: [1], toOffset: 0)

        #expect(names(in: store) == ["A", "D", "C", "B"])
    }

    @Test func onlyComputersThatChangedPlaceAreStamped() throws {
        let (store, computers) = makeStore(computers: ["A", "B", "C", "D"])
        LibraryFixtures.letClockAdvance()

        store.move(computers.map(\.id), fromOffsets: [0], toOffset: 2)

        #expect(names(in: store) == ["B", "A", "C", "D"])
        for moved in computers[0...1] {
            #expect(try #require(store.computer(moved.id)).modifiedAt > moved.modifiedAt)
        }
        for untouched in computers[2...3] {
            #expect(store.computer(untouched.id) == untouched)
        }
    }

    @Test func aMoveThatNamesUnknownComputersIsIgnored() {
        let (store, computers) = makeStore(computers: ["A", "B"])
        let log = ChangeLog(observing: store)

        store.move([computers[0].id, UUID()], fromOffsets: [0], toOffset: 2)

        #expect(store.computers == computers)
        #expect(log.count == 0)
    }

    /// Every device numbers its own computers from zero, so after a sync
    /// several share a place. They still have to be movable.
    @Test func computersThatShareASortIndexCanStillBeReordered() {
        let store = makeStore()
        let stamp = LibraryFixtures.recentWholeSecond()
        store.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("From the Mac", modifiedAt: stamp, sortIndex: 0),
            LibraryFixtures.computer("From the phone", modifiedAt: stamp, sortIndex: 0),
            LibraryFixtures.computer("Last", modifiedAt: stamp, sortIndex: 5),
        ]))
        let shown = store.computers.map(\.id)

        // Drag the second row above the first.
        store.move(shown, fromOffsets: [1], toOffset: 0)

        #expect(store.computers.map(\.id) == [shown[1], shown[0], shown[2]])
        #expect(store.computers.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func aMoveThatChangesNothingIsNotAnnounced() {
        let (store, computers) = makeStore(computers: ["A", "B", "C"])
        var announcements = 0
        store.onChange = { _ in announcements += 1 }

        store.move(computers.map(\.id), fromOffsets: [1], toOffset: 1)

        #expect(names(in: store) == ["A", "B", "C"])
        #expect(announcements == 0)
    }

    @Test func twoDevicesThatSyncShowTheirComputersInTheSameOrder() {
        let mac = makeStore(), phone = makeStore()
        mac.add(Computer(name: "Added on the Mac", host: "mac.local"))
        LibraryFixtures.letClockAdvance()
        phone.add(Computer(name: "Added on the phone", host: "phone.local"))
        let fromMac = mac.document, fromPhone = phone.document

        mac.merge(fromPhone)
        phone.merge(fromMac)

        #expect(mac.computers == phone.computers)
        #expect(mac.computers.map(\.name) == ["Added on the Mac", "Added on the phone"])
    }

    // MARK: - Groups

    @Test func groupsAreCreatedInOrder() {
        let store = makeStore()

        let home = store.addGroup(named: "Home")
        let work = store.addGroup(named: "Work", symbolName: "building.2")

        #expect(home.symbolName == "folder")
        #expect(work.symbolName == "building.2")
        #expect([home, work].map(\.sortIndex) == [0, 1])
        #expect(store.groups == [home, work])
        #expect(store.group(work.id) == work)
        #expect(store.group(UUID()) == nil)
    }

    @Test func updatingAGroupStampsIt() throws {
        let store = makeStore()
        let group = store.addGroup(named: "Home")
        let log = ChangeLog(observing: store)
        LibraryFixtures.letClockAdvance()

        var renamed = group
        renamed.name = "Home Office"
        store.update(renamed)

        let saved = try #require(store.group(group.id))
        #expect(saved.name == "Home Office")
        #expect(saved.modifiedAt > group.modifiedAt)
        #expect(log.count == 1)

        // Nothing to do for an unchanged group or one the library never had.
        store.update(saved)
        store.update(ComputerGroup(name: "Stranger"))
        #expect(store.groups == [saved])
        #expect(log.count == 1)
    }

    @Test func computersAreListedByGroup() {
        let store = makeStore()
        let home = store.addGroup(named: "Home")
        let work = store.addGroup(named: "Work")
        store.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        store.add(Computer(name: "Server", host: "server.local", groupID: work.id))
        store.add(Computer(name: "Mini", host: "mini.local", groupID: home.id))
        store.add(Computer(name: "Loose", host: "loose.local"))

        #expect(store.computers(in: home.id).map(\.name) == ["Studio", "Mini"])
        #expect(store.computers(in: work.id).map(\.name) == ["Server"])
        #expect(store.computers(in: nil).map(\.name) == ["Loose"])
        #expect(store.computers(in: UUID()).isEmpty)
    }

    @Test func deletingAGroupKeepsItsComputersAndUngroupsThem() throws {
        let store = makeStore()
        let home = store.addGroup(named: "Home")
        let work = store.addGroup(named: "Work")
        let member = store.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        let other = store.add(Computer(name: "Server", host: "server.local", groupID: work.id))
        let loose = store.add(Computer(name: "Loose", host: "loose.local"))
        LibraryFixtures.letClockAdvance()

        store.deleteGroup(home.id)

        #expect(store.groups == [work])
        #expect(store.document.tombstones.keys.contains(home.id.uuidString))
        let ungrouped = try #require(store.computer(member.id))
        #expect(ungrouped.groupID == nil)
        // Stamped, so the change reaches devices that still have it grouped.
        #expect(ungrouped.modifiedAt > member.modifiedAt)
        #expect(store.computer(other.id) == other)
        #expect(store.computer(loose.id) == loose)
        #expect(store.computers.count == 3)
    }

    @Test func movingGroupsRenumbersThem() {
        let store = makeStore()
        let groups = ["A", "B", "C"].map { store.addGroup(named: $0) }

        store.moveGroups(fromOffsets: [0], toOffset: 3)

        #expect(store.groups.map(\.name) == ["B", "C", "A"])
        #expect(store.groups.map(\.sortIndex) == [0, 1, 2])
        #expect(Set(store.groups.map(\.id)) == Set(groups.map(\.id)))

        store.moveGroups(fromOffsets: [2], toOffset: 0)
        #expect(store.groups.map(\.name) == ["A", "B", "C"])
    }

    // MARK: - Change announcements

    @Test func everyLocalChangeIsAnnouncedOnceWithTheSavedLibrary() throws {
        let store = makeStore()
        let log = ChangeLog(observing: store)

        func announced(_ what: Comment, by change: () throws -> Void) rethrows {
            let before = log.count
            try change()
            #expect(log.count == before + 1, what)
            #expect(log.documents.last == store.document, what)
        }

        var studio = Computer(name: "Studio", host: "studio.local")
        var server = Computer(name: "Server", host: "server.local")
        var home = ComputerGroup(name: "")
        announced("add") { studio = store.add(studio) }
        announced("add") { server = store.add(server) }
        announced("update") {
            studio.notes = "edited"
            store.update(studio)
        }
        announced("update in place") { store.update(server.id) { $0.notes = "edited" } }
        announced("toggle favorite") { store.toggleFavorite(studio.id) }
        announced("mark connected") { store.markConnected(studio.id) }
        announced("clear recents") { store.clearRecents() }
        announced("duplicate") { store.duplicate(studio.id) }
        announced("move") {
            store.move(store.computers.map(\.id), fromOffsets: [0], toOffset: 2)
        }
        announced("add group") { home = store.addGroup(named: "Home") }
        announced("add group") { store.addGroup(named: "Work") }
        announced("update group") {
            home.name = "Home Office"
            store.update(home)
        }
        announced("move groups") { store.moveGroups(fromOffsets: [0], toOffset: 2) }
        announced("delete group") { store.deleteGroup(home.id) }
        announced("delete") { store.delete(server.id) }
        let backup = try store.exportBackup()
        try announced("import, merging") { try store.importBackup(backup, strategy: .merge) }
        try announced("import, replacing") { try store.importBackup(backup, strategy: .replace) }
        announced("erase") { store.eraseAll() }
    }

    @Test func requestsThatChangeNothingAreNotAnnounced() {
        let store = makeStore()
        let studio = store.add(Computer(name: "Studio", host: "studio.local"))
        let home = store.addGroup(named: "Home")
        let log = ChangeLog(observing: store)

        store.update(studio)
        store.update(UUID()) { $0.name = "nobody" }
        store.toggleFavorite(UUID())
        store.markConnected(UUID())
        store.clearRecents()
        store.delete([])
        store.update(home)
        store.update(ComputerGroup(name: "Stranger"))
        store.deleteGroup(UUID())

        #expect(log.count == 0)
    }

    // MARK: - Merging

    @Test func mergingAppliesRemoteChangesWithoutAnnouncingThem() {
        let store = makeStore()
        let local = store.add(Computer(name: "Local", host: "local.local"))
        let log = ChangeLog(observing: store)
        let remote = LibraryFixtures.computer(
            "Remote", modifiedAt: LibraryFixtures.recentWholeSecond(), sortIndex: 5)
        let remoteGroup = LibraryFixtures.group("Shared", modifiedAt: remote.modifiedAt)
        let document = LibraryDocument(computers: [remote], groups: [remoteGroup])

        #expect(store.merge(document) == true)

        #expect(store.computers == [local, remote])
        #expect(store.groups == [remoteGroup])
        #expect(log.count == 0)

        // The same news twice is no news.
        #expect(store.merge(document) == false)
        #expect(log.count == 0)
    }

    @Test func mergingADeletionRemovesTheComputerHere() {
        let (store, computers) = makeStore(computers: ["Studio", "Server"])
        LibraryFixtures.letClockAdvance()

        let changed = store.merge(LibraryDocument(tombstones: [computers[0].id.uuidString: .now]))

        #expect(changed)
        #expect(names(in: store) == ["Server"])
        #expect(store.document.tombstones.keys.contains(computers[0].id.uuidString))
    }

    @Test func mergedComputersAreShownInManualOrder() {
        let store = makeStore()
        let stamp = LibraryFixtures.recentWholeSecond()
        store.merge(LibraryDocument(
            computers: [
                LibraryFixtures.computer("Third", modifiedAt: stamp, sortIndex: 30),
                LibraryFixtures.computer("First", modifiedAt: stamp, sortIndex: 10),
                LibraryFixtures.computer("Second", modifiedAt: stamp, sortIndex: 20),
            ],
            groups: [
                LibraryFixtures.group("Later", modifiedAt: stamp, sortIndex: 2),
                LibraryFixtures.group("Sooner", modifiedAt: stamp, sortIndex: 1),
            ]))

        #expect(names(in: store) == ["First", "Second", "Third"])
        #expect(store.groups.map(\.name) == ["Sooner", "Later"])
    }

    // MARK: - Persistence

    @Test func theLibraryIsReadBackFromItsFile() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("Library.json")
        let store = LibraryStore(fileURL: file, backupsDirectory: nil)
        let home = store.addGroup(named: "Home", symbolName: "house")
        let studio = store.add(Computer(
            name: "Studio", host: "studio.local", port: 5901, username: "me",
            kind: .linux, groupID: home.id, tags: ["work"], notes: "Under the desk"))
        let doomed = store.add(Computer(name: "Doomed", host: "doomed.local"))
        store.add(Computer(name: "Server", host: "server.local"))
        store.toggleFavorite(studio.id)
        store.markConnected(studio.id)
        store.delete(doomed.id)

        store.saveNow()
        #expect(store.lastError == nil)

        let reopened = LibraryStore(fileURL: file, backupsDirectory: nil)
        #expect(reopened.lastError == nil)
        #expect(reopened.computers.map(\.name) == ["Studio", "Server"])
        #expect(reopened.groups.map(\.name) == ["Home"])
        #expect(reopened.favorites.map(\.name) == ["Studio"])
        #expect(reopened.recents.map(\.name) == ["Studio"])
        #expect(reopened.computers(in: home.id).map(\.name) == ["Studio"])
        // Everything comes back exactly, dates included.
        #expect(reopened.document == store.document)
        #expect(reopened.document.tombstones.keys.contains(doomed.id.uuidString))
    }

    @Test func aLibraryWithWholeSecondDatesReloadsExactly() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("Library.json")
        let stamp = LibraryFixtures.recentWholeSecond()
        let group = LibraryFixtures.group("Home", modifiedAt: stamp)
        let document = LibraryDocument(
            computers: [
                LibraryFixtures.computer("Studio", groupID: group.id, modifiedAt: stamp, sortIndex: 0),
                LibraryFixtures.computer("Server", modifiedAt: stamp.addingTimeInterval(60), sortIndex: 1),
            ],
            groups: [group],
            tombstones: [UUID().uuidString: stamp.addingTimeInterval(-600)])

        let store = LibraryStore(fileURL: file, backupsDirectory: nil)
        store.merge(document)
        store.saveNow()

        let reopened = LibraryStore(fileURL: file, backupsDirectory: nil)
        #expect(reopened.document == document)
    }

    @Test func changesAreSavedShortlyAfterTheyAreMade() async throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("Library.json")
        let store = LibraryStore(fileURL: file, backupsDirectory: nil)

        store.add(Computer(name: "Studio", host: "studio.local"))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Nothing asks for a save here; the store writes on its own.
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let saved = try LibraryDocument.decode(Data(contentsOf: file))
        #expect(saved.computers.map(\.name) == ["Studio"])
        #expect(store.lastError == nil)
    }

    @Test func aMissingFileIsAnEmptyLibrary() throws {
        let scratch = try ScratchDirectory()
        let store = LibraryStore(fileURL: scratch.file("Library.json"), backupsDirectory: nil)

        #expect(store.computers.isEmpty)
        #expect(store.groups.isEmpty)
        #expect(store.lastError == nil)
        #expect(scratch.contents.isEmpty)
    }

    @Test(arguments: ["{ \"computers\": [ this is not json", "[1, 2, 3]", ""])
    func aFileThatCannotBeReadIsSetAsideNotOverwritten(contents: String) throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("Library.json")
        let unreadable = Data(contents.utf8)
        try unreadable.write(to: file)

        let store = LibraryStore(fileURL: file, backupsDirectory: nil)

        #expect(store.computers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = try #require(scratch.contents.first {
            $0.lastPathComponent.hasPrefix("Library.unreadable-")
        })
        #expect(aside.pathExtension == "json")
        #expect(try Data(contentsOf: aside) == unreadable)
        #expect(try #require(store.lastError).contains(aside.lastPathComponent))

        // Carrying on starts a new file and leaves the old one for recovery.
        store.add(Computer(name: "Studio", host: "studio.local"))
        store.saveNow()
        #expect(try LibraryDocument.decode(Data(contentsOf: file)).computers.count == 1)
        #expect(try Data(contentsOf: aside) == unreadable)
    }

    @Test func aSaveThatFailsIsReportedAndRetried() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("Not Created Yet/Library.json")
        let store = LibraryStore(fileURL: file, backupsDirectory: nil)
        store.add(Computer(name: "Studio", host: "studio.local"))

        store.saveNow()
        #expect(store.lastError != nil)

        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.saveNow()
        #expect(store.lastError == nil)
        #expect(try LibraryDocument.decode(Data(contentsOf: file)).computers.count == 1)
    }

    // MARK: - Backups

    @Test func anExportedBackupIsTheLibraryFile() throws {
        let store = makeStore()
        let home = store.addGroup(named: "Home")
        let studio = store.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        store.add(Computer(name: "Server", host: "server.local"))
        store.delete(studio.id)

        let backup = try LibraryDocument.decode(store.exportBackup())

        #expect(backup == store.document)
    }

    /// Restoring is deliberate: what the backup holds wins over what has
    /// happened to it since, and only what the backup never had is left as
    /// it is.
    @Test func importingWithMergeRestoresTheBackupAndKeepsWhatIsOnlyHere() throws {
        let earlier = LibraryFixtures.recentWholeSecond(secondsAgo: 7200)
        let later = LibraryFixtures.recentWholeSecond(secondsAgo: 3600)
        let editedSince = UUID(), editedInBackup = UUID()

        let store = makeStore()
        store.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Only here", modifiedAt: earlier, sortIndex: 0),
            LibraryFixtures.computer("Edited here since", id: editedSince, modifiedAt: later, sortIndex: 1),
            LibraryFixtures.computer("Stale here", id: editedInBackup, modifiedAt: earlier, sortIndex: 2),
        ]))
        let onlyHere = try #require(store.computers.first)
        let backupGroup = LibraryFixtures.group("From backup", modifiedAt: earlier)
        let backup = LibraryDocument(
            computers: [
                LibraryFixtures.computer("As backed up", id: editedSince, modifiedAt: earlier, sortIndex: 1),
                LibraryFixtures.computer("Newer in backup", id: editedInBackup, modifiedAt: later, sortIndex: 2),
                LibraryFixtures.computer("Only in backup", modifiedAt: earlier, sortIndex: 3),
            ],
            groups: [backupGroup])
        let before = Date.now

        try store.importBackup(backup.encoded(), strategy: .merge)

        #expect(names(in: store) == [
            "Only here", "As backed up", "Newer in backup", "Only in backup",
        ])
        #expect(store.groups.map(\.id) == [backupGroup.id])
        // What was restored is stamped as changed now, so that it wins on
        // the user's other devices too; the rest is untouched.
        #expect(store.computers.first == onlyHere)
        #expect(store.computers.dropFirst().allSatisfy { $0.modifiedAt >= before })
        #expect(store.groups.allSatisfy { $0.modifiedAt >= before })
    }

    @Test func importingABackupBringsBackWhatWasDeletedSinceItWasMade() throws {
        let store = makeStore()
        let home = store.addGroup(named: "Home")
        let studio = store.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        let backup = try store.exportBackup()

        store.delete(studio.id)
        store.deleteGroup(home.id)
        try store.importBackup(backup, strategy: .merge)

        #expect(store.computers.map(\.name) == ["Studio"])
        #expect(store.groups.map(\.name) == ["Home"])
        #expect(store.computers(in: home.id).map(\.name) == ["Studio"])
        #expect(store.document.tombstones.isEmpty)
    }

    @Test func aLibraryCanBeErasedAndThenRestoredFromItsExport() throws {
        let store = makeStore()
        store.add(Computer(name: "Studio", host: "studio.local"))
        store.add(Computer(name: "Server", host: "server.local"))
        let backup = try store.exportBackup()

        store.eraseAll()
        try store.importBackup(backup, strategy: .merge)

        #expect(store.computers.map(\.name) == ["Studio", "Server"])
    }

    @Test func importingWithReplaceLeavesOnlyWhatTheBackupHolds() throws {
        let stamp = LibraryFixtures.recentWholeSecond()
        let store = makeStore()
        let localGroup = store.addGroup(named: "Local group")
        let localOnly = store.add(Computer(name: "Only here", host: "here.local", groupID: localGroup.id))
        let shared = store.add(Computer(name: "Edited here since", host: "shared.local"))

        let backupGroup = LibraryFixtures.group("From backup", modifiedAt: stamp)
        let backup = LibraryDocument(
            computers: [
                LibraryFixtures.computer("As it was", id: shared.id, modifiedAt: stamp, sortIndex: 1),
                LibraryFixtures.computer("Only in backup", groupID: backupGroup.id, modifiedAt: stamp, sortIndex: 0),
            ],
            groups: [backupGroup])
        let before = Date.now

        try store.importBackup(backup.encoded(), strategy: .replace)

        #expect(names(in: store) == ["Only in backup", "As it was"])
        // The backup's items exactly, but for being stamped as changed now.
        func unstamped(_ computers: [Computer]) -> [Computer] {
            computers.map { computer in
                var computer = computer
                computer.modifiedAt = stamp
                return computer
            }
        }
        #expect(unstamped(store.document.sortedByID.computers) == backup.sortedByID.computers)
        #expect(store.computers.allSatisfy { $0.modifiedAt >= before })
        #expect(store.groups.map(\.id) == [backupGroup.id])
        #expect(store.groups.map(\.name) == ["From backup"])
        // What the backup does not contain is gone, and recorded as deleted
        // so that it disappears from the user's other devices as well.
        let tombstones = store.document.tombstones
        #expect(Set(tombstones.keys) == [localOnly.id.uuidString, localGroup.id.uuidString])
        #expect(tombstones.values.allSatisfy { $0 >= before && $0 <= .now })
    }

    @Test func importingSomethingThatIsNotABackupThrowsAndChangesNothing() {
        let (store, computers) = makeStore(computers: ["Studio", "Server"])
        let log = ChangeLog(observing: store)

        for strategy in [LibraryStore.ImportStrategy.merge, .replace] {
            #expect(throws: (any Error).self) {
                try store.importBackup(Data("definitely not a library".utf8), strategy: strategy)
            }
        }

        #expect(store.computers == computers)
        #expect(log.count == 0)
    }

    @Test func erasingRemovesEverythingAndRemembersTheDeletions() {
        let store = makeStore()
        let home = store.addGroup(named: "Home")
        let studio = store.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        let server = store.add(Computer(name: "Server", host: "server.local"))

        store.eraseAll()

        #expect(store.computers.isEmpty)
        #expect(store.groups.isEmpty)
        #expect(Set(store.document.tombstones.keys)
            == [home.id.uuidString, studio.id.uuidString, server.id.uuidString])
    }

    @Test func erasingThisDeviceOnlyRecordsNoDeletions() {
        let store = makeStore()
        let home = store.addGroup(named: "Home")
        store.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        store.delete(store.add(Computer(name: "Doomed", host: "doomed.local")).id)
        var announcements = 0
        store.onChange = { _ in announcements += 1 }

        store.eraseThisDeviceOnly()

        #expect(store.computers.isEmpty)
        #expect(store.groups.isEmpty)
        // Nothing says "deleted", so nothing is removed anywhere else, and
        // nothing is announced for sync to push.
        #expect(store.document == LibraryDocument())
        #expect(announcements == 0)
    }

    // MARK: - Clocks that disagree

    /// A copy stamped by a clock running ahead of this one must not outrank
    /// the edit made to it here.
    @Test func anEditOutranksTheCopyItWasMadeFrom() throws {
        let store = makeStore()
        let original = LibraryFixtures.computer(
            "Before", modifiedAt: Date.now.addingTimeInterval(3600))
        store.merge(LibraryDocument(computers: [original]))

        store.update(original.id) { $0.name = "After" }
        #expect(try #require(store.computer(original.id)).modifiedAt > original.modifiedAt)

        // Every other device, and iCloud, still hold the original.
        store.merge(LibraryDocument(computers: [original]))
        #expect(store.computer(original.id)?.name == "After")
    }

    @Test func aDeletionOutranksTheCopyItDeleted() {
        let store = makeStore()
        let original = LibraryFixtures.computer(
            "Doomed", modifiedAt: Date.now.addingTimeInterval(3600))
        store.merge(LibraryDocument(computers: [original]))

        store.delete(original.id)
        store.merge(LibraryDocument(computers: [original]))

        #expect(store.computers.isEmpty)
    }

    @Test func deletingAGroupOutranksTheCopyItDeleted() {
        let store = makeStore()
        let original = LibraryFixtures.group("Doomed", modifiedAt: Date.now.addingTimeInterval(3600))
        store.merge(LibraryDocument(groups: [original]))

        store.deleteGroup(original.id)
        store.merge(LibraryDocument(groups: [original]))

        #expect(store.groups.isEmpty)
    }

    @Test func addingAComputerAgainOutranksItsEarlierDeletion() {
        let store = makeStore()
        let computer = Computer(name: "Back again", host: "studio.local")
        let deletedLater = LibraryDocument(
            tombstones: [computer.id.uuidString: Date.now.addingTimeInterval(3600)])
        store.merge(deletedLater)

        store.add(computer)
        store.merge(deletedLater)

        #expect(store.computers.map(\.name) == ["Back again"])
    }

    // MARK: - Connections

    /// Connecting is not an edit: it must not make this copy outrank a
    /// change made on another device.
    @Test func connectingDoesNotCountAsAnEdit() throws {
        let (store, computers) = makeStore(computers: ["Studio"])
        let before = try #require(store.computer(computers[0].id))

        store.markConnected(before.id)

        let after = try #require(store.computer(before.id))
        #expect(after.lastConnectedAt != nil)
        #expect(after.modifiedAt == before.modifiedAt)
    }

    @Test func clearingTheRecentsIsRemembered() throws {
        let (store, computers) = makeStore(computers: ["Studio"])
        store.markConnected(computers[0].id)
        let connected = try #require(store.computer(computers[0].id))
        LibraryFixtures.letClockAdvance()

        store.clearRecents()

        // A copy that still has the connection does not bring it back.
        store.merge(LibraryDocument(computers: [connected]))
        #expect(store.recents.isEmpty)

        // Connecting again does count.
        store.markConnected(connected.id)
        #expect(store.recents.map(\.name) == ["Studio"])
        store.merge(LibraryDocument(computers: [connected]))
        #expect(store.recents.map(\.name) == ["Studio"])
    }

    /// A position taken from a hostile or damaged record must not be able
    /// to trap the arithmetic that numbers the next computer.
    @Test func addingAfterAnAbsurdSortIndexDoesNotOverflow() throws {
        let json = #"{"computers":[{"id":"11111111-2222-3333-4444-555555555555","host":"a","sortIndex":9223372036854775807}]}"#
        let store = makeStore()
        store.merge(try LibraryDocument.decode(Data(json.utf8)))

        let added = store.add(Computer(name: "Next", host: "next.local"))

        #expect(added.sortIndex > 0)
        #expect(store.computers.count == 2)
        #expect(throws: Never.self) { try store.exportBackup() }
    }

    // MARK: - Groups that are not here

    /// A computer can name a group this device does not have: deleted on
    /// another device, or not synced yet. It reads as being in no group.
    @Test func aComputerWhoseGroupIsNotHereReadsAsUngrouped() throws {
        let store = makeStore()
        let missing = UUID()
        store.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Orphan", groupID: missing, modifiedAt: .now),
        ]))
        let orphan = try #require(store.computers.first)

        #expect(orphan.groupID == missing)
        #expect(store.group(of: orphan) == nil)
        #expect(store.computers(in: nil).map(\.name) == ["Orphan"])
        #expect(store.computers(in: missing).isEmpty)

        // When the group turns up, the computer is in it.
        let group = ComputerGroup(id: missing, name: "Home")
        store.merge(LibraryDocument(groups: [group]))
        #expect(store.group(of: orphan)?.name == "Home")
        #expect(store.computers(in: missing).map(\.name) == ["Orphan"])
        #expect(store.computers(in: nil).isEmpty)
    }

    // MARK: - Automatic backups

    private func noon(daysAgo: Int) throws -> Date {
        let calendar = Calendar.current
        let today = try #require(calendar.date(
            bySettingHour: 12, minute: 0, second: 0, of: .now))
        return try #require(calendar.date(byAdding: .day, value: -daysAgo, to: today))
    }

    private func backupName(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Library \(formatter.string(from: day)).json"
    }

    private func fileNames(in directory: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.map(\.lastPathComponent))
    }

    @Test func anAutomaticBackupIsWrittenOncePerDay() throws {
        let scratch = try ScratchDirectory()
        let backups = try scratch.directory("Backups")
        let store = LibraryStore(fileURL: nil, backupsDirectory: backups)
        store.add(Computer(name: "Studio", host: "studio.local"))
        let yesterday = try noon(daysAgo: 1)
        let today = try noon(daysAgo: 0)

        store.writeAutomaticBackupIfNeeded(now: yesterday)
        #expect(fileNames(in: backups) == [backupName(for: yesterday)])

        // Later the same day, with more in the library: still one backup,
        // and it is not rewritten.
        store.add(Computer(name: "Server", host: "server.local"))
        store.writeAutomaticBackupIfNeeded(now: yesterday.addingTimeInterval(3 * 3600))
        #expect(fileNames(in: backups) == [backupName(for: yesterday)])
        #expect(store.automaticBackups().map(\.computerCount) == [1])

        store.writeAutomaticBackupIfNeeded(now: today)
        #expect(fileNames(in: backups) == [backupName(for: yesterday), backupName(for: today)])
        #expect(store.lastError == nil)

        // A backup is a complete library that can be imported again.
        let newest = try #require(store.automaticBackups().first { $0.computerCount == 2 })
        let restored = LibraryStore(fileURL: nil, backupsDirectory: nil)
        try restored.importBackup(Data(contentsOf: newest.url), strategy: .replace)
        #expect(Set(restored.computers.map(\.name)) == ["Studio", "Server"])
    }

    @Test func onlyTheNewestTenAutomaticBackupsAreKept() throws {
        let scratch = try ScratchDirectory()
        let backups = try scratch.directory("Backups")
        let store = LibraryStore(fileURL: nil, backupsDirectory: backups)
        store.add(Computer(name: "Studio", host: "studio.local"))

        // Thirteen consecutive days, oldest first.
        let days = try (0..<13).map { try noon(daysAgo: 20 - $0) }
        for day in days {
            store.writeAutomaticBackupIfNeeded(now: day)
            // Backups are ordered by file date. Give each file the date of
            // the day it stands for, so the order does not depend on files
            // written within the same instant.
            try FileManager.default.setAttributes(
                [.modificationDate: day],
                ofItemAtPath: backups.appending(path: backupName(for: day)).path)
        }

        #expect(LibraryStore.maximumAutomaticBackups == 10)
        let expected = days.suffix(10).map(backupName(for:))
        #expect(fileNames(in: backups) == Set(expected))
        #expect(store.automaticBackups().map(\.url.lastPathComponent) == expected.reversed())
        #expect(store.automaticBackups().map(\.date) == days.suffix(10).reversed())
    }

    @Test func anEmptyLibraryIsNotBackedUp() throws {
        let scratch = try ScratchDirectory()
        let backups = try scratch.directory("Backups")
        let store = LibraryStore(fileURL: nil, backupsDirectory: backups)
        store.addGroup(named: "A group but no computers")

        store.writeAutomaticBackupIfNeeded()

        #expect(fileNames(in: backups).isEmpty)
        #expect(store.automaticBackups().isEmpty)
    }

    @Test func filesThatAreNotBackupsAreNotListed() throws {
        let scratch = try ScratchDirectory()
        let backups = try scratch.directory("Backups")
        let store = LibraryStore(fileURL: nil, backupsDirectory: backups)
        store.add(Computer(name: "Studio", host: "studio.local"))
        store.writeAutomaticBackupIfNeeded()
        try Data("not a library".utf8).write(to: backups.appending(path: "Broken.json"))
        try Data("notes".utf8).write(to: backups.appending(path: "Read Me.txt"))

        let listed = store.automaticBackups()

        #expect(listed.count == 1)
        #expect(listed.first?.computerCount == 1)
        #expect(listed.first?.url.lastPathComponent == backupName(for: .now))
    }

    @Test func aStoreWithoutABackupsFolderWritesNoBackups() {
        let (store, _) = makeStore(computers: ["Studio"])

        store.writeAutomaticBackupIfNeeded()

        #expect(store.automaticBackups().isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func aBackupThatCannotBeWrittenIsReported() throws {
        let scratch = try ScratchDirectory()
        let missing = scratch.url.appending(path: "No Such Folder", directoryHint: .isDirectory)
        let store = LibraryStore(fileURL: nil, backupsDirectory: missing)
        store.add(Computer(name: "Studio", host: "studio.local"))

        store.writeAutomaticBackupIfNeeded()

        #expect(store.lastError != nil)
    }
}

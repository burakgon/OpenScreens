import Foundation
import Observation
import Testing
@testable import OpenScreensCore

@MainActor
@Suite("CloudSyncEngine")
struct CloudSyncEngineTests {

    // MARK: Helpers

    private func computer(_ name: String) -> Computer {
        Computer(name: name, host: "\(name.lowercased().replacing(" ", with: "-")).local")
    }

    /// Makes sure the next change is stamped later than everything before it.
    private func tick() {
        LibraryFixtures.letClockAdvance()
    }

    private func key(_ computer: Computer) -> String { "c.\(computer.id.uuidString)" }
    private func key(_ group: ComputerGroup) -> String { "g.\(group.id.uuidString)" }
    private func tombstoneKey(_ id: UUID) -> String { "t.\(id.uuidString)" }

    /// Two devices looking at the very same store, as if iCloud delivered
    /// every write instantly. Each still has to be told that something
    /// changed before it looks.
    private func twoDevicesSharingOneStore() -> (mac: SimulatedDevice, phone: SimulatedDevice) {
        let store = InMemoryCloudStore()
        return (SimulatedDevice(store: store), SimulatedDevice(store: store))
    }

    private func eventually(
        within timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: - On, off and unavailable

    @Test func syncIsOffUntilItIsTurnedOn() {
        let device = SimulatedDevice(syncEnabled: false)
        #expect(device.engine.status == .disabled)
        #expect(!device.engine.isEnabled)

        device.library.add(computer("Studio"))
        device.engine.syncNow()
        device.storeChangedExternally()

        #expect(device.engine.status == .disabled)
        #expect(device.store.operations.isEmpty)
        #expect(device.store.readCount == 0)
        #expect(device.store.synchronizeCount == 0)
    }

    @Test func withoutAStoreSyncIsUnavailableAndTheLibraryStillWorks() {
        let library = LibraryStore(fileURL: nil, backupsDirectory: nil)
        let center = NotificationCenter()
        let engine = CloudSyncEngine(library: library, store: nil, notificationCenter: center)
        library.onChange = { [weak engine] in engine?.libraryDidChange($0) }

        engine.isEnabled = true
        #expect(engine.status == .unavailable)

        let studio = library.add(computer("Studio"))
        library.update(studio.id) { $0.notes = "still editable" }
        library.add(computer("Server"))
        library.delete(studio.id)
        engine.syncNow()
        center.postCloudStoreChange(reason: NSUbiquitousKeyValueStoreServerChange)

        #expect(engine.status == .unavailable)
        #expect(library.computers.map(\.name) == ["Server"])
    }

    @Test func whileICloudIsUnavailableTheStoreIsNotTouched() {
        let store = InMemoryCloudStore()
        store.isAvailable = false
        let device = SimulatedDevice(store: store)
        #expect(device.engine.status == .unavailable)

        device.library.add(computer("Studio"))
        device.engine.syncNow()
        device.storeChangedExternally()

        #expect(device.engine.status == .unavailable)
        #expect(store.operations.isEmpty)
        #expect(store.readCount == 0)
        #expect(store.synchronizeCount == 0)
        #expect(device.library.computers.count == 1)
    }

    @Test func signingInToICloudStartsTheMergeThatWasWaiting() throws {
        // Another device has already put a computer in iCloud.
        let other = SimulatedDevice()
        let theirs = other.library.add(computer("Theirs"))

        let store = InMemoryCloudStore(values: other.store.values)
        store.isAvailable = false
        let device = SimulatedDevice(store: store)
        let mine = device.library.add(computer("Mine"))
        #expect(device.engine.status == .unavailable)

        store.isAvailable = true
        device.center.post(name: .NSUbiquityIdentityDidChange, object: nil)

        #expect(device.lastSync != nil)
        #expect(Set(device.library.computers.map(\.id)) == [mine.id, theirs.id])
        #expect(try store.computer(mine.id) == mine)
        #expect(try store.computer(theirs.id) == theirs)
    }

    @Test func aLocalChangeAlsoStartsTheMergeThatWasWaitingButNotInsideTheChange() async throws {
        let other = SimulatedDevice()
        let theirs = other.library.add(computer("Theirs"))
        let store = InMemoryCloudStore(values: other.store.values)
        store.isAvailable = false
        let device = SimulatedDevice(store: store)
        #expect(device.engine.status == .unavailable)

        // iCloud comes back without anyone announcing it.
        store.isAvailable = true
        let mine = device.library.add(computer("Mine"))

        // Merging changes the library, and the library was in the middle of
        // announcing a change of its own: nothing has been merged yet.
        #expect(device.library.computers.map(\.id) == [mine.id])

        #expect(await eventually { device.library.computer(theirs.id) != nil })
        #expect(device.lastSync != nil)
        #expect(try store.computer(mine.id) == mine)
    }

    @Test func aStoreThatKeepsNothingIsReportedAsUnavailable() {
        // What an app built without the iCloud entitlement is handed.
        let store = InMemoryCloudStore()
        store.discardsWrites = true
        let device = SimulatedDevice(store: store, syncEnabled: false)
        device.library.add(computer("Studio"))

        device.engine.isEnabled = true

        #expect(device.engine.status == .unavailable)
        // It stopped as soon as the first value did not stick.
        #expect(store.operations.count == 1)

        device.library.add(computer("Server"))
        #expect(device.engine.status == .unavailable)
        #expect(device.library.computers.map(\.name) == ["Studio", "Server"])
    }

    @Test func signingOutOfICloudStopsSyncWithoutLosingAnything() {
        let device = SimulatedDevice()
        device.library.add(computer("Studio"))
        let stored = device.store.values

        device.store.isAvailable = false
        device.center.post(name: .NSUbiquityIdentityDidChange, object: nil)
        #expect(device.engine.status == .unavailable)

        device.library.add(computer("Server"))
        #expect(device.library.computers.count == 2)
        #expect(device.store.values == stored)

        // Signing in again picks up where it left off.
        device.store.isAvailable = true
        device.center.post(name: .NSUbiquityIdentityDidChange, object: nil)
        #expect(device.lastSync != nil)
        #expect(device.store.keys(withPrefix: "c.").count == 2)
    }

    @Test func turningSyncOffStopsListeningAndDeletesNothing() {
        let (mac, phone) = twoDevicesSharingOneStore()
        let store = mac.store
        let studio = mac.library.add(computer("Studio"))
        phone.storeChangedExternally()
        #expect(phone.library.computers == [studio])
        let stored = store.values

        phone.engine.isEnabled = false

        #expect(phone.engine.status == .disabled)
        #expect(phone.library.computers == [studio])
        #expect(store.values == stored)

        // Off means off in both directions.
        store.forgetOperations()
        let onPhone = phone.library.add(computer("Phone only"))
        #expect(store.operations.isEmpty)
        let onMac = mac.library.add(computer("Mac only"))
        store.forgetOperations()
        phone.storeChangedExternally()
        phone.engine.syncNow()
        #expect(phone.library.computer(onMac.id) == nil)
        #expect(store.operations.isEmpty)
        #expect(phone.engine.status == .disabled)

        // Turning it back on merges both ways.
        phone.engine.isEnabled = true
        #expect(phone.library.computer(onMac.id) != nil)
        #expect(store.values[key(onPhone)] != nil)
        #expect(phone.lastSync != nil)
    }

    @Test func aCompletedPassRecordsWhenItHappened() throws {
        let before = Date.now
        let device = SimulatedDevice()
        let first = try #require(device.lastSync)
        #expect(first >= before && first <= .now)

        tick()
        device.library.add(computer("Studio"))
        #expect(try #require(device.lastSync) > first)
    }

    @Test func theEngineLeavesTheLibrarysChangeHandlerToTheApp() {
        let library = LibraryStore(fileURL: nil, backupsDirectory: nil)
        let store = InMemoryCloudStore()
        let engine = CloudSyncEngine(
            library: library, store: store, notificationCenter: NotificationCenter())
        engine.isEnabled = true
        #expect(library.onChange == nil)

        // Nobody forwards changes yet, so nothing is uploaded until asked.
        let studio = library.add(computer("Studio"))
        #expect(store.keys(withPrefix: "c.").isEmpty)
        engine.syncNow()
        #expect(store.keys(withPrefix: "c.") == [key(studio)])

        // The app's own handler forwards to the engine and does its own work.
        let app = SimulatedApp()
        library.onChange = { [weak engine] document in
            app.changesSeen += 1
            engine?.libraryDidChange(document)
        }
        library.add(computer("Server"))
        #expect(app.changesSeen == 1)
        #expect(store.keys(withPrefix: "c.").count == 2)

        // Turning sync off and on again does not displace it.
        engine.isEnabled = false
        engine.isEnabled = true
        library.add(computer("Pi"))
        #expect(app.changesSeen == 2)
        #expect(store.keys(withPrefix: "c.").count == 3)
    }

    @Test func theStatusCanBeObserved() {
        let device = SimulatedDevice(syncEnabled: false)
        let noticed = Flag()
        withObservationTracking {
            _ = device.engine.status
        } onChange: {
            noticed.raise()
        }

        device.engine.isEnabled = true

        #expect(noticed.isRaised)
        #expect(device.lastSync != nil)
    }

    @Test func anEngineThatIsReleasedStopsListening() {
        let library = LibraryStore(fileURL: nil, backupsDirectory: nil)
        let store = InMemoryCloudStore()
        let center = NotificationCenter()
        weak var released: CloudSyncEngine?
        do {
            let engine = CloudSyncEngine(library: library, store: store, notificationCenter: center)
            engine.isEnabled = true
            released = engine
            #expect(engine.status != .disabled)
        }
        #expect(released == nil)

        let readsBefore = store.readCount
        store.forgetOperations()
        center.postCloudStoreChange(reason: NSUbiquitousKeyValueStoreServerChange)
        center.post(name: .NSUbiquityIdentityDidChange, object: nil)

        #expect(store.readCount == readsBefore)
        #expect(store.operations.isEmpty)
    }

    @Test func aChangeAnnouncedInTheMiddleOfAPassIsHandledAfterIt() async {
        let device = SimulatedDevice()
        let center = device.center
        // The store announces an outside change from inside the engine's own
        // write. Passes must not nest; the announcement is dealt with once
        // the running pass is done.
        var announcements = 0
        device.store.onWrite = {
            announcements += 1
            center.postCloudStoreChange(reason: NSUbiquitousKeyValueStoreServerChange)
        }

        let studio = device.library.add(computer("Studio"))

        #expect(announcements == 1)
        #expect(device.store.operations.last == .set(key(studio)))
        #expect(device.lastSync != nil)
        let readsAfterThePass = device.store.readCount
        device.store.forgetOperations()

        // The pass that was asked for runs on a later turn, finds everything
        // in place and writes nothing, so nothing is announced again.
        #expect(await eventually { device.store.readCount > readsAfterThePass })
        #expect(device.store.operations.isEmpty)
        #expect(announcements == 1)
        #expect(device.lastSync != nil)
    }

    @Test func withoutTheICloudEntitlementTheRealStoreIsReportedAsUnavailable() {
        // Test processes are not signed with the iCloud key-value
        // entitlement, which makes this the place to see what such a build
        // gets: either nobody is signed in to iCloud, or the store accepts
        // writes and keeps none. The library is left empty so that nothing
        // of substance could reach a real account in any case.
        let library = LibraryStore(fileURL: nil, backupsDirectory: nil)
        let engine = CloudSyncEngine(library: library)

        engine.isEnabled = true
        #expect(engine.status == .unavailable)

        engine.syncNow()
        engine.libraryDidChange(library.document)
        #expect(engine.status == .unavailable)
        #expect(library.computers.isEmpty)

        engine.isEnabled = false
        #expect(engine.status == .disabled)
    }

    // MARK: - What is stored

    @Test func theLibraryIsStoredOneKeyPerItem() throws {
        let device = SimulatedDevice()
        let home = device.library.addGroup(named: "Home")
        let studio = device.library.add(
            Computer(name: "Studio", host: "studio.local", username: "me", groupID: home.id))
        let server = device.library.add(computer("Server"))
        let doomed = device.library.add(computer("Doomed"))
        device.library.delete(doomed.id)

        #expect(Set(device.store.values.keys) == [
            "meta", key(home), key(studio), key(server), tombstoneKey(doomed.id),
        ])
        #expect(device.store.values.keys.allSatisfy { $0.utf8.count <= 64 })

        // Each value is the item itself, exact to the last fraction of a second.
        #expect(try device.store.computer(studio.id) == studio)
        #expect(try device.store.computer(server.id) == server)
        #expect(try device.store.group(home.id) == home)
        #expect(try device.store.tombstone(doomed.id)
            == device.library.document.tombstones[doomed.id.uuidString])

        let meta = try #require(device.store.values["meta"])
        #expect(try JSONDecoder().decode([String: Int].self, from: meta)
            == ["schemaVersion": LibraryDocument.currentSchemaVersion])
    }

    @Test func passwordsNeverReachICloud() throws {
        let credentials = CredentialStore(storage: InMemorySecretStorage())
        let device = SimulatedDevice()
        let studio = device.library.add(
            Computer(name: "Studio", host: "studio.local", username: "me"))
        try credentials.setPassword("correct horse battery staple", for: studio.id)
        try credentials.setPassword("tunnel-secret", for: studio.id, kind: .ssh)
        device.library.update(studio.id) {
            $0.ssh = SSHSettings(isEnabled: true, username: "tunnel", authentication: .password)
        }
        device.engine.syncNow()

        func fieldNames(in json: Any) -> [String] {
            if let object = json as? [String: Any] {
                return object.keys + object.values.flatMap(fieldNames(in:))
            }
            if let array = json as? [Any] {
                return array.flatMap(fieldNames(in:))
            }
            return []
        }
        #expect(device.store.values.count == 2)
        for (key, value) in device.store.values {
            let text = String(decoding: value, as: UTF8.self)
            #expect(!text.contains("correct horse"), "\(key)")
            #expect(!text.contains("tunnel-secret"), "\(key)")
            let json = try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
            let names = fieldNames(in: json).map { $0.lowercased() }
            #expect(!names.contains("password"), "\(key)")
            #expect(!names.contains("secret"), "\(key)")
        }
    }

    @Test func aLocalChangeWritesOnlyTheItemThatChanged() {
        let device = SimulatedDevice()
        let computers = ["Studio", "Server", "Pi"].map { device.library.add(computer($0)) }
        device.library.addGroup(named: "Home")
        device.store.forgetOperations()

        device.library.update(computers[1].id) { $0.notes = "moved to the basement" }

        #expect(device.store.operations == [.set(key(computers[1]))])
    }

    @Test func whenNothingChangedNothingIsWritten() {
        let device = SimulatedDevice()
        let studio = device.library.add(computer("Studio"))
        device.library.addGroup(named: "Home")
        device.library.delete(device.library.add(computer("Doomed")).id)
        device.store.forgetOperations()

        device.engine.syncNow()
        device.engine.libraryDidChange(device.library.document)
        device.storeChangedExternally()
        // Announced by the library although nothing came of it.
        device.library.delete(UUID())
        device.library.update(studio)

        #expect(device.store.operations.isEmpty)
        #expect(device.lastSync != nil)
    }

    @Test func aDeletionIsRecordedBeforeTheItemIsRemoved() throws {
        let device = SimulatedDevice()
        let studio = device.library.add(computer("Studio"))
        device.store.forgetOperations()

        device.library.delete(studio.id)

        // A device that sees only half of this must find the deletion, not
        // an item that vanished for no reason.
        #expect(device.store.operations == [.set(tombstoneKey(studio.id)), .remove(key(studio))])
        let recorded = try #require(try device.store.tombstone(studio.id))
        #expect(recorded >= studio.modifiedAt)
    }

    @Test func groupsAreWrittenBeforeTheComputersInThem() throws {
        let stamp = LibraryFixtures.recentWholeSecond()
        let group = LibraryFixtures.group("Home", modifiedAt: stamp)
        let members = ["Studio", "Server"].map {
            LibraryFixtures.computer($0, groupID: group.id, modifiedAt: stamp)
        }
        let backup = LibraryDocument(computers: members, groups: [group])
        let device = SimulatedDevice()
        device.store.forgetOperations()

        try device.library.importBackup(backup.encoded(), strategy: .merge)

        let operations = device.store.operations
        let groupWritten = try #require(operations.firstIndex(of: .set(key(group))))
        for member in members {
            #expect(try #require(operations.firstIndex(of: .set(key(member)))) > groupWritten)
        }
    }

    @Test func keysThatBelongToSomeoneElseAreLeftAlone() {
        let foreign: [String: Data] = [
            "settings.theme": Data("dark".utf8),
            "metadata": Data("{}".utf8),
            "c.not-a-uuid": Data("{}".utf8),
            "c.\(UUID().uuidString.lowercased())": Data("{}".utf8),
            "x.\(UUID().uuidString)": Data("{}".utf8),
            "c.\(UUID().uuidString).draft": Data("{}".utf8),
        ]
        let device = SimulatedDevice(store: InMemoryCloudStore(values: foreign))

        let studio = device.library.add(computer("Studio"))
        device.library.delete(studio.id)
        device.library.add(computer("Server"))
        device.engine.syncNow()

        for (key, value) in foreign {
            #expect(device.store.values[key] == value, "\(key)")
        }
        #expect(device.library.computers.map(\.name) == ["Server"])
        #expect(device.lastSync != nil)
    }

    @Test func damagedValuesAreRepairedWhereTheLibraryKnowsBetter() throws {
        let device = SimulatedDevice()
        let studio = device.library.add(computer("Studio"))
        let gone = device.library.add(computer("Gone"))
        device.library.delete(gone.id)
        let unknown = UUID()
        let damage = Data("{ this is not an item".utf8)

        device.store.deliver(damage, forKey: key(studio))
        device.store.deliver(damage, forKey: key(gone))
        device.store.deliver(damage, forKey: "c.\(unknown.uuidString)")
        device.store.deliver(damage, forKey: tombstoneKey(UUID()))
        device.store.deliver(damage, forKey: "meta")
        device.storeChangedExternally()

        // An item this device has: written again.
        #expect(try device.store.computer(studio.id) == studio)
        // An item this device deleted: removed.
        #expect(device.store.values[key(gone)] == nil)
        // Something it has never heard of: left for whoever can read it.
        #expect(device.store.values["c.\(unknown.uuidString)"] == damage)
        // A deletion nobody can read protects nothing.
        #expect(device.store.keys(withPrefix: "t.") == [tombstoneKey(gone.id)])
        let meta = try #require(device.store.values["meta"])
        #expect(try JSONDecoder().decode([String: Int].self, from: meta)
            == ["schemaVersion": LibraryDocument.currentSchemaVersion])

        #expect(device.library.computers == [studio])
        #expect(device.lastSync != nil)
    }

    @Test func anItemFiledUnderAnotherItemsKeyIsNotMerged() throws {
        let other = SimulatedDevice()
        let real = other.library.add(computer("Real"))
        let record = try #require(other.store.values[key(real)])
        let wrongKey = "c.\(UUID().uuidString)"

        let device = SimulatedDevice(store: InMemoryCloudStore(values: [wrongKey: record]))

        #expect(device.library.computers.isEmpty)
        #expect(device.store.values[wrongKey] == record)
    }

    @Test func anItemWithFieldsFromANewerVersionIsNotRewritten() throws {
        let other = SimulatedDevice()
        let studio = other.library.add(computer("Studio"))
        // The same record as a later version of the app might write it: a
        // field this version does not know, and numbers formatted its way.
        let original = try #require(other.store.values[key(studio)])
        var fields = try #require(
            try JSONSerialization.jsonObject(with: original) as? [String: Any])
        fields["somethingNew"] = ["nested": true]
        let extended = try JSONSerialization.data(withJSONObject: fields)
        var contents = other.store.values
        contents[key(studio)] = extended

        let store = InMemoryCloudStore(values: contents)
        let device = SimulatedDevice(store: store)
        device.engine.syncNow()
        device.storeChangedExternally()

        #expect(device.library.computers == [studio])
        // Rewriting it would erase what the newer version stored.
        #expect(store.values[key(studio)] == extended)
        #expect(store.operations.isEmpty)

        // A real edit is still uploaded.
        tick()
        device.library.update(studio.id) { $0.notes = "edited here" }
        #expect(try store.computer(studio.id)?.notes == "edited here")
    }

    // MARK: - Two devices, one store

    @Test func turningSyncOnMergesTheLibraryWithICloudBothWays() {
        let store = InMemoryCloudStore()
        let mac = SimulatedDevice(store: store, syncEnabled: false)
        let phone = SimulatedDevice(store: store, syncEnabled: false)
        let onMac = mac.library.add(computer("On the Mac"))
        let onPhone = phone.library.add(computer("On the phone"))

        mac.engine.isEnabled = true
        #expect(store.keys(withPrefix: "c.") == [key(onMac)])

        // The phone takes what is in iCloud and adds what it has.
        phone.engine.isEnabled = true
        #expect(Set(phone.library.computers) == [onMac, onPhone])
        #expect(Set(store.keys(withPrefix: "c.")) == [key(onMac), key(onPhone)])

        mac.storeChangedExternally()
        #expect(Set(mac.library.computers) == [onMac, onPhone])
    }

    @Test func twoDevicesConvergeAfterEdits() throws {
        let (mac, phone) = twoDevicesSharingOneStore()
        let studio = mac.library.add(computer("Studio"))
        let home = mac.library.addGroup(named: "Home")

        phone.storeChangedExternally()
        // An exact copy, down to the timestamps.
        #expect(phone.library.computers == [studio])
        #expect(phone.library.groups == [home])

        tick()
        phone.library.update(studio.id) {
            $0.name = "Studio Display"
            $0.groupID = home.id
            $0.isFavorite = true
        }
        phone.library.update(ComputerGroup(
            id: home.id, name: "Home Office", sortIndex: home.sortIndex, modifiedAt: home.modifiedAt))
        mac.storeChangedExternally()

        let edited = try #require(mac.library.computer(studio.id))
        #expect(edited.name == "Studio Display")
        #expect(edited.groupID == home.id)
        #expect(edited.isFavorite)
        #expect(mac.library.group(home.id)?.name == "Home Office")
        #expect(mac.library.document.sortedByID == phone.library.document.sortedByID)
    }

    @Test func aDeletionOnOneDeviceRemovesTheItemOnTheOther() throws {
        let (mac, phone) = twoDevicesSharingOneStore()
        let home = mac.library.addGroup(named: "Home")
        let studio = mac.library.add(
            Computer(name: "Studio", host: "studio.local", groupID: home.id))
        let server = mac.library.add(
            Computer(name: "Server", host: "server.local", groupID: home.id))
        phone.storeChangedExternally()
        #expect(phone.library.computers.count == 2)

        tick()
        phone.library.delete(studio.id)
        phone.library.deleteGroup(home.id)
        mac.storeChangedExternally()

        #expect(mac.library.computers.map(\.id) == [server.id])
        #expect(mac.library.computer(server.id)?.groupID == nil)
        #expect(mac.library.groups.isEmpty)
        #expect(mac.library.document.sortedByID == phone.library.document.sortedByID)
        #expect(mac.store.values[key(studio)] == nil)
        #expect(mac.store.values[key(home)] == nil)
        #expect(Set(mac.store.keys(withPrefix: "t.")) == [tombstoneKey(studio.id), tombstoneKey(home.id)])
    }

    @Test func editsToDifferentComputersOnTwoDevicesBothSurvive() {
        let (mac, phone) = twoDevicesSharingOneStore()
        let studio = mac.library.add(computer("Studio"))
        let server = mac.library.add(computer("Server"))
        phone.storeChangedExternally()

        // Neither device has heard of the other's edit when it makes its own.
        tick()
        mac.library.update(studio.id) { $0.name = "Studio, edited on the Mac" }
        phone.library.update(server.id) { $0.name = "Server, edited on the phone" }
        #expect(mac.library.computer(server.id)?.name == "Server")
        #expect(phone.library.computer(studio.id)?.name == "Studio")

        mac.storeChangedExternally()
        phone.storeChangedExternally()

        for device in [mac, phone] {
            #expect(device.library.computer(studio.id)?.name == "Studio, edited on the Mac")
            #expect(device.library.computer(server.id)?.name == "Server, edited on the phone")
        }
        #expect(mac.library.document.sortedByID == phone.library.document.sortedByID)
    }

    @Test func dataThatArrivesFromICloudIsNotSentBack() throws {
        let (mac, phone) = twoDevicesSharingOneStore()
        let store = mac.store
        let doomed = mac.library.add(computer("Doomed"))
        phone.storeChangedExternally()
        tick()
        let studio = mac.library.add(computer("Studio"))
        let home = mac.library.addGroup(named: "Home")
        mac.library.delete(doomed.id)
        store.forgetOperations()
        let announcedBefore = phone.localChangeCount

        phone.storeChangedExternally()

        // The phone took the changes…
        #expect(phone.library.computers == [studio])
        #expect(phone.library.groups == [home])
        // …as they were made, not as fresh edits of its own…
        #expect(phone.library.computer(studio.id)?.modifiedAt == studio.modifiedAt)
        #expect(phone.localChangeCount == announcedBefore)
        // …and wrote nothing back.
        #expect(store.operations.isEmpty)

        // Going round again changes nothing either.
        phone.engine.syncNow()
        mac.storeChangedExternally()
        mac.engine.syncNow()
        phone.storeChangedExternally()
        #expect(store.operations.isEmpty)
        #expect(mac.library.document.sortedByID == phone.library.document.sortedByID)
    }

    @Test func erasingTheLibraryWhileSyncingErasesItOnEveryDevice() {
        // Erasing records a deletion for every item, and deletions sync.
        // An app that means to clear one device only has to turn sync off
        // first — and keep it off, or the deletions follow later.
        let (mac, phone) = twoDevicesSharingOneStore()
        mac.library.add(computer("Studio"))
        mac.library.addGroup(named: "Home")
        phone.storeChangedExternally()
        #expect(phone.library.computers.count == 1)

        tick()
        phone.library.eraseAll()
        mac.storeChangedExternally()

        #expect(mac.library.computers.isEmpty)
        #expect(mac.library.groups.isEmpty)
        #expect(mac.store.keys(withPrefix: "c.").isEmpty)
        #expect(mac.store.keys(withPrefix: "g.").isEmpty)
        #expect(mac.store.keys(withPrefix: "t.").count == 2)
    }

    @Test func relaunchingTheAppWritesNothingToICloud() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.file("Library.json")
        let store = InMemoryCloudStore()

        // First launch: build a library and let it sync.
        let library = LibraryStore(fileURL: file, backupsDirectory: nil)
        let engine = CloudSyncEngine(
            library: library, store: store, notificationCenter: NotificationCenter())
        library.onChange = { [weak engine] in engine?.libraryDidChange($0) }
        engine.isEnabled = true
        let home = library.addGroup(named: "Home")
        let studio = library.add(
            Computer(name: "Studio", host: "studio.local", groupID: home.id))
        library.delete(library.add(computer("Doomed")).id)
        library.saveNow()
        let stored = store.values
        store.forgetOperations()

        // Second launch. The library file keeps dates to the second while
        // iCloud has them exactly, so every local copy now looks a little
        // older than the identical one in iCloud. That must not be mistaken
        // for news in either direction.
        let relaunched = LibraryStore(fileURL: file, backupsDirectory: nil)
        let second = CloudSyncEngine(
            library: relaunched, store: store, notificationCenter: NotificationCenter())
        second.isEnabled = true

        #expect(store.operations.isEmpty)
        #expect(store.values == stored)
        #expect(relaunched.computers == [studio])
        #expect(relaunched.groups == [home])
        #expect(relaunched.document.tombstones == library.document.tombstones)
        if case .idle = second.status {} else {
            Issue.record("expected the relaunched engine to be in sync, got \(second.status)")
        }
    }

    // MARK: - Devices with their own replicas

    @Test func concurrentEditsToDifferentComputersSurviveOnEveryDevice() {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        let server = mac.library.add(computer("Server"))
        cloud.settle()
        #expect(phone.library.computers.count == 2)

        // Both edit while offline: each replica holds only its own change.
        tick()
        mac.library.update(studio.id) { $0.name = "Studio, edited on the Mac" }
        phone.library.update(server.id) { $0.name = "Server, edited on the phone" }
        cloud.settle()

        for device in cloud.devices {
            #expect(device.library.computer(studio.id)?.name == "Studio, edited on the Mac")
            #expect(device.library.computer(server.id)?.name == "Server, edited on the phone")
        }
        #expect(cloud.hasConverged)
    }

    @Test(arguments: [false, true])
    func theLaterOfTwoEditsToOneComputerWinsWhoeverUploadsLast(laterEditUploadsFirst: Bool) {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        cloud.settle()

        tick()
        mac.library.update(studio.id) { $0.name = "Earlier, on the Mac" }
        tick()
        phone.library.update(studio.id) { $0.name = "Later, on the phone" }
        // iCloud keeps whichever upload of the key arrives last. The engine
        // must not: the later edit wins.
        cloud.exchange(uploadOrder: laterEditUploadsFirst ? [phone, mac] : [mac, phone])
        cloud.settle()

        for device in cloud.devices {
            #expect(device.library.computer(studio.id)?.name == "Later, on the phone")
        }
        #expect(cloud.hasConverged)
    }

    @Test(arguments: [false, true])
    func aDeletionBeatsAnEditMadeBeforeIt(deletionUploadsFirst: Bool) throws {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        cloud.settle()

        tick()
        mac.library.update(studio.id) { $0.name = "Edited just before it was deleted" }
        tick()
        phone.library.delete(studio.id)
        cloud.exchange(uploadOrder: deletionUploadsFirst ? [phone, mac] : [mac, phone])
        cloud.settle()

        for device in cloud.devices {
            #expect(device.library.computer(studio.id) == nil)
        }
        #expect(cloud.server[key(studio)] == nil)
        #expect(cloud.server[tombstoneKey(studio.id)] != nil)
        #expect(cloud.hasConverged)
    }

    @Test(arguments: [false, true])
    func anEditMadeAfterADeletionBringsTheComputerBack(deletionUploadsFirst: Bool) throws {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        cloud.settle()

        tick()
        phone.library.delete(studio.id)
        tick()
        mac.library.update(studio.id) { $0.name = "Still in use" }
        cloud.exchange(uploadOrder: deletionUploadsFirst ? [phone, mac] : [mac, phone])
        cloud.settle()

        for device in cloud.devices {
            #expect(device.library.computer(studio.id)?.name == "Still in use")
            #expect(device.library.document.tombstones.isEmpty)
        }
        #expect(cloud.server[key(studio)] != nil)
        // The deletion lost; nothing is left of it.
        #expect(cloud.server[tombstoneKey(studio.id)] == nil)
        #expect(cloud.hasConverged)
    }

    @Test func deletingAGroupUngroupsItsComputersOnEveryDevice() {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let home = mac.library.addGroup(named: "Home")
        let studio = mac.library.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        cloud.settle()
        #expect(phone.library.computer(studio.id)?.groupID == home.id)

        tick()
        phone.library.deleteGroup(home.id)
        cloud.settle()

        for device in cloud.devices {
            #expect(device.library.groups.isEmpty)
            #expect(device.library.computer(studio.id)?.groupID == nil)
        }
        #expect(cloud.hasConverged)
    }

    @Test func aDeviceThatJoinsLaterCatchesUpAndContributes() {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let home = mac.library.addGroup(named: "Home")
        mac.library.add(Computer(name: "Studio", host: "studio.local", groupID: home.id))
        let doomed = phone.library.add(computer("Doomed"))
        cloud.settle()
        tick()
        mac.library.delete(doomed.id)
        cloud.settle()

        // A tablet that already has a library of its own signs in.
        let tablet = cloud.addDevice(syncEnabled: false)
        let onTablet = tablet.library.add(computer("Tablet only"))
        tablet.engine.isEnabled = true
        cloud.settle()

        for device in cloud.devices {
            #expect(Set(device.library.computers.map(\.name)) == ["Studio", "Tablet only"])
            #expect(device.library.groups.map(\.name) == ["Home"])
            #expect(device.library.computer(onTablet.id) == onTablet)
        }
        #expect(cloud.hasConverged)
    }

    @Test func aChangeTravelsOnceAndThenTheDevicesFallSilent() {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice()
        cloud.addDevice()
        cloud.addDevice()
        cloud.settle()

        mac.library.add(computer("Studio"))
        mac.library.addGroup(named: "Home")

        // Up from the Mac and down to the other two…
        #expect(cloud.exchange() == 6)
        // …and nothing comes back.
        #expect(cloud.exchange() == 0)
        for device in cloud.devices {
            device.engine.syncNow()
        }
        #expect(cloud.exchange() == 0)
        #expect(cloud.hasConverged)
    }

    @Test func copiesThatNothingCanOrderDoNotMakeDevicesFightOverICloud() throws {
        // Two devices hold different copies of a computer with the very same
        // modification date. The library has no way to pick one (see the
        // known-bug suite), so each device keeps its own. What must not
        // happen is that each keeps uploading its copy over the other's.
        let id = UUID()
        let stamp = LibraryFixtures.recentWholeSecond()
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(syncEnabled: false)
        let phone = cloud.addDevice(syncEnabled: false)
        mac.library.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Renamed on the Mac", id: id, modifiedAt: stamp),
        ]))
        phone.library.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Renamed on the phone", id: id, modifiedAt: stamp),
        ]))

        mac.engine.isEnabled = true
        phone.engine.isEnabled = true
        #expect(cloud.settle() <= 2)

        // iCloud holds one of the two, and it stays that one.
        let settled = try #require(cloud.server["c.\(id.uuidString)"])
        for _ in 0..<3 {
            mac.engine.syncNow()
            phone.engine.syncNow()
            #expect(cloud.exchange() == 0)
        }
        #expect(cloud.server["c.\(id.uuidString)"] == settled)
        #expect(mac.lastSync != nil)
        #expect(phone.lastSync != nil)
    }

    @Test func devicesConvergeAfterAnyMixOfChangesAndPartialSyncs() throws {
        for seed in UInt64(0)..<40 {
            var random = ReplayableRandom(seed: seed)
            let cloud = SimulatedCloud()
            let devices = (0..<3).map { _ in cloud.addDevice() }
            var counter = 0

            for _ in 0..<60 {
                let device = try #require(devices.randomElement(using: &random))
                let library = device.library
                // Names are unique and the same on every run; picking by
                // name makes a seed replay the same history whatever
                // identifiers were minted along the way.
                let computers = library.computers.sorted { $0.name < $1.name }
                let groups = library.groups.sorted { $0.name < $1.name }
                counter += 1
                switch Int.random(in: 0..<10, using: &random) {
                case 0...2:
                    library.add(computer("Computer \(counter)"))
                case 3, 4:
                    if let target = computers.randomElement(using: &random) {
                        library.update(target.id) { $0.name = "Renamed \(counter)" }
                    }
                case 5:
                    if let target = computers.randomElement(using: &random) {
                        library.toggleFavorite(target.id)
                    }
                case 6:
                    if let target = computers.randomElement(using: &random) {
                        library.delete(target.id)
                    }
                case 7:
                    library.addGroup(named: "Group \(counter)")
                case 8:
                    if var group = groups.randomElement(using: &random) {
                        group.name = "Regrouped \(counter)"
                        library.update(group)
                    }
                default:
                    // Groups are never deleted here: a computer whose group
                    // disappears and returns can end up grouped on one device
                    // and not on another, which is the library's doing and is
                    // pinned down in the known-bug suite.
                    if let target = computers.randomElement(using: &random) {
                        let group = random.chance(0.8)
                            ? groups.randomElement(using: &random)?.id : nil
                        library.update(target.id) { $0.groupID = group }
                    }
                }
                tick()
                if random.chance(0.3) {
                    cloud.exchange(uploadOrder: devices.shuffled(using: &random))
                }
            }
            cloud.settle()

            // Every device holds the same library, and iCloud holds exactly
            // that library: nothing missing, nothing left over.
            let library = devices[0].library
            let store = devices[0].store
            let sameKeys =
                Set(store.keys(withPrefix: "c.")) == Set(library.computers.map { key($0) })
                && Set(store.keys(withPrefix: "g.")) == Set(library.groups.map { key($0) })
                && Set(store.keys(withPrefix: "t."))
                    == Set(library.document.tombstones.keys.map { "t.\($0)" })
            let sameComputers = try library.computers.allSatisfy { try store.computer($0.id) == $0 }
            let sameGroups = try library.groups.allSatisfy { try store.group($0.id) == $0 }
            guard cloud.hasConverged, sameKeys, sameComputers, sameGroups else {
                Issue.record("the devices did not converge for seed \(seed)")
                return
            }
        }
    }

    // MARK: - Announcements from the store

    @Test func anAnnouncementWithoutDetailsStillPullsTheNewData() {
        let (mac, phone) = twoDevicesSharingOneStore()
        let studio = mac.library.add(computer("Studio"))

        phone.center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)

        #expect(phone.library.computers == [studio])
    }

    @Test func announcementsFromAnotherThreadAreHandledOnTheMainActor() async {
        let (mac, phone) = twoDevicesSharingOneStore()
        let studio = mac.library.add(computer("Studio"))

        // The real store posts from a thread of its own.
        let center = phone.center
        await Task.detached {
            center.postCloudStoreChange(reason: NSUbiquitousKeyValueStoreServerChange)
        }.value

        #expect(await eventually { phone.library.computers == [studio] })
        #expect(phone.lastSync != nil)
    }

    @Test(arguments: [NSUbiquitousKeyValueStoreInitialSyncChange, NSUbiquitousKeyValueStoreAccountChange])
    func whenTheStoreIsReplacedTheLibraryIsMergedWithWhatIsThereNow(reason: Int) throws {
        // Either the first download from iCloud finished and replaced what
        // had been written before it, or the user switched iCloud accounts.
        let device = SimulatedDevice()
        let mine = device.library.add(computer("Mine"))
        let other = SimulatedDevice()
        let theirs = other.library.add(computer("Theirs"))
        let theirGroup = other.library.addGroup(named: "Theirs")

        device.store.replaceContents(with: other.store.values)
        device.storeChangedExternally(reason: reason)

        #expect(Set(device.library.computers) == [mine, theirs])
        #expect(device.library.groups == [theirGroup])
        // What the store no longer had is put back.
        #expect(try device.store.computer(mine.id) == mine)
        #expect(try device.store.computer(theirs.id) == theirs)
        #expect(device.lastSync != nil)
    }

    @Test func aQuotaViolationIsReportedAndNothingIsLost() throws {
        let (mac, phone) = twoDevicesSharingOneStore()
        let store = mac.store
        mac.library.add(computer("Studio"))
        phone.storeChangedExternally()
        let arrivedWithIt = mac.library.add(computer("Server"))
        store.forgetOperations()

        phone.storeChangedExternally(reason: NSUbiquitousKeyValueStoreQuotaViolationChange)

        let message = try #require(phone.failure)
        #expect(message.contains("iCloud"))
        // Nothing is thrown away to make room, and nothing more is pushed
        // at a store that is full…
        #expect(store.operations.isEmpty)
        // …but whatever did arrive is still taken in.
        #expect(phone.library.computer(arrivedWithIt.id) == arrivedWithIt)
        #expect(phone.library.computers.count == 2)

        // The next local change tries again; deleting is how room is made.
        tick()
        phone.library.delete(arrivedWithIt.id)
        #expect(phone.lastSync != nil)
        #expect(store.values[key(arrivedWithIt)] == nil)
    }

    // MARK: - Limits

    @Test func aLibraryWithMoreItemsThanICloudHoldsIsNotUploaded() throws {
        let limits = CloudSyncEngine.Limits(
            maximumKeyCount: 4, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000)
        let device = SimulatedDevice(limits: limits)
        let fitting = ["One", "Two", "Three"].map { device.library.add(computer($0)) }
        #expect(device.lastSync != nil)
        #expect(device.store.values.count == 4)
        let stored = device.store.values
        device.store.forgetOperations()

        device.library.add(computer("Four"))

        let message = try #require(device.failure)
        #expect(message.contains("need 5 entries"))
        #expect(message.contains("allows 4"))
        // Not one key was written: an upload is all or nothing.
        #expect(device.store.operations.isEmpty)
        #expect(device.store.values == stored)
        // And nothing was taken out of the library to make it fit.
        #expect(device.library.computers.map(\.name) == ["One", "Two", "Three", "Four"])

        // Changes that would fit on their own wait as well, so iCloud never
        // holds a library with a piece missing.
        device.library.update(fitting[0].id) { $0.notes = "edited while over the limit" }
        #expect(device.failure != nil)
        #expect(device.store.values == stored)
        #expect(device.library.computer(fitting[0].id)?.notes == "edited while over the limit")
    }

    @Test func changesFromOtherDevicesStillArriveWhileUploadsAreOnHold() {
        let store = InMemoryCloudStore()
        let mac = SimulatedDevice(store: store)
        let phone = SimulatedDevice(
            store: store,
            limits: CloudSyncEngine.Limits(
                maximumKeyCount: 3, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000))
        mac.library.add(computer("One"))
        mac.library.add(computer("Two"))
        phone.storeChangedExternally()
        #expect(phone.lastSync != nil)

        let phoneOnly = phone.library.add(computer("Does not fit"))
        #expect(phone.failure != nil)

        let later = mac.library.add(computer("Three"))
        phone.storeChangedExternally()

        #expect(phone.library.computer(later.id) == later)
        #expect(phone.library.computer(phoneOnly.id) == phoneOnly)
        #expect(phone.failure != nil)
        #expect(store.values[key(phoneOnly)] == nil)
    }

    @Test func uploadingResumesOnceTheLibraryFitsAgain() throws {
        // Measure what one computer costs, then allow room for two and a half.
        let probe = SimulatedDevice()
        let sample = probe.library.add(computer("Alpha"))
        let sampleRecord = try #require(probe.store.values[key(sample)])
        let metaRecord = try #require(probe.store.values["meta"])
        let record = key(sample).utf8.count + sampleRecord.count
        let meta = "meta".utf8.count + metaRecord.count
        let limits = CloudSyncEngine.Limits(
            maximumKeyCount: 1024,
            maximumTotalBytes: meta + record * 5 / 2,
            maximumValueBytes: 1_000_000)

        let device = SimulatedDevice(limits: limits)
        let alpha = device.library.add(computer("Alpha"))
        let bravo = device.library.add(computer("Bravo"))
        #expect(device.lastSync != nil)

        let delta = device.library.add(computer("Delta"))
        let message = try #require(device.failure)
        #expect(message.contains("KB"))
        #expect(device.store.values[key(delta)] == nil)
        #expect(device.library.computers.count == 3)

        // Remembering a deletion costs far less than the computer did.
        tick()
        device.library.delete(alpha.id)

        #expect(device.lastSync != nil)
        #expect(Set(device.store.keys(withPrefix: "c.")) == [key(bravo), key(delta)])
        #expect(device.store.values[tombstoneKey(alpha.id)] != nil)
    }

    @Test func anItemTooLargeForICloudIsNamedInTheFailure() throws {
        let limits = CloudSyncEngine.Limits(
            maximumKeyCount: 1024, maximumTotalBytes: 1_000_000, maximumValueBytes: 3_000)
        let device = SimulatedDevice(limits: limits)
        let studio = device.library.add(computer("Studio"))
        #expect(device.lastSync != nil)

        tick()
        device.library.update(studio.id) { $0.notes = String(repeating: "long ", count: 1_000) }

        let message = try #require(device.failure)
        #expect(message.contains("“Studio”"))
        // iCloud still holds the last version that fitted, whole.
        #expect(try device.store.computer(studio.id) == studio)
        #expect(device.library.computer(studio.id)?.notes.count == 5_000)

        tick()
        device.library.update(studio.id) { $0.notes = "short again" }
        #expect(device.lastSync != nil)
        #expect(try device.store.computer(studio.id)?.notes == "short again")
    }

    @Test func theDocumentedICloudLimitsAreTheDefault() {
        #expect(CloudSyncEngine.Limits.iCloud.maximumKeyCount == 1024)
        #expect(CloudSyncEngine.Limits.iCloud.maximumTotalBytes <= 1_048_576)
        #expect(CloudSyncEngine.Limits.iCloud.maximumValueBytes <= 1_048_576)
        #expect(SimulatedDevice().engine.limits == .iCloud)
    }

    // MARK: - Forgetting deletions

    @Test func deletionsOlderThanTheirLifetimeAreForgottenInICloud() throws {
        let encoder = CloudCoding.makeEncoder()
        let lifetime = LibraryDocument.tombstoneLifetime
        let expired = UUID(), recent = UUID()
        let store = InMemoryCloudStore(values: [
            tombstoneKey(expired): try encoder.encode(Date.now.addingTimeInterval(-lifetime - 86_400)),
            tombstoneKey(recent): try encoder.encode(Date.now.addingTimeInterval(-lifetime + 86_400)),
        ])

        let device = SimulatedDevice(store: store)

        #expect(store.keys(withPrefix: "t.") == [tombstoneKey(recent)])
        #expect(store.operations.contains(.remove(tombstoneKey(expired))))
        #expect(Array(device.library.document.tombstones.keys) == [recent.uuidString])
    }

    @Test func aDeletionAlreadyPastItsLifetimeIsNeverUploaded() throws {
        let longAgo = Date(timeIntervalSince1970:
            (Date.now.timeIntervalSince1970 - LibraryDocument.tombstoneLifetime - 86_400).rounded(.down))
        let backup = LibraryDocument(tombstones: [UUID().uuidString: longAgo])
        let device = SimulatedDevice(syncEnabled: false)
        try device.library.importBackup(backup.encoded(), strategy: .replace)
        #expect(device.library.document.tombstones.count == 1)

        device.engine.isEnabled = true

        #expect(device.store.keys(withPrefix: "t.").isEmpty)
        #expect(device.lastSync != nil)
    }

    // MARK: - Layout versions

    @Test func theLayoutVersionIsRecordedAndBroughtUpToDate() throws {
        func version(in store: InMemoryCloudStore) throws -> Int? {
            let meta = try #require(store.values["meta"])
            return try JSONDecoder().decode([String: Int].self, from: meta)["schemaVersion"]
        }

        let fresh = SimulatedDevice()
        #expect(try version(in: fresh.store) == LibraryDocument.currentSchemaVersion)

        let older = InMemoryCloudStore(values: ["meta": Data(#"{"schemaVersion":0}"#.utf8)])
        _ = SimulatedDevice(store: older)
        #expect(try version(in: older) == LibraryDocument.currentSchemaVersion)
    }

    @Test func aLibraryFromANewerVersionIsReadButNeverWrittenOver() throws {
        let newer = SimulatedDevice()
        let theirs = newer.library.add(computer("Theirs"))
        var contents = newer.store.values
        contents["meta"] = Data(#"{"schemaVersion":99}"#.utf8)
        let store = InMemoryCloudStore(values: contents)
        let device = SimulatedDevice(store: store, syncEnabled: false)
        let mine = device.library.add(computer("Mine"))

        device.engine.isEnabled = true

        // It takes what it understands…
        #expect(device.library.computer(theirs.id) == theirs)
        // …and says why it will not write.
        #expect(try #require(device.failure).contains("newer version"))
        #expect(store.operations.isEmpty)
        #expect(store.values == contents)

        device.library.update(mine.id) { $0.notes = "stays on this device" }
        device.engine.syncNow()
        #expect(store.operations.isEmpty)
        #expect(device.failure != nil)
        #expect(device.library.computers.count == 2)
    }

    // MARK: - Restoring a backup

    /// A restored backup is stamped as changed now. With the dates it had
    /// when it was made, whatever was edited since would still be newer in
    /// iCloud, and the next sync would quietly undo the restore.
    @Test func restoringABackupSurvivesTheNextSync() throws {
        let store = InMemoryCloudStore()
        let mac = SimulatedDevice(store: store)
        let phone = SimulatedDevice(store: store)
        let studio = mac.library.add(Computer(name: "As backed up", host: "studio.local"))
        let backup = try mac.library.exportBackup()
        LibraryFixtures.letClockAdvance()
        mac.library.update(studio.id) { $0.name = "Edited after the backup" }
        phone.storeChangedExternally()

        try mac.library.importBackup(backup, strategy: .replace)
        #expect(mac.library.computers.map(\.name) == ["As backed up"])

        mac.engine.syncNow()
        phone.storeChangedExternally()

        #expect(mac.library.computers.map(\.name) == ["As backed up"])
        #expect(phone.library.computers.map(\.name) == ["As backed up"])
    }

    /// Connecting is not an edit. From a device that has not caught up it
    /// must not outrank, and undo, a change made on another.
    @Test func connectingFromADeviceThatIsBehindDoesNotUndoAnEditMadeElsewhere() {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        cloud.settle()

        tick()
        mac.library.update(studio.id) { $0.name = "Renamed on the Mac" }
        tick()
        // The phone has not heard of the rename when it connects.
        phone.library.markConnected(studio.id)
        cloud.exchange(uploadOrder: [phone, mac])
        cloud.settle()

        for device in cloud.devices {
            #expect(device.library.computer(studio.id)?.name == "Renamed on the Mac")
        }
        // The phone still knows it was connected.
        #expect(phone.library.computer(studio.id)?.lastConnectedAt != nil)
    }
}

/// Stands in for whatever else the app does when the library changes.
@MainActor
private final class SimulatedApp {
    var changesSeen = 0
}

/// Something an observation callback, which may run anywhere, can set.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.withLock { raised = true }
    }

    var isRaised: Bool {
        lock.withLock { raised }
    }
}

@Suite("Cloud library layout")
struct CloudLibraryLayoutTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makePlan(
        _ desired: LibraryDocument,
        against cloud: CloudSnapshot = CloudSnapshot()
    ) throws -> CloudSyncPlan {
        try CloudSyncPlan(desired: desired, cloud: cloud, schemaVersion: 1, now: now)
    }

    /// A snapshot of a store holding exactly the given library.
    private func snapshot(of document: LibraryDocument) throws -> CloudSnapshot {
        let store = InMemoryCloudStore()
        for write in try makePlan(document).writes {
            store.set(write.data, forKey: write.key.rawValue)
        }
        var reader = CloudReader()
        return reader.read(store)
    }

    // MARK: Keys

    @Test func keysAreWrittenAndRecognised() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-AAAAAAAAAAAA"))
        let keys: [(CloudKey, String)] = [
            (.metadata, "meta"),
            (.computer(id), "c.11111111-2222-3333-4444-AAAAAAAAAAAA"),
            (.group(id), "g.11111111-2222-3333-4444-AAAAAAAAAAAA"),
            (.tombstone(id), "t.11111111-2222-3333-4444-AAAAAAAAAAAA"),
        ]
        for (key, text) in keys {
            #expect(key.rawValue == text)
            #expect(CloudKey(text) == key)
            #expect(text.utf8.count <= 64)
        }
    }

    @Test(arguments: [
        "", "meta ", "Meta", "c", "c.", "c.1234",
        "c.11111111-2222-3333-4444-aaaaaaaaaaaa",
        "C.11111111-2222-3333-4444-AAAAAAAAAAAA",
        "x.11111111-2222-3333-4444-AAAAAAAAAAAA",
        "c:11111111-2222-3333-4444-AAAAAAAAAAAA",
        "c.11111111-2222-3333-4444-AAAAAAAAAAAA.bak",
        " c.11111111-2222-3333-4444-AAAAAAAAAAAA",
    ])
    func anythingElseIsNotOneOfOurKeys(text: String) {
        #expect(CloudKey(text) == nil)
    }

    // MARK: Values

    @Test func itemsSurviveTheTripExactlyIncludingFractionsOfASecond() throws {
        let encoder = CloudCoding.makeEncoder()
        let decoder = CloudCoding.makeDecoder()
        var random = ReplayableRandom(seed: 7)

        for _ in 0..<300 {
            // Timestamps as the wall clock produces them, not round numbers.
            let stamp = Date(timeIntervalSinceReferenceDate: .random(in: 0...2_000_000_000, using: &random))
            var computer = LibraryFixtures.computer("Studio", groupID: UUID(), modifiedAt: stamp)
            computer.createdAt = stamp.addingTimeInterval(-Double.random(in: 0...1_000_000, using: &random))
            computer.lastConnectedAt = stamp.addingTimeInterval(.random(in: 0...1, using: &random))
            computer.notes = "Tabs\tand “quotes” and 日本語"
            computer.origin = .tailscale(nodeID: "n123")
            let group = LibraryFixtures.group("Home", modifiedAt: stamp)

            #expect(try decoder.decode(Computer.self, from: encoder.encode(computer)) == computer)
            #expect(try decoder.decode(ComputerGroup.self, from: encoder.encode(group)) == group)
            #expect(try decoder.decode(Date.self, from: encoder.encode(stamp)) == stamp)
        }
    }

    @Test func theSameItemAlwaysEncodesToTheSameBytes() throws {
        let computer = LibraryFixtures.computer("Studio", modifiedAt: .now)
        #expect(try CloudCoding.makeEncoder().encode(computer) == CloudCoding.makeEncoder().encode(computer))
    }

    @Test func aSettingThatIsNotANumberDoesNotStopTheUpload() throws {
        var computer = LibraryFixtures.computer("Studio", modifiedAt: now)
        computer.settings.scrollSpeed = .infinity
        computer.settings.pointerSpeed = -.infinity

        let writes = try makePlan(LibraryDocument(computers: [computer])).writes
        let data = try #require(writes.last).data
        let decoded = try CloudCoding.makeDecoder().decode(Computer.self, from: data)

        // The record goes up, and whoever reads it gets a setting they can
        // use and save: the default, in place of what was not a number.
        var expected = computer
        expected.settings.scrollSpeed = ConnectionSettings().scrollSpeed
        expected.settings.pointerSpeed = ConnectionSettings().pointerSpeed
        #expect(decoded == expected)
        #expect(throws: Never.self) { try LibraryDocument(computers: [decoded]).encoded() }
    }

    // MARK: Planning

    @Test func anEmptyStoreReceivesEverythingInDependencyOrder() throws {
        let group = LibraryFixtures.group("Home", modifiedAt: now.addingTimeInterval(-300))
        let computer = LibraryFixtures.computer(
            "Studio", groupID: group.id, modifiedAt: now.addingTimeInterval(-200))
        let deleted = UUID()
        let document = LibraryDocument(
            computers: [computer],
            groups: [group],
            tombstones: [deleted.uuidString: now.addingTimeInterval(-100)])

        let plan = try makePlan(document)

        #expect(plan.writes.map(\.key) == [
            .metadata, .group(group.id), .computer(computer.id), .tombstone(deleted),
        ])
        #expect(plan.removals.isEmpty)
        #expect(plan.projectedKeyCount == 4)
        #expect(plan.projectedByteCount
            == plan.writes.reduce(0) { $0 + $1.key.rawValue.utf8.count + $1.data.count })
    }

    @Test func aStoreThatAlreadyMatchesNeedsNothing() throws {
        let document = LibraryDocument(
            computers: [LibraryFixtures.computer("Studio", modifiedAt: now.addingTimeInterval(-200))],
            groups: [LibraryFixtures.group("Home", modifiedAt: now.addingTimeInterval(-300))],
            tombstones: [UUID().uuidString: now.addingTimeInterval(-100)])

        let plan = try makePlan(document, against: snapshot(of: document))

        #expect(plan.isEmpty)
        #expect(plan.projectedKeyCount == 4)
    }

    @Test func onlyACopyNewerThanTheStoresIsUploaded() throws {
        let id = UUID()
        let stored = LibraryFixtures.computer("Stored", id: id, modifiedAt: now.addingTimeInterval(-200))
        let cloud = try snapshot(of: LibraryDocument(computers: [stored]))

        var newer = stored
        newer.name = "Edited since"
        newer.modifiedAt = now.addingTimeInterval(-100)
        #expect(try makePlan(LibraryDocument(computers: [newer]), against: cloud).writes.map(\.key)
            == [.computer(id)])

        // Same instant, different content: two edits that nothing can order.
        // Uploading ours would only make the other device upload theirs.
        var conflicting = stored
        conflicting.name = "Edited at the very same moment"
        #expect(try makePlan(LibraryDocument(computers: [conflicting]), against: cloud).isEmpty)

        var older = stored
        older.name = "Out of date"
        older.modifiedAt = now.addingTimeInterval(-300)
        #expect(try makePlan(LibraryDocument(computers: [older]), against: cloud).isEmpty)
    }

    @Test func itemsDeletedFromTheLibraryAreRemovedAndTheirDeletionRecorded() throws {
        let kept = LibraryFixtures.computer("Kept", modifiedAt: now.addingTimeInterval(-500))
        let deleted = LibraryFixtures.computer("Deleted", modifiedAt: now.addingTimeInterval(-500))
        let group = LibraryFixtures.group("Deleted group", modifiedAt: now.addingTimeInterval(-500))
        let cloud = try snapshot(of: LibraryDocument(computers: [kept, deleted], groups: [group]))

        let plan = try makePlan(
            LibraryDocument(
                computers: [kept],
                tombstones: [
                    deleted.id.uuidString: now.addingTimeInterval(-10),
                    group.id.uuidString: now.addingTimeInterval(-10),
                ]),
            against: cloud)

        #expect(Set(plan.writes.map(\.key)) == [.tombstone(deleted.id), .tombstone(group.id)])
        #expect(Set(plan.removals) == [.computer(deleted.id), .group(group.id)])
        #expect(plan.projectedKeyCount == 4)
    }

    @Test func aDeletionThatLostOrExpiredIsRemovedFromTheStore() throws {
        let revived = LibraryFixtures.computer("Revived", modifiedAt: now.addingTimeInterval(-50))
        let expired = UUID()
        let lifetime = LibraryDocument.tombstoneLifetime
        let cloud = try snapshot(of: LibraryDocument(tombstones: [
            revived.id.uuidString: now.addingTimeInterval(-100),
            expired.uuidString: now.addingTimeInterval(-100),
        ]))

        // The merged library has the computer back, and — because the merge
        // happens later here — no memory of the other deletion.
        let later = try CloudSyncPlan(
            desired: LibraryDocument(computers: [revived]),
            cloud: cloud, schemaVersion: 1, now: now.addingTimeInterval(lifetime))

        #expect(later.writes.map(\.key) == [.computer(revived.id)])
        #expect(Set(later.removals) == [.tombstone(revived.id), .tombstone(expired)])
    }

    @Test func aDeletionOlderThanItsLifetimeIsNotUploaded() throws {
        let lifetime = LibraryDocument.tombstoneLifetime
        let fresh = UUID(), stale = UUID()
        let plan = try makePlan(LibraryDocument(tombstones: [
            fresh.uuidString: now.addingTimeInterval(-lifetime + 1),
            stale.uuidString: now.addingTimeInterval(-lifetime),
        ]))

        #expect(plan.writes.map(\.key) == [.metadata, .tombstone(fresh)])
    }

    @Test func theFirstLimitThatWouldBeBrokenIsReported() throws {
        var large = LibraryFixtures.computer("Large", modifiedAt: now)
        large.notes = String(repeating: "x", count: 5_000)
        let small = LibraryFixtures.computer("Small", modifiedAt: now)
        let plan = try makePlan(LibraryDocument(computers: [large, small]))
        let roomy = CloudSyncEngine.Limits(
            maximumKeyCount: 100, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000)

        #expect(plan.violation(of: roomy) == nil)

        var limits = roomy
        limits.maximumKeyCount = 2
        #expect(plan.violation(of: limits) == .keyCount(needed: 3, limit: 2))

        limits = roomy
        limits.maximumTotalBytes = plan.projectedByteCount - 1
        #expect(plan.violation(of: limits)
            == .totalBytes(needed: plan.projectedByteCount, limit: plan.projectedByteCount - 1))
        limits.maximumTotalBytes = plan.projectedByteCount
        #expect(plan.violation(of: limits) == nil)

        limits = roomy
        limits.maximumValueBytes = 4_000
        guard case .valueBytes(let key, let size, 4_000)? = plan.violation(of: limits) else {
            Issue.record("expected the oversized computer to be reported")
            return
        }
        #expect(key == .computer(large.id))
        #expect(size > 5_000)
    }

    @Test func keysThatBelongToSomeoneElseCountTowardsTheLimits() throws {
        let store = InMemoryCloudStore(values: [
            "settings.theme": Data(count: 1_000),
            "something.else": Data(count: 2_000),
        ])
        var reader = CloudReader()
        let cloud = reader.read(store)
        let plan = try makePlan(
            LibraryDocument(computers: [LibraryFixtures.computer("Studio", modifiedAt: now)]),
            against: cloud)

        #expect(plan.projectedKeyCount == 4)
        #expect(plan.projectedByteCount > 3_000)
        #expect(plan.removals.isEmpty)
    }

    @Test func aPlanThatOnlyRemovesIsAlwaysAllowed() throws {
        let computers = (0..<5).map {
            LibraryFixtures.computer("Computer \($0)", modifiedAt: now.addingTimeInterval(-500))
        }
        let document = LibraryDocument(computers: computers)
        let cloud = try snapshot(of: document)
        let tiny = CloudSyncEngine.Limits(maximumKeyCount: 1, maximumTotalBytes: 1, maximumValueBytes: 1)

        // Deletions whose lifetime has passed: nothing to write, only to remove.
        let later = now.addingTimeInterval(LibraryDocument.tombstoneLifetime * 2)
        let plan = try CloudSyncPlan(
            desired: LibraryDocument(), cloud: cloud, schemaVersion: 1, now: later)

        #expect(plan.writes.isEmpty)
        #expect(plan.removals.count == 5)
        #expect(plan.violation(of: tiny) == nil)
    }

    @Test func readingTheSameStoreTwiceGivesTheSameSnapshot() throws {
        let document = LibraryDocument(
            computers: [LibraryFixtures.computer("Studio", modifiedAt: now)],
            groups: [LibraryFixtures.group("Home", modifiedAt: now)],
            tombstones: [UUID().uuidString: now])
        let store = InMemoryCloudStore()
        for write in try makePlan(document).writes {
            store.set(write.data, forKey: write.key.rawValue)
        }
        var reader = CloudReader()

        let first = reader.read(store)
        // The second read is served from what the first one decoded.
        let second = reader.read(store)

        #expect(first.document.sortedByID == document.sortedByID)
        #expect(second.document == first.document)
        #expect(second.schemaVersion == 1)
        #expect(second.unreadable.isEmpty)

        // A value that changes is decoded afresh, one that disappears is gone.
        var renamed = document.computers[0]
        renamed.name = "Renamed"
        store.set(try CloudCoding.makeEncoder().encode(renamed), forKey: "c.\(renamed.id.uuidString)")
        store.removeObject(forKey: "g.\(document.groups[0].id.uuidString)")
        let third = reader.read(store)
        #expect(third.computers[renamed.id]?.name == "Renamed")
        #expect(third.groups.isEmpty)
    }
}

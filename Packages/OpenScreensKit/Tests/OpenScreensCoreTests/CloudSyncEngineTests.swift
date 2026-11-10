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

    @Test func aRecordThisVersionCannotDecodeIsNotReplacedByItsOwnCopy() throws {
        let other = SimulatedDevice()
        let studio = other.library.add(computer("Studio"))
        let home = other.library.addGroup(named: "Home")
        let store = InMemoryCloudStore(values: other.store.values)
        let device = SimulatedDevice(store: store)
        #expect(device.library.computer(studio.id) == studio)
        #expect(device.library.group(home.id) == home)

        // A later version of the app changed the shape of a field without
        // raising the layout version, and saved both again.
        func reshaped(_ key: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
            let original = try #require(other.store.values[key])
            var fields = try #require(
                try JSONSerialization.jsonObject(with: original) as? [String: Any])
            change(&fields)
            fields["modifiedAt"] = Date.now.timeIntervalSinceReferenceDate + 10
            return try JSONSerialization.data(withJSONObject: fields)
        }
        let laterComputer = try reshaped(key(studio)) {
            $0["tags"] = ["work": ["colour": "red"]]
            $0["name"] = "Renamed by the later version"
        }
        let laterGroup = try reshaped(key(home)) { $0["sortIndex"] = ["manual": 3] }
        store.deliver(laterComputer, forKey: key(studio))
        store.deliver(laterGroup, forKey: key(home))
        store.forgetOperations()
        device.storeChangedExternally()

        // This device cannot read them. It keeps what it has, and keeps it
        // to itself: its older copies do not go back up over the newer ones.
        #expect(store.operations.isEmpty)
        #expect(store.values[key(studio)] == laterComputer)
        #expect(store.values[key(home)] == laterGroup)
        #expect(device.library.computer(studio.id) == studio)
        #expect(device.library.group(home.id) == home)
        #expect(device.lastSync != nil)

        // The same goes for an edit made here: there is no telling which of
        // the two is the later one.
        tick()
        device.library.update(studio.id) { $0.notes = "edited here" }
        device.engine.syncNow()
        #expect(store.values[key(studio)] == laterComputer)
        #expect(device.library.computer(studio.id)?.notes == "edited here")

        // Deleting is deliberate, and removes it for everyone.
        device.library.delete(studio.id)
        #expect(store.values[key(studio)] == nil)
        #expect(store.values[tombstoneKey(studio.id)] != nil)
        #expect(store.values[key(home)] == laterGroup)
    }

    @Test func whatIsNotARecordOfTheItemIsDamageAndIsRepaired() throws {
        let device = SimulatedDevice()
        let studio = device.library.add(computer("Studio"))
        let stored = try #require(device.store.values[key(studio)])
        let another = String(decoding: stored, as: UTF8.self)
            .replacing(studio.id.uuidString, with: UUID().uuidString)
        #expect(another.utf8.count == stored.count)

        for damage in [
            "{}", "[1, 2]", #""text""#, "42", "null", #"{"id": 7}"#, #"{"id": "not an identifier"}"#,
            #"{"host": "studio.local"}"#, "{ cut short", another,
        ] {
            device.store.deliver(Data(damage.utf8), forKey: key(studio))
            device.storeChangedExternally()
            #expect(device.store.values[key(studio)] == stored, "\(damage)")
        }
        #expect(device.library.computers == [studio])
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

    /// A record whose modification date is missing, or is no date at all, is
    /// not set aside as unreadable. Nothing in it is beyond this version,
    /// and a record nobody reads would stay in iCloud for good, unseen and
    /// taking up room. Read as the oldest there is, it never wins over a
    /// copy that has a date, is listed where there is no such copy, and is
    /// put right by the first edit or removed by a deletion like any other.
    @Test(arguments: ["inf", "-inf", "nan", nil] as [String?])
    func aRecordWithoutAUsableDateIsReadAsTheOldestThereIs(date: String?) throws {
        let other = SimulatedDevice()
        let studio = other.library.add(computer("Studio"))
        let original = try #require(other.store.values[key(studio)])
        var fields = try #require(
            try JSONSerialization.jsonObject(with: original) as? [String: Any])
        if let date {
            fields["modifiedAt"] = date
        } else {
            fields.removeValue(forKey: "modifiedAt")
        }
        var contents = other.store.values
        contents[key(studio)] = try JSONSerialization.data(withJSONObject: fields)

        // A device with nothing of its own lists it, leaves it as it is in
        // iCloud, and can still save its library and read it back.
        let scratch = try ScratchDirectory()
        let file = scratch.file("Library.json")
        let store = InMemoryCloudStore(values: contents)
        let library = LibraryStore(fileURL: file, backupsDirectory: nil)
        let engine = CloudSyncEngine(
            library: library, store: store, notificationCenter: NotificationCenter())
        library.onChange = { [weak engine] in engine?.libraryDidChange($0) }
        engine.isEnabled = true
        #expect(library.computer(studio.id)?.name == "Studio")
        #expect(library.computer(studio.id)?.modifiedAt == .distantPast)
        #expect(store.operations.isEmpty)
        library.saveNow()
        #expect(library.lastError == nil)
        #expect(LibraryStore(fileURL: file, backupsDirectory: nil).computers.map(\.id) == [studio.id])

        // An edit stamps it properly, and that is what iCloud then holds.
        library.update(studio.id) { $0.name = "Edited here" }
        let edited = try #require(try store.computer(studio.id))
        #expect(edited.name == "Edited here")
        #expect(edited.modifiedAt > Date.now.addingTimeInterval(-60))
        engine.syncNow()
        #expect(library.computer(studio.id) == edited)

        // A device that has a copy with a date keeps its own, and puts it in
        // iCloud in place of the one without.
        let mine = LibraryFixtures.computer(
            "Mine", id: studio.id, modifiedAt: LibraryFixtures.recentWholeSecond())
        let keeper = SimulatedDevice(store: InMemoryCloudStore(values: contents), syncEnabled: false)
        keeper.library.merge(LibraryDocument(computers: [mine]))
        keeper.engine.isEnabled = true
        #expect(keeper.library.computer(studio.id) == mine)
        #expect(try keeper.store.computer(studio.id) == mine)

        // And it can be deleted like any other.
        let deleter = SimulatedDevice(store: InMemoryCloudStore(values: contents))
        deleter.library.delete(studio.id)
        deleter.engine.syncNow()
        #expect(deleter.library.computers.isEmpty)
        #expect(deleter.store.values[key(studio)] == nil)
        #expect(deleter.store.values[tombstoneKey(studio.id)] != nil)
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

    @Test(arguments: [false, true])
    func copiesStampedAlikeSettleOnOneAndDoNotMakeDevicesFightOverICloud(
        theOneThatStandsUploadsFirst: Bool
    ) throws {
        // Two devices hold different copies of a computer with the very same
        // modification date. Neither is newer, so the library picks by the
        // copies themselves — the same one on every device — and the device
        // that holds it uploads it, even over the other one. Both end up
        // with it, iCloud holds it, and then nobody has anything to upload:
        // the devices neither keep their own copy nor fight over the key.
        let id = UUID()
        let stamp = LibraryFixtures.recentWholeSecond()
        let onMac = LibraryFixtures.computer("Renamed on the Mac", id: id, modifiedAt: stamp)
        let onPhone = LibraryFixtures.computer("Renamed on the phone", id: id, modifiedAt: stamp)
        let standing = Computer.resolve(onMac, onPhone)
        #expect(standing == onMac || standing == onPhone)

        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(syncEnabled: false)
        let phone = cloud.addDevice(syncEnabled: false)
        mac.library.merge(LibraryDocument(computers: [onMac]))
        phone.library.merge(LibraryDocument(computers: [onPhone]))

        mac.engine.isEnabled = true
        phone.engine.isEnabled = true
        // iCloud keeps whichever upload arrives last. When that is the copy
        // that does not stand, the device holding the other uploads again.
        let holder = standing == onMac ? mac : phone
        let other = standing == onMac ? phone : mac
        cloud.exchange(uploadOrder: theOneThatStandsUploadsFirst ? [holder, other] : [other, holder])
        #expect(cloud.settle() <= 2)

        #expect(mac.library.computer(id) == standing)
        #expect(phone.library.computer(id) == standing)
        let settled = try #require(cloud.server["c.\(id.uuidString)"])
        #expect(try CloudCoding.makeDecoder().decode(Computer.self, from: settled) == standing)

        // And it stays that one.
        for _ in 0..<3 {
            mac.engine.syncNow()
            phone.engine.syncNow()
            #expect(cloud.exchange() == 0)
        }
        #expect(cloud.server["c.\(id.uuidString)"] == settled)
        #expect(cloud.hasConverged)
        #expect(mac.lastSync != nil)
        #expect(phone.lastSync != nil)
    }

    @Test func aDeviceThatJoinsAfterTwoCopiesWereStampedAlikeGetsTheOneTheOthersHave() throws {
        let id = UUID()
        let stamp = LibraryFixtures.recentWholeSecond()
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(syncEnabled: false)
        let phone = cloud.addDevice(syncEnabled: false)
        mac.library.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Zulu, on the Mac", id: id, host: "studio.local", modifiedAt: stamp),
        ]))
        phone.library.merge(LibraryDocument(computers: [
            LibraryFixtures.computer("Alpha, on the phone", id: id, host: "studio.local", modifiedAt: stamp),
        ]))
        mac.engine.isEnabled = true
        phone.engine.isEnabled = true
        cloud.settle()

        let tablet = cloud.addDevice()
        cloud.settle()

        let name = try #require(mac.library.computer(id)?.name)
        #expect(phone.library.computer(id)?.name == name)
        #expect(tablet.library.computer(id)?.name == name)
        #expect(cloud.hasConverged)
    }

    /// A change is stamped later than the copy it was made from. When that
    /// copy came from a device whose clock runs ahead, two devices changing
    /// it before that time has come both use the very next instant — the
    /// same one — and the two changes are a tie.
    @Test(arguments: [false, true])
    func twoEditsOnTopOfACopyFromAFastClockEndUpTheSameEverywhere(macUploadsFirst: Bool) throws {
        for names in [("Alpha, set on the Mac", "Zulu, set on the phone"),
                      ("Zulu, set on the Mac", "Alpha, set on the phone")] {
            let cloud = SimulatedCloud()
            let mac = cloud.addDevice(), phone = cloud.addDevice()
            let ahead = Date.now.addingTimeInterval(300)
            let studio = LibraryFixtures.computer("Studio", host: "studio.local", modifiedAt: ahead)
            mac.library.merge(LibraryDocument(computers: [studio]))
            mac.engine.syncNow()
            cloud.settle()
            #expect(phone.library.computer(studio.id)?.modifiedAt == ahead)

            // Neither has heard of the other's edit when it makes its own.
            mac.library.update(studio.id) { $0.name = names.0 }
            phone.library.update(studio.id) { $0.name = names.1 }
            #expect(mac.library.computer(studio.id)?.modifiedAt
                == phone.library.computer(studio.id)?.modifiedAt)
            cloud.exchange(uploadOrder: macUploadsFirst ? [mac, phone] : [phone, mac])
            cloud.settle()

            let name = try #require(mac.library.computer(studio.id)?.name)
            #expect(names.0 == name || names.1 == name)
            #expect(phone.library.computer(studio.id)?.name == name)
            #expect(try phone.store.computer(studio.id)?.name == name)
            #expect(cloud.hasConverged)
        }
    }

    // MARK: - When a computer was last connected to

    @Test func aConnectionMadeOnOneDeviceShowsUpOnTheOthers() throws {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        cloud.settle()
        #expect(mac.library.recents.isEmpty)

        tick()
        phone.library.markConnected(studio.id)
        let connected = try #require(phone.library.computer(studio.id)?.lastConnectedAt)
        // Connecting is not an edit…
        #expect(phone.library.computer(studio.id)?.modifiedAt == studio.modifiedAt)
        // …and still travels: once up, once down, and then nothing more.
        #expect(cloud.exchange() == 2)
        #expect(cloud.exchange() == 0)

        #expect(try phone.store.computer(studio.id)?.lastConnectedAt == connected)
        #expect(mac.library.computer(studio.id)?.lastConnectedAt == connected)
        #expect(mac.library.recents.map(\.id) == [studio.id])
        #expect(cloud.hasConverged)

        // An edit made elsewhere afterwards does not make the phone forget.
        tick()
        mac.library.update(studio.id) { $0.notes = "edited on the Mac later" }
        cloud.settle()
        #expect(phone.library.computer(studio.id)?.notes == "edited on the Mac later")
        #expect(phone.library.computer(studio.id)?.lastConnectedAt == connected)
        #expect(cloud.hasConverged)
    }

    @Test(arguments: [false, true])
    func connectionsMadeOnTwoDevicesSettleOnTheLaterWithoutGoingBackAndForth(
        theLaterUploadsFirst: Bool
    ) throws {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        cloud.settle()

        // Each connects without having heard that the other did.
        tick()
        mac.library.markConnected(studio.id)
        tick()
        phone.library.markConnected(studio.id)
        let later = try #require(phone.library.computer(studio.id)?.lastConnectedAt)
        #expect(try #require(mac.library.computer(studio.id)?.lastConnectedAt) < later)

        // iCloud keeps the upload that arrives last. If that is the earlier
        // connection, the device with the later one uploads once more; in
        // no case does either upload a second time after that.
        cloud.exchange(uploadOrder: theLaterUploadsFirst ? [phone, mac] : [mac, phone])
        #expect(cloud.settle() <= 1)

        #expect(mac.library.computer(studio.id)?.lastConnectedAt == later)
        #expect(phone.library.computer(studio.id)?.lastConnectedAt == later)
        #expect(try mac.store.computer(studio.id)?.lastConnectedAt == later)
        for _ in 0..<3 {
            mac.engine.syncNow()
            phone.engine.syncNow()
            #expect(cloud.exchange() == 0)
        }
        #expect(cloud.hasConverged)
    }

    @Test func clearingRecentsOnOneDeviceClearsThemOnTheOthers() throws {
        let cloud = SimulatedCloud()
        let mac = cloud.addDevice(), phone = cloud.addDevice()
        let studio = mac.library.add(computer("Studio"))
        let server = mac.library.add(computer("Server"))
        cloud.settle()
        tick()
        phone.library.markConnected(studio.id)
        mac.library.markConnected(server.id)
        cloud.settle()
        #expect(Set(mac.library.recents.map(\.id)) == [studio.id, server.id])
        #expect(Set(phone.library.recents.map(\.id)) == [studio.id, server.id])

        tick()
        mac.library.clearRecents()
        cloud.settle()

        #expect(mac.library.recents.isEmpty)
        #expect(phone.library.recents.isEmpty)
        #expect(try phone.store.computer(studio.id)?.lastConnectedAt == nil)

        // A connection made afterwards counts again, everywhere.
        tick()
        phone.library.markConnected(studio.id)
        cloud.settle()
        #expect(mac.library.recents.map(\.id) == [studio.id])
        #expect(cloud.hasConverged)
    }

    @Test func connectingDoesNotRewriteARecordThatSaysMoreThanThisVersionReads() throws {
        // The record as a later version of the app wrote it: a field this
        // version does not know, and a kind it has no name for.
        let other = SimulatedDevice()
        let studio = other.library.add(computer("Studio"))
        let original = try #require(other.store.values[key(studio)])
        var fields = try #require(
            try JSONSerialization.jsonObject(with: original) as? [String: Any])
        fields["somethingNew"] = ["nested": true]
        fields["kind"] = "mainframe"
        let extended = try JSONSerialization.data(withJSONObject: fields)
        var contents = other.store.values
        contents[key(studio)] = extended
        let store = InMemoryCloudStore(values: contents)
        let device = SimulatedDevice(store: store)
        #expect(device.library.computer(studio.id) != nil)
        store.forgetOperations()

        // Connecting is remembered here, and is not worth erasing what the
        // later version stored.
        tick()
        device.library.markConnected(studio.id)
        device.engine.syncNow()
        #expect(device.library.computer(studio.id)?.lastConnectedAt != nil)
        #expect(store.operations.isEmpty)
        #expect(store.values[key(studio)] == extended)

        // A real edit is still uploaded, and takes the connection with it.
        tick()
        device.library.update(studio.id) { $0.notes = "edited here" }
        #expect(try store.computer(studio.id)?.notes == "edited here")
        #expect(try store.computer(studio.id)?.lastConnectedAt
            == device.library.computer(studio.id)?.lastConnectedAt)
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
                switch Int.random(in: 0..<13, using: &random) {
                case 10, 11:
                    // Not an edit, and has to reach every device all the same.
                    if let target = computers.randomElement(using: &random) {
                        library.markConnected(target.id)
                    }
                case 12:
                    library.clearRecents()
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

    @Test func takingBackWhatDidNotFitPutsTheLibraryBackInStep() throws {
        let limits = CloudSyncEngine.Limits(
            maximumKeyCount: 4, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000)
        let device = SimulatedDevice(limits: limits)
        let fitting = ["One", "Two", "Three"].map { device.library.add(computer($0)) }
        let four = device.library.add(computer("Four"))
        #expect(device.failure != nil)
        let stored = device.store.values

        // The deletion of a computer iCloud never held has nothing there to
        // delete. It must not need an entry of its own and so keep the
        // library one too large — for as long as deletions are remembered.
        tick()
        device.library.delete(four.id)

        #expect(device.failure == nil)
        #expect(device.lastSync != nil)
        #expect(device.store.values == stored)
        // The deletion is still remembered here, should the computer turn
        // up from somewhere after all.
        #expect(device.library.document.tombstones[four.id.uuidString] != nil)

        // And changes travel again.
        tick()
        device.library.update(fitting[0].id) { $0.notes = "edited once it fitted again" }
        #expect(device.failure == nil)
        #expect(try device.store.computer(fitting[0].id)?.notes == "edited once it fitted again")
        #expect(device.store.keys(withPrefix: "t.").isEmpty)
    }

    @Test func aLibraryThatWasEmptiedIsNeverTooLargeToSync() throws {
        let limits = CloudSyncEngine.Limits(
            maximumKeyCount: 4, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000)
        let device = SimulatedDevice(limits: limits)
        let fitting = ["One", "Two", "Three"].map { device.library.add(computer($0)) }
        let four = device.library.add(computer("Four"))
        #expect(device.failure != nil)

        // Deleting a computer that is in iCloud frees nothing at first: the
        // record of the deletion takes its entry over. With the fourth still
        // waiting, five entries are needed as before.
        tick()
        device.library.delete(fitting[0].id)
        device.library.delete(fitting[1].id)
        #expect(try #require(device.failure).contains("need 5 entries"))

        // Once nothing is waiting to go up, what is left does fit.
        device.library.delete(fitting[2].id)
        device.library.delete(four.id)
        #expect(device.library.computers.isEmpty)
        #expect(device.failure == nil)
        #expect(device.lastSync != nil)
        #expect(device.store.keys(withPrefix: "c.").isEmpty)
        #expect(Set(device.store.keys(withPrefix: "t.")) == Set(fitting.map { tombstoneKey($0.id) }))
    }

    @Test func whenICloudAlreadyHoldsMoreThanTheLimitChangesThatAddNothingStillGoThrough() throws {
        // Two devices can each add the last computers that fit; together
        // they are over. Here the Mac simply allows more than the phone.
        let store = InMemoryCloudStore()
        let mac = SimulatedDevice(store: store)
        let phone = SimulatedDevice(
            store: store,
            limits: CloudSyncEngine.Limits(
                maximumKeyCount: 4, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000))
        let computers = ["One", "Two", "Three", "Four", "Five"].map { mac.library.add(computer($0)) }
        phone.storeChangedExternally()
        #expect(phone.library.computers.count == 5)
        #expect(store.values.count == 6)

        // An edit replaces a value.
        tick()
        phone.library.update(computers[0].id) { $0.notes = "edited on the phone" }
        #expect(phone.failure == nil)
        #expect(try store.computer(computers[0].id)?.notes == "edited on the phone")

        // A deletion swaps the computer's entry for the record of it.
        phone.library.delete(computers[1].id)
        #expect(phone.failure == nil)
        #expect(store.values[key(computers[1])] == nil)
        #expect(store.values[tombstoneKey(computers[1].id)] != nil)
        #expect(store.values.count == 6)
        mac.storeChangedExternally()
        #expect(mac.library.computer(computers[1].id) == nil)
        #expect(mac.library.computer(computers[0].id)?.notes == "edited on the phone")

        // Adding is what has to wait, and with it everything else.
        let before = store.values
        let six = phone.library.add(computer("Six"))
        #expect(try #require(phone.failure).contains("allows 4"))
        #expect(store.values[key(six)] == nil)
        phone.library.update(computers[2].id) { $0.notes = "waits with it" }
        #expect(store.values == before)
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

    @Test func aDeletionAboutToBeForgottenIsNoLongerCarriedIntoICloud() throws {
        let (mac, phone) = twoDevicesSharingOneStore()
        let store = mac.store
        let old = LibraryFixtures.computer(
            "Old", modifiedAt: Date.now.addingTimeInterval(-200 * 86_400))
        phone.library.merge(LibraryDocument(computers: [old]))
        phone.engine.syncNow()
        #expect(store.values[key(old)] != nil)
        store.forgetOperations()

        // The Mac deleted that computer almost ninety days ago and has not
        // synced since: the deletion has an hour left before it is forgotten.
        mac.library.merge(LibraryDocument(tombstones: [
            old.id.uuidString: Date.now.addingTimeInterval(-LibraryDocument.tombstoneLifetime + 3600),
        ]))
        mac.engine.syncNow()

        // It still holds here, for that hour. It is too late to hand on:
        // the record would be gone again before it had done anything, and
        // the computer taken out of iCloud without it would come straight
        // back from the phone.
        #expect(mac.library.computer(old.id) == nil)
        #expect(store.operations.isEmpty)
        #expect(store.values[key(old)] != nil)
        phone.storeChangedExternally()
        #expect(phone.library.computer(old.id) == old)
        #expect(mac.lastSync != nil)
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

    /// A snapshot of a store that holds a record of the given deletions,
    /// whatever their age, and nothing else.
    private func snapshot(holdingDeletions deletions: [UUID: Date]) throws -> CloudSnapshot {
        let store = InMemoryCloudStore()
        store.set(try CloudCoding.makeEncoder().encode(CloudMetadata(schemaVersion: 1)), forKey: "meta")
        for (id, date) in deletions {
            store.set(try CloudCoding.makeEncoder().encode(date), forKey: "t.\(id.uuidString)")
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

        var older = stored
        older.name = "Out of date"
        older.modifiedAt = now.addingTimeInterval(-300)
        #expect(try makePlan(LibraryDocument(computers: [older]), against: cloud).isEmpty)
    }

    @Test func ofTwoCopiesStampedAlikeTheOneThatStandsIsUploaded() throws {
        let id = UUID()
        let stored = LibraryFixtures.computer("Stored", id: id, modifiedAt: now.addingTimeInterval(-200))
        let cloud = try snapshot(of: LibraryDocument(computers: [stored]))

        // Same instant, different content: neither edit is newer. One of the
        // two stands — the same one whoever compares them — and it is
        // uploaded unless it is the one the store already has.
        var early = stored, late = stored
        early.name = "Aardvark"
        late.name = "Zebra"
        let earlyStands = Computer.resolve(stored, early) == early
        let (standing, yielding) = earlyStands ? (early, late) : (late, early)
        #expect(Computer.resolve(stored, standing) == standing)
        #expect(Computer.resolve(stored, yielding) == stored)

        let plan = try makePlan(LibraryDocument(computers: [standing]), against: cloud)
        #expect(plan.writes.map(\.key) == [.computer(id)])
        #expect(try CloudCoding.makeDecoder().decode(Computer.self, from: #require(plan.writes.first).data)
            == standing)
        #expect(try makePlan(LibraryDocument(computers: [yielding]), against: cloud).isEmpty)

        // The same goes for groups.
        let group = LibraryFixtures.group("Stored", modifiedAt: now.addingTimeInterval(-200))
        let groupCloud = try snapshot(of: LibraryDocument(groups: [group]))
        var first = group, second = group
        first.name = "Aardvark"
        second.name = "Zebra"
        let (groupStanding, groupYielding) =
            ComputerGroup.resolve(group, first) == first ? (first, second) : (second, first)
        #expect(try makePlan(LibraryDocument(groups: [groupStanding]), against: groupCloud).writes.map(\.key)
            == [.group(group.id)])
        #expect(try makePlan(LibraryDocument(groups: [groupYielding]), against: groupCloud).isEmpty)
    }

    @Test func aLaterConnectionIsUploadedAndAnEarlierOneIsNot() throws {
        let id = UUID()
        var stored = LibraryFixtures.computer("Studio", id: id, modifiedAt: now.addingTimeInterval(-500))
        stored.lastConnectedAt = now.addingTimeInterval(-200)
        let cloud = try snapshot(of: LibraryDocument(computers: [stored]))
        let decoder = CloudCoding.makeDecoder()

        // Connecting does not touch the modification date.
        var connectedSince = stored
        connectedSince.lastConnectedAt = now.addingTimeInterval(-100)
        let plan = try makePlan(LibraryDocument(computers: [connectedSince]), against: cloud)
        #expect(plan.writes.map(\.key) == [.computer(id)])
        #expect(try decoder.decode(Computer.self, from: #require(plan.writes.first).data) == connectedSince)

        var connectedBefore = stored
        connectedBefore.lastConnectedAt = now.addingTimeInterval(-300)
        #expect(try makePlan(LibraryDocument(computers: [connectedBefore]), against: cloud).isEmpty)
        var neverConnected = stored
        neverConnected.lastConnectedAt = nil
        #expect(try makePlan(LibraryDocument(computers: [neverConnected]), against: cloud).isEmpty)

        // An older copy that knows of a later connection adds the connection
        // and nothing else: the newer edit in the store stays as it is.
        var behind = stored
        behind.name = "Out of date"
        behind.modifiedAt = now.addingTimeInterval(-900)
        behind.lastConnectedAt = now.addingTimeInterval(-50)
        let adding = try makePlan(LibraryDocument(computers: [behind]), against: cloud)
        var expected = stored
        expected.lastConnectedAt = behind.lastConnectedAt
        #expect(try decoder.decode(Computer.self, from: #require(adding.writes.first).data) == expected)
    }

    /// What keeps devices from uploading over each other for ever: whatever
    /// two copies settle on, a device holding either of them — or the result
    /// — finds nothing to write once the store has it.
    @Test func onceWhatTwoCopiesSettleOnIsInTheStoreNobodyWritesAgain() throws {
        var random = ReplayableRandom(seed: 5)
        let stamps = (0..<4).map { now.addingTimeInterval(Double($0) * -100) }
        func moment() -> Date? {
            random.chance(0.25) ? nil : now.addingTimeInterval(.random(in: -450...50, using: &random))
        }
        for _ in 0..<400 {
            let id = UUID()
            func copy() -> Computer {
                var computer = LibraryFixtures.computer(
                    random.chance(0.5) ? "Studio" : "Server", id: id, host: "studio.local",
                    modifiedAt: stamps.randomElement(using: &random)!)
                computer.createdAt = stamps[3]
                computer.lastConnectedAt = moment()
                computer.connectionsClearedAt = moment()
                return computer
            }
            let a = copy(), b = copy()
            let settled = Computer.resolve(a, b)

            // The device holding `b` finds `a` in the store.
            let wanted = LibraryDocument.merge(
                LibraryDocument(computers: [b]), LibraryDocument(computers: [a]), now: now)
            let plan = try makePlan(wanted, against: snapshot(of: LibraryDocument(computers: [a])))
            if let write = plan.writes.first {
                #expect(try CloudCoding.makeDecoder().decode(Computer.self, from: write.data) == settled)
            } else {
                #expect(settled == a)
            }

            // With that in the store, nobody has anything to add.
            let store = try snapshot(of: LibraryDocument(computers: [settled]))
            for held in [a, b, settled] {
                #expect(try makePlan(LibraryDocument(computers: [held]), against: store).isEmpty)
            }
        }
    }

    @Test func aRecordThatSaysMoreThanThisVersionReadsIsNotRewrittenToAddAConnection() throws {
        let id = UUID()
        let stored = LibraryFixtures.computer("Studio", id: id, modifiedAt: now.addingTimeInterval(-500))
        let plain = try CloudCoding.makeEncoder().encode(stored)
        var fields = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])

        func cloud(holding fields: [String: Any]) throws -> CloudSnapshot {
            let store = InMemoryCloudStore()
            store.set(try JSONSerialization.data(withJSONObject: fields), forKey: "c.\(id.uuidString)")
            store.set(Data(#"{"schemaVersion":1}"#.utf8), forKey: "meta")
            var reader = CloudReader()
            return reader.read(store)
        }
        var connected = stored
        connected.lastConnectedAt = now.addingTimeInterval(-100)

        // Written by this version, only formatted differently: it goes up.
        #expect(try makePlan(LibraryDocument(computers: [connected]), against: cloud(holding: fields))
            .writes.map(\.key) == [.computer(id)])

        // Written by an earlier version that did not have every field: the
        // rewrite loses nothing, so it goes up as well.
        var fewer = fields
        fewer["notes"] = nil
        fewer["tags"] = nil
        #expect(try makePlan(LibraryDocument(computers: [connected]), against: cloud(holding: fewer))
            .writes.map(\.key) == [.computer(id)])

        // A field this version does not know, at the top or further in, or a
        // value it reads as something else: left alone.
        fields["somethingNew"] = 1
        #expect(try makePlan(LibraryDocument(computers: [connected]), against: cloud(holding: fields)).isEmpty)
        fields["somethingNew"] = nil
        var settings = try #require(fields["settings"] as? [String: Any])
        settings["somethingNew"] = "x"
        fields["settings"] = settings
        #expect(try makePlan(LibraryDocument(computers: [connected]), against: cloud(holding: fields)).isEmpty)
        settings["somethingNew"] = nil
        settings["quality"] = "holographic"
        fields["settings"] = settings
        // `connected` is the record as this version reads it, plus the connection.
        var asRead = connected
        asRead.settings.quality = .standard
        #expect(try makePlan(LibraryDocument(computers: [asRead]), against: cloud(holding: fields)).isEmpty)

        // An edit is another matter: it is uploaded whatever the store says.
        var edited = asRead
        edited.notes = "edited here"
        edited.modifiedAt = now.addingTimeInterval(-50)
        #expect(try makePlan(LibraryDocument(computers: [edited]), against: cloud(holding: fields))
            .writes.map(\.key) == [.computer(id)])
    }

    @Test func rewritingIsJudgedByWhatAValueSaysNotByItsBytes() throws {
        func keeps(_ stored: String, _ rewritten: String) -> Bool {
            CloudCoding.keepsEverything(in: Data(stored.utf8), whenWrittenAs: Data(rewritten.utf8))
        }
        #expect(keeps(#"{"a":1,"b":"x"}"#, #"{"a":1,"b":"x"}"#))
        // Order, spacing and the spelling of a number do not matter.
        #expect(keeps(#"{"b":"x", "a":1.0}"#, #"{"a":1,"b":"x"}"#))
        #expect(keeps(#"{"a":8.5e2}"#, #"{"a":850}"#))
        // Saying more is fine; saying less, or something else, is not.
        #expect(keeps(#"{"a":1}"#, #"{"a":1,"b":"x"}"#))
        #expect(!keeps(#"{"a":1,"b":"x"}"#, #"{"a":1}"#))
        #expect(!keeps(#"{"a":1}"#, #"{"a":2}"#))
        #expect(!keeps(#"{"a":"mainframe"}"#, #"{"a":"other"}"#))
        #expect(!keeps(#"{"a":null}"#, #"{"a":0}"#))
        // All the way down.
        #expect(keeps(#"{"a":{"b":[1,{"c":true}]}}"#, #"{"a":{"b":[1,{"c":true,"d":2}],"e":0}}"#))
        #expect(!keeps(#"{"a":{"b":[1,{"c":true,"x":0}]}}"#, #"{"a":{"b":[1,{"c":true}]}}"#))
        #expect(!keeps(#"{"a":[1,2,3]}"#, #"{"a":[1,2]}"#))
        #expect(!keeps(#"{"a":{"b":1}}"#, #"{"a":[1]}"#))
        // Something that is not JSON says nothing that could be kept.
        #expect(!keeps("{ not json", #"{"a":1}"#))
        #expect(!keeps(#"{"a":1}"#, ""))
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
            fresh.uuidString: now.addingTimeInterval(-lifetime + 2 * 86_400),
            stale.uuidString: now.addingTimeInterval(-lifetime),
        ]))

        #expect(plan.writes.map(\.key) == [.metadata, .tombstone(fresh)])
    }

    /// Two devices whose clocks differ by a couple of minutes, around the
    /// moment a deletion has been remembered long enough.
    @Test func devicesWhoseClocksDisagreeDoNotPassAnExpiringDeletionBackAndForth() throws {
        let lifetime = LibraryDocument.tombstoneLifetime
        let deleted = UUID()
        let deletedAt = now.addingTimeInterval(-lifetime)
        let ahead = now.addingTimeInterval(60), behind = now.addingTimeInterval(-60)
        let library = LibraryDocument(tombstones: [deleted.uuidString: deletedAt])
        let recorded = try snapshot(holdingDeletions: [deleted: deletedAt])
        #expect(recorded.tombstones[deleted] == deletedAt)

        // The device that is ahead finds the record expired and takes it out.
        let removing = try CloudSyncPlan(
            desired: LibraryDocument.merge(library, recorded.document, now: ahead),
            cloud: recorded, schemaVersion: 1, now: ahead)
        #expect(removing.removals == [.tombstone(deleted)])
        #expect(removing.writes.isEmpty)

        // For the one that is behind it has a minute to go. It still holds
        // the deletion, does not find it in the store — and leaves it at that.
        let without = try snapshot(holdingDeletions: [:])
        let wanted = LibraryDocument.merge(library, without.document, now: behind)
        #expect(wanted.tombstones[deleted.uuidString] == deletedAt)
        let leaving = try CloudSyncPlan(desired: wanted, cloud: without, schemaVersion: 1, now: behind)
        #expect(leaving.isEmpty)
    }

    @Test func aDeletionAboutToBeForgottenIsUploadedOnlyWhereTheStoreAlreadyHasIt() throws {
        let lifetime = LibraryDocument.tombstoneLifetime
        let stretch = CloudSyncPlan.finalStretchOfADeletion
        #expect(stretch >= 3600 && stretch < lifetime / 10)
        let lapsing = LibraryFixtures.computer("Lapsing", modifiedAt: now.addingTimeInterval(-lifetime * 2))
        let lasting = LibraryFixtures.computer("Lasting", modifiedAt: now.addingTimeInterval(-lifetime * 2))
        let home = LibraryFixtures.group("Home", modifiedAt: now.addingTimeInterval(-lifetime * 2))
        let almostForgotten = now.addingTimeInterval(-lifetime + stretch - 60)
        let stillRemembered = now.addingTimeInterval(-lifetime + stretch + 60)

        // The store still has what was deleted, and no record of the
        // deletions: this device made them long ago and is only now back.
        let cloud = try snapshot(of: LibraryDocument(computers: [lapsing, lasting], groups: [home]))
        let plan = try makePlan(
            LibraryDocument(tombstones: [
                lapsing.id.uuidString: almostForgotten,
                home.id.uuidString: almostForgotten,
                lasting.id.uuidString: stillRemembered,
            ]),
            against: cloud)

        // The deletion with time left is carried out. The others are past
        // it, record and removal alike: a computer that vanished from the
        // store without a record would only be uploaded again by the next
        // device that has it.
        #expect(plan.writes.map(\.key) == [.tombstone(lasting.id)])
        #expect(plan.removals == [.computer(lasting.id)])

        // Where the store has the record already, it is kept up to date to
        // the end.
        let known = try snapshot(holdingDeletions: [lapsing.id: almostForgotten.addingTimeInterval(-30)])
        let redating = try makePlan(
            LibraryDocument(tombstones: [lapsing.id.uuidString: almostForgotten]), against: known)
        #expect(redating.writes.map(\.key) == [.tombstone(lapsing.id)])
        #expect(redating.removals.isEmpty)
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

    @Test func aRecordOfTheItemThatCannotBeReadIsLeftAsItIs() throws {
        let computer = LibraryFixtures.computer("Studio", modifiedAt: now.addingTimeInterval(-200))
        let group = LibraryFixtures.group("Home", modifiedAt: now.addingTimeInterval(-200))
        let document = LibraryDocument(computers: [computer], groups: [group])

        func cloud(computer computerValue: String, group groupValue: String) -> CloudSnapshot {
            let store = InMemoryCloudStore()
            store.set(Data(#"{"schemaVersion":1}"#.utf8), forKey: "meta")
            store.set(Data(computerValue.utf8), forKey: "c.\(computer.id.uuidString)")
            store.set(Data(groupValue.utf8), forKey: "g.\(group.id.uuidString)")
            var reader = CloudReader()
            return reader.read(store)
        }

        // Records of these very items, in a shape this version does not read.
        let later = cloud(
            computer: #"{"id":"\#(computer.id.uuidString)","host":{"name":"studio.local"}}"#,
            group: #"{"id":"\#(group.id.uuidString.lowercased())","name":["Home"]}"#)
        #expect(later.unreadable == [.computer(computer.id), .group(group.id)])
        #expect(try makePlan(document, against: later).isEmpty)

        // Anything else under those keys is damage, and is replaced.
        let damaged = cloud(computer: #"{"id":"\#(UUID().uuidString)","host":"x"}"#, group: "[]")
        #expect(damaged.unreadable == [.computer(computer.id), .group(group.id)])
        #expect(try makePlan(document, against: damaged).writes.map(\.key)
            == [.group(group.id), .computer(computer.id)])

        // A deletion still removes what cannot be read.
        let deleting = try makePlan(
            LibraryDocument(tombstones: [
                computer.id.uuidString: now.addingTimeInterval(-10),
                group.id.uuidString: now.addingTimeInterval(-10),
            ]),
            against: later)
        #expect(Set(deleting.removals) == [.computer(computer.id), .group(group.id)])
    }

    @Test func aRecordIsToldFromDamageByTheItemItNames() {
        let id = UUID()
        func isRecord(_ text: String) -> Bool { CloudCoding.isRecord(Data(text.utf8), of: id) }
        #expect(isRecord(#"{"id":"\#(id.uuidString)"}"#))
        #expect(isRecord(#"{"somethingNew":[1,2],"id":"\#(id.uuidString.lowercased())"}"#))
        #expect(!isRecord(#"{"id":"\#(UUID().uuidString)"}"#))
        #expect(!isRecord(#"{"id":12}"#))
        #expect(!isRecord(#"{"identifier":"\#(id.uuidString)"}"#))
        #expect(!isRecord(#"["\#(id.uuidString)"]"#))
        #expect(!isRecord(#""\#(id.uuidString)""#))
        #expect(!isRecord("{ cut short"))
        #expect(!isRecord(""))
    }

    @Test func aPlanThatAddsNoKeysIsAllowedInAStoreThatIsAlreadyOverItsLimit() throws {
        let kept = LibraryFixtures.computer("Kept", modifiedAt: now.addingTimeInterval(-500))
        let doomed = LibraryFixtures.computer("Doomed", modifiedAt: now.addingTimeInterval(-500))
        let cloud = try snapshot(of: LibraryDocument(computers: [kept, doomed]))
        // Three keys are there — two computers and `meta` — where two are allowed.
        let tight = CloudSyncEngine.Limits(
            maximumKeyCount: 2, maximumTotalBytes: 1_000_000, maximumValueBytes: 1_000_000)

        var edited = kept
        edited.notes = "edited"
        edited.modifiedAt = now.addingTimeInterval(-100)
        let editing = try makePlan(LibraryDocument(computers: [edited, doomed]), against: cloud)
        #expect(editing.existingKeyCount == 3)
        #expect(editing.projectedKeyCount == 3)
        #expect(editing.violation(of: tight) == nil)

        let deleting = try makePlan(
            LibraryDocument(
                computers: [kept], tombstones: [doomed.id.uuidString: now.addingTimeInterval(-10)]),
            against: cloud)
        #expect(deleting.writes.map(\.key) == [.tombstone(doomed.id)])
        #expect(deleting.removals == [.computer(doomed.id)])
        #expect(deleting.projectedKeyCount == 3)
        #expect(deleting.violation(of: tight) == nil)

        let added = LibraryFixtures.computer("Added", modifiedAt: now.addingTimeInterval(-100))
        let adding = try makePlan(LibraryDocument(computers: [kept, doomed, added]), against: cloud)
        #expect(adding.violation(of: tight) == .keyCount(needed: 4, limit: 2))

        // The other limits are what they were.
        var tiny = tight
        tiny.maximumTotalBytes = 10
        #expect(editing.violation(of: tiny) == .totalBytes(needed: editing.projectedByteCount, limit: 10))
    }

    @Test func aDeletionOfSomethingTheStoreDoesNotHoldCanWaitForRoom() throws {
        let kept = LibraryFixtures.computer("Kept", modifiedAt: now.addingTimeInterval(-500))
        let inStore = LibraryFixtures.computer("In the store", modifiedAt: now.addingTimeInterval(-500))
        let cloud = try snapshot(of: LibraryDocument(computers: [kept, inStore]))
        let neverUploaded = UUID()
        let plan = try makePlan(
            LibraryDocument(computers: [kept], tombstones: [
                inStore.id.uuidString: now.addingTimeInterval(-10),
                neverUploaded.uuidString: now.addingTimeInterval(-10),
            ]),
            against: cloud)
        #expect(Set(plan.writes.map(\.key)) == [.tombstone(inStore.id), .tombstone(neverUploaded)])
        #expect(plan.projectedKeyCount == 4)

        // Only the deletion with nothing to delete is put off; the other
        // takes the place of the computer it removes.
        let postponed = plan.postponingDeletionsThatCanWait()
        #expect(postponed.writes.map(\.key) == [.tombstone(inStore.id)])
        #expect(postponed.removals == [.computer(inStore.id)])
        #expect(postponed.projectedKeyCount == 3)
        #expect(postponed.projectedByteCount < plan.projectedByteCount)
        #expect(postponed.postponingDeletionsThatCanWait().writes == postponed.writes)

        // A deletion that is already recorded in the store, and only gets a
        // later date, takes no key and is not put off.
        let known = try snapshot(of: LibraryDocument(
            computers: [kept], tombstones: [neverUploaded.uuidString: now.addingTimeInterval(-50)]))
        let redated = try makePlan(
            LibraryDocument(computers: [kept], tombstones: [neverUploaded.uuidString: now.addingTimeInterval(-10)]),
            against: known)
        #expect(redated.writes.map(\.key) == [.tombstone(neverUploaded)])
        #expect(redated.postponingDeletionsThatCanWait().writes == redated.writes)
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

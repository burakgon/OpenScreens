import Foundation
import Observation

/// The saved library of computers and groups.
///
/// The store owns the on-disk document. Views read ``computers`` and
/// ``groups`` and call the mutating methods; every change is written back
/// atomically and announced through ``onChange`` so iCloud sync can follow.
@MainActor
@Observable
public final class LibraryStore {

    public private(set) var computers: [Computer] = []
    public private(set) var groups: [ComputerGroup] = []

    /// Called after every local change with the document that was saved.
    /// Not called for changes that arrive through ``merge(_:)``.
    @ObservationIgnored
    public var onChange: (@MainActor (LibraryDocument) -> Void)?

    /// The most recent problem reading or writing the library file.
    public private(set) var lastError: String?

    @ObservationIgnored private var tombstones: [String: Date] = [:]
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let backupsDirectory: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Creates a store backed by a file. Pass `nil` for an in-memory store.
    public init(
        fileURL: URL? = StorageLocation.libraryFile,
        backupsDirectory: URL? = StorageLocation.backupsDirectory
    ) {
        self.fileURL = fileURL
        self.backupsDirectory = backupsDirectory
        load()
    }

    // MARK: - Reading

    public var document: LibraryDocument {
        LibraryDocument(computers: computers, groups: groups, tombstones: tombstones)
    }

    public func computer(_ id: Computer.ID) -> Computer? {
        computers.first { $0.id == id }
    }

    public func group(_ id: ComputerGroup.ID) -> ComputerGroup? {
        groups.first { $0.id == id }
    }

    public var favorites: [Computer] {
        computers.filter(\.isFavorite)
    }

    /// Computers that have been connected to, most recent first.
    public var recents: [Computer] {
        computers
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    /// The group a computer is in. A computer can name a group that is not
    /// here — deleted elsewhere, or not synced yet — and is then in none.
    public func group(of computer: Computer) -> ComputerGroup? {
        computer.groupID.flatMap(group)
    }

    /// The computers in a group, or those in no group for `nil`.
    public func computers(in group: ComputerGroup.ID?) -> [Computer] {
        computers.filter { self.group(of: $0)?.id == group }
    }

    public var allTags: [String] {
        Array(Set(computers.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// A saved computer that points at the same address, if there is one.
    public func existingComputer(host: String, port: Int) -> Computer? {
        let needle = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return computers.first {
            $0.port == port
                && $0.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == needle
        }
    }

    // MARK: - Stamping changes

    /// A modification time for a change made now to something last stamped at
    /// `previous`.
    ///
    /// Merging trusts timestamps, and clocks disagree: the copy being changed
    /// may have been stamped by a device whose clock runs ahead, or this
    /// clock may have been set back. A change stamped with the bare time of
    /// day could then be older than what it replaced, and the next merge
    /// would quietly put the old version back. So a change is always stamped
    /// later than what it was made from — by the smallest step there is when
    /// the clock does not already say so, to keep the true order of changes
    /// that follow closely on one another.
    private static func stamp(after previous: Date?, now: Date = .now) -> Date {
        guard let previous else { return now }
        let next = Date(timeIntervalSinceReferenceDate: previous.timeIntervalSinceReferenceDate.nextUp)
        return max(now, next)
    }

    // MARK: - Computers

    @discardableResult
    public func add(_ computer: Computer) -> Computer {
        var copy = computer
        let now = Date.now
        copy.createdAt = now
        // Outrank the deletion of an earlier computer with the same identity.
        copy.modifiedAt = Self.stamp(after: tombstones[copy.id.uuidString], now: now)
        copy.sortIndex = Computer.sortIndex(after: computers.map(\.sortIndex))
        tombstones[copy.id.uuidString] = nil
        computers.append(copy)
        didChange()
        return copy
    }

    public func update(_ computer: Computer) {
        guard let index = computers.firstIndex(where: { $0.id == computer.id }) else {
            add(computer)
            return
        }
        var copy = computer
        copy.sortIndex = Computer.clampedSortIndex(copy.sortIndex)
        guard computers[index] != copy else { return }
        copy.modifiedAt = Self.stamp(after: computers[index].modifiedAt)
        computers[index] = copy
        didChange()
    }

    /// Applies an in-place edit to one computer.
    public func update(_ id: Computer.ID, _ edit: (inout Computer) -> Void) {
        guard var computer = computer(id) else { return }
        edit(&computer)
        update(computer)
    }

    public func delete(_ ids: Set<Computer.ID>) {
        guard !ids.isEmpty else { return }
        let now = Date.now
        for computer in computers where ids.contains(computer.id) {
            tombstones[computer.id.uuidString] = Self.stamp(after: computer.modifiedAt, now: now)
        }
        computers.removeAll { ids.contains($0.id) }
        didChange()
    }

    public func delete(_ id: Computer.ID) {
        delete([id])
    }

    @discardableResult
    public func duplicate(_ id: Computer.ID) -> Computer? {
        guard var copy = computer(id) else { return nil }
        copy.id = UUID()
        copy.name = "\(copy.displayName) Copy"
        copy.lastConnectedAt = nil
        copy.isFavorite = false
        return add(copy)
    }

    public func toggleFavorite(_ id: Computer.ID) {
        update(id) { $0.isFavorite.toggle() }
    }

    /// Records that a computer was connected to just now.
    ///
    /// This is not an edit and leaves `modifiedAt` alone. Otherwise simply
    /// connecting from a device that had not synced yet would outrank, and
    /// undo, a change made to the computer on another device.
    public func markConnected(_ id: Computer.ID) {
        guard let index = computers.firstIndex(where: { $0.id == id }) else { return }
        // Later than the last clearing, or it would not count.
        computers[index].lastConnectedAt = Self.stamp(after: computers[index].connectionsClearedAt)
        didChange()
    }

    public func clearRecents() {
        var changed = false
        let now = Date.now
        for index in computers.indices {
            guard let connected = computers[index].lastConnectedAt else { continue }
            computers[index].lastConnectedAt = nil
            // Remembered, so that a copy elsewhere that still has the
            // connection does not bring it back.
            computers[index].connectionsClearedAt = Self.stamp(after: connected, now: now)
            computers[index].modifiedAt = Self.stamp(after: computers[index].modifiedAt, now: now)
            changed = true
        }
        if changed { didChange() }
    }

    /// Reorders the computers shown in a manually sorted list.
    ///
    /// `visible` is the list as displayed; the move is expressed in its
    /// indices, exactly as SwiftUI's `onMove` reports it.
    public func move(_ visible: [Computer.ID], fromOffsets: IndexSet, toOffset: Int) {
        var order = visible
        let moving = fromOffsets.map { order[$0] }
        let adjustedTarget = toOffset - fromOffsets.filter { $0 < toOffset }.count
        order.removeAll { moving.contains($0) }
        order.insert(contentsOf: moving, at: min(max(0, adjustedTarget), order.count))

        let slots = visible
            .compactMap { id in computers.first { $0.id == id }?.sortIndex }
            .sorted()
        guard slots.count == order.count, order != visible else { return }

        var positions: [Computer.ID: Int] = [:]
        if zip(slots, slots.dropFirst()).allSatisfy({ $0 < $1 }) {
            // The moved computers trade places among the slots they held.
            positions = Dictionary(uniqueKeysWithValues: zip(order, slots))
        } else {
            // Some share a slot — routine after a sync, since every device
            // numbers its own computers from zero — and trading equal numbers
            // would change nothing. Number the whole library afresh, with the
            // visible computers taking their new order in the places the
            // visible ones occupy.
            let visibleIDs = Set(visible)
            var reordered = order.makeIterator()
            for (position, computer) in computers.enumerated() {
                let id = visibleIDs.contains(computer.id) ? reordered.next() ?? computer.id : computer.id
                positions[id] = position
            }
        }
        for index in computers.indices {
            guard let position = positions[computers[index].id],
                  computers[index].sortIndex != position else { continue }
            computers[index].sortIndex = position
            computers[index].modifiedAt = Self.stamp(after: computers[index].modifiedAt)
        }
        computers.sort(by: Computer.precedesInLibrary)
        didChange()
    }

    // MARK: - Groups

    @discardableResult
    public func addGroup(named name: String, symbolName: String = "folder") -> ComputerGroup {
        let group = ComputerGroup(
            name: name,
            symbolName: symbolName,
            sortIndex: Computer.sortIndex(after: groups.map(\.sortIndex)))
        groups.append(group)
        didChange()
        return group
    }

    public func update(_ group: ComputerGroup) {
        var copy = group
        copy.sortIndex = Computer.clampedSortIndex(copy.sortIndex)
        guard let index = groups.firstIndex(where: { $0.id == group.id }),
              groups[index] != copy else { return }
        copy.modifiedAt = Self.stamp(after: groups[index].modifiedAt)
        groups[index] = copy
        didChange()
    }

    /// Deletes a group. Its computers are kept and become ungrouped.
    public func deleteGroup(_ id: ComputerGroup.ID) {
        guard let group = group(id) else { return }
        tombstones[id.uuidString] = Self.stamp(after: group.modifiedAt)
        groups.removeAll { $0.id == id }
        for index in computers.indices where computers[index].groupID == id {
            computers[index].groupID = nil
            computers[index].modifiedAt = Self.stamp(after: computers[index].modifiedAt)
        }
        didChange()
    }

    public func moveGroups(fromOffsets: IndexSet, toOffset: Int) {
        var order = groups
        let moving = fromOffsets.map { order[$0] }
        let adjustedTarget = toOffset - fromOffsets.filter { $0 < toOffset }.count
        order.removeAll { group in moving.contains { $0.id == group.id } }
        order.insert(contentsOf: moving, at: min(max(0, adjustedTarget), order.count))
        for index in order.indices where order[index].sortIndex != index {
            order[index].sortIndex = index
            order[index].modifiedAt = Self.stamp(after: order[index].modifiedAt)
        }
        groups = order
        didChange()
    }

    // MARK: - Sync and backup

    /// Folds another copy of the library into this one. Used by iCloud sync;
    /// the result is saved but not re-announced through ``onChange``.
    /// - Returns: `true` when the merge changed anything locally.
    @discardableResult
    public func merge(_ remote: LibraryDocument) -> Bool {
        let merged = LibraryDocument.merge(document, remote)
        guard merged != document else { return false }
        apply(merged)
        scheduleSave()
        return true
    }

    public func exportBackup() throws -> Data {
        try document.encoded()
    }

    public enum ImportStrategy: Sendable {
        /// Keep what is here and add or update from the backup.
        case merge
        /// Discard what is here and use the backup as is.
        case replace
    }

    /// Brings a backup into the library.
    ///
    /// Restoring is a deliberate act, so what the backup holds outranks
    /// whatever happened to those computers and groups since it was made —
    /// later edits and later deletions alike, here and, once synced, on the
    /// user's other devices.
    public func importBackup(_ data: Data, strategy: ImportStrategy) throws {
        var incoming = try LibraryDocument.decode(data)
        let now = Date.now
        let current = document

        // What is known about each item so far, to stamp the restored copy
        // later than all of it.
        var latest = current.tombstones.merging(incoming.tombstones) { max($0, $1) }
        for computer in current.computers {
            latest[computer.id.uuidString] = max(latest[computer.id.uuidString] ?? .distantPast, computer.modifiedAt)
        }
        for group in current.groups {
            latest[group.id.uuidString] = max(latest[group.id.uuidString] ?? .distantPast, group.modifiedAt)
        }
        for index in incoming.computers.indices {
            let id = incoming.computers[index].id.uuidString
            incoming.computers[index].modifiedAt = Self.stamp(
                after: max(latest[id] ?? .distantPast, incoming.computers[index].modifiedAt), now: now)
        }
        for index in incoming.groups.indices {
            let id = incoming.groups[index].id.uuidString
            incoming.groups[index].modifiedAt = Self.stamp(
                after: max(latest[id] ?? .distantPast, incoming.groups[index].modifiedAt), now: now)
        }
        let restored = Set(incoming.computers.map(\.id.uuidString) + incoming.groups.map(\.id.uuidString))

        switch strategy {
        case .merge:
            apply(LibraryDocument.merge(current, incoming, now: now))
        case .replace:
            var replaced = incoming
            // Deletions made here still stand for anything the backup does
            // not bring back, and everything it leaves out is deleted too.
            replaced.tombstones.merge(current.tombstones) { max($0, $1) }
            for computer in current.computers where !restored.contains(computer.id.uuidString) {
                replaced.tombstones[computer.id.uuidString] = Self.stamp(after: computer.modifiedAt, now: now)
            }
            for group in current.groups where !restored.contains(group.id.uuidString) {
                replaced.tombstones[group.id.uuidString] = Self.stamp(after: group.modifiedAt, now: now)
            }
            for id in restored {
                replaced.tombstones[id] = nil
            }
            apply(replaced)
        }
        didChange()
    }

    /// Removes every computer and group, here and — through sync — on the
    /// user's other devices.
    public func eraseAll() {
        let now = Date.now
        for computer in computers {
            tombstones[computer.id.uuidString] = Self.stamp(after: computer.modifiedAt, now: now)
        }
        for group in groups {
            tombstones[group.id.uuidString] = Self.stamp(after: group.modifiedAt, now: now)
        }
        computers = []
        groups = []
        didChange()
    }

    /// Forgets the library on this device only: nothing is recorded as
    /// deleted, so nothing is removed from the user's other devices. Sync has
    /// to be off first, or the next pass brings everything back.
    public func eraseThisDeviceOnly() {
        computers = []
        groups = []
        tombstones = [:]
        saveNow()
    }

    // MARK: - Automatic backups

    public static let maximumAutomaticBackups = 10

    public struct BackupFile: Identifiable, Hashable, Sendable {
        public let url: URL
        public let date: Date
        public let computerCount: Int
        public var id: URL { url }
    }

    /// Writes a dated copy of the library, at most once per calendar day, and
    /// trims the oldest copies beyond ``maximumAutomaticBackups``.
    public func writeAutomaticBackupIfNeeded(now: Date = .now) {
        guard let backupsDirectory, !computers.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = backupsDirectory.appending(path: "Library \(formatter.string(from: now)).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try document.encoded().write(to: url, options: .atomic)
        } catch {
            lastError = "Could not write the automatic backup: \(error.localizedDescription)"
            return
        }
        let existing = automaticBackups()
        for stale in existing.dropFirst(LibraryStore.maximumAutomaticBackups) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    /// Automatic backups, newest first.
    public func automaticBackups() -> [BackupFile] {
        guard let backupsDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: backupsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> BackupFile? in
                guard let data = try? Data(contentsOf: url),
                      let document = try? LibraryDocument.decode(data) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return BackupFile(url: url, date: date, computerCount: document.computers.count)
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Persistence

    private func apply(_ document: LibraryDocument) {
        computers = document.computers.sorted(by: Computer.precedesInLibrary)
        groups = document.groups.sorted(by: ComputerGroup.precedesInLibrary)
        tombstones = document.tombstones
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            apply(try LibraryDocument.decode(Data(contentsOf: fileURL)))
        } catch {
            // Never overwrite a file we could not read: keep it aside so the
            // data can still be recovered by hand.
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            lastError = "The library file could not be read and was set aside as \(aside.lastPathComponent)."
        }
    }

    private func didChange() {
        scheduleSave()
        onChange?(document)
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes any pending change immediately. Call before the app suspends.
    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        do {
            try document.encoded().write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save the library: \(error.localizedDescription)"
        }
    }
}

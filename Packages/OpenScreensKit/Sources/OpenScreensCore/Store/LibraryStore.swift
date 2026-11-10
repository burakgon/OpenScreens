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

    public func computers(in group: ComputerGroup.ID?) -> [Computer] {
        computers.filter { $0.groupID == group }
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

    // MARK: - Computers

    @discardableResult
    public func add(_ computer: Computer) -> Computer {
        var copy = computer
        copy.createdAt = .now
        copy.modifiedAt = .now
        copy.sortIndex = (computers.map(\.sortIndex).max() ?? -1) + 1
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
        guard computers[index] != computer else { return }
        var copy = computer
        copy.modifiedAt = .now
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
        for id in ids where computers.contains(where: { $0.id == id }) {
            tombstones[id.uuidString] = now
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

    public func markConnected(_ id: Computer.ID) {
        update(id) { $0.lastConnectedAt = .now }
    }

    public func clearRecents() {
        var changed = false
        for index in computers.indices where computers[index].lastConnectedAt != nil {
            computers[index].lastConnectedAt = nil
            computers[index].modifiedAt = .now
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
        guard slots.count == order.count else { return }
        for (id, slot) in zip(order, slots) {
            guard let index = computers.firstIndex(where: { $0.id == id }),
                  computers[index].sortIndex != slot else { continue }
            computers[index].sortIndex = slot
            computers[index].modifiedAt = .now
        }
        computers.sort { $0.sortIndex < $1.sortIndex }
        didChange()
    }

    // MARK: - Groups

    @discardableResult
    public func addGroup(named name: String, symbolName: String = "folder") -> ComputerGroup {
        let group = ComputerGroup(
            name: name,
            symbolName: symbolName,
            sortIndex: (groups.map(\.sortIndex).max() ?? -1) + 1)
        groups.append(group)
        didChange()
        return group
    }

    public func update(_ group: ComputerGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }),
              groups[index] != group else { return }
        var copy = group
        copy.modifiedAt = .now
        groups[index] = copy
        didChange()
    }

    /// Deletes a group. Its computers are kept and become ungrouped.
    public func deleteGroup(_ id: ComputerGroup.ID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        tombstones[id.uuidString] = .now
        groups.removeAll { $0.id == id }
        for index in computers.indices where computers[index].groupID == id {
            computers[index].groupID = nil
            computers[index].modifiedAt = .now
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
            order[index].modifiedAt = .now
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

    public func importBackup(_ data: Data, strategy: ImportStrategy) throws {
        let incoming = try LibraryDocument.decode(data)
        switch strategy {
        case .merge:
            apply(LibraryDocument.merge(document, incoming))
        case .replace:
            let now = Date.now
            var replaced = incoming
            let kept = Set(incoming.computers.map(\.id.uuidString) + incoming.groups.map(\.id.uuidString))
            for id in computers.map(\.id.uuidString) + groups.map(\.id.uuidString) where !kept.contains(id) {
                replaced.tombstones[id] = now
            }
            apply(replaced)
        }
        didChange()
    }

    /// Removes every computer and group.
    public func eraseAll() {
        let now = Date.now
        for id in computers.map(\.id.uuidString) + groups.map(\.id.uuidString) {
            tombstones[id] = now
        }
        computers = []
        groups = []
        didChange()
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
        computers = document.computers.sorted { $0.sortIndex < $1.sortIndex }
        groups = document.groups.sorted { $0.sortIndex < $1.sortIndex }
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

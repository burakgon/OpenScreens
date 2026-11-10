import OpenScreensCore
import SwiftUI

/// The library's sidebar: built-in sections, the user's groups and tags.
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: LibraryFilter?

    @State private var renamingGroup: ComputerGroup?
    @State private var groupName = ""
    @State private var showsNewGroup = false

    var body: some View {
        List(selection: $filter) {
            Section {
                row(.all, count: model.library.computers.count)
                row(.favorites, count: model.library.favorites.count)
                row(.recents, count: model.library.recents.count)
            }

            Section("Groups") {
                ForEach(model.library.groups) { group in
                    Label(group.name, systemImage: group.symbolName)
                        .badge(model.library.computers(in: group.id).count)
                        .tag(LibraryFilter.group(group.id))
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                groupName = group.name
                                renamingGroup = group
                            }
                            Button("Delete Group", systemImage: "trash", role: .destructive) {
                                if filter == .group(group.id) { filter = .all }
                                model.library.deleteGroup(group.id)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            move(items, to: group.id)
                        }
                }
                .onMove { offsets, destination in
                    model.library.moveGroups(fromOffsets: offsets, toOffset: destination)
                }

                Button("New Group", systemImage: "plus") {
                    groupName = ""
                    showsNewGroup = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            let tags = model.library.allTags
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        Label(tag, systemImage: "number")
                            .tag(LibraryFilter.tag(tag))
                    }
                }
            }
        }
        .navigationTitle("OpenScreens")
        .alert("New Group", isPresented: $showsNewGroup) {
            TextField("Name", text: $groupName)
            Button("Create") {
                let name = groupName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let group = model.library.addGroup(named: name)
                filter = .group(group.id)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename Group",
            isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } })
        ) {
            TextField("Name", text: $groupName)
            Button("Rename") {
                let name = groupName.trimmingCharacters(in: .whitespaces)
                if var group = renamingGroup, !name.isEmpty {
                    group.name = name
                    model.library.update(group)
                }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) {
                renamingGroup = nil
            }
        }
    }

    private func row(_ item: LibraryFilter, count: Int) -> some View {
        Label(item.title(in: model.library), systemImage: item.symbolName)
            .badge(count)
            .tag(item)
    }

    /// Handles computers dropped on a group. The payload is the computer's ID.
    private func move(_ items: [String], to group: UUID) {
        for id in items.compactMap(UUID.init(uuidString:)) {
            model.library.update(id) { $0.groupID = group }
        }
    }
}

/// The menu for one computer, used as a context menu and from the "more" button.
struct ComputerMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.libraryActions) private var actions
    let computer: Computer

    var body: some View {
        Button("Connect", systemImage: "play.fill") {
            actions.connect(computer, nil)
        }

        Menu("Connect Using", systemImage: "slider.horizontal.3") {
            ForEach(QualityMode.allCases) { quality in
                if quality != .highPerformance || computer.kind.isApple {
                    Button(quality.title, systemImage: quality.symbolName) {
                        actions.connect(computer) { $0.quality = quality }
                    }
                }
            }
            Divider()
            Button("Observe Only", systemImage: "eye") {
                actions.connect(computer) { $0.observeOnly = true }
            }
        }

        Divider()

        Button("Edit…", systemImage: "pencil") {
            actions.edit(computer)
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.library.duplicate(computer.id)
        }
        Button(
            computer.isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: computer.isFavorite ? "star.slash" : "star"
        ) {
            model.library.toggleFavorite(computer.id)
        }

        if !model.library.groups.isEmpty {
            Menu("Move to Group", systemImage: "folder") {
                Button("None") {
                    model.library.update(computer.id) { $0.groupID = nil }
                }
                .disabled(computer.groupID == nil)
                Divider()
                ForEach(model.library.groups) { group in
                    Button(group.name, systemImage: group.symbolName) {
                        model.library.update(computer.id) { $0.groupID = group.id }
                    }
                    .disabled(computer.groupID == group.id)
                }
            }
        }

        Divider()

        Button("Copy Address", systemImage: "doc.on.doc") {
            Pasteboard.copy(computer.displayAddress)
        }
        if let url = ConnectionTarget.url(for: computer) {
            ShareLink("Share Link", item: url)
        }

        Divider()

        Button("Delete…", systemImage: "trash", role: .destructive) {
            actions.delete([computer.id])
        }
    }
}

/// Minimal cross-platform pasteboard access.
enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static var string: String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}

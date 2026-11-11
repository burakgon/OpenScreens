import OpenScreensCore
import SwiftUI

/// The library: every saved computer, organised by the sidebar.
public struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    #endif

    @State private var filter: LibraryFilter?
    @State private var searchText = ""
    @State private var selection = Set<Computer.ID>()
    @State private var editor: ComputerEditor.Request?
    @State private var showsQuickConnect = false
    @State private var pendingDeletion: Set<Computer.ID> = []
    @State private var showsDeleteConfirmation = false
    #if os(iOS)
    @State private var presentedSession: RemoteSession?
    @State private var showsSettings = false
    @State private var filesComputer: Computer?
    #endif

    /// - Parameter section: The section of the library to open at.
    public init(showing section: LibraryFilter = .all) {
        _filter = State(initialValue: section)
    }

    private var activeFilter: LibraryFilter { filter ?? .all }

    private var visibleComputers: [Computer] {
        let matching = activeFilter.computers(in: model.library).filter { $0.matches(searchText) }
        return activeFilter.hasIntrinsicOrder ? matching : model.settings.librarySort.sorted(matching)
    }

    public var body: some View {
        NavigationSplitView {
            LibrarySidebar(filter: $filter)
                .navigationSplitViewColumnWidth(min: 190, ideal: 224, max: 320)
        } detail: {
            content
                .navigationTitle(activeFilter.title(in: model.library))
                .toolbar { toolbar }
        }
        .searchable(text: $searchText, prompt: "Search Computers")
        .sheet(item: $editor) { request in
            ComputerEditor(request: request)
        }
        .sheet(isPresented: $showsQuickConnect) {
            QuickConnectView { target in
                connect(to: target)
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.delete(pendingDeletion)
                selection.subtract(pendingDeletion)
                pendingDeletion = []
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = []
            }
        } message: {
            Text("Saved passwords for the deleted computers are removed from the keychain too.")
        }
        .environment(\.libraryActions, actions)
        .onOpenURL { url in
            if let link = AppLink(url: url) {
                open(link)
            }
        }
        .onChange(of: model.pendingLink, initial: true) { _, link in
            guard let link else { return }
            model.pendingLink = nil
            open(link)
        }
        #if DEBUG
        .task {
            DebugSampleData.seedIfRequested(model: model)
            if let section = DebugAutomation.requestedSection {
                filter = section
            }
            DebugAutomation.runIfRequested(model: model) { present($0) }
            DebugAutomation.runFilesIfRequested(model: model) { browseFiles(on: $0) }
            if ProcessInfo.processInfo.environment["OPENSCREENS_EDIT"] == "first",
               let computer = model.library.computers.first {
                editor = .edit(computer)
            }
            #if os(macOS)
            if ProcessInfo.processInfo.environment["OPENSCREENS_SETTINGS"] != nil {
                openSettings()
            }
            #endif
        }
        #endif
        #if os(iOS)
        .fullScreenCover(item: $presentedSession) { session in
            SessionScreen(session: session) {
                model.sessions.close(session)
                presentedSession = nil
            }
            .environment(model)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
                .environment(model)
        }
        .sheet(item: $filesComputer) { computer in
            FileBrowserView(computer: computer)
                .environment(model)
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let computers = visibleComputers
        if activeFilter == .nearby {
            NearbyContent(searchText: searchText)
        } else if activeFilter == .tailscale {
            TailscaleContent(searchText: searchText)
        } else if model.library.computers.isEmpty {
            EmptyLibraryView(
                onAdd: { addComputer() },
                onQuickConnect: { showsQuickConnect = true })
        } else if computers.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: activeFilter.symbolName,
                    description: Text(emptyDescription))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            switch model.settings.libraryLayout {
            case .grid:
                grid(computers)
            case .list:
                list(computers)
            }
        }
    }

    private var emptyDescription: String {
        switch activeFilter {
        case .favorites: "Mark a computer as a favorite to keep it here."
        case .recents: "Computers you connect to will appear here."
        case .group: "Drag computers here, or choose Move to Group from a computer's menu."
        default: "No computers match."
        }
    }

    private func grid(_ computers: [Computer]) -> some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(computers) { computer in
                    ComputerCard(computer: computer, isSelected: selection.contains(computer.id))
                        #if os(macOS)
                        .onTapGesture(count: 2) { connect(to: computer) }
                        .simultaneousGesture(TapGesture().onEnded { select(computer.id) })
                        #else
                        .onTapGesture { connect(to: computer) }
                        #endif
                        .contextMenu { ComputerMenu(computer: computer) }
                        .draggable(computer.id.uuidString)
                }
            }
            .padding(16)
        }
        #if os(macOS)
        .background {
            // Clicking empty space clears the selection.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { selection = [] }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let id = selection.first, let computer = model.library.computer(id) else {
                return .ignored
            }
            connect(to: computer)
            return .handled
        }
        .onDeleteCommand {
            requestDeletion(selection)
        }
        #endif
    }

    /// Two columns on a phone, as many as fit comfortably everywhere else.
    private var gridColumns: [GridItem] {
        sizeClass == .compact
            ? [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 10)]
            : [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12)]
    }

    private func list(_ computers: [Computer]) -> some View {
        List(selection: $selection) {
            ForEach(computers) { computer in
                ComputerRow(computer: computer)
                    .tag(computer.id)
                    .contextMenu { ComputerMenu(computer: computer) }
                    #if os(iOS)
                    .onTapGesture { connect(to: computer) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            requestDeletion([computer.id])
                        }
                        Button("Edit", systemImage: "pencil") {
                            editor = .edit(computer)
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button(
                            computer.isFavorite ? "Unfavorite" : "Favorite",
                            systemImage: computer.isFavorite ? "star.slash" : "star"
                        ) {
                            model.library.toggleFavorite(computer.id)
                        }
                        .tint(.yellow)
                    }
                    #endif
            }
            .onMove(perform: canReorder ? { offsets, destination in
                model.library.move(computers.map(\.id), fromOffsets: offsets, toOffset: destination)
            } : nil)
        }
        #if os(macOS)
        .contextMenu(forSelectionType: Computer.ID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let computer = model.library.computer(id) {
                connect(to: computer)
            }
        }
        .onDeleteCommand {
            requestDeletion(selection)
        }
        #endif
    }

    /// Manual order only means something when the whole section is visible
    /// in that order.
    private var canReorder: Bool {
        model.settings.librarySort == .manual && searchText.isEmpty && !activeFilter.hasIntrinsicOrder
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Quick Connect", systemImage: "bolt") {
                showsQuickConnect = true
            }
            .help("Connect to an address without saving it")

            Button("Add Computer", systemImage: "plus") {
                addComputer()
            }
            .help("Add a computer to the library")
        }

        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") {
                showsSettings = true
            }
        }
        #endif

        ToolbarItem(placement: .secondaryAction) {
            @Bindable var settings = model.settings
            Menu("View Options", systemImage: "line.3.horizontal.decrease") {
                Picker("Layout", selection: $settings.libraryLayout) {
                    ForEach(LibraryLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbolName).tag(layout)
                    }
                }
                .pickerStyle(.inline)
                Picker("Sort By", selection: $settings.librarySort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }

    // MARK: - Actions

    private var actions: LibraryActions {
        LibraryActions(
            connect: { computer, configure in connect(to: computer, configure: configure) },
            open: { connect(to: $0) },
            browseFiles: { browseFiles(on: $0) },
            edit: { editor = .edit($0) },
            delete: { requestDeletion($0) },
            add: { addComputer($0) })
    }

    private func select(_ id: Computer.ID) {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            return
        }
        #endif
        selection = [id]
    }

    private func addComputer(_ template: Computer? = nil) {
        var computer = template ?? Computer(name: "", host: "", settings: model.settings.defaultConnection)
        if case .group(let id) = activeFilter, template == nil {
            computer.groupID = id
        }
        editor = .new(computer)
        if template == nil, activeFilter.isDiscovery {
            // A computer added by hand goes to the library, not to a list
            // of what was found.
            filter = .all
        }
    }

    private func requestDeletion(_ ids: Set<Computer.ID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
        showsDeleteConfirmation = true
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1,
           let id = pendingDeletion.first,
           let computer = model.library.computer(id) {
            return "Delete “\(computer.displayName)”?"
        }
        return "Delete \(pendingDeletion.count) Computers?"
    }

    private func connect(
        to computer: Computer,
        configure: ((inout ConnectionSettings) -> Void)? = nil
    ) {
        present(model.sessions.open(computer, configure: configure))
    }

    private func connect(to target: ConnectionTarget) {
        present(model.sessions.open(target))
    }

    private func browseFiles(on computer: Computer) {
        #if os(macOS)
        openWindow(id: WindowID.files, value: computer)
        #else
        filesComputer = computer
        #endif
    }

    private func open(_ link: AppLink) {
        switch link {
        case .computer(let id):
            if let computer = model.library.computer(id) {
                connect(to: computer)
            }
        case .target(let target):
            connect(to: target)
        }
    }

    private func present(_ session: RemoteSession) {
        #if os(macOS)
        openWindow(id: WindowID.session, value: session.id)
        #else
        presentedSession = session
        #endif
    }
}

// MARK: - Actions shared with child views

/// What rows, cards and menus can ask the library to do. Passed through the
/// environment so deeply nested views do not need a chain of closures.
struct LibraryActions {
    var connect: (Computer, ((inout ConnectionSettings) -> Void)?) -> Void = { _, _ in }
    /// Connects to an address that is not in the library.
    var open: (ConnectionTarget) -> Void = { _ in }
    /// Shows a computer's files.
    var browseFiles: (Computer) -> Void = { _ in }
    var edit: (Computer) -> Void = { _ in }
    var delete: (Set<Computer.ID>) -> Void = { _ in }
    var add: (Computer?) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var libraryActions = LibraryActions()
}

// MARK: - Empty state

private struct EmptyLibraryView: View {
    let onAdd: () -> Void
    let onQuickConnect: () -> Void

    var body: some View {
        // A scroll view, so that the text is never squeezed and a short
        // window still reaches all of it. It also keeps the height this
        // needs from becoming the least height of the split view: on the
        // Mac, a split view taller than its window is centred in it, which
        // puts the top of the sidebar out of sight.
        ScrollView {
            message
                .padding(32)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var message: some View {
        VStack(spacing: 22) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 58, weight: .ultraLight))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("Welcome to OpenScreens")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("Control your Mac, PC or Raspberry Pi from anywhere. Add a computer to get started.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    quickConnectButton
                    addButton
                }
                VStack(spacing: 10) {
                    addButton
                    quickConnectButton
                }
            }
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 8) {
                tip("macbook", "On the Mac you want to control, turn on Screen Sharing in System Settings › General › Sharing.")
                tip("bolt.fill", "Apple silicon Macs connect in High Performance mode, with sound and a desktop sized to fit.")
                tip("lock.fill", "Away from home? Connect over Tailscale or through an SSH tunnel.")
            }
            .padding(.top, 8)
            .frame(maxWidth: 460)
        }
    }

    private var quickConnectButton: some View {
        Button(action: onQuickConnect) {
            Label("Quick Connect", systemImage: "bolt")
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.glass)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Label("Add Computer", systemImage: "plus")
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.glassProminent)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

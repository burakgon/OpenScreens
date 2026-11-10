import OpenScreensCore
import SwiftUI
import UniformTypeIdentifiers

/// The app's settings. A tabbed window on the Mac, a navigation list on
/// iPhone and iPad — the panes themselves are shared.
public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @State private var pane = SettingsView.initialPane
    #endif

    public init() {}

    #if os(macOS)
    /// The panes of the Mac's Settings window.
    enum Pane: String, Hashable {
        case general, connections, shortcuts, tailscale, sshKeys, privacy, about
    }

    private static var initialPane: Pane {
        #if DEBUG
        // Lets a scripted launch open Settings on a given pane.
        if let requested = ProcessInfo.processInfo.environment["OPENSCREENS_SETTINGS"].flatMap(Pane.init(rawValue:)) {
            return requested
        }
        #endif
        return .general
    }
    #endif

    public var body: some View {
        #if os(macOS)
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralSettingsPane()
            }
            Tab("Connections", systemImage: "slider.horizontal.3", value: Pane.connections) {
                DefaultConnectionPane()
            }
            Tab("Shortcuts", systemImage: "command", value: Pane.shortcuts) {
                ShortcutsSettingsPane()
            }
            Tab("Tailscale", systemImage: "point.3.connected.trianglepath.dotted", value: Pane.tailscale) {
                TailscaleSettingsPane()
            }
            Tab("SSH Keys", systemImage: "key", value: Pane.sshKeys) {
                SSHKeysSettingsPane()
            }
            Tab("Privacy", systemImage: "hand.raised", value: Pane.privacy) {
                PrivacySettingsPane()
            }
            Tab("About", systemImage: "info.circle", value: Pane.about) {
                AboutPane()
            }
        }
        .scenePadding()
        .frame(width: 620, height: 560)
        #else
        NavigationStack {
            List {
                Section {
                    link("General", "gearshape") { GeneralSettingsPane() }
                    link("Connection Defaults", "slider.horizontal.3") { DefaultConnectionPane() }
                    link("Shortcuts", "command") { ShortcutsSettingsPane() }
                }
                Section {
                    link("Tailscale", "point.3.connected.trianglepath.dotted") { TailscaleSettingsPane() }
                    link("SSH Keys", "key") { SSHKeysSettingsPane() }
                }
                Section {
                    link("Privacy & Backup", "hand.raised") { PrivacySettingsPane() }
                    link("About", "info.circle") { AboutPane() }
                }
            }
            .navigationTitle("Settings")
        }
        #endif
    }

    #if os(iOS)
    private func link<Destination: View>(
        _ title: String,
        _ symbol: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
    #endif
}

// MARK: - General

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Library") {
                Picker("Layout", selection: $settings.libraryLayout) {
                    ForEach(LibraryLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Picker("Sort By", selection: $settings.librarySort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                Toggle("Show Nearby Computers", isOn: $settings.showsNearbyComputers)
                #if os(macOS)
                Toggle("Show OpenScreens in the Menu Bar", isOn: $settings.showsMenuBarItem)
                #endif
            }

            Section {
                Toggle("Keep This Device Awake While Connected", isOn: $settings.keepsDisplayAwake)
                Toggle("Ask Before Disconnecting", isOn: $settings.confirmsDisconnect)
                Toggle("Show Connection Statistics", isOn: $settings.showsStatisticsOverlay)
                #if os(iOS)
                Toggle("Haptic Feedback", isOn: $settings.hapticFeedback)
                #endif
            } header: {
                Text("Sessions")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Connection defaults

struct DefaultConnectionPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                EmptyView()
            } footer: {
                Text("New computers and quick connections start with these settings. Each computer keeps its own copy afterwards.")
            }
            ConnectionSettingsForm(settings: $settings.defaultConnection, kind: .mac)
            Section {
                Button("Restore Defaults") {
                    settings.defaultConnection = ConnectionSettings()
                }
                .disabled(settings.defaultConnection == ConnectionSettings())
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RemoteShortcut?

    var body: some View {
        Form {
            Section {
                if model.settings.customShortcuts.isEmpty {
                    Text("No custom shortcuts yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.settings.customShortcuts) { shortcut in
                    Button {
                        editing = shortcut
                    } label: {
                        HStack {
                            Label(shortcut.name, systemImage: shortcut.symbolName)
                            Spacer()
                            KeyCap(shortcut.keyString)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.settings.customShortcuts.removeAll { $0.id == shortcut.id }
                        }
                    }
                }
                .onDelete { offsets in
                    model.settings.customShortcuts.remove(atOffsets: offsets)
                }
                .onMove { offsets, destination in
                    model.settings.customShortcuts.move(fromOffsets: offsets, toOffset: destination)
                }
                Button("Add Shortcut", systemImage: "plus") {
                    editing = RemoteShortcut(name: "", modifiers: [.command], key: .character("k"))
                }
            } header: {
                Text("My Shortcuts")
            } footer: {
                Text("Your shortcuts appear at the top of the Shortcuts menu in every session, alongside the built-in ones for each kind of computer.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { shortcut in
            ShortcutEditor(shortcut: shortcut) { saved in
                if let index = model.settings.customShortcuts.firstIndex(where: { $0.id == saved.id }) {
                    model.settings.customShortcuts[index] = saved
                } else {
                    model.settings.customShortcuts.append(saved)
                }
            }
        }
    }
}

private struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var shortcut: RemoteShortcut
    let onSave: (RemoteShortcut) -> Void

    private enum KeyKind: String, CaseIterable, Identifiable {
        case character = "Character"
        case special = "Special Key"
        case function = "Function Key"
        var id: Self { self }
    }

    @State private var keyKind = KeyKind.character
    @State private var character = "k"
    @State private var special = SpecialKey.returnKey
    @State private var function = 1

    private var key: RemoteKey {
        switch keyKind {
        case .character: .character(String(character.prefix(1)))
        case .special: .special(special)
        case .function: .function(function)
        }
    }

    private var isValid: Bool {
        !shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty && key.keysym != 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $shortcut.name, prompt: Text("Show Launchpad"))
                }
                Section("Modifiers") {
                    modifierToggle("⌃  Control", .control)
                    modifierToggle("⌥  Option / Alt", .option)
                    modifierToggle("⇧  Shift", .shift)
                    modifierToggle("⌘  Command / Windows", .command)
                }
                Section("Key") {
                    Picker("Type", selection: $keyKind) {
                        ForEach(KeyKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch keyKind {
                    case .character:
                        TextField("Character", text: $character)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onChange(of: character) { _, value in
                                if value.count > 1 { character = String(value.suffix(1)) }
                            }
                    case .special:
                        Picker("Key", selection: $special) {
                            ForEach(SpecialKey.allCases) { key in
                                Text(key.title).tag(key)
                            }
                        }
                    case .function:
                        Picker("Key", selection: $function) {
                            ForEach(1...20, id: \.self) { number in
                                Text("F\(number)").tag(number)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("Sends") {
                        KeyCap(shortcut.modifiers.symbols + key.glyph)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Shortcut")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = shortcut
                        saved.key = key
                        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
        .onAppear {
            switch shortcut.key {
            case .character(let value):
                keyKind = .character
                character = value
            case .special(let value):
                keyKind = .special
                special = value
            case .function(let value):
                keyKind = .function
                function = value
            }
        }
    }

    private func modifierToggle(_ title: String, _ modifier: KeyModifiers) -> some View {
        Toggle(title, isOn: Binding(
            get: { shortcut.modifiers.contains(modifier) },
            set: { isOn in
                if isOn {
                    shortcut.modifiers.insert(modifier)
                } else {
                    shortcut.modifiers.remove(modifier)
                }
            }))
    }
}

// MARK: - Privacy and backup

struct PrivacySettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showsEraseConfirmation = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: LibraryBackupDocument?
    @State private var importError: String?
    @State private var backups: [LibraryStore.BackupFile] = []

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Require \(BiometricGate.methodName) to Open", isOn: $settings.requiresAuthentication)
                Toggle("Remember What Each Screen Looked Like", isOn: $settings.savesSessionPreviews)
                Button("Clear Saved Previews") {
                    PreviewStore.shared.removeAll()
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Previews are small pictures of each computer's screen from your last session, shown in the library. They stay on this device.")
            }

            Section {
                Toggle("Sync Library with iCloud", isOn: $settings.syncsWithICloud)
                if settings.syncsWithICloud {
                    LabeledContent("Status") {
                        Text(syncStatus)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Keeps your computers and groups the same on all your devices. Passwords are never part of that: they stay in your keychain, and travel between devices only through iCloud Keychain if you use it.")
            }

            Section {
                Button("Export Library…", systemImage: "square.and.arrow.up") {
                    if let data = try? model.library.exportBackup() {
                        exportDocument = LibraryBackupDocument(data: data)
                        isExporting = true
                    }
                }
                Button("Import Library…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                if !backups.isEmpty {
                    Menu("Restore an Automatic Backup") {
                        ForEach(backups) { backup in
                            Button("\(backup.date.formatted(date: .abbreviated, time: .omitted)) — \(backup.computerCount) computers") {
                                restore(backup)
                            }
                        }
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Backups contain your computers and their settings, never passwords. OpenScreens also keeps a daily automatic backup on this device.")
            }

            Section {
                Button("Erase All Content and Settings…", role: .destructive) {
                    showsEraseConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { backups = model.library.automaticBackups() }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "OpenScreens Library"
        ) { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try model.library.importBackup(Data(contentsOf: url), strategy: .merge)
            } catch {
                importError = "That file is not an OpenScreens library backup."
            }
        }
        .alert("Couldn't Import", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(
            "Erase everything?",
            isPresented: $showsEraseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase on All My Devices", role: .destructive) {
                model.eraseAllContent(everywhere: true)
            }
            Button("Erase This Device Only", role: .destructive) {
                model.eraseAllContent(everywhere: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Erasing on all your devices removes every saved computer through iCloud, along with every saved password and SSH key. Erasing this device only removes the library, trusted servers, previews and preferences here, turns iCloud sync off on this device, and leaves your keychain alone. Neither can be undone.")
        }
    }

    private var syncStatus: String {
        switch model.sync.status {
        case .disabled: "Off"
        case .unavailable: "iCloud is not available on this device"
        case .syncing: "Syncing…"
        case .idle(let lastSync):
            lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Up to date"
        case .failed(let message): message
        }
    }

    private func restore(_ backup: LibraryStore.BackupFile) {
        guard let data = try? Data(contentsOf: backup.url) else { return }
        do {
            try model.library.importBackup(data, strategy: .merge)
        } catch {
            importError = "That backup could not be read."
        }
    }
}

/// A library backup as an exportable file.
struct LibraryBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                    Text("OpenScreens")
                        .font(.title2.weight(.semibold))
                    Text(version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Free and open-source remote desktop for Mac, iPhone and iPad.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Link(destination: AppLinks.repository) {
                    Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppLinks.issues) {
                    Label("Report a Problem", systemImage: "ladybug")
                }
                Link(destination: AppLinks.releases) {
                    Label("Release Notes", systemImage: "sparkles")
                }
            }

            Section {
                acknowledgement(
                    "rootshellVNC",
                    "RFB protocol engine with Apple Screen Sharing support. MIT License, © Rootshell LLC, Kit Knox.")
                acknowledgement(
                    "SwiftNIO and SwiftNIO SSH",
                    "Networking and SSH transport. Apache License 2.0, © Apple Inc. and the SwiftNIO project authors.")
                acknowledgement(
                    "BigInt",
                    "Arbitrary-precision arithmetic. MIT License, © Károly Lőrentey.")
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("OpenScreens is released under the MIT License. It is an independent project and is not affiliated with Apple Inc. or any other remote-desktop vendor.")
            }
        }
        .formStyle(.grouped)
    }

    private func acknowledgement(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import OpenScreensCore
import SwiftUI
import UniformTypeIdentifiers

/// A remote computer's files: browse, copy in, copy out.
public struct FileBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let computer: Computer

    @State private var browser: FileBrowser?
    @State private var selection = Set<SFTPItem.ID>()
    @State private var picker: Picker?
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var doomed: [SFTPItem] = []
    @State private var pendingUpload: [URL] = []
    @State private var pendingDownload: [SFTPItem] = []

    /// What the system file picker is open for. One picker serves both,
    /// because a view can only present one.
    private enum Picker: Identifiable {
        case upload, downloadDestination
        var id: Self { self }
    }

    private enum Naming: Identifiable {
        case newFolder
        case rename(SFTPItem)

        var id: String {
            switch self {
            case .newFolder: "new"
            case .rename(let item): item.id
            }
        }
    }

    public init(computer: Computer) {
        self.computer = computer
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let browser {
                    content(browser)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .task {
            guard browser == nil else { return }
            let browser = FileBrowser(
                computer: computer, credentials: model.credentials,
                sshKeys: model.sshKeys, knownHosts: model.knownHosts)
            self.browser = browser
            browser.start()
        }
        .onDisappear {
            browser?.close()
        }
        .fileImporter(
            isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
            allowedContentTypes: picker == .downloadDestination ? [.folder] : [.item, .folder],
            allowsMultipleSelection: picker == .upload
        ) { result in
            let purpose = picker
            picker = nil
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            switch purpose {
            case .upload: requestUpload(urls)
            case .downloadDestination:
                browser?.download(pendingDownload, to: urls[0])
                pendingDownload = []
            case nil: break
            }
        }
        .alert(
            namingTitle,
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
            presenting: naming
        ) { purpose in
            TextField("Name", text: $nameText)
                .autocorrectionDisabled()
            Button(purpose.id == "new" ? "Create" : "Rename") {
                switch purpose {
                case .newFolder: browser?.makeFolder(named: nameText)
                case .rename(let item): browser?.rename(item, to: nameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { !doomed.isEmpty }, set: { if !$0 { doomed = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                browser?.delete(doomed)
                selection = []
                doomed = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes them from \(computer.displayName) for good. Folders are deleted with everything in them.")
        }
        .confirmationDialog(
            replacementTitle,
            isPresented: Binding(get: { !pendingUpload.isEmpty }, set: { if !$0 { pendingUpload = [] } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                browser?.upload(pendingUpload)
                pendingUpload = []
            }
            Button("Skip Those") {
                let taken = Set(browser?.conflicts(for: pendingUpload) ?? [])
                browser?.upload(pendingUpload.filter { !taken.contains($0.lastPathComponent) })
                pendingUpload = []
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Files",
            isPresented: Binding(
                get: { browser?.errorMessage != nil },
                set: { if !$0 { browser?.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser?.errorMessage ?? "")
        }
    }

    private var title: String {
        guard let browser, browser.phase == .ready else { return computer.displayName }
        return browser.folderName == "/" ? computer.displayName : browser.folderName
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ browser: FileBrowser) -> some View {
        switch browser.phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(computer.displayName)…")
                    .foregroundStyle(.secondary)
            }
        case .signIn(let prompt):
            FileSignInCard(computer: computer, prompt: prompt) { username, password, remember in
                browser.submit(username: username, password: password, remember: remember)
            } onCancel: {
                dismiss()
            }
            .frame(maxWidth: 380)
            .padding(24)
        case .hostKey(let prompt):
            HostKeyCard(computer: computer, prompt: prompt) {
                browser.answerHostKey(trust: true)
            } onCancel: {
                browser.answerHostKey(trust: false)
                dismiss()
            }
            .frame(maxWidth: 380)
            .padding(24)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Show the Files", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    browser.start()
                }
                .buttonStyle(.glass)
            }
        case .ready:
            VStack(spacing: 0) {
                listing(browser)
                if !browser.transfers.isEmpty {
                    Divider()
                    TransferList(browser: browser)
                }
            }
        }
    }

    private func listing(_ browser: FileBrowser) -> some View {
        List(selection: $selection) {
            ForEach(browser.items) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .contextMenu { menu(for: item, in: browser) }
                    #if os(iOS)
                    .onTapGesture {
                        if item.isDirectory || item.isSymlink {
                            browser.open(item)
                        } else {
                            selection = selection == [item.id] ? [] : [item.id]
                        }
                    }
                    #endif
            }
        }
        #if os(macOS)
        .contextMenu(forSelectionType: SFTPItem.ID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let item = browser.items.first(where: { $0.id == id }) {
                browser.open(item)
            }
        }
        .onDeleteCommand {
            doomed = selected(in: browser)
        }
        #endif
        .dropDestination(for: URL.self) { urls, _ in
            requestUpload(urls.filter(\.isFileURL))
            return true
        }
        .overlay {
            if browser.items.isEmpty, !browser.isLoading {
                ContentUnavailableView(
                    "Nothing Here",
                    systemImage: "folder",
                    description: Text("Drop files here, or choose Upload, to copy them to this folder."))
            }
        }
        .onChange(of: browser.path) {
            selection = []
        }
    }

    @ViewBuilder
    private func menu(for item: SFTPItem, in browser: FileBrowser) -> some View {
        if item.isDirectory || item.isSymlink {
            Button("Open", systemImage: "folder") {
                browser.open(item)
            }
        }
        Button("Download…", systemImage: "arrow.down.circle") {
            pendingDownload = [item]
            picker = .downloadDestination
        }
        Button("Rename…", systemImage: "pencil") {
            nameText = item.name
            naming = .rename(item)
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            Pasteboard.copy(item.path)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            doomed = [item]
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Enclosing Folder", systemImage: "chevron.up") {
                browser?.goUp()
            }
            .disabled(browser?.parentPath == nil || browser?.phase != .ready)
            .help(browser?.parentPath ?? "")
        }
        #if os(iOS)
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Upload", systemImage: "arrow.up.circle") {
                picker = .upload
            }
            .disabled(browser?.phase != .ready)
            .help("Copy files from this device to this folder")

            Button("Download", systemImage: "arrow.down.circle") {
                if let browser {
                    pendingDownload = selected(in: browser)
                    picker = .downloadDestination
                }
            }
            .disabled(selection.isEmpty || browser?.phase != .ready)
            .help("Copy what is selected to this device")

            Menu("More", systemImage: "ellipsis.circle") {
                Button("New Folder…", systemImage: "folder.badge.plus") {
                    nameText = ""
                    naming = .newFolder
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    browser?.refresh()
                }
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { browser?.showsHiddenFiles ?? false },
                    set: { browser?.showsHiddenFiles = $0 }))
                if !selection.isEmpty {
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) {
                        if let browser { doomed = selected(in: browser) }
                    }
                }
            }
            .disabled(browser?.phase != .ready)
        }
    }

    // MARK: - Helpers

    private func selected(in browser: FileBrowser) -> [SFTPItem] {
        browser.items.filter { selection.contains($0.id) }
    }

    /// Uploads at once, unless something of the same name is already there.
    private func requestUpload(_ urls: [URL]) {
        guard let browser, !urls.isEmpty else { return }
        if browser.conflicts(for: urls).isEmpty {
            browser.upload(urls)
        } else {
            pendingUpload = urls
        }
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename" }
        return "New Folder"
    }

    private var deletionTitle: String {
        doomed.count == 1 ? "Delete “\(doomed[0].name)”?" : "Delete \(doomed.count) Items?"
    }

    private var replacementTitle: String {
        let names = browser?.conflicts(for: pendingUpload) ?? []
        return names.count == 1
            ? "“\(names[0])” is already in this folder."
            : "\(names.count) of these are already in this folder."
    }
}

// MARK: - Rows

private struct FileRow: View {
    let item: SFTPItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(item.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let modified = item.modified {
                Text(modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(item.isDirectory ? "—" : item.size.formatted(.byteCount(style: .file)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        if item.isDirectory { return "folder.fill" }
        if item.isSymlink { return "arrowshape.turn.up.right" }
        return "doc"
    }
}

/// Transfers under way and done, along the bottom.
private struct TransferList: View {
    let browser: FileBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if browser.transfers.contains(where: { !$0.isActive }) {
                    Button("Clear Finished") {
                        browser.clearFinishedTransfers()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            ForEach(browser.transfers.suffix(4)) { transfer in
                HStack(spacing: 10) {
                    Image(systemName: transfer.isUpload ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transfer.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        status(for: transfer)
                    }
                    if transfer.isActive {
                        Button("Stop", systemImage: "xmark.circle.fill") {
                            browser.cancel(transfer.id)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func status(for transfer: FileBrowser.Transfer) -> some View {
        switch transfer.state {
        case .waiting:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        case .finished:
            Text(transfer.isUpload ? "Uploaded" : "Downloaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

/// Asks for the Remote Login name and password.
private struct FileSignInCard: View {
    let computer: Computer
    let prompt: FileBrowser.SignInPrompt
    let onSubmit: (String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    private enum Field {
        case username, password
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.person.crop")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                Text("Sign In to Browse Files")
                    .font(.title3.weight(.semibold))
                Text(computer.kind.isApple
                    ? "Files are reached through Remote Login, with your account on \(computer.displayName)."
                    : "Files are reached through SSH, with your account on \(computer.displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = prompt.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                TextField("User Name", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .credentialField()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
                    .credentialField()
            }

            Toggle("Remember this password", isOn: $remember)
                .font(.callout)
                #if os(macOS)
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassPanel()
        .onAppear {
            username = prompt.username
            focus = prompt.username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(username, password, remember)
    }
}

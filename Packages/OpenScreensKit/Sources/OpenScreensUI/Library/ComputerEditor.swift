import OpenScreensCore
import SwiftUI

/// Add or edit a computer.
struct ComputerEditor: View {
    /// What the editor was opened for.
    struct Request: Identifiable {
        let id = UUID()
        var computer: Computer
        var isNew: Bool

        static func new(_ computer: Computer) -> Request {
            Request(computer: computer, isNew: true)
        }

        static func edit(_ computer: Computer) -> Request {
            Request(computer: computer, isNew: false)
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var draft: Computer
    @State private var portText: String
    @State private var password = ""
    @State private var passwordEdited = false
    @State private var sshPassword = ""
    @State private var sshPasswordEdited = false
    @State private var tagsText: String

    init(request: Request) {
        isNew = request.isNew
        _draft = State(initialValue: request.computer)
        _portText = State(initialValue: String(request.computer.port))
        _tagsText = State(initialValue: request.computer.tags.joined(separator: ", "))
    }

    private var parsedPort: Int? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else { return nil }
        return port
    }

    private var canSave: Bool {
        !draft.host.trimmingCharacters(in: .whitespaces).isEmpty && parsedPort != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                computerSection
                signInSection
                ConnectionSettingsForm(settings: $draft.settings, kind: draft.kind)
                tunnelSection
                organizeSection
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Computer" : "Edit Computer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 680)
        #endif
    }

    // MARK: - Sections

    private var computerSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Optional"))
            TextField("Address", text: $draft.host, prompt: Text("Host name or IP address"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            TextField("Port", text: $portText, prompt: Text("5900"))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Picker("Kind", selection: $draft.kind) {
                ForEach(ComputerKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(kind)
                }
            }
            .onChange(of: draft.kind) { old, new in
                // Switching between Mac and non-Mac changes what is possible,
                // so move to that kind's sensible defaults.
                if old.isApple != new.isApple, isNew {
                    draft.settings = new.isApple
                        ? model.settings.defaultConnection
                        : ConnectionSettings.defaults(for: new)
                }
            }
        } header: {
            Text("Computer")
        } footer: {
            if parsedPort == nil {
                Text("The port must be a number between 1 and 65535.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var signInSection: some View {
        Section {
            TextField(
                "User Name",
                text: Binding(
                    get: { draft.username ?? "" },
                    set: { draft.username = $0.isEmpty ? nil : $0 }),
                prompt: Text(draft.kind.isApple ? "macOS account name" : "Optional"))
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField(
                "Password",
                text: Binding(
                    get: { password },
                    set: {
                        password = $0
                        passwordEdited = true
                    }),
                prompt: Text(storedPasswordPrompt(kind: .screenSharing)))
                .textContentType(.password)
        } header: {
            Text("Sign In")
        } footer: {
            Text("Passwords are stored in your keychain, never in the library file. Leave the password empty to be asked each time.")
        }
    }

    private var tunnelSection: some View {
        Section {
            Toggle("Connect Through SSH", isOn: $draft.ssh.isEnabled)
            if draft.ssh.isEnabled {
                TextField("SSH Server", text: $draft.ssh.host, prompt: Text("Same as the computer"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField(
                    "SSH Port",
                    text: Binding(
                        get: { String(draft.ssh.port) },
                        set: { draft.ssh.port = Int($0) ?? 22 }))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                TextField("SSH User Name", text: $draft.ssh.username, prompt: Text("Same as above"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Authentication", selection: $draft.ssh.authentication) {
                    ForEach(SSHAuthentication.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                if draft.ssh.authentication == .password {
                    SecureField(
                        "SSH Password",
                        text: Binding(
                            get: { sshPassword },
                            set: {
                                sshPassword = $0
                                sshPasswordEdited = true
                            }),
                        prompt: Text(storedPasswordPrompt(kind: .ssh)))
                } else {
                    SSHKeyPicker(selection: $draft.ssh.keyID)
                }
            }
        } header: {
            Text("Secure Tunnel")
        } footer: {
            Text("Carries the whole connection inside SSH. The computer needs Remote Login turned on. High Performance mode is not available through a tunnel, so the connection uses Standard.")
        }
    }

    private var organizeSection: some View {
        Section("Organize") {
            Toggle("Favorite", isOn: $draft.isFavorite)
            Picker("Group", selection: $draft.groupID) {
                Text("None").tag(UUID?.none)
                ForEach(model.library.groups) { group in
                    Text(group.name).tag(UUID?.some(group.id))
                }
            }
            Picker("Colour", selection: $draft.tint) {
                ForEach(ComputerTint.allCases) { tint in
                    Label {
                        Text(tint.title)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(tint.color ?? draft.kind.defaultColor)
                    }
                    .tag(tint)
                }
            }
            TextField("Tags", text: $tagsText, prompt: Text("work, studio"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Wake-on-LAN Address", text: Binding(
                get: { draft.macAddress ?? "" },
                set: { draft.macAddress = $0.isEmpty ? nil : $0 }),
                prompt: Text("aa:bb:cc:dd:ee:ff"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private func storedPasswordPrompt(kind: CredentialStore.Kind) -> String {
        !isNew && model.credentials.hasPassword(for: draft.id, kind: kind) ? "Saved" : "Optional"
    }

    // MARK: - Saving

    private func save() {
        guard let port = parsedPort else { return }
        draft.host = draft.host.trimmingCharacters(in: .whitespaces)
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.port = port
        draft.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let saved: Computer
        if isNew {
            saved = model.library.add(draft)
        } else {
            model.library.update(draft)
            saved = draft
        }
        if passwordEdited {
            try? model.credentials.setPassword(password, for: saved.id, kind: .screenSharing)
        }
        if sshPasswordEdited {
            try? model.credentials.setPassword(sshPassword, for: saved.id, kind: .ssh)
        }
        dismiss()
    }
}

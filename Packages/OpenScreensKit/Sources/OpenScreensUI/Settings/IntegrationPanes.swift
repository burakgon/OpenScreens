import OpenScreensCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tailscale

struct TailscaleSettingsPane: View {
    @Environment(AppModel.self) private var model

    @State private var accessToken = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var hasSavedCredentials = false
    @State private var saveError: String?

    private typealias Names = TailscaleCredentials.SecretName

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Show Tailscale Devices", isOn: $settings.tailscaleEnabled)
                if settings.tailscaleEnabled {
                    Toggle("Hide Devices That Are Offline", isOn: $settings.hidesOfflineTailscaleDevices)
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if model.tailscale.isRefreshing {
                                ProgressView().controlSize(.small)
                            }
                            Text(status)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button("Refresh Now") {
                        Task { await model.tailscale.refresh() }
                    }
                    .disabled(model.tailscale.isRefreshing)
                }
            } footer: {
                Text(overview)
            }

            if settings.tailscaleEnabled {
                Section {
                    SecureField(
                        "Access Token", text: $accessToken,
                        prompt: Text(savedPrompt(Names.accessToken, otherwise: "tskey-api-…")))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    TextField("Tailnet", text: $settings.tailnet, prompt: Text("-"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Link(destination: AppLinks.tailscaleKeys) {
                        Label("Create an Access Token", systemImage: "arrow.up.forward.square")
                    }
                } header: {
                    Text("Tailscale API")
                } footer: {
                    Text("An access token lets OpenScreens read the list of devices in your tailnet, and nothing else is asked of it. Leave the tailnet as “-” to use the one the token belongs to. Access tokens expire after at most 90 days; an OAuth client does not.")
                }

                Section {
                    TextField("Client ID", text: $clientID, prompt: Text(savedPrompt(Names.oauthClientID, otherwise: "Optional")))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField(
                        "Client Secret", text: $clientSecret,
                        prompt: Text(savedPrompt(Names.oauthClientSecret, otherwise: "tskey-client-…")))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } header: {
                    Text("OAuth Client")
                } footer: {
                    Text("Used instead of an access token when both are saved. Give the client read access to devices.")
                }

                Section {
                    Button("Save") {
                        save()
                    }
                    .disabled(accessToken.isEmpty && (clientID.isEmpty || clientSecret.isEmpty))
                    if hasSavedCredentials {
                        Button("Remove Saved Credentials", role: .destructive) {
                            removeCredentials()
                        }
                    }
                } footer: {
                    Text("Credentials are kept in your keychain.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshSavedState)
        .alert("Couldn't Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var overview: String {
        #if os(macOS)
        "Lists the computers in your tailnet in the library. With the Tailscale app running on this Mac, that works without any setup; an access token works everywhere."
        #else
        "Lists the computers in your tailnet in the library, so they are one tap away from anywhere. Needs an access token or OAuth client."
        #endif
    }

    private var status: String {
        switch model.tailscale.state {
        case .notConfigured:
            #if os(macOS)
            return "Not set up — no Tailscale app, no credentials"
            #else
            return "Not set up"
            #endif
        case .loading:
            return "Loading…"
        case .ready:
            let count = model.tailscale.devices.count
            return count == 1 ? "1 device" : "\(count) devices"
        case .failed(let message):
            return message
        }
    }

    private func savedPrompt(_ name: String, otherwise: String) -> String {
        model.credentials.secret(named: name) != nil ? "Saved" : otherwise
    }

    private func refreshSavedState() {
        hasSavedCredentials = TailscaleCredentials.saved(in: model.credentials) != nil
    }

    private func save() {
        do {
            let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                try model.credentials.setSecret(token, named: Names.accessToken)
            }
            let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !secret.isEmpty {
                try model.credentials.setSecret(id, named: Names.oauthClientID)
                try model.credentials.setSecret(secret, named: Names.oauthClientSecret)
            }
        } catch {
            saveError = error.localizedDescription
            return
        }
        accessToken = ""
        clientID = ""
        clientSecret = ""
        refreshSavedState()
        Task { await model.tailscale.refresh() }
    }

    private func removeCredentials() {
        for name in [Names.accessToken, Names.oauthClientID, Names.oauthClientSecret] {
            try? model.credentials.setSecret(nil, named: name)
        }
        refreshSavedState()
        Task { await model.tailscale.refresh() }
    }
}

// MARK: - SSH keys and trusted servers

struct SSHKeysSettingsPane: View {
    @Environment(AppModel.self) private var model

    @State private var keys: [StoredSSHKey] = []
    @State private var hosts: [KnownHostsStore.Entry] = []
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var isImporting = false
    @State private var pendingImport: PendingImport?
    @State private var passphrase = ""
    @State private var errorMessage: String?
    @State private var copiedKey: StoredSSHKey.ID?

    /// What the name being typed is for.
    private enum Naming: Identifiable {
        case newKey
        case rename(StoredSSHKey)

        var id: String {
            switch self {
            case .newKey: "new"
            case .rename(let key): key.id.uuidString
            }
        }
    }

    /// A key file that turned out to need its passphrase.
    private struct PendingImport: Identifiable {
        let id = UUID()
        var name: String
        var text: String
    }

    var body: some View {
        Form {
            Section {
                if keys.isEmpty {
                    Text("No keys yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(keys) { key in
                    keyRow(key)
                }
                Button("Generate a New Key…", systemImage: "plus") {
                    nameText = defaultKeyName
                    naming = .newKey
                }
                Button("Import a Key File…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            } header: {
                Text("Keys")
            } footer: {
                Text("A key signs you in to SSH servers without a password. Copy its public key into ~/.ssh/authorized_keys on each computer you tunnel through. Private keys never leave your keychain.")
            }

            Section {
                if hosts.isEmpty {
                    Text("None yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(hosts) { host in
                    hostRow(host)
                }
            } header: {
                Text("Trusted Servers")
            } footer: {
                Text("SSH servers whose keys you chose to trust. Forget one to be shown its key again the next time you connect.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data, .text]) { result in
            guard case .success(let url) = result else { return }
            importKey(from: url)
        }
        .alert(
            namingTitle,
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
            presenting: naming
        ) { purpose in
            TextField("Name", text: $nameText)
            Button(purpose.id == "new" ? "Generate" : "Rename") {
                finishNaming(purpose)
            }
            Button("Cancel", role: .cancel) {}
        } message: { purpose in
            if case .newKey = purpose {
                Text("OpenScreens creates an Ed25519 key and keeps it in your keychain.")
            }
        }
        .alert(
            "Passphrase for “\(pendingImport?.name ?? "")”",
            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
            presenting: pendingImport
        ) { pending in
            SecureField("Passphrase", text: $passphrase)
            Button("Import") {
                add(pending, passphrase: passphrase)
            }
            Button("Cancel", role: .cancel) {
                passphrase = ""
            }
        } message: { _ in
            Text("The key is stored without its passphrase, protected by your keychain instead.")
        }
        .alert("SSH Keys", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func keyRow(_ key: StoredSSHKey) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                Text("\(key.algorithm) · \(key.fingerprint)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(
                copiedKey == key.id ? "Copied" : "Copy Public Key",
                systemImage: copiedKey == key.id ? "checkmark" : "doc.on.doc"
            ) {
                Pasteboard.copy(key.authorizedKeysLine)
                copiedKey = key.id
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if copiedKey == key.id { copiedKey = nil }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy the line to add to authorized_keys")
        }
        .contextMenu {
            Button("Copy Public Key", systemImage: "doc.on.doc") {
                Pasteboard.copy(key.authorizedKeysLine)
            }
            Button("Rename…", systemImage: "pencil") {
                nameText = key.name
                naming = .rename(key)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                delete(key)
            }
        }
        #if os(iOS)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                delete(key)
            }
        }
        #endif
    }

    private func hostRow(_ host: KnownHostsStore.Entry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.port == 22 ? host.host : "\(host.host):\(host.port)")
                ForEach(host.keys, id: \.self) { key in
                    Text("\(key.type) · \(key.fingerprint)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("Forget", role: .destructive) {
                try? model.knownHosts.remove(host: host.host, port: host.port)
                reload()
            }
            .buttonStyle(.borderless)
        }
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename Key" }
        return "New SSH Key"
    }

    private var defaultKeyName: String {
        #if os(macOS)
        Host.current().localizedName ?? "This Mac"
        #else
        UIDevice.current.name
        #endif
    }

    private func reload() {
        keys = model.sshKeys.keys()
        hosts = model.knownHosts.all()
    }

    private func finishNaming(_ purpose: Naming) {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            switch purpose {
            case .newKey:
                try model.sshKeys.add(name: name, key: .generateEd25519())
            case .rename(let key):
                try model.sshKeys.rename(key.id, to: name)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func delete(_ key: StoredSSHKey) {
        do {
            try model.sshKeys.delete(key.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func importKey(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A private key is a few kilobytes of text; anything much larger was
        // picked by mistake.
        guard let data = try? Data(contentsOf: url), data.count < 256 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            errorMessage = "That file is not an OpenSSH private key."
            return
        }
        add(PendingImport(name: url.deletingPathExtension().lastPathComponent, text: text), passphrase: nil)
    }

    private func add(_ pending: PendingImport, passphrase: String?) {
        defer { self.passphrase = "" }
        do {
            let key = try SSHPrivateKey(openSSH: pending.text, passphrase: passphrase)
            let name = key.comment.isEmpty ? pending.name : key.comment
            try model.sshKeys.add(name: name, key: key)
            pendingImport = nil
            reload()
        } catch SSHKeyError.passphraseRequired {
            pendingImport = pending
        } catch SSHKeyError.wrongPassphrase {
            errorMessage = "The passphrase is not correct."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import OpenScreensCore
import SwiftUI

/// What is shown over the remote screen while a session is not connected:
/// progress, a credential form, or what went wrong.
struct SessionStatusOverlay: View {
    let session: RemoteSession
    let onClose: () -> Void

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .connecting:
                ProgressCard(
                    computer: session.computer,
                    title: "Connecting to \(session.computer.displayName)",
                    detail: session.progressDescription,
                    onCancel: onClose)
            case .reconnecting(let attempt):
                ProgressCard(
                    computer: session.computer,
                    title: "Reconnecting…",
                    detail: attempt > 1 ? "Attempt \(attempt)" : "The connection was interrupted.",
                    onCancel: onClose)
            case .awaitingCredentials(let prompt):
                CredentialCard(session: session, prompt: prompt, onCancel: onClose)
                    // A second prompt is a different form, not the same one
                    // with its fields kept.
                    .id(prompt.purpose)
            case .awaitingHostKey(let prompt):
                HostKeyCard(session: session, prompt: prompt, onCancel: onClose)
            case .failed(let message):
                if session.isWaking {
                    ProgressCard(
                        computer: session.computer,
                        title: "Waking \(session.computer.displayName)",
                        detail: "Giving it a moment to wake up…",
                        onCancel: onClose)
                } else {
                    FailureCard(
                        computer: session.computer,
                        message: message,
                        onWake: session.canWake ? { session.wakeAndRetry() } : nil,
                        onRetry: { session.retry() },
                        onClose: onClose)
                }
            case .connected, .ended:
                EmptyView()
            }
        }
        .frame(maxWidth: 380)
        .padding(24)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

/// The header shared by every status card.
private struct CardHeader: View {
    let computer: Computer
    let title: String
    var symbolName: String?
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName ?? computer.kind.symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .frame(height: 44)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(computer.displayAddress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct ProgressCard: View {
    let computer: Computer
    let title: String
    let detail: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(computer: computer, title: title)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(detail ?? "Opening connection…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(.default, value: detail)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassPanel()
    }
}

private struct FailureCard: View {
    let computer: Computer
    let message: String
    /// Sends a Wake-on-LAN packet first, for computers with an address saved.
    var onWake: (() -> Void)?
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(
                computer: computer,
                title: "Couldn't Connect",
                symbolName: "exclamationmark.triangle",
                tint: .orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Close", role: .cancel, action: onClose)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                if let onWake {
                    Button("Wake", systemImage: "power", action: onWake)
                        .buttonStyle(.glass)
                        .help("Send a Wake-on-LAN signal, then try again")
                }
                Button("Try Again", action: onRetry)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassPanel()
    }
}

/// Asks the user to vouch for an SSH server's key.
private struct HostKeyCard: View {
    let session: RemoteSession
    let prompt: RemoteSession.HostKeyPrompt
    let onCancel: () -> Void

    private var server: String {
        prompt.port == 22 ? prompt.host : "\(prompt.host), port \(prompt.port)"
    }

    var body: some View {
        VStack(spacing: 16) {
            CardHeader(
                computer: session.computer,
                title: prompt.keyHasChanged ? "The SSH Server's Key Has Changed" : "Verify the SSH Server",
                symbolName: prompt.keyHasChanged ? "exclamationmark.shield" : "key.horizontal",
                tint: prompt.keyHasChanged ? .red : .accentColor)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                fingerprint("Presented now", prompt.fingerprint)
                if let expected = prompt.expectedFingerprint {
                    fingerprint("Trusted before", expected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 11, style: .continuous))

            HStack(spacing: 12) {
                if prompt.keyHasChanged {
                    // The safe answer is the default one.
                    Button("Trust New Key", role: .destructive) {
                        session.answerHostKey(trust: true)
                    }
                    .buttonStyle(.glass)
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button("Trust and Connect") {
                        session.answerHostKey(trust: true)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassPanel()
    }

    private var explanation: String {
        if prompt.keyHasChanged {
            return "\(server) is not presenting the key OpenScreens trusted before. Someone may be intercepting the connection, or the server was set up again. Continue only if you know why the key changed."
        }
        return "OpenScreens has not connected to \(server) before. To be sure it is the right server, compare this fingerprint with the one the server reports for its \(prompt.keyType) key."
    }

    private func fingerprint(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CredentialCard: View {
    let session: RemoteSession
    let prompt: RemoteSession.CredentialPrompt
    let onCancel: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    private enum Field {
        case username, password
    }

    private var isForTunnel: Bool {
        prompt.purpose == .secureTunnel
    }

    private var canSubmit: Bool {
        if isForTunnel {
            let hasUsername = !prompt.asksForUsername
                || !username.trimmingCharacters(in: .whitespaces).isEmpty
            return hasUsername && !password.isEmpty
        }
        if prompt.asksForUsername, session.computer.kind.isApple {
            return !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        }
        return true
    }

    private var title: String {
        guard isForTunnel else {
            return "Sign In to \(session.computer.displayName)"
        }
        let server = session.computer.ssh.host.trimmingCharacters(in: .whitespaces)
        return server.isEmpty ? "Sign In to the Secure Tunnel" : "Sign In to \(server)"
    }

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(
                computer: session.computer,
                title: title,
                symbolName: isForTunnel ? "lock.rectangle.stack" : "lock.shield")

            if isForTunnel, prompt.message == nil {
                Text("The connection goes through SSH, which has its own sign-in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = prompt.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if prompt.asksForUsername {
                    TextField("User Name", text: $username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .credentialField()
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .credentialField()
            }

            if session.isSaved {
                Toggle("Remember this password", isOn: $remember)
                    .font(.callout)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
            }

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
            focus = prompt.asksForUsername && prompt.username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        guard canSubmit else { return }
        session.submitCredentials(
            username: prompt.asksForUsername ? username : "",
            password: password,
            remember: remember && session.isSaved)
    }
}

private extension View {
    func credentialField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 11, style: .continuous))
    }
}

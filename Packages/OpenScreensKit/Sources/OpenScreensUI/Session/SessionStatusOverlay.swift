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
            case .failed(let message):
                FailureCard(
                    computer: session.computer,
                    message: message,
                    onRetry: { session.retry() },
                    onClose: onClose)
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

    private var canSubmit: Bool {
        if prompt.asksForUsername, session.computer.kind.isApple {
            return !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 18) {
            CardHeader(
                computer: session.computer,
                title: "Sign In to \(session.computer.displayName)",
                symbolName: "lock.shield")

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

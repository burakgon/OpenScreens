import OpenScreensCore
import SwiftUI

// Menus that act on a live session. They are plain views with no chrome of
// their own, so the Mac toolbar, the menu bar and the floating toolbar on
// iPhone and iPad can all present exactly the same choices.

/// Picks the connection mode.
struct QualityMenuItems: View {
    let session: RemoteSession

    var body: some View {
        Picker("Mode", selection: Binding(
            get: { session.settings.quality },
            set: { quality in session.update { $0.quality = quality } })
        ) {
            ForEach(QualityMode.allCases) { mode in
                if mode != .highPerformance || session.computer.kind.isApple {
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
        }
        .pickerStyle(.inline)

        if let reason = session.fallbackReason {
            Section("Running in Standard") {
                Text(reason)
            }
        }
    }
}

/// Picks which displays are shown and how the desktop is sized.
struct DisplayMenuItems: View {
    let session: RemoteSession

    private var isHighPerformance: Bool {
        session.settings.quality == .highPerformance
    }

    var body: some View {
        if session.computer.kind.isApple {
            Picker("Displays", selection: Binding(
                get: { session.settings.displays },
                set: { layout in
                    session.update {
                        $0.displays = layout
                        switch layout {
                        case .twoVirtual: $0.resolution = .matchWindow
                        case .allCombined: $0.resolution = .remote
                        case .single: break
                        }
                    }
                })
            ) {
                ForEach(DisplayLayout.allCases) { layout in
                    if layout != .twoVirtual || isHighPerformance {
                        Label(layout.title, systemImage: layout.symbolName).tag(layout)
                    }
                }
            }
            .pickerStyle(.inline)

            if isHighPerformance, session.settings.displays != .allCombined {
                Picker("Desktop Size", selection: Binding(
                    get: { session.settings.resolution },
                    set: { mode in session.update { $0.resolution = mode } })
                ) {
                    ForEach(ResolutionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }
}

/// Picks how the picture fits the window, and resets zoom.
struct ScalingMenuItems: View {
    let session: RemoteSession

    var body: some View {
        Picker("Scaling", selection: Binding(
            get: { session.settings.scaling },
            set: { mode in session.update { $0.scaling = mode } })
        ) {
            ForEach(ScalingMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbolName).tag(mode)
            }
        }
        .pickerStyle(.inline)

        Button("Reset Zoom", systemImage: "arrow.counterclockwise") {
            withAnimation(.smooth(duration: 0.25)) {
                session.viewport.reset()
            }
        }
        .disabled(!session.viewport.isTransformed)
    }
}

/// Clipboard transfer actions.
struct ClipboardMenuItems: View {
    let session: RemoteSession

    var body: some View {
        Button("Send Clipboard", systemImage: "arrow.up.doc") {
            session.clipboard.sendClipboard()
        }
        .disabled(!session.clipboard.canSendClipboard || session.settings.observeOnly)

        Button("Get Clipboard", systemImage: "arrow.down.doc") {
            session.clipboard.getClipboard()
        }
        .disabled(!session.clipboard.canGetClipboard)

        Divider()

        Toggle(isOn: Binding(
            get: { session.settings.sharedClipboard },
            set: { enabled in session.update { $0.sharedClipboard = enabled } })
        ) {
            Label("Share Clipboard Automatically", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}

/// Key combinations that are awkward or impossible to type locally.
struct ShortcutMenuItems: View {
    @Environment(AppModel.self) private var model
    let session: RemoteSession

    var body: some View {
        let kind = session.computer.kind
        if !model.settings.customShortcuts.isEmpty {
            Section("My Shortcuts") {
                ForEach(model.settings.customShortcuts) { shortcut in
                    button(for: shortcut, kind: kind)
                }
            }
        }
        Section(kind.isApple ? "Mac" : kind.title) {
            ForEach(RemoteShortcut.builtIn(for: kind)) { shortcut in
                button(for: shortcut, kind: kind)
            }
        }
    }

    private func button(for shortcut: RemoteShortcut, kind: ComputerKind) -> some View {
        Button {
            session.send(shortcut)
        } label: {
            Label {
                Text("\(shortcut.name)   \(shortcut.displayString(for: kind))")
            } icon: {
                Image(systemName: shortcut.symbolName)
            }
        }
    }
}

/// Privacy and remote-state actions: Curtain Mode, password, audio, observe.
struct RemoteActionMenuItems: View {
    let session: RemoteSession
    var onCurtain: () -> Void

    var body: some View {
        if session.computer.kind.isApple {
            Button(
                session.isCurtained ? "Turn Off Curtain Mode" : "Turn On Curtain Mode…",
                systemImage: session.isCurtained ? "eye" : "eye.slash",
                action: onCurtain)
                .disabled(!session.supportsCurtain)

            Button("Type Password", systemImage: "key") {
                session.typePassword()
            }
            .disabled(!session.canTypePassword)

            Toggle(isOn: Binding(
                get: { session.settings.remoteAudio },
                set: { enabled in session.update { $0.remoteAudio = enabled } })
            ) {
                Label("Play Remote Sound", systemImage: "speaker.wave.2")
            }
            .disabled(session.settings.quality != .highPerformance)
        }

        Toggle(isOn: Binding(
            get: { session.settings.observeOnly },
            set: { enabled in session.update { $0.observeOnly = enabled } })
        ) {
            Label("Observe Only", systemImage: "eye")
        }
    }
}

/// Asks for the optional lock-screen message before curtaining the remote Mac.
struct CurtainPrompt: ViewModifier {
    let session: RemoteSession
    @Binding var isPresented: Bool
    @State private var message = ""

    func body(content: Content) -> some View {
        content
            .alert("Turn On Curtain Mode?", isPresented: $isPresented) {
                TextField("Message (optional)", text: $message)
                Button("Turn On") {
                    session.setCurtain(true, message: message)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The remote Mac's own display will show a lock screen while you keep working. Anyone sitting at it sees your message.")
            }
            .alert(
                "Curtain Mode Did Not Change",
                isPresented: Binding(
                    get: { session.engine.curtainChangeFailed },
                    set: { if !$0 { session.engine.acknowledgeCurtainFailure() } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The remote Mac did not confirm the change, so its display may still be visible to people nearby.")
            }
            .onAppear { message = session.settings.curtainMessage }
    }
}

extension View {
    func curtainPrompt(for session: RemoteSession, isPresented: Binding<Bool>) -> some View {
        modifier(CurtainPrompt(session: session, isPresented: isPresented))
    }
}

/// A compact indicator of the connection mode and whether it is encrypted.
struct ConnectionBadge: View {
    let session: RemoteSession

    var body: some View {
        let quality = session.activeQuality
        HStack(spacing: 5) {
            Image(systemName: quality.symbolName)
                .foregroundStyle(quality.color)
            Text(quality.title)
            if session.engine.negotiatedContentEncryption.map({ $0 != .none }) ?? false
                || session.computer.ssh.isEnabled {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Encrypted")
            }
        }
        .font(.callout.weight(.medium))
        .accessibilityElement(children: .combine)
    }
}

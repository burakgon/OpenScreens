#if os(macOS)
import AppKit
import OpenScreensCore
import SwiftUI

// Menu-bar commands.
//
// Commands that act on a session use ⌃⌥⌘ shortcuts. While the pointer is over
// a remote screen every ordinary shortcut is forwarded to the remote computer,
// so the app keeps this one modifier combination for itself.

struct LibraryCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Library") {
                openWindow(id: WindowID.library)
            }
            .keyboardShortcut("0", modifiers: [.command])
        }

        CommandGroup(replacing: .help) {
            Link("OpenScreens Help", destination: AppLinks.documentation)
            Link("Report an Issue", destination: AppLinks.issues)
            Divider()
            Link("OpenScreens on GitHub", destination: AppLinks.repository)
        }
    }
}

struct SessionCommands: Commands {
    let model: AppModel
    @FocusedValue(\.activeSession) private var session

    private static let local: EventModifiers = [.control, .option, .command]

    private var live: RemoteSession? {
        guard let session, session.isConnected else { return nil }
        return session
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                scalingButton("Fit", .fit, key: "1")
                scalingButton("Fill", .fill, key: "2")
                scalingButton("Actual Size", .actualSize, key: "3")
                Button("Reset Zoom") {
                    live?.viewport.reset()
                }
                .keyboardShortcut("0", modifiers: Self.local)
                .disabled(!(live?.viewport.isTransformed ?? false))
                Button("Fit Window to Remote Screen") {
                    if let live {
                        SessionActions.fitWindow(to: live, window: NSApp.keyWindow)
                    }
                }
                .keyboardShortcut("f", modifiers: Self.local)
                .disabled(live == nil)
            }
            Section {
                Toggle("Show Statistics", isOn: Binding(
                    get: { model.settings.showsStatisticsOverlay },
                    set: { model.settings.showsStatisticsOverlay = $0 }))
                    .keyboardShortcut("i", modifiers: Self.local)
            }
        }

        CommandMenu("Remote") {
            Section {
                Button("Send Clipboard") {
                    live?.clipboard.sendClipboard()
                }
                .keyboardShortcut("v", modifiers: Self.local)
                .disabled(live == nil)

                Button("Get Clipboard") {
                    live?.clipboard.getClipboard()
                }
                .keyboardShortcut("c", modifiers: Self.local)
                .disabled(live == nil)
            }

            Section {
                Button("Save Screenshot…") {
                    if let live { SessionActions.saveScreenshot(of: live) }
                }
                .keyboardShortcut("s", modifiers: Self.local)
                .disabled(live == nil)

                Button("Copy Screenshot") {
                    if let live { SessionActions.copyScreenshot(of: live) }
                }
                .keyboardShortcut("s", modifiers: [.control, .option, .command, .shift])
                .disabled(live == nil)
            }

            Section {
                Button("Type Password") {
                    live?.typePassword()
                }
                .keyboardShortcut("p", modifiers: Self.local)
                .disabled(!(live?.canTypePassword ?? false))

                Button(live?.isCurtained == true ? "Turn Off Curtain Mode" : "Turn On Curtain Mode") {
                    guard let live else { return }
                    live.setCurtain(!live.isCurtained)
                }
                .keyboardShortcut("l", modifiers: Self.local)
                .disabled(!(live?.supportsCurtain ?? false))
            }

            if let live {
                Menu("Send Shortcut") {
                    ShortcutMenuItems(session: live)
                        .environment(model)
                }
                Menu("Mode") {
                    QualityMenuItems(session: live)
                }
                Menu("Display") {
                    DisplayMenuItems(session: live)
                }
            }

            Divider()

            Button("Disconnect") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: Self.local)
            .disabled(session == nil)
        }
    }

    private func scalingButton(_ title: String, _ mode: ScalingMode, key: KeyEquivalent) -> some View {
        Button(title) {
            live?.update { $0.scaling = mode }
        }
        .keyboardShortcut(key, modifiers: Self.local)
        .disabled(live == nil)
    }
}
#endif

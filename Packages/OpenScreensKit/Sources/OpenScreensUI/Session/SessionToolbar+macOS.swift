#if os(macOS)
import AppKit
import OpenScreensCore
import SwiftUI
import UniformTypeIdentifiers

/// The session window's toolbar.
struct SessionToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let session: RemoteSession

    @State private var showsCurtainPrompt = false
    @State private var showsInspector = false
    @State private var showsTypeText = false
    @State private var showsFilePicker = false

    private var isLive: Bool { session.isConnected }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                QualityMenuItems(session: session)
            } label: {
                ConnectionBadge(session: session)
            }
            .menuIndicator(.hidden)
            .help("Connection mode")
            .disabled(!isLive)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Shortcuts", systemImage: "command") {
                ShortcutMenuItems(session: session)
            }
            .help("Send a keyboard shortcut")

            Menu("Clipboard", systemImage: "doc.on.clipboard") {
                ClipboardMenuItems(session: session)
            }
            .help("Clipboard")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Display", systemImage: "display") {
                DisplayMenuItems(session: session)
                ScalingMenuItems(session: session)
            }
            .help("Displays and scaling")

            Button("Screenshot", systemImage: "camera") {
                SessionActions.saveScreenshot(of: session)
            }
            .help("Save a picture of the remote screen")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis") {
                RemoteActionMenuItems(session: session) {
                    if session.isCurtained {
                        session.setCurtain(false)
                    } else {
                        showsCurtainPrompt = true
                    }
                }
                Button("Type Text…", systemImage: "text.cursor") {
                    showsTypeText = true
                }
                .disabled(!session.canSendInput)
                Button("Browse Files…", systemImage: "folder") {
                    openWindow(id: WindowID.files, value: session.computer)
                }
                if session.fileTransfers.canUpload {
                    Button("Send Files…", systemImage: "arrow.up.doc") {
                        showsFilePicker = true
                    }
                    .disabled(!session.canDropFiles)
                }
                Divider()
                @Bindable var settings = model.settings
                Toggle(isOn: $settings.showsStatisticsOverlay) {
                    Label("Show Statistics", systemImage: "chart.bar")
                }
                Button("Connection Settings…", systemImage: "slider.horizontal.3") {
                    showsInspector = true
                }
                if !session.isSaved {
                    Divider()
                    Button("Save to Library", systemImage: "plus.square.on.square") {
                        session.saveToLibrary()
                    }
                }
            }
            .help("More")
            .curtainPrompt(for: session, isPresented: $showsCurtainPrompt)
            .sheet(isPresented: $showsInspector) {
                SessionSettingsSheet(session: session)
            }
            .sheet(isPresented: $showsTypeText) {
                TypeTextSheet(session: session)
            }
            .fileImporter(
                isPresented: $showsFilePicker, allowedContentTypes: [.item, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    session.sendFiles(urls)
                }
            }
        }
    }
}

/// Edits the connection settings of a live session.
struct SessionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession
    @State private var draft = ConnectionSettings()

    var body: some View {
        NavigationStack {
            Form {
                ConnectionSettingsForm(settings: $draft, kind: session.computer.kind)
            }
            .formStyle(.grouped)
            .navigationTitle(session.computer.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        session.apply(draft)
                        dismiss()
                    }
                    .disabled(draft == session.settings)
                }
            }
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 480, idealHeight: 620)
        .onAppear { draft = session.settings }
    }
}

/// Session actions that need AppKit.
enum SessionActions {
    /// Asks where to save a screenshot of the remote screen, then writes it.
    static func saveScreenshot(of session: RemoteSession) {
        guard let image = session.screenshot(),
              let data = ScreenshotEncoder.pngData(image) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ScreenshotEncoder.fileName(for: session.computer.displayName)
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    /// Puts a screenshot of the remote screen on the clipboard.
    static func copyScreenshot(of session: RemoteSession) {
        guard let image = session.screenshot() else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    /// Resizes the session window so the remote screen fits it exactly.
    static func fitWindow(to session: RemoteSession, window: NSWindow?) {
        guard let window, let screen = window.screen else { return }
        let remote = session.remoteSize
        guard remote.width > 0, remote.height > 0 else { return }
        let scale = window.backingScaleFactor
        var content = CGSize(width: remote.width / scale, height: remote.height / scale)
        let chrome = window.frame.height - window.contentLayoutRect.height
        let available = CGSize(
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height - chrome)
        let shrink = min(1, available.width / content.width, available.height / content.height)
        content = CGSize(width: content.width * shrink, height: content.height * shrink)
        var frame = window.frame
        let newSize = CGSize(width: content.width, height: content.height + chrome)
        frame.origin.y += frame.height - newSize.height
        frame.size = newSize
        frame.origin.x = min(max(frame.origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - newSize.width)
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        window.setFrame(frame, display: true, animate: true)
    }
}
#endif

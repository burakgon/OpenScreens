#if os(iOS)
import OpenScreensCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A session on iPhone and iPad: the remote screen edge to edge, with the
/// controls floating on glass above it.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    let session: RemoteSession
    let onClose: () -> Void

    @State private var showsCurtainPrompt = false
    @State private var showsSettings = false
    @State private var showsCloseConfirmation = false
    @State private var deckEnabled = false
    @State private var hardwareKeyboard = HardwareKeyboardMonitor()

    private var bridge: CanvasBridge { session.canvasBridge }

    /// The trackpad deck appears when asked for, and by itself on a foldable
    /// held half open like a laptop.
    private func showsDeck(in size: CGSize) -> Bool {
        guard session.isConnected else { return false }
        return deckEnabled || (bridge.hingeIsPartiallyOpen && size.width > size.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let deckVisible = showsDeck(in: geometry.size)
            let deckHeight = deckVisible ? deckHeight(in: geometry.size) : 0

            ZStack(alignment: .bottom) {
                SessionView(session: session, onClose: onClose)

                if deckVisible {
                    TrackpadDeck(session: session)
                        .frame(height: deckHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if session.isConnected {
                    FloatingToolbar(
                        session: session,
                        deckEnabled: $deckEnabled,
                        showsHardwareKeyboardHint: hardwareKeyboard.isAttached,
                        onCurtain: toggleCurtain,
                        onSettings: { showsSettings = true },
                        onClose: requestClose)
                        // Keep the toolbar clear of whatever covers the
                        // bottom of the screen.
                        .padding(.bottom, max(bridge.keyboardInset, deckHeight))
                }
            }
            .animation(.smooth(duration: 0.3), value: deckVisible)
            .onChange(of: deckHeight, initial: true) { _, height in
                bridge.deckInset = height
                bridge.isDeckVisible = height > 0
                bridge.canvas?.setNeedsLayout()
                bridge.canvas?.refreshCursorVisibility()
            }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .curtainPrompt(for: session, isPresented: $showsCurtainPrompt)
        .sheet(isPresented: $showsSettings) {
            SessionSettingsSheet(session: session)
        }
        .confirmationDialog(
            "Disconnect from \(session.computer.displayName)?",
            isPresented: $showsCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: session.isConnected, initial: true) { _, connected in
            UIApplication.shared.isIdleTimerDisabled = connected && model.settings.keepsDisplayAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: hardwareKeyboard.isAttached, initial: true) { _, attached in
            bridge.hasHardwareKeyboard = attached
            if attached {
                bridge.hideKeyboard()
            }
        }
    }

    private func deckHeight(in size: CGSize) -> CGFloat {
        if bridge.hingeIsPartiallyOpen, size.width > size.height {
            // The fold runs across the middle; the deck takes the lower half.
            return size.height / 2
        }
        return min(max(size.height * 0.36, 220), 360)
    }

    private func toggleCurtain() {
        if session.isCurtained {
            session.setCurtain(false)
        } else {
            showsCurtainPrompt = true
        }
    }

    private func requestClose() {
        if model.settings.confirmsDisconnect {
            showsCloseConfirmation = true
        } else {
            onClose()
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
            .navigationTitle(session.computer.displayName)
            .navigationBarTitleDisplayMode(.inline)
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
        .onAppear { draft = session.settings }
    }
}

/// The floating controls of a session.
struct FloatingToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    let session: RemoteSession
    @Binding var deckEnabled: Bool
    let showsHardwareKeyboardHint: Bool
    let onCurtain: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    /// Which edge the toolbar is docked to. It can be dragged between them.
    private enum Dock {
        case top, bottom
    }

    @State private var dock = Dock.bottom
    @State private var isCollapsed = false
    @State private var dragOffset = CGSize.zero
    @State private var screenshotURL: URL?
    @State private var showsTypeText = false
    @State private var showsFilePicker = false
    @State private var showsFiles = false

    private var bridge: CanvasBridge { session.canvasBridge }

    var body: some View {
        VStack {
            if dock == .bottom { Spacer(minLength: 0) }
            content
                .offset(dragOffset)
                .gesture(dockingDrag)
            if dock == .top { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: dock)
        .animation(.smooth(duration: 0.25), value: isCollapsed)
    }

    @ViewBuilder
    private var content: some View {
        if isCollapsed {
            Button {
                isCollapsed = false
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Show Controls")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: sizeClass == .compact ? 2 : 6) {
                    buttons
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
            .glassEffect(.regular, in: .capsule)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if !showsHardwareKeyboardHint || bridge.isKeyboardVisible {
            ToolbarButton(
                "Keyboard",
                systemName: bridge.isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                isActive: bridge.isKeyboardVisible
            ) {
                bridge.toggleKeyboard()
            }
        }

        ToolbarButton(
            session.settings.touchInput == .trackpad ? "Trackpad Mode" : "Touch Mode",
            systemName: session.settings.touchInput.symbolName
        ) {
            session.update {
                $0.touchInput = $0.touchInput == .trackpad ? .touch : .trackpad
            }
        }
        .sensoryFeedback(.selection, trigger: session.settings.touchInput)

        ToolbarButton("Trackpad Deck", systemName: "rectangle.bottomhalf.inset.filled", isActive: deckEnabled) {
            deckEnabled.toggle()
        }

        Menu {
            ShortcutMenuItems(session: session)
        } label: {
            ToolbarIcon(systemName: "command")
        }
        .accessibilityLabel("Shortcuts")

        Menu {
            ClipboardMenuItems(session: session)
        } label: {
            ToolbarIcon(systemName: "doc.on.clipboard")
        }
        .accessibilityLabel("Clipboard")

        Menu {
            DisplayMenuItems(session: session)
            ScalingMenuItems(session: session)
        } label: {
            ToolbarIcon(systemName: "display")
        }
        .accessibilityLabel("Display")

        Menu {
            Menu("Mode", systemImage: session.activeQuality.symbolName) {
                QualityMenuItems(session: session)
            }
            RemoteActionMenuItems(session: session, onCurtain: onCurtain)
            Button("Type Text…", systemImage: "text.cursor") {
                showsTypeText = true
            }
            .disabled(!session.canSendInput)
            Button("Browse Files…", systemImage: "folder") {
                showsFiles = true
            }
            if session.fileTransfers.canUpload {
                Button("Send Files…", systemImage: "arrow.up.doc") {
                    showsFilePicker = true
                }
                .disabled(!session.canDropFiles)
            }
            Divider()
            Button("Take Screenshot", systemImage: "camera") {
                screenshotURL = Self.writeScreenshot(of: session, scale: displayScale)
            }
            @Bindable var settings = model.settings
            Toggle(isOn: $settings.showsStatisticsOverlay) {
                Label("Show Statistics", systemImage: "chart.bar")
            }
            Button("Connection Settings…", systemImage: "slider.horizontal.3", action: onSettings)
            if !session.isSaved {
                Button("Save to Library", systemImage: "plus.square.on.square") {
                    session.saveToLibrary()
                }
            }
            Divider()
            Button("Hide Controls", systemImage: "chevron.down.circle") {
                isCollapsed = true
            }
        } label: {
            ToolbarIcon(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .sheet(item: $screenshotURL) { url in
            ScreenshotShareSheet(url: url)
        }
        .sheet(isPresented: $showsTypeText) {
            TypeTextSheet(session: session)
        }
        .sheet(isPresented: $showsFiles, onDismiss: { session.requestKeyboardFocus() }) {
            FileBrowserView(computer: session.computer)
                .environment(model)
        }
        .fileImporter(
            isPresented: $showsFilePicker, allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                session.sendFiles(urls)
            }
            session.requestKeyboardFocus()
        }

        ToolbarButton("Disconnect", systemName: "xmark", tint: .red, action: onClose)
    }

    /// Dragging the toolbar across the middle of the screen moves it to the
    /// other edge.
    private var dockingDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                let travelled = value.predictedEndTranslation.height
                withAnimation(.smooth(duration: 0.3)) {
                    if dock == .bottom, travelled < -160 {
                        dock = .top
                    } else if dock == .top, travelled > 160 {
                        dock = .bottom
                    }
                    dragOffset = .zero
                }
            }
    }

    private static func writeScreenshot(of session: RemoteSession, scale: CGFloat) -> URL? {
        guard let image = session.screenshot(),
              let data = ScreenshotEncoder.pngData(image, scale: scale) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: ScreenshotEncoder.fileName(for: session.computer.displayName))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Presents the system share sheet for a saved screenshot.
private struct ScreenshotShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ToolbarIcon: View {
    let systemName: String
    var isActive = false
    var tint: Color?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .symbolVariant(isActive ? .fill : .none)
            .foregroundStyle(tint ?? (isActive ? Color.accentColor : Color.primary))
            .frame(width: 42, height: 42)
            .contentShape(.circle)
    }
}

private struct ToolbarButton: View {
    private let title: String
    private let systemName: String
    private let isActive: Bool
    private let tint: Color?
    private let action: () -> Void

    init(
        _ title: String,
        systemName: String,
        isActive: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemName = systemName
        self.isActive = isActive
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ToolbarIcon(systemName: systemName, isActive: isActive, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
#endif

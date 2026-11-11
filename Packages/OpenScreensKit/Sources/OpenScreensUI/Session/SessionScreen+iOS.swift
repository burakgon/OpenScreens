#if os(iOS)
import OpenScreensCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A session on iPhone and iPad: the remote screen on all of the display it
/// can be seen on, and the controls out of its way.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    let session: RemoteSession
    let onClose: () -> Void

    @State private var showsCurtainPrompt = false
    @State private var showsSettings = false
    @State private var showsCloseConfirmation = false
    /// Whether the trackpad deck is out. Nil leaves it to how the device is
    /// being held.
    @State private var deckChoice: Bool? = SessionScreen.initialDeckChoice
    @State private var hardwareKeyboard = HardwareKeyboardMonitor()

    private var bridge: CanvasBridge { session.canvasBridge }

    private static var initialDeckChoice: Bool? {
        #if DEBUG
        if DebugAutomation.startsWithDeck { return true }
        #endif
        return nil
    }

    /// The trackpad deck appears when asked for, and by itself on a foldable
    /// set down half open like a laptop.
    private func showsDeck(in size: CGSize) -> Bool {
        guard session.isConnected else { return false }
        return deckChoice ?? (bridge.hingeIsPartiallyOpen && size.width > size.height)
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
            }
            .animation(.smooth(duration: 0.3), value: deckVisible)
            .onChange(of: deckHeight, initial: true) { _, height in
                // The picture goes down to the edge of the screen, and
                // the deck stands on the part the system keeps clear.
                bridge.deckInset = height > 0 ? height + geometry.safeAreaInsets.bottom : 0
                bridge.isDeckVisible = height > 0
                bridge.canvas?.setNeedsLayout()
                bridge.canvas?.refreshCursorVisibility()
            }
            .overlay {
                if session.isConnected {
                    SessionControls(
                        session: session,
                        deckIsOut: deckVisible,
                        showsHardwareKeyboardHint: hardwareKeyboard.isAttached,
                        onToggleDeck: { deckChoice = !deckVisible },
                        onCurtain: toggleCurtain,
                        onSettings: { showsSettings = true },
                        onClose: requestClose)
                        .ignoresSafeArea()
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(!(bridge.chromeLayout?.showsStatusBar ?? false))
        // The picture is dark at its edges and the status bar is over black.
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        // An edge of the screen is an edge of the remote desktop first: its
        // Dock, its menu bar. A swipe for the system takes a second try.
        .defersSystemGestures(on: .all)
        .onChange(of: bridge.hingeIsPartiallyOpen) { _, isHalfOpen in
            // Turning the deck away lasts for as long as the device is held
            // the way that brought it out.
            if !isHalfOpen, deckChoice == false {
                deckChoice = nil
            }
        }
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

/// The controls of a session on a touch screen.
///
/// The picture is someone's desktop, with a Dock along one edge and a menu
/// bar along another, and controls left standing over it are in the way of
/// one of them. So they stand beside the picture where the screen has a
/// strip the picture cannot use, and everywhere else they are put away to a
/// small handle as soon as the remote screen is touched.
struct SessionControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    let session: RemoteSession
    let deckIsOut: Bool
    let showsHardwareKeyboardHint: Bool
    let onToggleDeck: () -> Void
    let onCurtain: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    /// Whether the controls are out, where they can be put away.
    @State private var isOut = true
    /// Whether the controls have been touched since they came out.
    @State private var wasUsed = false
    @State private var dragOffset = CGSize.zero
    @State private var screenshotURL: URL?
    @State private var showsTypeText = false
    @State private var showsFilePicker = false
    @State private var showsFiles = false

    private var bridge: CanvasBridge { session.canvasBridge }
    private var staysOut: Bool { model.settings.keepsSessionControlsVisible }
    private var edge: SessionControlsEdge { model.settings.sessionControlsEdge }

    /// How long the controls stay out when a session opens, for someone to
    /// see that they are there and where they go.
    private static let introduction: Duration = .seconds(4)

    var body: some View {
        GeometryReader { geometry in
            let layout = bridge.chromeLayout
                ?? SessionChromeLayout(size: geometry.size, safeArea: .zero)
            switch layout.controls {
            case .strip(let strip):
                bar(.vertical)
                    // A status bar shown in the strip is at its top, and the
                    // screen's corners are at both ends.
                    .frame(
                        width: strip.width, height: max(strip.height - 44, 0),
                        alignment: layout.showsStatusBar ? .bottom : .center)
                    .position(x: strip.midX, y: strip.midY)
            case .floating:
                floating(layout)
            }
        }
        .animation(.smooth(duration: 0.25), value: isOut)
        .animation(.smooth(duration: 0.25), value: staysOut)
        .animation(.smooth(duration: 0.3), value: edge)
        .task(id: session.id) {
            try? await Task.sleep(for: Self.introduction)
            if !wasUsed {
                isOut = false
            }
        }
        .onChange(of: bridge.canvasTouches) {
            // Back to the remote screen: the controls have done their work.
            isOut = false
        }
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
    }

    // MARK: Over the picture

    private func floating(_ layout: SessionChromeLayout) -> some View {
        let shown = isOut || staysOut
        // What covers the bottom of the screen: a keyboard, the deck, or
        // only the part the system keeps for the home indicator.
        let covered = max(bridge.bottomObstruction, layout.safeArea.bottom)
        return VStack(spacing: 0) {
            if edge == .bottom { Spacer(minLength: 0) }
            Group {
                if shown {
                    bar(.horizontal)
                        .padding(.top, layout.pictureInsets.top + 8)
                        .padding(.bottom, covered + 8)
                } else {
                    handle
                        // Beside a sensor housing the handle is mostly
                        // above the picture, just clear of the housing.
                        // Anywhere else it sits on the top of the picture,
                        // and not above it: the strip left clear for a
                        // screen's corners is the system's to take taps in.
                        .padding(.top, layout.pictureInsets.top >= SessionChromeLayout.shallowestHousing
                            ? layout.pictureInsets.top - 18
                            : layout.pictureInsets.top)
                        .padding(.bottom, max(bridge.bottomObstruction, 2))
                }
            }
            .offset(dragOffset)
            .gesture(edgeDrag)
            if edge == .top { Spacer(minLength: 0) }
        }
        .padding(.leading, layout.pictureInsets.left + 10)
        .padding(.trailing, layout.pictureInsets.right + 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What is left of the controls while they are put away.
    private var handle: some View {
        Button {
            wasUsed = true
            isOut = true
        } label: {
            Capsule()
                .fill(.primary.opacity(0.7))
                .frame(width: 30, height: 4)
                .frame(width: 58, height: 16)
                .glassEffect(.regular.interactive(), in: .capsule)
                .frame(width: 96, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Controls")
        .transition(.opacity.combined(with: .scale(scale: 0.7)))
    }

    /// Dragging the controls, or their handle, towards the middle of the
    /// screen brings them out; dragging them most of the way across moves
    /// them to the other edge.
    private var edgeDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                let inward = edge == .top
                    ? value.predictedEndTranslation.height
                    : -value.predictedEndTranslation.height
                wasUsed = true
                withAnimation(.smooth(duration: 0.3)) {
                    if inward > 220 {
                        model.settings.sessionControlsEdge = edge == .top ? .bottom : .top
                    } else if inward > 16 {
                        isOut = true
                    }
                    dragOffset = .zero
                }
            }
    }

    // MARK: The bar

    /// The controls in a row, or one above the other in a strip.
    private func bar(_ axis: Axis) -> some View {
        // In a row or column of their own when there is room for all of
        // them, and one that scrolls when there is not.
        ViewThatFits(in: axis == .horizontal ? .horizontal : .vertical) {
            stack(axis)
            ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                stack(axis)
            }
        }
        .frame(maxWidth: axis == .horizontal ? 560 : nil)
        .glassEffect(.regular, in: .capsule)
        .simultaneousGesture(TapGesture().onEnded { wasUsed = true })
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    @ViewBuilder
    private func stack(_ axis: Axis) -> some View {
        let spacing: CGFloat = sizeClass == .compact ? 2 : 6
        if axis == .horizontal {
            HStack(spacing: spacing) { buttons }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        } else {
            VStack(spacing: spacing) { buttons }
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
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

        ToolbarButton("Trackpad Deck", systemName: "rectangle.bottomhalf.inset.filled", isActive: deckIsOut) {
            onToggleDeck()
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
            if case .floating = bridge.chromeLayout?.controls ?? .floating {
                Divider()
                Toggle(isOn: $settings.keepsSessionControlsVisible) {
                    Label("Keep Controls in View", systemImage: "pin")
                }
                Button(
                    edge == .top ? "Move Controls to the Bottom" : "Move Controls to the Top",
                    systemImage: edge == .top ? "arrow.down.to.line" : "arrow.up.to.line"
                ) {
                    model.settings.sessionControlsEdge = edge == .top ? .bottom : .top
                }
            }
        } label: {
            ToolbarIcon(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")

        ToolbarButton("Disconnect", systemName: "xmark", tint: .red, action: onClose)
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

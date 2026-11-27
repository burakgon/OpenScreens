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
    /// Whether the deck of keys is out. Nil leaves it to how the device is
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

    /// The deck appears when asked for, then as the way the device is held
    /// has been set to answer, and if neither says anything then by itself on
    /// a foldable set down half open like a laptop.
    ///
    /// A foldable set down like a laptop gets its keyboard and trackpad the
    /// moment it is, whatever was said about the key row in another posture
    /// and without waiting for the connection: the lower half has no picture
    /// on it, and an empty half would look broken. Only putting it away
    /// while held that way puts it away.
    private func showsDeck(in size: CGSize) -> Bool {
        if isLaptopLike(size) { return deckChoice ?? true }
        guard session.isConnected else { return false }
        if let deckChoice { return deckChoice }
        if let chosen = session.computer.settings.postures[session.devicePosture].showsDeck {
            return chosen
        }
        return isLaptopLike(size)
    }

    private var display: ExternalDisplay { .shared }

    var body: some View {
        Group {
            if display.isConnected {
                // The desktop is on the display; the phone is what is under
                // a laptop's screen.
                ExternalDisplayControls(session: session, onClose: requestClose)
            } else {
                onPhone
            }
        }
        // While a session is open, a connected display is asked for and the
        // desktop is drawn there.
        .background {
            ExternalDisplayAccessory()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(.keyboard)
        // Always, and never as a function of the layout: whether the bar
        // shows changes what the screen keeps clear, which is what the
        // layout is worked out from.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // An edge of the screen is an edge of the remote desktop first: its
        // Dock, its menu bar. A swipe for the system takes a second try.
        .defersSystemGestures(on: .all)
        .onChange(of: bridge.hingeIsPartiallyOpen) { _, isHalfOpen in
            // Set down like a laptop, the keyboard comes out whatever was
            // chosen before; turning it away lasts for as long as the device
            // is held that way.
            if isHalfOpen || deckChoice == false {
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
        .onAppear { display.session = session }
        .onDisappear {
            if display.session === session {
                display.session = nil
            }
        }
        .onChange(of: display.isConnected, initial: true) { wasConnected, isConnected in
            if isConnected {
                // Nothing of the phone's screen covers the desktop, and how
                // the phone is folded has no bearing on it.
                bridge.deckInset = 0
                bridge.deckIsLaptop = false
                session.devicePostureChanged(to: .open)
            } else if wasConnected {
                // Back on the phone, where the fold counts again.
                session.devicePostureChanged(to: DevicePosture.resolve(
                    hingeIsClosed: bridge.hingeIsClosed,
                    hingeIsLaptopLike: bridge.hingeIsPartiallyOpen))
            }
        }
        .onChange(of: hardwareKeyboard.isAttached, initial: true) { _, attached in
            bridge.hasHardwareKeyboard = attached
            if attached {
                bridge.hideKeyboard()
            }
        }
    }

    /// The session on the phone's own screen, with the deck under it when
    /// there is one.
    private var onPhone: some View {
        GeometryReader { geometry in
            let deckVisible = showsDeck(in: geometry.size)
            let deckIsLaptop = deckVisible && isLaptopLike(geometry.size)
            let deckHeight = deckVisible
                ? deckHeight(in: geometry.size, safeArea: geometry.safeAreaInsets) : 0

            ZStack(alignment: .bottom) {
                SessionView(session: session, onClose: onClose)

                if deckVisible {
                    Group {
                        if deckIsLaptop {
                            // The whole half under the crease, made into the
                            // keyboard and trackpad of a laptop.
                            LaptopDeck(session: session)
                        } else {
                            ControlDeck(session: session)
                        }
                    }
                    .frame(height: deckHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: deckVisible)
            .onChange(of: deckHeight, initial: true) { _, height in
                // The picture goes down to the edge of the screen, and
                // the deck stands on the part the system keeps clear.
                bridge.deckInset = height > 0 ? height + geometry.safeAreaInsets.bottom : 0
                bridge.deckIsLaptop = deckIsLaptop
                bridge.canvas?.setNeedsLayout()
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
    }

    /// Whether the device is stood up half open with the fold running
    /// across the screen, the way a laptop is.
    ///
    /// The hinge says how far it is open but not which way it runs, so the
    /// shape of the window says it: the Duo's fold crosses its inner screen
    /// held upright, and a half-open Duo turned on its side is a book, not a
    /// laptop.
    private func isLaptopLike(_ size: CGSize) -> Bool {
        bridge.hingeIsPartiallyOpen && size.height > size.width
    }

    private func deckHeight(in size: CGSize, safeArea: EdgeInsets) -> CGFloat {
        if isLaptopLike(size) {
            // The fold runs across the middle of the screen, which is not
            // the middle of the part the system keeps clear: the two ends of
            // the screen keep different amounts back. So the half below it
            // is measured from the edges of the screen, and given to the
            // keyboard and trackpad, so that the picture stops above the
            // crease and the keys start below it.
            let screenHeight = size.height + safeArea.top + safeArea.bottom
            return max(screenHeight / 2 - safeArea.bottom, 0)
        }
        return ControlDeck.height
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
                    .disabled(draft == session.computer.settings)
                }
            }
        }
        // The computer's own settings, not the ones in force: while the
        // device is folded, what a session works to has the folded posture's
        // changes over the top, and applying that would save a fold as an
        // edit someone made.
        .onAppear { draft = session.computer.settings }
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
                    // The screen's corners are at both ends of the strip.
                    .frame(width: strip.width, height: max(strip.height - 44, 0))
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

        ToolbarButton("Key Row", systemName: "keyboard.badge.ellipsis", isActive: deckIsOut) {
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

/// The phone while the desktop is on a display of its own: the whole screen
/// a trackpad, the phone's own keyboard to type with, and a strip along the
/// top for what the session controls would otherwise give.
///
/// Signing in and anything that goes wrong are shown here, over the
/// trackpad, because the phone is what is in the hand and the display cannot
/// be touched.
private struct ExternalDisplayControls: View {
    let session: RemoteSession
    let onClose: () -> Void

    @State private var showsKeyboard = false

    var body: some View {
        ZStack {
            Color(white: 0.13)
                .ignoresSafeArea()

            GeometryReader { geometry in
                let isUpright = geometry.size.height > geometry.size.width
                // Held on its side, a phone keeps room clear of its camera
                // on one side only. The same room on both sides keeps the
                // trackpad in the middle, and out from under the camera.
                // Upright, the camera is above, and the trackpad goes from
                // one edge to the other.
                let side = isUpright
                    ? 0 : max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing)
                let width = geometry.size.width + geometry.safeAreaInsets.leading
                    + geometry.safeAreaInsets.trailing - 2 * side - 20
                VStack(spacing: 10) {
                    bar
                    // A trackpad is wider than it is tall, however the phone
                    // is held. Upright that leaves the bottom of the screen
                    // over, which is where the keyboard comes up.
                    trackpad
                        .frame(height: isUpright ? max(width / 1.5, 0) : nil)
                    if isUpright {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .safeAreaPadding(.horizontal, side)
                .ignoresSafeArea(.container, edges: .horizontal)
            }

            if !session.isConnected {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                SessionStatusOverlay(session: session, onClose: onClose)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.28), value: session.phase)
        .onChange(of: session.isConnected) { _, connected in
            if !connected {
                showsKeyboard = false
            }
        }
        .task(id: session.id) {
            // Starting is the canvas's to do on the phone. Here it is on the
            // display, so the phone does it, a moment later so that the
            // display's canvas has been laid out and the desktop is made the
            // display's size from the first.
            try? await Task.sleep(for: .milliseconds(80))
            session.start()
        }
    }

    /// The screen below the strip, drawn as a trackpad and working as one.
    private var trackpad: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return TypingTrackpad(session: session, showsKeyboard: $showsKeyboard)
            .background {
                shape.fill(LinearGradient(
                    colors: [Color(white: 0.25), Color(white: 0.2)],
                    startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if session.isConnected, !showsKeyboard {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 34, weight: .light))
                        Text("Move with one finger, scroll with two.\nSwipe with three for Mission Control and Spaces.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Label("On the External Display", systemImage: "display")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 14)
            Spacer(minLength: 8)
            if session.isConnected {
                ToolbarButton(
                    showsKeyboard ? "Hide Keyboard" : "Keyboard",
                    systemName: showsKeyboard ? "keyboard.chevron.compact.down" : "keyboard",
                    isActive: showsKeyboard
                ) {
                    showsKeyboard.toggle()
                }
                Menu {
                    ShortcutMenuItems(session: session)
                } label: {
                    ToolbarIcon(systemName: "command")
                }
                .accessibilityLabel("Shortcuts")
            }
            ToolbarButton("Disconnect", systemName: "xmark", tint: .red, action: onClose)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 4)
    }
}

/// The trackpad, which is also what the phone's keyboard types into.
private struct TypingTrackpad: UIViewRepresentable {
    let session: RemoteSession
    @Binding var showsKeyboard: Bool

    func makeUIView(context: Context) -> TypingTrackpadView {
        TypingTrackpadView(session: session)
    }

    func updateUIView(_ view: TypingTrackpadView, context: Context) {
        view.onKeyboardHidden = { [$showsKeyboard] in
            $showsKeyboard.wrappedValue = false
        }
        if showsKeyboard, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !showsKeyboard, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

/// A trackpad that takes the phone's keyboard as well.
///
/// The canvas is what is typed into on the phone's own screen. With the
/// desktop on a display that cannot be touched, the canvas is there and
/// cannot have the keyboard, so the trackpad has it instead: the letters are
/// typed on the remote computer, with the row of modifiers, Escape, Tab and
/// arrows above the keys as on the phone's own screen.
final class TypingTrackpadView: UIView, UIKeyInput {
    private let session: RemoteSession
    /// Told when the keyboard goes away by itself, to keep the button that
    /// brings it out in step.
    var onKeyboardHidden: (() -> Void)?
    private lazy var accessory: UIView = makeAccessory()

    init(session: RemoteSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        let pad = LaptopTrackpadView(session: session)
        pad.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pad)
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: leadingAnchor),
            pad.trailingAnchor.constraint(equalTo: trailingAnchor),
            pad.topAnchor.constraint(equalTo: topAnchor),
            pad.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { accessory }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // After the update that asked for it, never during it.
            Task { @MainActor [weak self] in
                self?.onKeyboardHidden?()
            }
        }
        return resigned
    }

    // MARK: Typing

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard session.canSendInput else { return }
        // Modifiers latched from the row above the keys wrap the next
        // character, which is what turns "c" into ⌘C.
        session.type(text)
    }

    func deleteBackward() {
        guard session.canSendInput else { return }
        session.tap(.special(.delete))
    }

    // The remote computer has its own ideas about correction and
    // capitalisation; the phone's keyboard should not second-guess them.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    private func makeAccessory() -> UIView {
        let bar = KeyboardAccessoryBar(
            session: session, bridge: session.canvasBridge,
            onHide: { [weak self] in self?.resignFirstResponder() })
        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        let container = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardAccessoryBar.height),
            inputViewStyle: .keyboard)
        container.allowsSelfSizing = true
        container.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: KeyboardAccessoryBar.height),
        ])
        return container
    }
}
#endif

import OpenScreensCore
import SwiftUI

/// The form sections that edit a ``ConnectionSettings`` value.
///
/// Used in three places — a computer's editor, the app-wide defaults, and the
/// live session inspector — so a setting looks and reads the same wherever it
/// is changed.
struct ConnectionSettingsForm: View {
    @Binding var settings: ConnectionSettings
    /// The kind of computer being configured, which decides what is offered.
    var kind: ComputerKind = .mac

    private var isHighPerformance: Bool {
        settings.quality == .highPerformance
    }

    var body: some View {
        pictureSection
        if kind.isApple {
            soundSection
        }
        controlSection
        keyboardSection
        privacySection
        reliabilitySection
    }

    private var pictureSection: some View {
        Section {
            Picker("Mode", selection: $settings.quality) {
                ForEach(QualityMode.allCases) { mode in
                    if mode != .highPerformance || kind.isApple {
                        Text(mode.title).tag(mode)
                    }
                }
            }

            if kind.isApple {
                Picker("Desktop Size", selection: $settings.resolution) {
                    ForEach(ResolutionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!isHighPerformance)

                if isHighPerformance, settings.resolution == .matchWindow {
                    Toggle(isOn: $settings.moreSpace) {
                        Text("More Space on Small Screens")
                        Text("A desktop wide enough for every Mac window, even on a phone. Text is smaller and the picture takes more to send.")
                    }
                }

                Picker("Displays", selection: $settings.displays) {
                    ForEach(DisplayLayout.allCases) { layout in
                        if layout != .twoVirtual || isHighPerformance {
                            Text(layout.title).tag(layout)
                        }
                    }
                }
            }

            Picker("Scaling", selection: $settings.scaling) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if !isHighPerformance {
                Picker("Colours", selection: $settings.colorDepth) {
                    ForEach(ColorDepth.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
            }

            Picker("Frame Rate", selection: $settings.frameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
        } header: {
            Text("Picture")
        } footer: {
            Text(settings.quality.summary)
        }
        .onChange(of: settings.quality) { _, quality in
            // Keep dependent options valid for the chosen mode.
            if quality != .highPerformance {
                settings.resolution = .remote
                if settings.displays == .twoVirtual {
                    settings.displays = .single
                }
            }
        }
        .onChange(of: settings.displays) { _, layout in
            switch layout {
            case .twoVirtual: settings.resolution = .matchWindow
            case .allCombined: settings.resolution = .remote
            case .single: break
            }
        }
    }

    private var soundSection: some View {
        Section {
            Toggle("Play Sound from the Remote Mac", isOn: $settings.remoteAudio)
            Toggle("Keep Video in Sync with Sound", isOn: $settings.syncVideoToAudio)
                .disabled(!settings.remoteAudio)
        } header: {
            Text("Sound")
        } footer: {
            Text("Sound needs High Performance mode with the desktop sized to fit. Syncing adds a little delay and is best for watching video.")
        }
        .disabled(!isHighPerformance || settings.resolution != .matchWindow)
    }

    private var controlSection: some View {
        Section {
            Toggle("Observe Only", isOn: $settings.observeOnly)

            Picker("Pointer", selection: $settings.cursor) {
                ForEach(CursorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            #if os(iOS)
            Picker("Touch Controls", selection: $settings.touchInput) {
                ForEach(TouchInputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            LabeledContent("Pointer Speed") {
                Slider(value: $settings.pointerSpeed, in: 0.5...2.5, step: 0.1)
            }
            #endif

            Toggle("Natural Scrolling", isOn: $settings.naturalScrolling)
            LabeledContent("Scroll Speed") {
                Slider(value: $settings.scrollSpeed, in: 0.25...3, step: 0.25)
            }

        } header: {
            Text("Control")
        }
    }

    private var keyboardSection: some View {
        Section {
            Picker("Typing", selection: keyboardInput) {
                ForEach(KeyboardInputMode.choices(for: kind)) { mode in
                    Text(mode.title(for: kind)).tag(mode)
                }
            }

            Toggle("Send System Shortcuts", isOn: $settings.captureSystemShortcuts)

            if !kind.isApple {
                Toggle("Use ⌘ as Control", isOn: $settings.swapCommandAndControl)
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text(keyboardInput.wrappedValue.explanation(for: kind) + " " + shortcutsFooter)
        }
    }

    /// The typing mode, shown as one of the choices this kind of computer
    /// has: a setting carried over from another kind falls back to Automatic.
    private var keyboardInput: Binding<KeyboardInputMode> {
        Binding {
            KeyboardInputMode.choices(for: kind).contains(settings.keyboardInput)
                ? settings.keyboardInput
                : .automatic
        } set: {
            settings.keyboardInput = $0
        }
    }

    private var shortcutsFooter: String {
        kind.isApple
            ? "With system shortcuts on, combinations such as ⌘Q and ⌘W act on the remote Mac while the pointer is over its screen."
            : "With ⌘ as Control, familiar shortcuts such as ⌘C and ⌘V work as Ctrl+C and Ctrl+V on the remote computer."
    }

    private var privacySection: some View {
        Section {
            Toggle("Share Clipboard", isOn: $settings.sharedClipboard)
            if kind.isApple {
                Toggle("Turn On Curtain Mode When Connecting", isOn: $settings.curtainOnConnect)
                if settings.curtainOnConnect {
                    TextField("Message on the Locked Screen", text: $settings.curtainMessage, prompt: Text("Optional"))
                }
                Toggle("Lock the Mac When Disconnecting", isOn: $settings.lockOnDisconnect)
                Toggle("Offer to Type the Password at the Login Window", isOn: $settings.offerPasswordAtLoginWindow)
            }
        } header: {
            Text("Clipboard & Privacy")
        } footer: {
            if kind.isApple {
                Text("Curtain Mode hides the remote Mac's own display behind a lock screen while you work.")
            }
        }
    }

    private var reliabilitySection: some View {
        Section("Reliability") {
            Toggle("Reconnect Automatically", isOn: $settings.reconnectAutomatically)
            if kind.isApple {
                Toggle("Fall Back to Standard If Needed", isOn: $settings.fallBackToStandard)
                    .disabled(!isHighPerformance)
            }
        }
    }
}

/// Chooses which SSH key a computer signs in with.
struct SSHKeyPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    var body: some View {
        if let keys = try? model.sshKeys.keys() {
            if keys.isEmpty {
                LabeledContent("Key") {
                    Text("No keys yet — add one in Settings › SSH Keys")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Key", selection: $selection) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(keys) { key in
                        Text(key.name).tag(UUID?.some(key.id))
                    }
                }
            }
        } else {
            // Not the same as having none: Settings › SSH Keys says why.
            LabeledContent("Key") {
                Text("Your keys could not be read from the keychain")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

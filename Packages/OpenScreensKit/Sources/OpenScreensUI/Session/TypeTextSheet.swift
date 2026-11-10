import OpenScreensCore
import SwiftUI

/// Compose text locally, then type it on the remote computer.
///
/// Writing in a local field first means everything the device offers for
/// text works: dictation, emoji, input methods for other scripts, password
/// managers, autocorrection. The finished text is then typed remotely as
/// characters.
struct TypeTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession

    @State private var text = ""
    @State private var pressesReturn = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
                    .focused($isFocused)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Type, dictate or paste text here.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                Toggle("Press Return Afterwards", isOn: $pressesReturn)

                Text("The text is typed on \(session.computer.displayName) wherever its cursor is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Type Text")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Type") {
                        send()
                    }
                    .disabled(text.isEmpty || !session.canSendInput)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 320)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .onAppear { isFocused = true }
        .onDisappear { session.requestKeyboardFocus() }
    }

    private func send() {
        let pending = text
        let finishWithReturn = pressesReturn
        dismiss()
        // Let the sheet get out of the way so the remote window is active
        // again before the keystrokes arrive.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            for line in pending.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.offset > 0 {
                    session.tap(.special(.returnKey))
                }
                session.type(String(line.element))
            }
            if finishWithReturn {
                session.tap(.special(.returnKey))
            }
        }
    }
}

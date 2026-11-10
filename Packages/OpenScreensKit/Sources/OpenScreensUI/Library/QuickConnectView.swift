import OpenScreensCore
import SwiftUI

/// Connect to an address without adding it to the library first.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    let onConnect: (ConnectionTarget) -> Void

    @State private var address = ""
    @State private var kind = ComputerKind.mac
    @FocusState private var addressFocused: Bool

    private var target: ConnectionTarget? {
        guard var target = ConnectionTarget(text: address) else { return nil }
        target.kind = kind
        return target
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text("Quick Connect")
                    .font(.title2.weight(.semibold))
                Text("Enter a host name, an IP address or a vnc:// link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    TextField("studio.local, 192.168.1.20:5901, user@host", text: $address)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .focused($addressFocused)
                        .submitLabel(.go)
                        .onSubmit(connect)
                    if !address.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") {
                            address = ""
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    } else if let pasted = Pasteboard.string, ConnectionTarget(text: pasted) != nil {
                        Button("Paste") {
                            address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))

                Picker("Kind", selection: $kind) {
                    ForEach(ComputerKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if !address.isEmpty, target == nil {
                    Label("That doesn't look like an address.", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect", action: connect)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 480)
        .presentationDetents([.medium])
        .onAppear { addressFocused = true }
    }

    private func connect() {
        guard let target else { return }
        dismiss()
        onConnect(target)
    }
}

import OpenScreensCore
import SwiftUI

/// Computers on the local network.
struct NearbyContent: View {
    @Environment(AppModel.self) private var model
    let searchText: String

    var body: some View {
        let computers = model.nearbyComputers.filter { $0.matches(searchText) }
        if !computers.isEmpty {
            DiscoveredList(computers: computers)
        } else if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.nearby.state {
        case .denied:
            ContentUnavailableView {
                Label("Local Network Access Is Off", systemImage: "network.slash")
            } description: {
                Text("OpenScreens needs access to your local network to find computers on it. You can still connect by typing an address.")
            } actions: {
                Button("Open Settings") {
                    SystemSettings.openLocalNetworkPrivacy()
                }
                .buttonStyle(.glass)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Look for Computers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    model.nearby.start()
                }
                .buttonStyle(.glass)
            }
        case .idle, .searching:
            ContentUnavailableView {
                Label("Looking for Computers", systemImage: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } description: {
                Text("Macs with Screen Sharing turned on, and other computers running a VNC server, appear here when they are on the same network.")
            }
        }
    }
}

/// Devices in the user's tailnet.
struct TailscaleContent: View {
    @Environment(AppModel.self) private var model
    let searchText: String

    var body: some View {
        let computers = model.tailnetComputers.filter { $0.matches(searchText) }
        Group {
            if !computers.isEmpty {
                DiscoveredList(computers: computers)
            } else if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                emptyState
            }
        }
        .task {
            await model.tailscale.refresh()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.tailscale.state {
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Reach Tailscale", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.tailscale.refresh() }
                }
                .buttonStyle(.glass)
            }
        case .loading:
            ContentUnavailableView {
                Label("Loading Your Tailnet", systemImage: "point.3.connected.trianglepath.dotted")
                    .symbolEffect(.pulse, options: .repeating)
            }
        case .notConfigured:
            ContentUnavailableView {
                Label("Tailscale Is Not Set Up", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Add an access token in Settings to list the computers in your tailnet.")
            }
        case .ready:
            ContentUnavailableView {
                Label("No Computers to Connect To", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text(model.settings.hidesOfflineTailscaleDevices
                    ? "None of the computers in your tailnet are online."
                    : "Your tailnet has no computers that can share their screen.")
            }
        }
    }
}

/// Discovered computers, laid out the way the library is.
private struct DiscoveredList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.libraryActions) private var actions
    @Environment(\.horizontalSizeClass) private var sizeClass
    let computers: [DiscoveredComputer]

    var body: some View {
        switch model.settings.libraryLayout {
        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(computers) { computer in
                        DiscoveredCard(computer: computer, saved: model.savedComputer(for: computer))
                            #if os(macOS)
                            .onTapGesture(count: 2) { connect(computer) }
                            #else
                            .onTapGesture { connect(computer) }
                            #endif
                            .contextMenu { menu(for: computer) }
                    }
                }
                .padding(16)
            }
        case .list:
            List {
                ForEach(computers) { computer in
                    DiscoveredRow(computer: computer, saved: model.savedComputer(for: computer))
                        .contextMenu { menu(for: computer) }
                        #if os(macOS)
                        .onTapGesture(count: 2) { connect(computer) }
                        #else
                        .onTapGesture { connect(computer) }
                        #endif
                }
            }
        }
    }

    private var columns: [GridItem] {
        sizeClass == .compact
            ? [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 10)]
            : [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12)]
    }

    private func connect(_ computer: DiscoveredComputer) {
        if let saved = model.savedComputer(for: computer) {
            actions.connect(saved, nil)
        } else if let target = computer.target {
            actions.open(target)
        }
    }

    @ViewBuilder
    private func menu(for computer: DiscoveredComputer) -> some View {
        let saved = model.savedComputer(for: computer)
        Button("Connect", systemImage: "play.fill") {
            connect(computer)
        }
        .disabled(computer.host == nil)

        if let saved {
            Button("Edit…", systemImage: "pencil") {
                actions.edit(saved)
            }
        } else {
            Button("Add to Library…", systemImage: "plus") {
                actions.add(computer.template(defaults: model.settings.defaultConnection))
            }
            .disabled(computer.host == nil)
        }

        if let host = computer.host {
            Divider()
            Button("Copy Address", systemImage: "doc.on.doc") {
                Pasteboard.copy(host)
            }
        }
    }
}

private struct DiscoveredCard: View {
    @Environment(AppModel.self) private var model
    let computer: DiscoveredComputer
    let saved: Computer?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComputerArtwork(
                computer: saved ?? computer.template(defaults: model.settings.defaultConnection),
                showsPreview: saved != nil && model.settings.savesSessionPreviews,
                symbolName: computer.symbolName)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
                .overlay(alignment: .bottomLeading) {
                    DiscoveredStatus(computer: computer, saved: saved)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                }
                .saturation(computer.isOnline ? 1 : 0.2)
                .opacity(computer.isOnline ? 1 : 0.7)
                .shadow(color: .black.opacity(isHovering ? 0.22 : 0.12), radius: isHovering ? 14 : 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(saved?.displayName ?? computer.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(computer.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.smooth(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [computer.name, computer.kind.title, computer.subtitle]
        if let detail = computer.detail { parts.append(detail) }
        if !computer.isOnline { parts.append("Offline") }
        if saved != nil { parts.append("In your library") }
        return parts.joined(separator: ", ")
    }
}

private struct DiscoveredRow: View {
    let computer: DiscoveredComputer
    let saved: Computer?

    var body: some View {
        HStack(spacing: 12) {
            ComputerIcon(
                kind: computer.kind,
                color: saved?.accentColor ?? computer.kind.defaultColor,
                size: 34)
                .saturation(computer.isOnline ? 1 : 0.2)
            VStack(alignment: .leading, spacing: 1) {
                Text(saved?.displayName ?? computer.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(computer.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            DiscoveredStatus(computer: computer, saved: saved)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }
}

/// The one thing most worth knowing about a discovered computer.
private struct DiscoveredStatus: View {
    let computer: DiscoveredComputer
    let saved: Computer?

    var body: some View {
        if !computer.isOnline {
            StatusPill("Offline", color: .secondary)
        } else if saved != nil {
            StatusPill("In Library", systemName: "checkmark", color: .secondary)
        } else if let detail = computer.detail {
            StatusPill(detail, systemName: computer.symbolName, color: .secondary)
        } else if computer.supportsSSH {
            StatusPill("SSH", systemName: "lock.fill", color: .secondary)
        }
    }
}

/// Deep links into the system's own settings.
enum SystemSettings {
    static func openLocalNetworkPrivacy() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

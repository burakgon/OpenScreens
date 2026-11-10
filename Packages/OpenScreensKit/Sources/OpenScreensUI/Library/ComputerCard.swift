import OpenScreensCore
import SwiftUI

/// A computer in the library grid.
struct ComputerCard: View {
    @Environment(AppModel.self) private var model
    let computer: Computer
    var isSelected = false

    @State private var isHovering = false

    private var isLive: Bool {
        model.sessions.session(for: computer.id)?.isConnected ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(computer.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if computer.ssh.isEnabled {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Secure tunnel")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        }
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.smooth(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var artwork: some View {
        ComputerArtwork(computer: computer, showsPreview: model.settings.savesSessionPreviews)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if computer.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .padding(7)
                        .glassEffect(.regular, in: .circle)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isLive {
                    StatusPill("Connected", color: .green)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                }
            }
            .shadow(color: .black.opacity(isHovering ? 0.22 : 0.12), radius: isHovering ? 14 : 8, y: 4)
    }

    private var subtitle: String {
        if let username = computer.username, !username.isEmpty {
            return "\(username) · \(computer.displayAddress)"
        }
        return computer.displayAddress
    }

    private var accessibilityText: String {
        var parts = [computer.displayName, computer.kind.title, computer.displayAddress]
        if computer.isFavorite { parts.append("Favorite") }
        if isLive { parts.append("Connected") }
        return parts.joined(separator: ", ")
    }
}

/// A computer in the library list.
struct ComputerRow: View {
    @Environment(AppModel.self) private var model
    let computer: Computer

    var body: some View {
        HStack(spacing: 12) {
            ComputerIcon(kind: computer.kind, color: computer.accentColor, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(computer.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if computer.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(computer.displayAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if model.sessions.session(for: computer.id)?.isConnected ?? false {
                StatusPill("Connected", color: .green)
            } else if let last = computer.lastConnectedAt {
                Text(last.relativeDescription)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }
}

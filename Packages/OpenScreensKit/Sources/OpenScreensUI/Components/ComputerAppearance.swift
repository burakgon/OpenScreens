import OpenScreensCore
import SwiftUI

extension ComputerTint {
    /// The colour for a tint, or `nil` to derive one from the kind of computer.
    var color: Color? {
        switch self {
        case .automatic: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }
}

extension ComputerKind {
    var defaultColor: Color {
        switch self {
        case .mac: .blue
        case .windows: .teal
        case .linux: .orange
        case .raspberryPi: .pink
        case .other: .indigo
        }
    }
}

extension Computer {
    /// The accent colour used for this computer's card and icon.
    var accentColor: Color {
        tint.color ?? kind.defaultColor
    }
}

extension QualityMode {
    var color: Color {
        switch self {
        case .highPerformance: .yellow
        case .standard: .blue
        case .fullQuality: .purple
        }
    }
}

/// The picture on a computer's card: its last-seen screen when there is one,
/// otherwise a soft gradient in the computer's colour with its icon.
struct ComputerArtwork: View {
    let computer: Computer
    var showsPreview = true
    /// A more specific symbol than the computer's kind gives, when the
    /// hardware is known.
    var symbolName: String?

    var body: some View {
        let preview = showsPreview ? PreviewStore.shared.image(for: computer.id) : nil
        ZStack {
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        let color = computer.accentColor
        return ZStack {
            LinearGradient(
                colors: [color.opacity(0.85), color.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            // A soft highlight keeps large flat cards from looking dead.
            RadialGradient(
                colors: [.white.opacity(0.28), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260)
            Image(systemName: symbolName ?? computer.kind.symbolName)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }
}

/// A small rounded icon for list rows and menus.
struct ComputerIcon: View {
    let kind: ComputerKind
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.27, style: .continuous))
    }
}

extension Date {
    /// "2 hours ago" style text for last-connected labels.
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}

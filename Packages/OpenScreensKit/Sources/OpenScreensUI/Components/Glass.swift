import SwiftUI

// Shared Liquid Glass building blocks. Everything that floats above the
// remote screen or the library is built from these, so the app has one
// consistent material vocabulary.

extension View {
    /// A floating glass panel with the app's standard corner radius.
    public func glassPanel(cornerRadius: CGFloat = 26, tint: Color? = nil) -> some View {
        glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A glass capsule that responds to touch, for controls.
    public func glassControl(tint: Color? = nil, isInteractive: Bool = true) -> some View {
        glassEffect(.regular.tint(tint).interactive(isInteractive), in: .capsule)
    }

    /// Applies `transform` only when `condition` holds.
    @ViewBuilder
    public func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

/// A round glass button showing a symbol.
public struct GlassIconButton: View {
    private let systemName: String
    private let label: String
    private let isActive: Bool
    private let size: CGFloat
    private let action: () -> Void

    public init(
        _ label: String,
        systemName: String,
        isActive: Bool = false,
        size: CGFloat = 44,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemName = systemName
        self.isActive = isActive
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .medium))
                .symbolVariant(isActive ? .fill : .none)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A small status pill: a coloured dot and a label.
public struct StatusPill: View {
    private let text: String
    private let systemName: String?
    private let color: Color

    public init(_ text: String, systemName: String? = nil, color: Color = .secondary) {
        self.text = text
        self.systemName = systemName
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.caption2.weight(.semibold))
            } else {
                Circle()
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: .capsule)
    }
}

/// A key cap, as shown in shortcut lists and on the key toolbar.
public struct KeyCap: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

import OpenScreensCore
import SwiftUI

/// A remote session: the screen itself, plus whatever needs to be shown over
/// it while connecting or when something goes wrong.
public struct SessionView: View {
    @Environment(AppModel.self) private var model
    private let session: RemoteSession
    private let onClose: () -> Void

    public init(session: RemoteSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
    }

    private var isLive: Bool {
        session.phase == .connected
    }

    public var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            RemoteCanvas(session: session)
                #if os(iOS)
                // The canvas fills the screen and keeps the picture clear of
                // the notch and home indicator itself.
                .ignoresSafeArea()
                #endif
                .allowsHitTesting(isLive)
                .accessibilityLabel("Screen of \(session.computer.displayName)")

            if !isLive {
                // Keep the last picture faintly visible behind the status
                // card, so a reconnect does not feel like starting over.
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if isLive, model.settings.showsStatisticsOverlay {
                StatisticsOverlay(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .allowsHitTesting(false)
            }

            SessionStatusOverlay(session: session, onClose: onClose)
        }
        .animation(.smooth(duration: 0.28), value: session.phase)
        .task(id: session.id) {
            // Give the canvas one layout pass first, so a desktop that follows
            // the window is created at the right size from the start.
            try? await Task.sleep(for: .milliseconds(80))
            session.start()
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .ended {
                onClose()
            }
        }
    }
}

/// Live connection numbers, shown in a corner of the session.
struct StatisticsOverlay: View {
    let session: RemoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let statistics = session.statistics {
                row("Mode", statistics.quality.title)
                row("Size", "\(Int(statistics.remoteSize.width)) × \(Int(statistics.remoteSize.height))")
                if let fps = statistics.framesPerSecond {
                    row("Frames", "\(Int(fps.rounded())) fps")
                }
                if let bitrate = statistics.bitrateKbps {
                    row("Bitrate", Self.bitrate(bitrate))
                }
                if let loss = statistics.packetLossPercent, statistics.quality == .highPerformance {
                    row("Loss", String(format: "%.1f%%", loss))
                }
                if let delay = statistics.queueDelayMilliseconds, statistics.quality == .highPerformance {
                    row("Delay", "\(Int(delay.rounded())) ms")
                }
                if let encryption = statistics.encryption {
                    row("Security", encryption)
                }
            } else {
                Text("Measuring…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 14)
        .onAppear { session.setStatisticsActive(true) }
        .onDisappear { session.setStatisticsActive(false) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
        }
    }

    static func bitrate(_ kbps: Double) -> String {
        kbps >= 1000
            ? String(format: "%.1f Mbps", kbps / 1000)
            : "\(Int(kbps.rounded())) kbps"
    }
}

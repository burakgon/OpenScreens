#if DEBUG
import Foundation
import OpenScreensCore
import SwiftUI

/// Scripted launches for development and end-to-end checks.
///
/// Debug builds read a few environment variables at launch so a connection
/// can be opened, exercised and reported on without touching the interface:
///
///     OPENSCREENS_CONNECT=vnc://user:password@host   open this address
///     OPENSCREENS_QUALITY=highPerformance|standard|fullQuality
///     OPENSCREENS_RESOLUTION=matchWindow|remote
///     OPENSCREENS_DISPLAYS=single|allCombined|twoVirtual
///     OPENSCREENS_TYPE="text"                         type this once connected
///     OPENSCREENS_REPORT=/path/prefix                 write prefix.json and prefix.png
///     OPENSCREENS_REPORT_AFTER=6                      seconds to wait after connecting
///     OPENSCREENS_EXIT=1                              quit after reporting
///
/// None of this exists in release builds.
enum DebugAutomation {
    private static var didStart = false

    static func runIfRequested(model: AppModel, present: @escaping (RemoteSession) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard !didStart,
              let address = environment["OPENSCREENS_CONNECT"],
              var target = ConnectionTarget(text: address) else { return }
        didStart = true
        if let kind = environment["OPENSCREENS_KIND"].flatMap(ComputerKind.init(rawValue:)) {
            target.kind = kind
        }

        let session = model.sessions.open(target)
        session.update { settings in
            if let quality = environment["OPENSCREENS_QUALITY"].flatMap(QualityMode.init(rawValue:)) {
                settings.quality = quality
                if quality != .highPerformance {
                    settings.resolution = .remote
                }
            }
            if let resolution = environment["OPENSCREENS_RESOLUTION"].flatMap(ResolutionMode.init(rawValue:)) {
                settings.resolution = resolution
            }
            if let displays = environment["OPENSCREENS_DISPLAYS"].flatMap(DisplayLayout.init(rawValue:)) {
                settings.displays = displays
            }
        }
        present(session)

        guard let reportPrefix = environment["OPENSCREENS_REPORT"] else { return }
        let delay = Double(environment["OPENSCREENS_REPORT_AFTER"] ?? "") ?? 6
        let text = environment["OPENSCREENS_TYPE"]
        let exits = environment["OPENSCREENS_EXIT"] == "1"

        Task {
            // Wait for the connection to settle one way or the other.
            let deadline = Date.now.addingTimeInterval(40)
            while Date.now < deadline {
                switch session.phase {
                case .connected, .failed, .ended: break
                default:
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                break
            }
            if session.phase == .connected {
                session.setStatisticsActive(true)
                if let text {
                    try? await Task.sleep(for: .seconds(1))
                    session.type(text)
                }
                try? await Task.sleep(for: .seconds(delay))
            }
            writeReport(for: session, prefix: reportPrefix)
            if exits {
                session.end()
                try? await Task.sleep(for: .milliseconds(400))
                exit(0)
            }
        }
    }

    private static func writeReport(for session: RemoteSession, prefix: String) {
        var report: [String: Any] = [
            "phase": String(describing: session.phase),
            "requestedQuality": session.requestedQuality.rawValue,
            "activeQuality": session.activeQuality.rawValue,
            "isHighPerformance": session.engine.isHighPerformanceMode,
            "serverName": session.engine.serverName,
            "framebuffer": [session.engine.framebufferWidth, session.engine.framebufferHeight],
            "presentedSize": [session.remoteSize.width, session.remoteSize.height],
            "viewSize": [session.viewport.viewSize.width, session.viewport.viewSize.height],
            "contentRect": [
                session.viewport.contentRect.minX, session.viewport.contentRect.minY,
                session.viewport.contentRect.width, session.viewport.contentRect.height,
            ],
            "displayCount": session.engine.activeVideoDisplayCount,
            "supportsCurtain": session.supportsCurtain,
            "isCurtained": session.isCurtained,
            "appleModifiers": session.engine.serverUsesAppleModifierConvention,
            "cursor": String(describing: session.engine.remoteCursorPresence),
            "cursorRendering": session.engine.activeCursorRendering.rawValue,
            "encryption": String(describing: session.engine.negotiatedContentEncryption),
            "clipboardRequest": session.engine.supportsRemoteClipboardRequest,
        ]
        if let reason = session.fallbackReason {
            report["fallbackReason"] = reason
        }
        if let statistics = session.statistics {
            report["framesPerSecond"] = statistics.framesPerSecond ?? -1
            report["bitrateKbps"] = statistics.bitrateKbps ?? -1
            report["packetLossPercent"] = statistics.packetLossPercent ?? -1
        }
        report["diagnostics"] = session.engine.getDiagnostics().summary()

        var hasImage = false
        if let image = session.screenshot(), let data = ScreenshotEncoder.pngData(image) {
            hasImage = (try? data.write(to: URL(fileURLWithPath: prefix + ".png"))) != nil
            report["imageSize"] = [image.width, image.height]
        }
        report["hasImage"] = hasImage

        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: prefix + ".json"))
        }
    }
}
#endif

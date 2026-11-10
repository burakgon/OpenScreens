#if os(macOS)
import AppKit
import OpenScreensCore
import SwiftUI

/// Identifiers of the app's windows.
public enum WindowID {
    public static let library = "library"
    public static let session = "session"
}

/// Every scene of the Mac app: the library, one window per session, and
/// Settings. The app target only has to create the model and return this.
public struct OpenScreensScenes: Scene {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        Window("OpenScreens", id: WindowID.library) {
            LibraryView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            LibraryCommands(model: model)
        }

        WindowGroup(id: WindowID.session, for: RemoteSession.ID.self) { $sessionID in
            SessionWindow(sessionID: sessionID)
                .environment(model)
        }
        .defaultSize(width: 1280, height: 800)
        .restorationBehavior(.disabled)
        .commands {
            SessionCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The window that hosts one session.
struct SessionWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let sessionID: RemoteSession.ID?

    var body: some View {
        if let session = model.sessions.session(sessionID) {
            SessionView(session: session) {
                close(session)
            }
            .navigationTitle(session.computer.displayName)
            .navigationSubtitle(subtitle(for: session))
            .toolbar {
                SessionToolbar(session: session)
            }
            .focusedSceneValue(\.activeSession, session)
            .frame(minWidth: 480, minHeight: 320)
            .onDisappear {
                model.sessions.close(session)
            }
        } else {
            // A session window restored without its session has nothing to show.
            Color.black
                .onAppear {
                    dismissWindow(id: WindowID.session, value: sessionID)
                }
        }
    }

    private func subtitle(for session: RemoteSession) -> String {
        switch session.phase {
        case .connected:
            let size = session.remoteSize
            guard size.width > 0 else { return session.activeQuality.title }
            return "\(session.activeQuality.title) — \(Int(size.width)) × \(Int(size.height))"
        case .connecting, .idle: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .awaitingCredentials: return "Waiting for sign in"
        case .failed: return "Not connected"
        case .ended: return ""
        }
    }

    private func close(_ session: RemoteSession) {
        model.sessions.close(session)
        dismissWindow(id: WindowID.session, value: session.id)
    }
}

// MARK: - Focused session

struct ActiveSessionKey: FocusedValueKey {
    typealias Value = RemoteSession
}

extension FocusedValues {
    /// The session in the key window, for menu commands to act on.
    var activeSession: RemoteSession? {
        get { self[ActiveSessionKey.self] }
        set { self[ActiveSessionKey.self] = newValue }
    }
}
#endif

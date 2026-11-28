#if os(iOS)
import OpenScreensCore
import SwiftUI
import UIKit

/// A screen plugged into the phone, or reached by AirPlay, and what is shown
/// on it.
///
/// With a display of its own the remote desktop is drawn there, at the size
/// of that display, and the phone becomes what a laptop has under its
/// screen: a keyboard and a trackpad. The phone is what is in the hand, so
/// everything to read and answer — signing in, a computer that could not be
/// reached — stays on it.
@MainActor
@Observable
public final class ExternalDisplay {
    public static let shared = ExternalDisplay()

    /// Whether a display is connected and has a window of the app's on it.
    public private(set) var isConnected = false
    /// The session the phone is showing, which is the one the display draws.
    public internal(set) var session: RemoteSession?

    private init() {}

    /// The scene configuration for a scene the system is connecting, or nil
    /// for any that is not an external display.
    ///
    /// The app's delegate returns this from
    /// `application(_:configurationForConnecting:options:)`, which is how a
    /// SwiftUI app is told about a screen it was not asked to open.
    public static func configuration(for session: UISceneSession) -> UISceneConfiguration? {
        guard session.role == .windowExternalDisplayNonInteractive else { return nil }
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: session.role)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }

    fileprivate func connected() {
        isConnected = true
    }

    fileprivate func disconnected() {
        isConnected = false
    }
}

/// Asks the system to give a connected display to the app, for as long as
/// the view it is placed in is on screen.
///
/// From iOS 27 a display is the app's only when something has asked for it:
/// declaring the scene in the Info.plist is no longer enough, and without
/// asking, the system mirrors the phone. A session asks, so that the desktop
/// goes to the display; the library does not, so the display shows the phone
/// while a computer is being chosen.
struct ExternalDisplayAccessory: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ExternalDisplayAccessoryController {
        ExternalDisplayAccessoryController()
    }

    func updateUIViewController(_ controller: ExternalDisplayAccessoryController, context: Context) {}
}

final class ExternalDisplayAccessoryController: UIViewController {
    /// The registration, kept untyped so the class builds for iOS 26.
    private var registration: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        register()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unregister()
    }

    private func register() {
        guard #available(iOS 27.0, *), registration == nil else { return }
        let configuration = UISceneConfiguration(
            name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        let registration = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
        registration.isEnabled = true
        self.registration = registration
    }

    private func unregister() {
        guard #available(iOS 27.0, *),
              let registration = registration as? UISceneAccessoryRegistration else { return }
        unregisterSceneAccessory(registration)
        self.registration = nil
    }
}

/// Puts the app's window on a display that has been connected, and takes it
/// away again.
///
/// Named for the Objective-C runtime as the app's Info.plist names it, so
/// the system finds it whatever module it is built into.
@objc(OpenScreensExternalDisplaySceneDelegate)
public final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: ExternalDisplayRoot())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.connected()
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        ExternalDisplay.shared.disconnected()
    }
}

/// What the external display shows: the remote desktop filling it, or,
/// until a computer is chosen on the phone, a word about where to choose one.
struct ExternalDisplayRoot: View {
    private var display: ExternalDisplay { .shared }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            if let session = display.session {
                RemoteCanvas(session: session)
                    // One canvas for each session, so a new one is made for
                    // a computer chosen after another.
                    .id(session.id)
                    .ignoresSafeArea()
                if !session.isConnected {
                    status(
                        symbol: "desktopcomputer",
                        title: session.computer.displayName,
                        detail: "Connecting… Follow along on your iPhone.")
                }
            } else {
                status(
                    symbol: "macbook.and.iphone",
                    title: "OpenScreens",
                    detail: "Choose a computer on your iPhone to show it here.")
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    private func status(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}
#endif

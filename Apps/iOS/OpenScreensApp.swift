import OpenScreensUI
import SwiftUI
import UIKit

@main
struct OpenScreensApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            OpenScreensMobileRoot(model: model)
        }
    }
}

/// Gives a display connected to the phone a window of its own, rather than a
/// copy of the phone's screen.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ExternalDisplay.startTracing()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let external = ExternalDisplay.configuration(for: connectingSceneSession) {
            return external
        }
        // Everything else is SwiftUI's to set up.
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

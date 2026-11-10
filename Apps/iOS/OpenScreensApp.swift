import OpenScreensUI
import SwiftUI

@main
struct OpenScreensApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            OpenScreensMobileRoot(model: model)
        }
    }
}

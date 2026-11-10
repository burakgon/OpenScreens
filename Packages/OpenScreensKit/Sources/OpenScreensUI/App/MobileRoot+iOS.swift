#if os(iOS)
import OpenScreensCore
import SwiftUI

/// The root of the iPhone and iPad app.
public struct OpenScreensMobileRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        LibraryView()
            .environment(model)
            .appLock()
            .environment(model)
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    model.becomeActive()
                case .background:
                    // Discovery has no business running out of sight, and
                    // the library should be on disk before the app sleeps.
                    model.resignActive()
                default:
                    break
                }
            }
    }
}
#endif

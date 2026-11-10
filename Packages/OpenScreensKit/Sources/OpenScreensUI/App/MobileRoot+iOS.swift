#if os(iOS)
import OpenScreensCore
import SwiftUI

/// The root of the iPhone and iPad app.
public struct OpenScreensMobileRoot: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        LibraryView()
            .environment(model)
            .appLock()
            .environment(model)
    }
}
#endif

#if os(macOS)
import AppKit
import Foundation
import OpenScreensCore
import SwiftUI
import Testing
@testable import OpenScreensUI

/// The library window's layout, measured in a real window that is never put
/// on screen.
@Suite(
    .serialized,
    .enabled("A window needs a display to be laid out for.") {
        await MainActor.run { !NSScreen.screens.isEmpty }
    })
struct LibraryLayoutTests {

    private func makeModel() throws -> AppModel {
        let suite = "OpenScreensTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        // Nothing here asks Tailscale about anyone's real tailnet.
        settings.tailscaleEnabled = false
        return AppModel(
            library: LibraryStore(fileURL: nil, backupsDirectory: nil),
            settings: settings,
            credentials: CredentialStore(storage: InMemorySecretStorage()))
    }

    /// The library in a window of the smallest size the app allows, and the
    /// split view it is made of once SwiftUI has built it.
    private func makeWindow(
        for model: AppModel, showing section: LibraryFilter
    ) async throws -> (NSWindow, NSView, NSSplitView) {
        let host = NSHostingView(
            rootView: LibraryView(showing: section)
                .environment(model)
                .frame(minWidth: 720, minHeight: 440))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host

        var split: NSSplitView?
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            split = host.firstDescendant(NSSplitView.self)
            if split != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // One more pass, so that what is measured is the settled layout.
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        return (window, host, try #require(split))
    }

    /// What the library can be showing when there is little or nothing in
    /// it, which is when the detail is text rather than a list.
    enum Case: String, CaseIterable, CustomTestStringConvertible {
        case emptyLibrary
        case oneComputer
        case noFavorites
        case nobodyNearby

        var testDescription: String { rawValue }

        var section: LibraryFilter {
            switch self {
            case .emptyLibrary, .oneComputer: .all
            case .noFavorites: .favorites
            case .nobodyNearby: .nearby
            }
        }

        var hasComputer: Bool {
            self == .oneComputer || self == .noFavorites
        }
    }

    /// Whatever the library shows has to fit the window it is in. A split
    /// view that asks for more height than the window has is centred in it,
    /// and then the top of the sidebar, with its first rows, lies above the
    /// window's edge: the sidebar looks empty.
    @Test(arguments: Case.allCases)
    func theSplitViewFitsItsWindow(_ state: Case) async throws {
        let model = try makeModel()
        if state.hasComputer {
            model.library.add(Computer(
                name: "Studio", host: "studio.local", settings: .defaults(for: .mac)))
        }
        let (window, host, split) = try await makeWindow(for: model, showing: state.section)
        defer { window.close() }

        let frame = split.convert(split.bounds, to: host)
        #expect(frame.minY >= host.bounds.minY - 1, "the split view starts above the window: \(frame)")
        #expect(frame.maxY <= host.bounds.maxY + 1, "the split view ends below the window: \(frame)")
    }
}

private extension NSView {
    func firstDescendant<View: NSView>(_ type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View { return match }
            if let match = subview.firstDescendant(type) { return match }
        }
        return nil
    }
}
#endif

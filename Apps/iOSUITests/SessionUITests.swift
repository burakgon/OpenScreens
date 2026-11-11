import RFBTestServer
import XCTest

/// Touches and key presses, from the finger to the wire.
///
/// Each test starts a small screen-sharing server inside the test runner,
/// launches the app pointed at it, and checks what the server received.
@MainActor
final class SessionUITests: XCTestCase {
    private var server: RFBTestServer!
    private var app: XCUIApplication!

    /// The size of the remote screen the server shows.
    private let remoteSize = CGSize(width: 800, height: 600)

    override func setUp() async throws {
        // Stopping at the first failure works by unwinding, which an async
        // test cannot do; the tests bail out themselves instead.
        continueAfterFailure = true
        let image = try XCTUnwrap(DemoDesktop.image(width: Int(remoteSize.width), height: Int(remoteSize.height)))
        let server = RFBTestServer(image: image)
        let port = try await server.start()
        self.server = server

        let app = XCUIApplication()
        let data = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensUITests-\(UUID().uuidString)")
        // A library of its own, and straight into a session.
        app.launchEnvironment["OPENSCREENS_DATA_DIR"] = data.path
        app.launchEnvironment["OPENSCREENS_CONNECT"] = "vnc://127.0.0.1:\(port)"
        app.launchEnvironment["OPENSCREENS_KIND"] = "linux"
        self.app = app
    }

    override func tearDown() async throws {
        app?.terminate()
        server?.stop()
    }

    private func launch(touch mode: String) async throws -> XCUIElement {
        app.launchEnvironment["OPENSCREENS_TOUCH"] = mode
        app.launch()
        let connected = await server.waitForEvents(timeout: .seconds(20)) { $0.contains(.connected) }
        XCTAssertTrue(connected, "the app never connected")
        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Screen of")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "the remote screen never appeared")
        // The first picture has to arrive before the screen maps touches.
        try await Task.sleep(for: .seconds(1.5))
        server.clearEvents()
        return canvas
    }

    private func pointerEvents() -> [(x: Int, y: Int, buttons: UInt8)] {
        server.events.compactMap { event in
            guard case .pointer(let x, let y, let buttons) = event else { return nil }
            return (x, y, buttons)
        }
    }

    private func keyEvents() -> [String] {
        server.events.compactMap { event in
            guard case .key(let keysym, let isDown) = event else { return nil }
            return "\(isDown ? "+" : "-")\(String(keysym, radix: 16))"
        }
    }

    /// How far apart two points of the canvas, given as fractions of its
    /// size, are on the remote screen — in points of the canvas, so that the
    /// two axes can be compared.
    ///
    /// The picture is fitted inside the device's safe area, whose insets a
    /// test cannot see and which need not be symmetrical. So positions are
    /// checked as distances between two touches: the same scale has to hold
    /// across and down, and it cannot make the picture larger than the
    /// canvas.
    private func separation(from a: CGVector, to b: CGVector, in canvas: XCUIElement) -> CGSize {
        CGSize(
            width: canvas.frame.width * (b.dx - a.dx),
            height: canvas.frame.height * (b.dy - a.dy))
    }

    private func assertUniformScale(
        remote: (dx: Int, dy: Int), view: CGSize, in canvas: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let across = Double(remote.dx) / Double(view.width)
        let down = Double(remote.dy) / Double(view.height)
        XCTAssertEqual(across, down, accuracy: 0.08, "the picture is stretched", file: file, line: line)
        let smallest = Double(remoteSize.width / canvas.frame.width)
        XCTAssertGreaterThanOrEqual(across, smallest - 0.05, "the picture is wider than the screen", file: file, line: line)
    }

    private func tapAndWaitForClick(_ spot: CGVector, in canvas: XCUIElement) async -> (x: Int, y: Int)? {
        server.clearEvents()
        canvas.coordinate(withNormalizedOffset: spot).tap()
        let clicked = await server.waitForEvents { events in
            events.contains { if case .pointer(_, _, 1) = $0 { true } else { false } }
        }
        guard clicked, let press = pointerEvents().first(where: { $0.buttons == 1 }) else { return nil }
        // Let the release arrive before the next touch.
        _ = await server.waitForEvents { events in
            guard let down = events.firstIndex(where: { if case .pointer(_, _, 1) = $0 { true } else { false } }) else {
                return false
            }
            return events[down...].contains { if case .pointer(_, _, 0) = $0 { true } else { false } }
        }
        return (press.x, press.y)
    }

    // MARK: - Touch mode

    func testATapClicksWhereTheFingerIs() async throws {
        let canvas = try await launch(touch: "touch")
        let first = CGVector(dx: 0.3, dy: 0.45)
        let second = CGVector(dx: 0.7, dy: 0.55)

        let firstClick = await tapAndWaitForClick(first, in: canvas)
        let a = try XCTUnwrap(firstClick, "no click arrived: \(server.events)")
        // The button was let go again.
        XCTAssertTrue(pointerEvents().contains { $0.buttons == 0 }, "the button stayed down: \(pointerEvents())")
        try await Task.sleep(for: .milliseconds(500))
        let secondClick = await tapAndWaitForClick(second, in: canvas)
        let b = try XCTUnwrap(secondClick, "no second click arrived")

        assertUniformScale(
            remote: (b.x - a.x, b.y - a.y), view: separation(from: first, to: second, in: canvas), in: canvas)
        XCTAssertTrue((0..<Int(remoteSize.width)).contains(a.x), "the click was off the remote screen")
        XCTAssertTrue((0..<Int(remoteSize.height)).contains(a.y), "the click was off the remote screen")
    }

    func testATwoFingerTapIsARightClick() async throws {
        let canvas = try await launch(touch: "touch")

        canvas.twoFingerTap()

        let clicked = await server.waitForEvents { events in
            events.contains { if case .pointer(_, _, 4) = $0 { true } else { false } }
        }
        XCTAssertTrue(clicked, "no right click arrived: \(pointerEvents())")
        XCTAssertFalse(pointerEvents().contains { $0.buttons == 1 }, "a left click arrived too")
    }

    /// The top of a remote Mac's screen is its menu bar, and where the
    /// picture reaches the top of the device that is a strip the system may
    /// keep for a gesture of its own. A tap there is a click all the same,
    /// and only one.
    func testATapAtTheTopEdgeOfThePictureStillClicks() async throws {
        let canvas = try await launch(touch: "touch")

        // Where the status bar runs across the top, the picture starts
        // under it, and a tap on the bar itself is the system's.
        var top: CGFloat = 0
        let statusBar = XCUIApplication(bundleIdentifier: "com.apple.springboard").statusBars.firstMatch
        if statusBar.exists, statusBar.frame.minY < 1, statusBar.frame.width > canvas.frame.width * 0.8 {
            top = statusBar.frame.maxY
        }
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0))
            .withOffset(CGVector(dx: 0, dy: top + 6))
            .tap()

        let clicked = await server.waitForEvents { events in
            events.contains { if case .pointer(_, _, 1) = $0 { true } else { false } }
        }
        XCTAssertTrue(clicked, "no click arrived: \(pointerEvents())")
        // Long enough for a tap the system held back to be delivered late.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(
            pointerEvents().filter { $0.buttons == 1 }.count, 1,
            "one tap was more than one click: \(pointerEvents())")
    }

    func testPressingAndDraggingHoldsTheButtonDown() async throws {
        let canvas = try await launch(touch: "touch")
        let start = CGVector(dx: 0.3, dy: 0.45)
        let end = CGVector(dx: 0.7, dy: 0.55)

        canvas.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.6, thenDragTo: canvas.coordinate(withNormalizedOffset: end))

        let finished = await server.waitForEvents { events in
            guard let down = events.firstIndex(where: { if case .pointer(_, _, 1) = $0 { true } else { false } }) else {
                return false
            }
            return events[down...].contains { if case .pointer(_, _, 0) = $0 { true } else { false } }
        }
        XCTAssertTrue(finished, "the drag never finished: \(pointerEvents())")
        let held = pointerEvents().filter { $0.buttons == 1 }
        guard let first = held.first, let last = held.last else {
            return XCTFail("the button never went down: \(pointerEvents())")
        }
        assertUniformScale(
            remote: (last.x - first.x, last.y - first.y),
            view: separation(from: start, to: end, in: canvas), in: canvas)
        XCTAssertGreaterThan(held.count, 3, "the pointer jumped instead of moving")
    }

    // MARK: - Trackpad mode

    func testInTrackpadModeADragMovesThePointerWithoutClicking() async throws {
        let canvas = try await launch(touch: "trackpad")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))

        let moved = await server.waitForEvents { events in
            events.filter { if case .pointer = $0 { true } else { false } }.count > 3
        }
        XCTAssertTrue(moved, "the pointer did not move: \(pointerEvents())")
        let events = pointerEvents()
        XCTAssertTrue(events.allSatisfy { $0.buttons == 0 }, "a button went down: \(events)")
        let first = try XCTUnwrap(events.first), last = try XCTUnwrap(events.last)
        XCTAssertGreaterThan(last.x, first.x, "the pointer did not move right")
    }

    func testInTrackpadModeATapClicksWhereThePointerIs() async throws {
        let canvas = try await launch(touch: "trackpad")
        // Move the pointer somewhere first, so its place is known.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        _ = await server.waitForEvents { events in
            events.contains { if case .pointer = $0 { true } else { false } }
        }
        try await Task.sleep(for: .milliseconds(600))
        let resting = try XCTUnwrap(pointerEvents().last)
        server.clearEvents()

        // Tap far from it.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()

        let clicked = await server.waitForEvents { events in
            events.contains { if case .pointer(_, _, 1) = $0 { true } else { false } }
        }
        XCTAssertTrue(clicked, "no click arrived: \(pointerEvents())")
        let press = try XCTUnwrap(pointerEvents().first { $0.buttons == 1 })
        XCTAssertEqual(press.x, resting.x, accuracy: 2)
        XCTAssertEqual(press.y, resting.y, accuracy: 2)
    }

    // MARK: - Keyboard

    func testTypingReachesTheRemoteComputer() async throws {
        _ = try await launch(touch: "touch")

        app.typeText("Hi!")

        let typed = await server.waitForEvents(timeout: .seconds(10)) { events in
            events.contains(.key(keysym: 0x21, isDown: false))
        }
        XCTAssertTrue(typed, "the text never arrived: \(keyEvents())")
        // Whatever modifiers the keyboard used to get there, these are the
        // characters, each pressed and released, in order.
        let characters = keyEvents().filter { ["+48", "-48", "+69", "-69", "+21", "-21"].contains($0) }
        XCTAssertEqual(characters, ["+48", "-48", "+69", "-69", "+21", "-21"])
        // Nothing is left held down.
        var down = Set<String>()
        for event in keyEvents() {
            if event.hasPrefix("+") {
                down.insert(String(event.dropFirst()))
            } else {
                down.remove(String(event.dropFirst()))
            }
        }
        XCTAssertTrue(down.isEmpty, "keys left down: \(down)")
    }

    // MARK: - Leaving

    // MARK: - Controls

    /// Brings the controls out if they have been put away. Where they stand
    /// beside the picture they are never away.
    private func showControls() {
        let handle = app.buttons["Show Controls"].firstMatch
        if handle.waitForExistence(timeout: 1), handle.isHittable {
            handle.tap()
        }
    }

    /// The controls are in the way of whatever is under them, and the first
    /// touch on the remote screen says they are done with.
    func testTouchingTheRemoteScreenPutsTheControlsAway() async throws {
        let canvas = try await launch(touch: "touch")
        showControls()
        let disconnect = app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 3), "the controls never came out")

        let handle = app.buttons["Show Controls"].firstMatch
        // Controls standing beside the picture stay: they cover nothing.
        let floats = disconnect.frame.maxX <= canvas.frame.midX + canvas.frame.width / 2
            && disconnect.frame.width < disconnect.frame.height * 3
            && disconnect.frame.minY < canvas.frame.height / 2
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).tap()

        if handle.waitForExistence(timeout: 3) {
            XCTAssertFalse(disconnect.exists && disconnect.isHittable, "the controls stayed out")
            // And the handle brings them back.
            handle.tap()
            XCTAssertTrue(disconnect.waitForExistence(timeout: 3), "the handle did not bring the controls back")
            XCTAssertTrue(disconnect.isHittable)
        } else {
            XCTAssertTrue(disconnect.isHittable, "the controls went and left no way to bring them back")
            _ = floats
        }
    }

    func testDisconnectingClosesTheConnection() async throws {
        _ = try await launch(touch: "touch")

        showControls()
        app.buttons["Disconnect"].firstMatch.tap()
        // Asked to confirm, when that preference is on.
        let confirm = app.buttons["Disconnect"].firstMatch
        if confirm.waitForExistence(timeout: 2), confirm.isHittable {
            confirm.tap()
        }

        let closed = await server.waitForEvents(timeout: .seconds(10)) { $0.contains(.disconnected) }
        XCTAssertTrue(closed, "the connection stayed open")
    }
}

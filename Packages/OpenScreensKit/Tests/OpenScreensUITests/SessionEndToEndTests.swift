import CoreGraphics
import Foundation
import OpenScreensCore
import RFBTestServer
import Testing
@testable import OpenScreensUI

/// Drives a real `RemoteSession` against the loopback test server: the same
/// handshake, decoding and input paths the apps use, with no stubs between.
@Suite(.serialized)
struct SessionEndToEndTests {

    /// A session to a freshly started server, torn down by the caller.
    private func makeSession(
        password: String? = nil,
        image: CGImage? = DemoDesktop.testCard(),
        configure: (inout Computer) -> Void = { _ in }
    ) async throws -> (RemoteSession, RFBTestServer, AppModel) {
        let image = try #require(image)
        let server = RFBTestServer(image: image, configuration: .init(password: password))
        let port = try await server.start()

        let suite = "OpenScreensTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = AppModel(
            library: LibraryStore(fileURL: nil, backupsDirectory: nil),
            settings: AppSettings(defaults: defaults),
            credentials: CredentialStore(storage: InMemorySecretStorage()))
        var computer = Computer(
            name: "Test", host: "127.0.0.1", port: Int(port), kind: .other,
            settings: .defaults(for: .other))
        configure(&computer)
        computer = model.library.add(computer)
        let session = model.sessions.open(computer)
        // Stand in for the canvas, which normally reports its size.
        session.viewport.viewSize = CGSize(width: 640, height: 400)
        return (session, server, model)
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func connectsAndReceivesThePicture() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()

        #expect(await waitUntil { session.phase == .connected })
        #expect(session.remoteSize == CGSize(width: 320, height: 200))
        #expect(session.engine.serverName == "OpenScreens Demo")
        #expect(session.activeQuality == .standard)

        #expect(await waitUntil { session.screenshot() != nil })
        let image = try #require(session.screenshot())
        #expect(image.width == 320)
        #expect(image.height == 200)

        // The four quadrants arrive the right way up with channels in order.
        let pixels = try #require(Pixels(image))
        #expect(pixels.isClose(to: (255, 0, 0), atX: 40, y: 30))        // top left: red
        #expect(pixels.isClose(to: (0, 255, 0), atX: 280, y: 30))       // top right: green
        #expect(pixels.isClose(to: (0, 0, 255), atX: 40, y: 170))       // bottom left: blue
        #expect(pixels.isClose(to: (255, 255, 255), atX: 280, y: 170))  // bottom right: white
    }

    @Test func pointerEventsArriveAtTheSamePixel() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        session.click(.left, at: CGPoint(x: 123, y: 45))
        session.click(.right, at: CGPoint(x: 300, y: 199))

        let arrived = await server.waitForEvents { events in
            events.contains(.pointer(x: 300, y: 199, buttons: 0x04))
        }
        #expect(arrived)
        let pointer = server.events.filter {
            if case .pointer = $0 { return true }
            return false
        }
        #expect(pointer.contains(.pointer(x: 123, y: 45, buttons: 0x01)))
        #expect(pointer.contains(.pointer(x: 123, y: 45, buttons: 0x00)))
        #expect(pointer.contains(.pointer(x: 300, y: 199, buttons: 0x04)))
    }

    @Test func viewportMapsViewPointsToRemotePixels() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        // A 640×400 view showing a 320×200 screen: exactly 2 points per pixel.
        session.viewport.contentSize = session.remoteSize
        let remote = try #require(session.viewport.remotePoint(for: CGPoint(x: 320, y: 200)))
        #expect(remote == CGPoint(x: 160, y: 100))
        session.click(.left, at: remote)
        #expect(await server.waitForEvents { $0.contains(.pointer(x: 160, y: 100, buttons: 0x01)) })
    }

    @Test func typingAndShortcutsSendTheRightKeys() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        session.type("Hi!")
        session.tap(.special(.returnKey))
        // A shortcut names the remote computer's own modifiers: on a PC,
        // Control-Alt-Delete is exactly those keys.
        session.send(RemoteShortcut(
            name: "Task Manager", modifiers: [.control, .option], key: .special(.forwardDelete)))

        let finished = await server.waitForEvents { events in
            events.contains(.key(keysym: Keysym.controlLeft, isDown: false))
        }
        #expect(finished)
        #expect(keys(from: server) == [
            "+48", "-48", "+69", "-69", "+21", "-21",   // H i !
            "+ff0d", "-ff0d",                           // Return
            "+ffe3", "+ffe9", "+ffff", "-ffff", "-ffe9", "-ffe3",
        ])
    }

    @Test func aMacKeyboardDrivesAPC() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        // ⌘C is Control-C on a PC, unless the user turns the swap off.
        session.hardwareModifier(.leftCommand, down: true)
        session.hardwareKeyDown(KeyStroke(key: 8, text: "c", textWithoutOption: "c", shortcutText: "c"))
        session.hardwareKeyUp(key: 8)
        session.hardwareModifier(.leftCommand, down: false)

        // Option-Q types @ on a Turkish keyboard. Alt stays out of it.
        session.hardwareModifier(.leftOption, down: true)
        session.hardwareKeyDown(KeyStroke(key: 12, text: "@", textWithoutOption: "q", shortcutText: "q"))
        session.hardwareKeyUp(key: 12)
        session.hardwareModifier(.leftOption, down: false)

        // Option held for a click is Alt.
        session.hardwareModifier(.leftOption, down: true)
        session.click(.left, at: CGPoint(x: 10, y: 10))
        session.hardwareModifier(.leftOption, down: false)

        #expect(await server.waitForEvents { $0.contains(.key(keysym: Keysym.altLeft, isDown: false)) })
        #expect(keys(from: server) == [
            "+ffe3", "+63", "-63", "-ffe3",
            "+40", "-40",
            "+ffe9", "-ffe9",
        ])
        let altDown = try #require(server.events.firstIndex(of: .key(keysym: Keysym.altLeft, isDown: true)))
        let press = try #require(server.events.firstIndex(of: .pointer(x: 10, y: 10, buttons: 0x01)))
        #expect(altDown < press)
    }

    @Test func keysHeldWhenTheKeyboardIsLostAreReleased() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        session.hardwareModifier(.leftShift, down: true)
        session.hardwareKeyDown(KeyStroke(key: 0, text: "A", textWithoutOption: "A", shortcutText: "a"))
        session.releaseHardwareKeys()

        #expect(await server.waitForEvents { $0.contains(.key(keysym: Keysym.shiftLeft, isDown: false)) })
        #expect(keys(from: server) == ["+ffe1", "+41", "-41", "-ffe1"])
    }

    /// The key events a server received, as `+keysym` and `-keysym`.
    private func keys(from server: RFBTestServer) -> [String] {
        server.events.compactMap { event -> String? in
            guard case .key(let keysym, let isDown) = event else { return nil }
            return "\(isDown ? "+" : "-")\(String(keysym, radix: 16))"
        }
    }

    @Test func latchedModifiersWrapTheNextKeyOnly() async throws {
        let (session, server, model) = try await makeSession()
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        session.toggleLatched(.shift)
        session.tap(keysym: Keysym.character("a"))
        session.tap(keysym: Keysym.character("b"))

        #expect(await server.waitForEvents { $0.contains(.key(keysym: 0x62, isDown: false)) })
        // Shift with a letter is the capital letter.
        #expect(keys(from: server) == ["+ffe1", "+41", "-41", "-ffe1", "+62", "-62"])
        #expect(session.latchedModifiers.isEmpty)
    }

    @Test func observeOnlySendsNoInput() async throws {
        let (session, server, model) = try await makeSession { $0.settings.observeOnly = true }
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        session.click(.left, at: CGPoint(x: 10, y: 10))
        session.type("secret")
        session.send(RemoteShortcut(name: "Quit", modifiers: [.command], key: .character("q")))
        try await Task.sleep(for: .milliseconds(400))

        let input = server.events.filter {
            switch $0 {
            case .key, .pointer, .cutText: true
            default: false
            }
        }
        #expect(input.isEmpty)
    }

    @Test func passwordIsRequestedThenAccepted() async throws {
        let (session, server, model) = try await makeSession(password: "s3cret")
        defer {
            model.sessions.close(session)
            server.stop()
        }
        session.start()

        // Nothing saved: the first attempt is rejected and the session asks.
        #expect(await waitUntil {
            if case .awaitingCredentials = session.phase { return true }
            return false
        })

        session.submitCredentials(username: "", password: "wrong", remember: false)
        #expect(await server.waitForEvents { $0.filter { $0 == .authenticationFailed }.count >= 2 })
        #expect(await waitUntil {
            if case .awaitingCredentials(let prompt) = session.phase { return prompt.message != nil }
            return false
        })

        session.submitCredentials(username: "", password: "s3cret", remember: true)
        #expect(await waitUntil { session.phase == .connected })
        #expect(model.credentials.password(for: session.computer.id) == "s3cret")
        #expect(model.library.computer(session.computer.id)?.lastConnectedAt != nil)
    }

    @Test func aRefusedConnectionReportsFailure() async throws {
        let (session, server, model) = try await makeSession()
        // Nothing is listening once the server has stopped.
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        defer { model.sessions.close(session) }
        session.start()

        // The engine dials a few times, for networks that only come up when
        // asked. A refusal ends each attempt at once, so that takes seconds
        // rather than a connect timeout per attempt.
        #expect(await waitUntil(timeout: .seconds(8)) {
            if case .failed = session.phase { return true }
            return false
        })
        guard case .failed(let message) = session.phase else { return }
        #expect(message.contains("refused"))
    }

    @Test func endingASessionDisconnects() async throws {
        let (session, server, model) = try await makeSession()
        defer { server.stop() }
        session.start()
        #expect(await waitUntil { session.phase == .connected })

        model.sessions.close(session)
        #expect(session.phase == .ended)
        #expect(await server.waitForEvents { $0.contains(.disconnected) })
        #expect(model.sessions.sessions.isEmpty)
    }
}

/// Read access to an image's pixels, for assertions.
private struct Pixels {
    private let data: [UInt8]
    private let width: Int

    init?(_ image: CGImage) {
        width = image.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        data = bytes
    }

    /// Whether the pixel at (x, y), counted from the top left, is within a
    /// small tolerance of `color`. Colour management may nudge values.
    func isClose(to color: (Int, Int, Int), atX x: Int, y: Int, tolerance: Int = 12) -> Bool {
        let offset = (y * width + x) * 4
        return abs(Int(data[offset]) - color.0) <= tolerance
            && abs(Int(data[offset + 1]) - color.1) <= tolerance
            && abs(Int(data[offset + 2]) - color.2) <= tolerance
    }
}

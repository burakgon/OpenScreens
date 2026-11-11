import XCTest
import RFBProtocol
@testable import RFBTransport

/// Clipboard flows over a scripted connection: ExtendedClipboard with a
/// conventional server, and rich packed scraps with an Apple server.
final class TransportSessionClipboardTests: XCTestCase {
    private typealias Extended = ExtendedClipboardProtocol

    func testExtendedClipboardNegotiatesAndRequestsAnnouncedFormats() async throws {
        let (session, connection, recorder) = try await connectConventionalServer()

        let serverFormats: Extended.Formats = [.text, .rtf, .html]
        await connection.enqueueServerBytes(Self.serverMessage(.caps(
            serverFormats,
            [.request, .peek, .notify, .provide],
            maximumSizes: [1: 0, 2: 0, 4: 0])))
        let capsChanged = await Self.waitUntil {
            recorder.contains { if case .clipboardCapabilitiesChanged = $0 { true } else { false } }
        }
        XCTAssertTrue(capsChanged)
        let clientCaps = try Extended.clientMessage(Extended.clientCaps)
        let afterCaps = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: clientCaps, in: afterCaps), 1)
        let support = await session.clipboardContentSupport
        XCTAssertEqual(support, .formats([
            ClipboardType.utf8PlainText, ClipboardType.rtf, ClipboardType.html,
        ]))
        let canRequest = await session.supportsRemoteClipboardRequest
        XCTAssertTrue(canRequest)

        // A notify while sharing is off is only recorded.
        await connection.enqueueServerBytes(Self.serverMessage(.notify([.text, .html])))
        let request = try Extended.clientMessage(.request([.text, .html]))
        let requestedEarly = await Self.waitUntil(timeout: .milliseconds(200)) {
            Self.occurrenceCount(of: request, in: await connection.sentBytes()) > 0
        }
        XCTAssertFalse(requestedEarly)

        try await session.setSharedClipboardEnabled(true)
        await connection.enqueueServerBytes(Self.serverMessage(.notify([.text, .html])))
        let requested = await Self.waitUntil {
            Self.occurrenceCount(of: request, in: await connection.sentBytes()) == 1
        }
        XCTAssertTrue(requested)

        await connection.enqueueServerBytes(Self.serverMessage(.provide([
            Extended.Formats.text.rawValue: Data("one\r\ntwo\0".utf8),
            Extended.Formats.html.rawValue: Data("<b>one</b>\0".utf8),
        ])))
        let received = await Self.waitUntil {
            recorder.clipboardContents().contains { $0.plainText == "one\ntwo" }
        }
        XCTAssertTrue(received)
        let content = recorder.clipboardContents().last
        XCTAssertEqual(content?.contains(type: ClipboardType.html), true)

        await session.disconnect()
    }

    func testExtendedClipboardAnnouncesThenProvidesOnRequest() async throws {
        let (session, connection, _) = try await connectConventionalServer()
        await connection.enqueueServerBytes(Self.serverMessage(.caps(
            [.text], [.request, .notify, .provide], maximumSizes: [1: 0])))
        let negotiated = await Self.waitUntil {
            await session.clipboardContentSupport != .plainText
        }
        XCTAssertTrue(negotiated)

        try await session.sendClipboard(.text("copied\nhere"))
        let notify = try Extended.clientMessage(.notify([.text]))
        let notified = await Self.waitUntil {
            Self.occurrenceCount(of: notify, in: await connection.sentBytes()) == 1
        }
        XCTAssertTrue(notified, "A zero size limit means notify, not provide")

        await connection.enqueueServerBytes(Self.serverMessage(.request([.text])))
        let provide = try Extended.clientMessage(.provide([
            Extended.Formats.text.rawValue: Data("copied\r\nhere\0".utf8),
        ]))
        let provided = await Self.waitUntil {
            Self.occurrenceCount(of: provide, in: await connection.sentBytes()) == 1
        }
        XCTAssertTrue(provided)
        await session.disconnect()
    }

    func testExtendedClipboardProvidesDirectlyWithinServerLimit() async throws {
        let (session, connection, _) = try await connectConventionalServer()
        await connection.enqueueServerBytes(Self.serverMessage(.caps(
            [.text], [.notify, .provide], maximumSizes: [1: 1024])))
        _ = await Self.waitUntil { await session.clipboardContentSupport != .plainText }

        try await session.sendClipboard(.text("small"))
        let provide = try Extended.clientMessage(.provide([
            Extended.Formats.text.rawValue: Data("small\0".utf8),
        ]))
        let sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: provide, in: sent), 1)
        await session.disconnect()
    }

    func testImageOnlyClipboardIsNotSentToLegacyServer() async throws {
        let (session, connection, _) = try await connectConventionalServer()
        let before = await connection.sentBytes()

        try await session.sendClipboard(ClipboardContent(items: [[
            .init(type: ClipboardType.png, data: Data([0x89, 0x50, 0x4E, 0x47])),
        ]]))
        let after = await connection.sentBytes()
        XCTAssertEqual(after, before)

        try await session.sendClipboard(.text("plain"))
        let legacy = ClientMessage.clientCutText("plain").serialize()
        let afterText = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: legacy, in: afterText), 1)
        await session.disconnect()
    }

    func testMalformedExtendedClipboardMessageKeepsSession() async throws {
        let (session, connection, recorder) = try await connectConventionalServer()

        // Two bytes cannot hold a flags word; the framing is still consumed.
        var malformed = Data([3, 0, 0, 0])
        malformed.append(contentsOf: [0xff, 0xff, 0xff, 0xfe, 0xAA, 0xBB])
        await connection.enqueueServerBytes(malformed)
        await connection.enqueueServerBytes(Self.legacyServerCutText("after"))

        let received = await Self.waitUntil {
            recorder.clipboardContents().contains { $0.plainText == "after" }
        }
        XCTAssertTrue(received)
        let errors = recorder.contains { if case .error = $0 { true } else { false } }
        XCTAssertFalse(errors)
        await session.disconnect()
    }

    func testAppleServerSendsAndReceivesRichPackedScrap() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.appleServerInitMessage(
            serverCommands: [AppleClipboardProtocol.packedScrapMessageType]))
        await connection.enqueueServerBytes(script)
        let session = TransportSession(
            host: "apple.test", port: 5900, password: "",
            preferredEncodings: [.raw], connection: connection)
        let recorder = EventRecorder()
        try await session.connect()
        recorder.record(session)

        let support = await session.clipboardContentSupport
        XCTAssertEqual(support, .all)

        let rich = ClipboardContent(items: [[
            .init(type: ClipboardType.rtf, data: Data("{\\rtf1 hi}".utf8)),
            .init(type: ClipboardType.png, data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])),
            .init(type: ClipboardType.utf8PlainText, data: Data("hi".utf8)),
        ]])
        try await session.sendClipboard(rich)
        let packed = try AppleClipboardProtocol.packedMessage(rich)
        let sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: packed, in: sent), 1)

        // The server's reply to request 11 carries the same scrap layout.
        var reply = packed
        reply[4] = 0
        reply[7] = 1 // echoed request id
        await connection.enqueueServerBytes(reply)
        let received = await Self.waitUntil {
            recorder.clipboardContents().contains { $0 == rich }
        }
        XCTAssertTrue(received)
        await session.disconnect()
    }

    /// An Apple server reports several things with message 20, among them,
    /// every two seconds, that nothing happened. Only the report of a
    /// changed pasteboard may fetch the pasteboard: fetching on the others
    /// copied the remote clipboard over the local one again and again.
    func testAppleStateChangeFetchesThePasteboardOnlyWhenItChanged() async throws {
        let (session, connection) = try await connectAppleServer()
        try await session.setSharedClipboardEnabled(true)
        // Requests are numbered from one.
        let requestCount: @Sendable () async -> Int = {
            let sent = await connection.sentBytes()
            return (1...4).reduce(0) { count, id in
                count + Self.occurrenceCount(
                    of: AppleClipboardProtocol.requestMessage(requestID: UInt32(id)), in: sent)
            }
        }

        // Idle, a session change, and a code nobody has named.
        for code: UInt16 in [AppleStateChange.idle, AppleStateChange.userSessionChanged, 0x0c] {
            await connection.enqueueServerBytes(Self.stateChange(code))
        }
        let fetchedEarly = await Self.waitUntil(timeout: .milliseconds(250)) {
            await requestCount() > 0
        }
        XCTAssertFalse(fetchedEarly)

        await connection.enqueueServerBytes(Self.stateChange(AppleStateChange.pasteboardChanged))
        let fetched = await Self.waitUntil { await requestCount() == 1 }
        XCTAssertTrue(fetched)

        // The messages before it were consumed whole: the stream is still
        // framed, and a second change is a second fetch.
        await connection.enqueueServerBytes(Self.stateChange(AppleStateChange.idle))
        await connection.enqueueServerBytes(Self.stateChange(AppleStateChange.pasteboardChanged))
        let fetchedAgain = await Self.waitUntil { await requestCount() == 2 }
        XCTAssertTrue(fetchedAgain)
        await session.disconnect()
    }

    func testAppleStateChangeIsIgnoredWhileTheClipboardIsNotShared() async throws {
        let (session, connection) = try await connectAppleServer()
        let request = AppleClipboardProtocol.requestMessage(requestID: 1)

        await connection.enqueueServerBytes(Self.stateChange(AppleStateChange.pasteboardChanged))
        let fetched = await Self.waitUntil(timeout: .milliseconds(250)) {
            Self.occurrenceCount(of: request, in: await connection.sentBytes()) > 0
        }
        XCTAssertFalse(fetched)
        await session.disconnect()
    }

    /// The size field says how long the message is. One longer than today's
    /// must be skipped whole, not leave its tail to be read as a message.
    func testALongerAppleStateChangeKeepsTheStreamFramed() async throws {
        let (session, connection) = try await connectAppleServer()
        try await session.setSharedClipboardEnabled(true)
        let request = AppleClipboardProtocol.requestMessage(requestID: 1)

        // Six bytes of payload: version, code, and two bytes this version
        // does not know. Read as eight bytes, the tail would start a bell and
        // then an unknown message, which ends the session.
        await connection.enqueueServerBytes(Data([
            AppleStateChange.messageType, 0, 0, 6,
            0, 1, 0, 4,
            0x02, 0x77,
        ]))
        await connection.enqueueServerBytes(Self.stateChange(AppleStateChange.pasteboardChanged))
        let fetched = await Self.waitUntil {
            Self.occurrenceCount(of: request, in: await connection.sentBytes()) == 1
        }
        XCTAssertTrue(fetched)
        await session.disconnect()
    }

    /// Every state change but the idle notice is passed on, so a host can
    /// tell a session ended at the other computer from one that was lost.
    func testAppleStateChangesArePublishedExceptTheIdleNotice() async throws {
        let (session, connection) = try await connectAppleServer()
        let recorder = EventRecorder()
        recorder.record(session)

        await connection.enqueueServerBytes(Self.stateChange(AppleStateChange.idle))
        await connection.enqueueServerBytes(
            Self.stateChange(AppleStateChange.localUserClosedConnection))
        let published = await Self.waitUntil {
            recorder.contains {
                if case .appleStateChange(let change) = $0 {
                    change.code == AppleStateChange.localUserClosedConnection
                } else {
                    false
                }
            }
        }
        XCTAssertTrue(published)
        XCTAssertFalse(recorder.contains {
            if case .appleStateChange(let change) = $0 {
                change.code == AppleStateChange.idle
            } else {
                false
            }
        })
        await session.disconnect()
    }

    // MARK: - Helpers

    private func connectAppleServer() async throws -> (TransportSession, ScriptedRFBConnection) {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.appleServerInitMessage(
            serverCommands: [AppleClipboardProtocol.packedScrapMessageType]))
        await connection.enqueueServerBytes(script)
        let session = TransportSession(
            host: "apple.test", port: 5900, password: "",
            preferredEncodings: [.raw], connection: connection)
        try await session.connect()
        return (session, connection)
    }

    private static func stateChange(_ code: UInt16) -> Data {
        Data([AppleStateChange.messageType, 0, 0, 4, 0, 1, UInt8(code >> 8), UInt8(code & 0xff)])
    }

    private func connectConventionalServer() async throws
        -> (TransportSession, ScriptedRFBConnection, EventRecorder) {
        let connection = ScriptedRFBConnection()
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(width: 640, height: 480, name: "conventional"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "conventional.test", port: 5900, password: "",
            preferredEncodings: [.raw], connection: connection)
        let recorder = EventRecorder()
        try await session.connect()
        recorder.record(session)

        let sent = await connection.sentBytes()
        let tail = ClientMessage.setEncodings([.extendedDesktopSize, .extendedClipboard])
            .serialize().suffix(8)
        XCTAssertEqual(
            Self.occurrenceCount(of: Data(tail), in: sent), 1,
            "Conventional servers are offered ExtendedClipboard")
        return (session, connection, recorder)
    }

    private static func serverMessage(_ message: Extended.Message) -> Data {
        var data = try! Extended.clientMessage(message)
        data[0] = 3 // ServerCutText shares ClientCutText's layout
        return data
    }

    private static func legacyServerCutText(_ text: String) -> Data {
        var data = ClientMessage.clientCutText(text).serialize()
        data[0] = 3
        return data
    }

    private static func serverInitMessage(width: UInt16, height: UInt16, name: String) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xff)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xff)])
        data.append(PixelFormat.bgra8888.wireBytes())
        let nameBytes = Data(name.utf8)
        AppleClipboardProtocol.appendUInt32BE(UInt32(nameBytes.count), to: &data)
        data.append(nameBytes)
        return data
    }

    private static func appleServerInitMessage(serverCommands: [UInt8]) -> Data {
        var field = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x52])
        var bitmap = Data(repeating: 0, count: 16)
        for command in serverCommands {
            bitmap[Int(command) / 8] |= 0x80 >> (command % 8)
        }
        field.append(bitmap)
        field.append(Data("Mac".utf8))

        var data = Data([0x07, 0x80, 0x04, 0x38]) // 1920x1080
        data.append(PixelFormat.bgra8888.wireBytes())
        AppleClipboardProtocol.appendUInt32BE(UInt32(field.count), to: &data)
        data.append(field)
        return data
    }

    private static func occurrenceCount(of pattern: Data, in data: Data) -> Int {
        let patternBytes = [UInt8](pattern)
        let bytes = [UInt8](data)
        guard !patternBytes.isEmpty, patternBytes.count <= bytes.count else { return 0 }
        return (0...(bytes.count - patternBytes.count)).reduce(into: 0) { count, offset in
            if bytes[offset..<(offset + patternBytes.count)].elementsEqual(patternBytes) {
                count += 1
            }
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SessionEvent] = []
    private var task: Task<Void, Never>?

    func record(_ session: TransportSession) {
        task = Task { [weak self] in
            for await event in session.events {
                self?.append(event)
            }
        }
    }

    deinit { task?.cancel() }

    private func append(_ event: SessionEvent) {
        lock.withLock { events.append(event) }
    }

    func contains(_ predicate: (SessionEvent) -> Bool) -> Bool {
        lock.withLock { events.contains(where: predicate) }
    }

    func clipboardContents() -> [ClipboardContent] {
        lock.withLock { events.compactMap {
            if case .clipboardContent(let content) = $0 { content } else { nil }
        } }
    }
}

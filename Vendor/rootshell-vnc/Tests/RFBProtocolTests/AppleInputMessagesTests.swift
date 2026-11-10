import XCTest
import Foundation
@testable import RFBProtocol

final class AppleKeyEventTests: XCTestCase {
    func testBlockCarriesKeysymKeyboardTypeAndKeyCode() {
        let event = AppleKeyEvent(keysym: 0x0100_015F, isDown: true, keyCode: 41)

        XCTAssertEqual(event.plainBlock, Data([
            0xff, 0x01,                 // key event, down
            0x01, 0x00, 0x01, 0x5f,     // keysym
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,                 // no pointer event, no buttons
            0x00, 0xc6,                 // keyboard type 198
            0x00, 0x29,                 // key code 41
        ]))
    }

    func testReleaseClearsTheDownFlagAndKeepsTheRest() {
        let down = AppleKeyEvent(keysym: 0x61, isDown: true, keyCode: 0)
        let up = AppleKeyEvent(keysym: 0x61, isDown: false, keyCode: 0)

        XCTAssertEqual(up.plainBlock[1], 0)
        XCTAssertEqual(up.plainBlock.dropFirst(2), down.plainBlock.dropFirst(2))
    }

    func testBlockIsOneAESBlockAndStartsWithTheMarkersTheServerChecks() {
        let block = AppleKeyEvent(keysym: 0xff0d, isDown: true).plainBlock

        XCTAssertEqual(block.count, 16)
        XCTAssertEqual(block[0], 0xff)
        XCTAssertEqual(block[10], 0x00)
    }

    func testMessageWrapsTheEncryptedBlockInAnInputEventHeader() throws {
        let event = AppleKeyEvent(keysym: 0x61, isDown: true, keyCode: 0)
        let encrypted = Data((0..<16).map { UInt8(0xa0 + $0) })

        let message = try XCTUnwrap(event.wireMessage(encryptedBlock: encrypted))

        XCTAssertEqual(message.prefix(10), Data([
            0x17, 0x00,     // input event, no timestamp
            0x00, 0x16,     // 22 bytes follow
            0x00, 0x01,     // version 1
            0x00, 0x0c,     // key and mouse event
            0x00, 0x03,     // the key code is to be used as given
        ]))
        XCTAssertEqual(message.suffix(16), encrypted)
        XCTAssertEqual(message.count, AppleKeyEvent.wireByteCount)
    }

    func testMessageWithoutAKeyCodeLeavesTheKeyToTheKeysym() throws {
        let event = AppleKeyEvent(keysym: 0x61, isDown: true)

        let message = try XCTUnwrap(event.wireMessage(encryptedBlock: Data(count: 16)))

        XCTAssertEqual(message[9], 0x00)
        XCTAssertEqual(event.plainBlock.suffix(2), Data([0x00, 0x00]))
    }

    func testMessageRejectsABlockOfTheWrongSize() {
        let event = AppleKeyEvent(keysym: 0x61, isDown: true)

        XCTAssertNil(event.wireMessage(encryptedBlock: Data(count: 15)))
        XCTAssertNil(event.wireMessage(encryptedBlock: Data(count: 32)))
    }
}

final class AppleKeyboardInputSourceTests: XCTestCase {
    func testMessageNamesTheInputSource() throws {
        let identifier = "com.apple.keylayout.ABC"

        let message = try XCTUnwrap(AppleKeyboardInputSource.wireMessage(identifier: identifier))

        XCTAssertEqual(message.prefix(8), Data([
            0x1a, 0x00,
            0x00, 0x1b,     // 27 bytes follow: version, length and 23 of name
            0x00, 0x01,     // version 1
            0x00, 0x17,     // 23 bytes of name
        ]))
        XCTAssertEqual(message.dropFirst(8), Data(identifier.utf8))
    }

    func testIdentifierIsMeasuredInBytes() throws {
        let message = try XCTUnwrap(AppleKeyboardInputSource.wireMessage(identifier: "é"))

        XCTAssertEqual(message[7], 2)
        XCTAssertEqual(message.count, 8 + 2)
    }

    func testEmptyAndOversizedIdentifiersAreNotSent() {
        XCTAssertNil(AppleKeyboardInputSource.wireMessage(identifier: ""))
        XCTAssertNil(AppleKeyboardInputSource.wireMessage(
            identifier: String(repeating: "a", count: 256)))
        XCTAssertNotNil(AppleKeyboardInputSource.wireMessage(
            identifier: String(repeating: "a", count: 255)))
    }
}

final class AppleStateChangeTests: XCTestCase {
    private func message(_ code: UInt16) -> Data {
        Data([0x14, 0, 0, 4, 0, 1, UInt8(code >> 8), UInt8(code & 0xff)])
    }

    func testReadsTheCode() throws {
        XCTAssertEqual(try XCTUnwrap(AppleStateChange(wire: message(2))).code, 2)
        XCTAssertEqual(try XCTUnwrap(AppleStateChange(wire: message(4))).code, 4)
        XCTAssertEqual(try XCTUnwrap(AppleStateChange(wire: message(0x1234))).code, 0x1234)
    }

    func testOnlyAChangedPasteboardAnnouncesThePasteboard() throws {
        XCTAssertTrue(try XCTUnwrap(AppleStateChange(wire: message(AppleStateChange.pasteboardChanged))).announcesPasteboard)
        for code in [AppleStateChange.idle, AppleStateChange.localUserClosedConnection,
                     AppleStateChange.userSessionChanged, 0, 0x0c, 6] {
            XCTAssertFalse(try XCTUnwrap(AppleStateChange(wire: message(code))).announcesPasteboard, "\(code)")
        }
    }

    func testRefusesWhatIsNotAStateChange() {
        var other = message(2)
        other[0] = 0x15
        XCTAssertNil(AppleStateChange(wire: other))
        XCTAssertNil(AppleStateChange(wire: message(2).prefix(7)))
        XCTAssertNil(AppleStateChange(wire: Data()))
        // A size too small to hold a code.
        XCTAssertNil(AppleStateChange(wire: Data([0x14, 0, 0, 2, 0, 1, 0, 2])))
    }

    func testReadsTheCodeFromALongerMessage() throws {
        let longer = Data([0x14, 0, 0, 6, 0, 1, 0, 2, 0xaa, 0xbb])
        XCTAssertEqual(AppleStateChange.payloadSize(header: longer), 6)
        XCTAssertEqual(try XCTUnwrap(AppleStateChange(wire: longer)).code, 2)
    }

    func testPayloadSizeNeedsAWholeHeader() {
        XCTAssertEqual(AppleStateChange.payloadSize(header: Data([0x14, 0, 0, 4])), 4)
        XCTAssertEqual(AppleStateChange.payloadSize(header: Data([0x14, 0, 0])), 0)
        XCTAssertEqual(AppleStateChange.payloadSize(header: Data([0x14, 0, 0x01, 0x02, 9, 9])), 0x0102)
    }

    /// A slice does not start at index zero; the reader must not assume it.
    func testReadsFromASliceOfALargerBuffer() throws {
        let buffer = Data([0xff, 0xff, 0xff]) + message(2)
        let slice = buffer[3...]
        XCTAssertEqual(try XCTUnwrap(AppleStateChange(wire: slice)).code, 2)
        XCTAssertEqual(AppleStateChange.payloadSize(header: slice), 4)
    }
}

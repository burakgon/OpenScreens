import XCTest
import Foundation
@testable import RFBTransport

final class AppleKeyEventCipherTests: XCTestCase {
    /// The AES-128 example from FIPS 197, appendix C.1.
    func testEncryptsOneBlockInECBMode() {
        let key = Data((0x00...0x0f).map { UInt8($0) })
        let block = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        ])

        XCTAssertEqual(TransportSession.aesECBEncryptBlock(block, key: key), Data([
            0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
            0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
        ]))
    }

    func testRejectsAnythingThatIsNotOneBlockAndOneKey() {
        let key = Data(count: 16)

        XCTAssertNil(TransportSession.aesECBEncryptBlock(Data(count: 15), key: key))
        XCTAssertNil(TransportSession.aesECBEncryptBlock(Data(count: 32), key: key))
        XCTAssertNil(TransportSession.aesECBEncryptBlock(Data(count: 16), key: Data(count: 32)))
    }
}

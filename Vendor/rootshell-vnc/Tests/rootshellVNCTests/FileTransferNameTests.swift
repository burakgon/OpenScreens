import XCTest
@testable import rootshellVNC

/// Names of downloaded items come from the other computer and become file
/// names here. None may lead out of the folder a download is written to.
final class FileTransferNameTests: XCTestCase {
    func testOrdinaryNamesAreKept() {
        XCTAssertEqual(VNCFileTransferController.sanitizedName("Report.pdf"), "Report.pdf")
        XCTAssertEqual(VNCFileTransferController.sanitizedName("Résumé – final.txt"), "Résumé – final.txt")
        XCTAssertEqual(VNCFileTransferController.sanitizedName(".hidden"), ".hidden")
    }

    func testSlashesAndNULsDoNotSurvive() {
        XCTAssertEqual(VNCFileTransferController.sanitizedName("a/b"), "a:b")
        XCTAssertEqual(VNCFileTransferController.sanitizedName("../../etc/passwd"), "..:..:etc:passwd")
        XCTAssertEqual(VNCFileTransferController.sanitizedName("a\0b"), "ab")
    }

    func testDotNamesAreReplaced() {
        XCTAssertEqual(VNCFileTransferController.sanitizedName(""), "File")
        XCTAssertEqual(VNCFileTransferController.sanitizedName("."), "File")
        XCTAssertEqual(VNCFileTransferController.sanitizedName(".."), "File")
        XCTAssertEqual(VNCFileTransferController.sanitizedName("\0"), "File")
    }

    /// A slash followed by a combining mark or an invisible joiner is one
    /// character that is not "/", and a search of the text for "/" does not
    /// find it. The file system splits the name there all the same.
    func testASlashHiddenInsideACharacterIsStillReplaced() {
        for hidden in ["../\u{0301}escaped.txt", "../\u{200D}escaped", "x/\u{FE0F}y", "a/\u{0338}b"] {
            let cleaned = VNCFileTransferController.sanitizedName(hidden)
            XCTAssertFalse(cleaned.utf8.contains(UInt8(ascii: "/")), "\(hidden.unicodeScalars.map { $0.value })")
        }
    }

    /// Whatever the name, the place it leads to is directly inside the folder.
    func testEveryCleanedNameStaysInsideTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/openscreens-downloads/one", isDirectory: true)
        let names = [
            "../\u{0301}up", "..", "../..", "/absolute", "a/../../b", "\u{0301}/..",
            "..\u{200D}/x", "normal.txt", "..:..", "\0/\0",
        ]
        for name in names {
            let url = VNCFileTransferController.uniqueURL(
                in: folder, name: VNCFileTransferController.sanitizedName(name))
            XCTAssertEqual(
                url.standardizedFileURL.deletingLastPathComponent().path, folder.path,
                "\(name.unicodeScalars.map { $0.value })")
        }
    }
}

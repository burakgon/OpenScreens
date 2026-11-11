import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// What counts as a name, and where a name from a server may lead on
    /// this device.
    @Suite("SFTP names")
    struct SFTPPathTests {
        /// Odd, some of them, but each is one entry of a folder and nothing
        /// more.
        static let usableNames = [
            "notes.txt", "Projects", ".hidden", "..hidden", "...", "a b", " ", "日本", "👨‍👩‍👧",
            "e\u{0301}", "\u{0301}", "..\u{200D}", ".\u{0301}", "back\\slash", "new\nline", "tab\t",
            "%2F", "%2f..%2f", "%", "a:b", "#", "?", "~", "~root", "-", "--help", "\u{202E}txt.exe",
            String(repeating: "n", count: 255),
        ]

        /// Empty, the two names every folder has, and anything with a slash
        /// or a NUL among its bytes, however the slash is dressed up.
        static let unusableNames = [
            "", ".", "..", "/", "//", "a/b", "/absolute", "trailing/", "../up", "./here", "x/..",
            "../\u{0301}escaped.txt", "../\u{200D}escaped", "a/\u{0301}b", "/\u{0301}", "\u{200D}/..",
            "\u{FEFF}/..", "nul\0byte", "\0",
        ]

        @Test(arguments: usableNames)
        func aPlainNameIsUsable(_ name: String) {
            #expect(SFTPPath.isUsableName(name))
        }

        @Test(arguments: unusableNames)
        func aNameThatIsNotOneEntryIsNot(_ name: String) {
            #expect(!SFTPPath.isUsableName(name))
        }

        @Test func aSlashIsFoundAmongTheBytesNotTheCharacters() {
            // This is the name that passed a search for the character "/":
            // the slash and the accent after it are one character.
            let name = "../\u{0301}escaped.txt"
            #expect(!name.contains("/"))
            #expect(name.utf8.contains(UInt8(ascii: "/")))
            #expect(!SFTPPath.isUsableName(name))
        }

        /// A folder that exists, reached through the `/private` that macOS
        /// puts in front of its temporary directory: the spelling Foundation
        /// rewrites for things that exist and leaves alone for things that
        /// do not exist yet.
        private func existingFolder() throws -> (TemporaryDirectory, URL) {
            let scratch = try TemporaryDirectory()
            let folder = URL(filePath: try scratch.url.canonicalPath).appending(path: "chosen")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (scratch, folder)
        }

        @Test func aUsableNameLeadsToTheEntryOfThatNameInTheFolder() throws {
            let (scratch, folder) = try existingFolder()
            defer { _ = scratch }
            try Data().write(to: folder.appending(path: "notes.txt"))

            for name in Self.usableNames {
                let url = try #require(SFTPPath.localURL(for: name, in: folder), "\(name.debugDescription)")
                #expect(url.lastPathComponent == name, "\(name.debugDescription)")
                #expect(url.deletingLastPathComponent().pathComponents == folder.pathComponents,
                        "\(name.debugDescription)")
            }
            // A trailing slash on the folder changes nothing.
            let withSlash = URL(filePath: folder.path + "/", directoryHint: .isDirectory)
            #expect(SFTPPath.localURL(for: "notes.txt", in: withSlash)?.path == folder.path + "/notes.txt")
        }

        @Test func anUnusableNameLeadsNowhere() throws {
            let (scratch, folder) = try existingFolder()
            defer { _ = scratch }
            for name in Self.unusableNames {
                #expect(SFTPPath.localURL(for: name, in: folder) == nil, "\(name.debugDescription)")
            }
        }

        /// The second check stands on its own: it is given places that the
        /// check on the name would never have let through.
        @Test func aPlaceOutsideTheFolderIsRecognisedWhateverTheNameWas() throws {
            let (scratch, folder) = try existingFolder()
            defer { _ = scratch }

            for name in ["../up", "../\u{0301}escaped.txt", "a/b", "a/\u{0301}b", "..", ".", "x/..", "/absolute", "//"] {
                let url = folder.appending(path: name)
                #expect(!SFTPPath.leads(url, to: name, in: folder), "\(name.debugDescription)")
            }
            // Somewhere else altogether, and the folder itself.
            #expect(!SFTPPath.leads(URL(filePath: "/etc/passwd"), to: "passwd", in: folder))
            #expect(!SFTPPath.leads(folder, to: folder.lastPathComponent, in: folder))
            // Inside, but not under the name that was asked for.
            #expect(!SFTPPath.leads(folder.appending(path: "other"), to: "notes.txt", in: folder))
            #expect(SFTPPath.leads(folder.appending(path: "notes.txt"), to: "notes.txt", in: folder))
            // A way round that ends up in the right place is still that place.
            #expect(SFTPPath.leads(folder.appending(path: "x/../notes.txt"), to: "notes.txt", in: folder))
        }

        @Test func aNameTheSystemWouldAlterIsNotUsedUnderAnotherName() throws {
            let (scratch, folder) = try existingFolder()
            defer { _ = scratch }
            // Whatever a URL makes of an unusual name, the name is either
            // kept exactly or not used at all: a file is never saved under a
            // name other than its own, where it could replace its neighbour.
            for name in ["\u{FEFF}notes.txt", "notes.txt\u{FEFF}", "\u{200B}", "\u{2028}", "\u{FFFD}", "a\rb"] {
                if let url = SFTPPath.localURL(for: name, in: folder) {
                    #expect(url.lastPathComponent == name, "\(name.debugDescription)")
                }
            }
        }
    }
}

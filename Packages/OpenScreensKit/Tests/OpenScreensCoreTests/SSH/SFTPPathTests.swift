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

        @Test func aNameLongerThanAnyFileSystemAllowsIsNotAName() {
            let longest = String(repeating: "n", count: SFTPPath.maximumNameLength)
            #expect(SFTPPath.isUsableName(longest))
            #expect(!SFTPPath.isUsableName(longest + "n"))
            // The length is the length in bytes, as it is to a file system.
            let wide = String(repeating: "日", count: SFTPPath.maximumNameLength / 3)
            #expect(SFTPPath.isUsableName(wide))
            #expect(!SFTPPath.isUsableName(wide + "日"))
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

            let chosen = SFTPPath.LocalFolder(folder)
            for name in ["../up", "../\u{0301}escaped.txt", "a/b", "a/\u{0301}b", "..", ".", "x/..", "/absolute", "//"] {
                #expect(!chosen.holds(folder.appending(path: name), as: name), "\(name.debugDescription)")
            }
            // Somewhere else altogether, and the folder itself.
            #expect(!chosen.holds(URL(filePath: "/etc/passwd"), as: "passwd"))
            #expect(!chosen.holds(folder, as: folder.lastPathComponent))
            // Inside, but not under the name that was asked for.
            #expect(!chosen.holds(folder.appending(path: "other"), as: "notes.txt"))
            #expect(chosen.holds(folder.appending(path: "notes.txt"), as: "notes.txt"))
            // A way round that ends up in the right place is still that place.
            #expect(chosen.holds(folder.appending(path: "x/../notes.txt"), as: "notes.txt"))
        }

        @Test func aPathInsideATreeIsCheckedNameByName() throws {
            let (scratch, folder) = try existingFolder()
            defer { _ = scratch }
            #expect(SFTPPath.localURL(forPath: "", in: folder) == folder)
            #expect(SFTPPath.localURL(forPath: "a", in: folder)?.path == folder.path + "/a")
            #expect(SFTPPath.localURL(forPath: "a/b c/d.txt", in: folder)?.path == folder.path + "/a/b c/d.txt")
            for path in ["..", "a/..", "a/../..", "a//b", "/a", "a/", "a/./b", "../\u{0301}x", "a/nul\0/b"] {
                #expect(SFTPPath.localURL(forPath: path, in: folder) == nil, "\(path.debugDescription)")
            }
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

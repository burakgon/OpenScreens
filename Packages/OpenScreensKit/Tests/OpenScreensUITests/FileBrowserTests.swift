import Foundation
import Testing
@testable import OpenScreensCore
@testable import OpenScreensUI

/// What the file browser does with names it did not choose.
@MainActor
@Suite("File browser")
struct FileBrowserTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensFileBrowserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The server names the files. A name must not be able to put a download
    /// anywhere but the folder the user chose, and that includes a slash with
    /// a combining mark or an invisible character after it, which is not the
    /// character "/" and still separates folders.
    @Test(arguments: [
        "../../evil", "/etc/passwd", "a/b/c.txt", "..", ".", "", "nul\0byte",
        "../\u{0301}evil", "../\u{200D}evil", "a/\u{0301}b", "/\u{0301}", "\u{FEFF}/../evil", "..\0",
    ])
    func aRemoteNameCannotLeaveTheChosenFolder(name: String) throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = FileBrowser.unusedURL(for: name, in: directory)

        #expect(target.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(!target.lastPathComponent.isEmpty)
        #expect(target.lastPathComponent != "..")
        #expect(target.lastPathComponent != ".")
        #expect(!target.lastPathComponent.contains("\0"))
        #expect(SFTPPath.isUsableName(target.lastPathComponent))
    }

    @Test func aDownloadNeverReplacesWhatIsAlreadyThere() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FileBrowser.unusedURL(for: "Report.pdf", in: directory)
        #expect(first.lastPathComponent == "Report.pdf")
        try Data("one".utf8).write(to: first)

        let second = FileBrowser.unusedURL(for: "Report.pdf", in: directory)
        #expect(second.lastPathComponent == "Report 2.pdf")
        try Data("two".utf8).write(to: second)

        #expect(FileBrowser.unusedURL(for: "Report.pdf", in: directory).lastPathComponent == "Report 3.pdf")
        #expect(FileBrowser.unusedURL(for: "Notes", in: directory).lastPathComponent == "Notes")
        #expect(try Data(contentsOf: first) == Data("one".utf8))
    }

    @Test(arguments: [
        ("Projects", true), ("a b.txt", true), (".hidden", true), ("日本", true),
        ("", false), (".", false), ("..", false), ("a/b", false), ("/", false), ("a\0b", false),
        ("a/\u{0301}b", false), ("../\u{200D}up", false), ("e\u{0301}", true), ("..\u{200D}", true),
    ])
    func onlyAPlainNameCanBeGivenToAFolderOrARename(name: String, isUsable: Bool) {
        #expect(FileBrowser.isUsableName(name) == isUsable)
    }

    @Test func aTransferSaysWhenItCouldNotCopyEverything() {
        var transfer = FileBrowser.Transfer(name: "Photos", isUpload: false)
        #expect(transfer.skippedNote == nil)
        transfer.skippedCount = 1
        #expect(transfer.skippedNote == "1 item with a name that cannot be shown was skipped.")
        transfer.skippedCount = 12
        #expect(transfer.skippedNote == "12 items with names that cannot be shown were skipped.")
    }

    @Test func aFolderSaysWhenItHoldsMoreThanIsShown() {
        #expect(FileBrowser.unlistedNote(for: 0) == nil)
        #expect(FileBrowser.unlistedNote(for: 1) == "1 item with a name that cannot be shown is not listed.")
        #expect(FileBrowser.unlistedNote(for: 3) == "3 items with names that cannot be shown are not listed.")
    }

    @Test func pathsAreJoinedWithOneSlash() {
        #expect(FileBrowser.join("/Users/me", "Desktop") == "/Users/me/Desktop")
        #expect(FileBrowser.join("/", "tmp") == "/tmp")
        #expect(FileBrowser.join("/Users/me/", "Desktop") == "/Users/me/Desktop")
    }

    @Test func aBrowserWithNothingSavedAsksWhoToSignInAs() {
        let browser = FileBrowser(
            computer: Computer(name: "Studio", host: "studio.invalid"),
            credentials: CredentialStore(storage: InMemorySecretStorage()),
            sshKeys: SSHKeyStore(storage: InMemorySecretStorage()),
            knownHosts: KnownHostsStore(fileURL: nil))

        browser.start()

        #expect(browser.phase == .signIn(FileBrowser.SignInPrompt(message: nil, username: "")))
        browser.close()
    }
}

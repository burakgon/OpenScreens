import Foundation
import Observation
import OpenScreensCore

/// The files of a remote computer, over SFTP.
///
/// One browser is one SSH connection to the computer: it signs in the way a
/// secure tunnel would, lists folders, and copies files and folders in both
/// directions, one transfer at a time.
@Observable
public final class FileBrowser: Identifiable {

    public enum Phase: Equatable {
        case connecting
        /// The SSH server wants a name and password.
        case signIn(SignInPrompt)
        /// The SSH server presented a key the user has to vouch for.
        case hostKey(RemoteSession.HostKeyPrompt)
        case ready
        case failed(String)
    }

    public struct SignInPrompt: Equatable {
        /// Why the user is being asked, when an attempt was rejected.
        public var message: String?
        public var username: String
    }

    /// One file or folder on its way to or from the computer.
    public struct Transfer: Identifiable, Equatable {
        public enum State: Equatable {
            case waiting, running, finished, failed(String), cancelled
        }

        public let id = UUID()
        public var name: String
        public var isUpload: Bool
        public var completed: Int64 = 0
        public var total: Int64?
        public var state = State.waiting
        /// How many files and folders a finished transfer left out because
        /// their names cannot be used here.
        public var skippedCount = 0

        public var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(completed) / Double(total))
        }

        /// Says that the copy is not complete, when it is not.
        public var skippedNote: String? {
            switch skippedCount {
            case ..<1: nil
            case 1: "1 item with a name that cannot be shown was skipped."
            default: "\(skippedCount) items with names that cannot be shown were skipped."
            }
        }

        public var isActive: Bool {
            state == .waiting || state == .running
        }
    }

    public let id = UUID()
    public let computer: Computer

    public private(set) var phase = Phase.connecting
    /// The folder being shown, as the server names it.
    public private(set) var path = ""
    public private(set) var items: [SFTPItem] = []
    /// How many things in the folder are missing from ``items`` because
    /// their names cannot be used: they are not text, or not the name of
    /// one thing. They cannot be opened, copied or deleted from here.
    public private(set) var unlistedCount = 0
    public private(set) var isLoading = false
    public private(set) var transfers: [Transfer] = []
    /// What went wrong with the last thing the user asked for.
    public var errorMessage: String?
    public var showsHiddenFiles = false {
        didSet { applyListing() }
    }

    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let sshKeys: SSHKeyStore
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var sftp: SFTPClient?
    @ObservationIgnored private var listing: [SFTPItem] = []
    @ObservationIgnored private var entered: (username: String, password: String, remember: Bool)?
    @ObservationIgnored private var hostKeyAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [(id: Transfer.ID, work: Work)] = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    private enum Work {
        case upload(local: URL, remoteDirectory: String, isDirectory: Bool)
        case download(item: SFTPItem, localDirectory: URL)
    }

    public init(
        computer: Computer,
        credentials: CredentialStore,
        sshKeys: SSHKeyStore,
        knownHosts: KnownHostsStore
    ) {
        self.computer = computer
        self.credentials = credentials
        self.sshKeys = sshKeys
        self.knownHosts = knownHosts
    }

    isolated deinit {
        connectTask?.cancel()
        runner?.cancel()
        hostKeyAnswer?.resume(returning: false)
    }

    // MARK: - Where and who

    /// The SSH server holding the files: the computer itself.
    private var port: Int {
        // A port set for a tunnel to the computer itself is its SSH port.
        computer.ssh.isEnabled && tunnelsToItself ? computer.ssh.port : 22
    }

    private var tunnelsToItself: Bool {
        computer.ssh.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var savedUsername: String {
        let ssh = computer.ssh.username.trimmingCharacters(in: .whitespaces)
        if tunnelsToItself, !ssh.isEmpty { return ssh }
        return computer.username?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private enum Identity {
        case ready(username: String, credential: SSHCredential)
        case needsSignIn(username: String)
    }

    /// On a Mac, Remote Login is the same account as screen sharing, so the
    /// saved name and password are tried before asking.
    private func identity() -> Identity {
        let username = entered?.username ?? savedUsername
        if entered == nil, tunnelsToItself, computer.ssh.authentication == .key,
           let keyID = computer.ssh.keyID, let key = sshKeys.privateKey(for: keyID), !username.isEmpty {
            return .ready(username: username, credential: .key(key))
        }
        let password = entered?.password
            ?? (tunnelsToItself ? credentials.password(for: computer.id, kind: .ssh) : nil)
            ?? credentials.password(for: computer.id, kind: .screenSharing)
        guard let password, !password.isEmpty, !username.isEmpty else {
            return .needsSignIn(username: username)
        }
        return .ready(username: username, credential: .password(password))
    }

    // MARK: - Connecting

    public func start() {
        guard connectTask == nil, sftp == nil, !isClosed else { return }
        switch identity() {
        case .needsSignIn(let username):
            phase = .signIn(SignInPrompt(message: nil, username: username))
        case .ready(let username, let credential):
            connect(username: username, credential: credential)
        }
    }

    public func submit(username: String, password: String, remember: Bool) {
        entered = (username.trimmingCharacters(in: .whitespaces), password, remember)
        start()
    }

    public func answerHostKey(trust: Bool) {
        if case .hostKey = phase { phase = .connecting }
        hostKeyAnswer?.resume(returning: trust)
        hostKeyAnswer = nil
    }

    private func connect(username: String, credential: SSHCredential) {
        phase = .connecting
        let host = computer.host
        let port = port
        connectTask = Task { [weak self, knownHosts] in
            defer { self?.connectTask = nil }
            do {
                let client = try await SSHClient.connect(
                    host: host, port: port, username: username, credential: credential,
                    knownHosts: knownHosts,
                    hostKeyPolicy: { [weak self] challenge in
                        await self?.decide(challenge) ?? false
                    })
                let sftp = try await client.openSFTP()
                let home = try await sftp.homeDirectory()
                guard let self, !self.isClosed else {
                    await client.close()
                    return
                }
                self.client = client
                self.sftp = sftp
                self.rememberSignInIfAsked()
                self.phase = .ready
                await self.load(home)
            } catch is CancellationError {
                return
            } catch {
                self?.connectionFailed(error)
            }
        }
    }

    private func decide(_ challenge: SSHHostKeyChallenge) async -> Bool {
        let expected: String?
        switch challenge.verdict {
        case .trusted: return true
        case .unknown: expected = nil
        case .mismatch(let onRecord, _): expected = onRecord
        }
        guard !isClosed else { return false }
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                hostKeyAnswer?.resume(returning: false)
                hostKeyAnswer = continuation
                phase = .hostKey(RemoteSession.HostKeyPrompt(
                    host: challenge.host, port: challenge.port,
                    keyType: challenge.keyType, fingerprint: challenge.fingerprint,
                    expectedFingerprint: expected))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerHostKey(trust: false)
            }
        }
        guard accepted else { return false }
        if expected != nil {
            try? challenge.knownHosts.remove(host: challenge.host, port: challenge.port)
        }
        try? challenge.trust()
        return true
    }

    private func connectionFailed(_ error: any Error) {
        if let error = error as? SSHError {
            switch error {
            case .authenticationFailed:
                let username = entered?.username ?? savedUsername
                entered = nil
                phase = .signIn(SignInPrompt(
                    message: "The computer did not accept that user name and password for Remote Login.",
                    username: username))
                return
            case .hostKeyRejected:
                phase = .failed("The connection was stopped because the computer's SSH key was not trusted.")
                return
            case .connectionFailed(let detail) where detail.localizedCaseInsensitiveContains("refused"):
                phase = .failed(computer.kind.isApple
                    ? "The computer refused the connection. Turn on Remote Login in System Settings › General › Sharing on that Mac to browse its files."
                    : "The computer refused the connection. Browsing files needs an SSH server running on it.")
                return
            default:
                break
            }
        }
        phase = .failed(error.localizedDescription)
    }

    private func rememberSignInIfAsked() {
        guard let entered, entered.remember,
              credentials.password(for: computer.id, kind: .screenSharing) != entered.password else { return }
        try? credentials.setPassword(entered.password, for: computer.id, kind: .ssh)
    }

    /// Ends the connection. Transfers still under way are stopped.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        answerHostKey(trust: false)
        connectTask?.cancel()
        runner?.cancel()
        queue.removeAll()
        for index in transfers.indices where transfers[index].isActive {
            transfers[index].state = .cancelled
        }
        let client = client
        self.client = nil
        sftp = nil
        Task { await client?.close() }
    }

    // MARK: - Folders

    /// The folder above the one shown, or `nil` at the top.
    public var parentPath: String? {
        guard path != "/", !path.isEmpty else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// The name of the folder shown.
    public var folderName: String {
        if path == "/" || path.isEmpty { return "/" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    public func open(_ item: SFTPItem) {
        guard let sftp else { return }
        if item.isDirectory {
            Task { await load(item.path) }
        } else if item.isSymlink {
            // A link to a folder opens like one.
            Task {
                if let target = try? await sftp.attributes(of: item.path, followSymlinks: true), target.isDirectory {
                    await load(item.path)
                }
            }
        }
    }

    public func goUp() {
        guard let parentPath else { return }
        Task { await load(parentPath) }
    }

    public func refresh() {
        Task { await load(path) }
    }

    public func go(to path: String) {
        Task { await load(path) }
    }

    private func load(_ newPath: String) async {
        guard let sftp else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let resolved = try await sftp.realPath(newPath)
            let listed = try await sftp.listing(of: resolved)
            path = resolved
            listing = listed.items
            unlistedCount = listed.unusableNameCount
            applyListing()
        } catch {
            report(error, doing: "open that folder")
        }
    }

    private func applyListing() {
        items = listing
            .filter { $0.name != "." && $0.name != ".." }
            .filter { showsHiddenFiles || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Says that the folder holds more than is shown, when it does.
    public var unlistedNote: String? {
        Self.unlistedNote(for: unlistedCount)
    }

    static func unlistedNote(for count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 item with a name that cannot be shown is not listed."
        default: "\(count) items with names that cannot be shown are not listed."
        }
    }

    private func report(_ error: any Error, doing what: String) {
        if error is CancellationError { return }
        errorMessage = "Couldn't \(what): \(error.localizedDescription)"
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// A name can be used as it is: not empty, not a path. The rule is the
    /// one listings and downloads go by.
    static func isUsableName(_ name: String) -> Bool {
        SFTPPath.isUsableName(name)
    }

    // MARK: - Changes

    public func makeFolder(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let sftp, Self.isUsableName(name) else { return }
        let target = Self.join(path, name)
        Task {
            do {
                try await sftp.makeDirectory(target)
                await load(path)
            } catch {
                report(error, doing: "create the folder")
            }
        }
    }

    public func rename(_ item: SFTPItem, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let sftp, Self.isUsableName(name), name != item.name else { return }
        guard !listing.contains(where: { $0.name == name }) else {
            errorMessage = "There is already something called “\(name)” here."
            return
        }
        let target = Self.join(path, name)
        Task {
            do {
                try await sftp.rename(item.path, to: target)
                await load(path)
            } catch {
                report(error, doing: "rename “\(item.name)”")
            }
        }
    }

    /// Deletes files and folders, folders with everything in them.
    public func delete(_ doomed: [SFTPItem]) {
        guard let sftp, !doomed.isEmpty else { return }
        Task {
            do {
                for item in doomed {
                    try await Self.remove(item, using: sftp)
                }
            } catch {
                report(error, doing: "delete everything selected")
            }
            await load(path)
        }
    }

    private static func remove(_ item: SFTPItem, using sftp: SFTPClient) async throws {
        // A link is removed as a link, whatever it points to.
        guard item.isDirectory else {
            try await sftp.remove(item.path)
            return
        }
        let contents = try await sftp.listing(of: item.path)
        for child in contents.items where child.name != "." && child.name != ".." {
            try Task.checkCancellation()
            try await remove(child, using: sftp)
        }
        // What cannot be named cannot be deleted, and the folder is not
        // empty without it. Say so, in place of the server's "failure".
        guard contents.unusableNameCount == 0 else {
            throw UndeletableContents(folder: item.name)
        }
        try await sftp.removeDirectory(item.path)
    }

    private struct UndeletableContents: LocalizedError {
        let folder: String

        var errorDescription: String? {
            "“\(folder)” holds items with names that cannot be shown, which can only be deleted on the computer itself."
        }
    }

    // MARK: - Transfers

    /// Names among `urls` that already exist in the folder shown.
    public func conflicts(for urls: [URL]) -> [String] {
        let existing = Set(listing.map(\.name))
        return urls.map(\.lastPathComponent).filter(existing.contains)
    }

    /// Copies files and folders from this device into the folder shown.
    public func upload(_ urls: [URL]) {
        guard sftp != nil else { return }
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            enqueue(
                Transfer(name: url.lastPathComponent, isUpload: true),
                .upload(local: url, remoteDirectory: path, isDirectory: isDirectory))
        }
    }

    /// Copies files and folders from the computer into a folder here.
    public func download(_ wanted: [SFTPItem], to directory: URL) {
        guard sftp != nil else { return }
        for item in wanted {
            enqueue(
                Transfer(name: item.name, isUpload: false, total: item.isDirectory ? nil : item.size),
                .download(item: item, localDirectory: directory))
        }
    }

    public func cancel(_ id: Transfer.ID) {
        if let waiting = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: waiting)
            update(id) { $0.state = .cancelled }
        } else if transfers.first(where: { $0.id == id })?.state == .running {
            runner?.cancel()
        }
    }

    public func clearFinishedTransfers() {
        transfers.removeAll { !$0.isActive }
    }

    private func enqueue(_ transfer: Transfer, _ work: Work) {
        transfers.append(transfer)
        queue.append((transfer.id, work))
        runNext()
    }

    private func update(_ id: Transfer.ID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func runNext() {
        guard runner == nil, !queue.isEmpty, let sftp, !isClosed else { return }
        let (id, work) = queue.removeFirst()
        update(id) { $0.state = .running }
        runner = Task { [weak self] in
            let progress: SFTPProgressHandler = { [weak self] completed, total in
                Task { @MainActor [weak self] in
                    self?.update(id) {
                        $0.completed = max($0.completed, completed)
                        if let total { $0.total = total }
                    }
                }
            }
            var outcome = Transfer.State.finished
            var skipped = 0
            do {
                skipped = try await Self.perform(work, using: sftp, progress: progress)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            guard let self else { return }
            self.update(id) {
                $0.state = outcome
                $0.skippedCount = skipped
            }
            self.runner = nil
            if case .upload(_, let directory, _) = work, directory == self.path {
                await self.load(self.path)
            }
            self.runNext()
        }
    }

    /// - Returns: How many files and folders were left out because their
    ///   names cannot be used here.
    private static func perform(
        _ work: Work, using sftp: SFTPClient, progress: @escaping SFTPProgressHandler
    ) async throws -> Int {
        switch work {
        case .upload(let local, let remoteDirectory, let isDirectory):
            // A file picked or dropped comes with access that has to be
            // claimed for as long as it is being read.
            let scoped = local.startAccessingSecurityScopedResource()
            defer { if scoped { local.stopAccessingSecurityScopedResource() } }
            let target = join(remoteDirectory, local.lastPathComponent)
            if isDirectory {
                try await sftp.uploadDirectory(localURL: local, to: target, progress: progress)
            } else {
                try await sftp.upload(localURL: local, to: target, progress: progress)
            }
            return 0
        case .download(let item, let localDirectory):
            let scoped = localDirectory.startAccessingSecurityScopedResource()
            defer { if scoped { localDirectory.stopAccessingSecurityScopedResource() } }
            let target = unusedURL(for: item.name, in: localDirectory)
            guard item.isDirectory else {
                try await sftp.download(remotePath: item.path, to: target, progress: progress)
                return 0
            }
            return try await sftp.downloadDirectory(
                remotePath: item.path, to: target, progress: progress).unusableNameCount
        }
    }

    /// Where to put a download so that it replaces nothing: `name`, or
    /// `name 2`, `name 3`… when that is taken. A remote name is not trusted
    /// to be a plain file name.
    static func unusedURL(for name: String, in directory: URL) -> URL {
        // Slashes and NULs are replaced one code point at a time. Searching
        // the text for "/" would step over a slash that has a combining mark
        // after it, and leave it in the name.
        var safe = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where scalar != "\0" {
            safe.append(scalar == "/" ? "_" : scalar)
        }
        // Whatever is left has to lead into the folder and nowhere else.
        let plain = SFTPPath.localURL(for: String(safe), in: directory) == nil ? "Download" : String(safe)
        let base = (plain as NSString).deletingPathExtension
        let ext = (plain as NSString).pathExtension
        var candidate = directory.appending(path: plain)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = directory.appending(path: numbered)
            number += 1
        }
        return candidate
    }
}

import Foundation
import Synchronization
import Testing
@testable import OpenScreensCore

/// The home of the SSH module's test suites. Nesting them here is what lets
/// `swift test --filter SSH` select all of them, whatever each is called.
enum SSHTests {}

/// A scratch directory that is deleted when the last reference goes away.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name)
    }
}

extension URL {
    /// The path with every symbolic link resolved, as `realpath(3)` and an
    /// SFTP server report it. Unlike `resolvingSymlinksInPath()`, this keeps
    /// the `/private` in front of macOS's temporary directory.
    var canonicalPath: String {
        get throws {
            try #require(resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        }
    }
}

extension Data {
    /// `count` bytes that do not repeat at any period a transfer works in, so
    /// that a chunk written to the wrong place cannot go unnoticed. The same
    /// seed always gives the same bytes.
    static func testPattern(count: Int, seed: UInt64 = 0x5EED) -> Data {
        var state = seed
        var data = Data(capacity: count + 8)
        while data.count < count {
            // SplitMix64: small, fast and good enough to fill a buffer.
            state &+= 0x9E37_79B9_7F4A_7C15
            var word = state
            word = (word ^ (word >> 30)) &* 0xBF58_476D_1CE4_E5B9
            word = (word ^ (word >> 27)) &* 0x94D0_49BB_1331_11EB
            word ^= word >> 31
            Swift.withUnsafeBytes(of: word) { data.append(contentsOf: $0) }
        }
        return Data(data.prefix(count))
    }
}

#if os(macOS)

/// A child process, started and reaped with the POSIX calls themselves.
///
/// Foundation's `Process` is avoided on purpose. Its `waitUntilExit()` learns
/// that the child is gone through the run loop of the thread that launched
/// it. Tests run on the cooperative thread pool, where the thread that waits
/// is seldom the thread that launched, and the wait then never returns.
final class ChildProcess: Sendable {
    struct SpawnFailure: Error, CustomStringConvertible {
        var description: String
    }

    let processIdentifier: pid_t
    /// The exit status once the child has been reaped. A process can only be
    /// waited for once, so the answer is kept.
    private let reapedStatus = Mutex<Int32?>(nil)

    /// Starts `executable` with no standard input.
    /// - Parameter output: A file descriptor for the child's standard output
    ///   and standard error; `nil` discards both.
    init(_ executable: String, _ arguments: [String], output: Int32? = nil) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            if let output {
                posix_spawn_file_actions_adddup2(&actions, output, descriptor)
            } else {
                posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_WRONLY, 0)
            }
        }

        // Hand the child the three standard descriptors and nothing else:
        // tests run side by side, and a pipe that leaked into someone else's
        // child would never report end-of-file.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + environment).forEach { free($0) } }
        var identifier: pid_t = 0
        let result = posix_spawn(
            &identifier, executable, &actions, &attributes, argv + [nil], environment + [nil])
        guard result == 0 else {
            throw SpawnFailure(description: "\(executable): \(String(cString: strerror(result)))")
        }
        processIdentifier = identifier
    }

    /// The child's exit status if it has ended, without waiting for it.
    /// A child killed by a signal reports the signal number, negated.
    func exitStatusIfEnded() -> Int32? {
        wait(options: WNOHANG)
    }

    /// Waits for the child to end and returns its exit status.
    @discardableResult
    func waitForExit() -> Int32 {
        wait(options: 0) ?? -1
    }

    /// Asks the child to end, insists if it does not within a few seconds,
    /// and reaps it.
    func stop() {
        guard exitStatusIfEnded() == nil else { return }
        kill(processIdentifier, SIGTERM)
        let deadline = ContinuousClock.now + .seconds(3)
        while exitStatusIfEnded() == nil, ContinuousClock.now < deadline {
            usleep(5_000)
        }
        if exitStatusIfEnded() == nil {
            kill(processIdentifier, SIGKILL)
            waitForExit()
        }
    }

    private func wait(options: Int32) -> Int32? {
        reapedStatus.withLock { reaped in
            if let reaped { return reaped }
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processIdentifier, &status, options)
            } while result == -1 && errno == EINTR
            guard result == processIdentifier else { return nil }
            // The low seven bits name the signal that ended the child, or are
            // zero when it exited by itself with the status in the next byte.
            let signal = status & 0x7F
            reaped = signal == 0 ? (status >> 8) & 0xFF : -signal
            return reaped
        }
    }
}

/// Runs the command-line tools the tests check this module against.
enum CommandLineTool {
    static let sshKeygen = "/usr/bin/ssh-keygen"

    struct Failure: Error, CustomStringConvertible {
        var command: String
        var status: Int32
        var output: String

        var description: String {
            "\(command) exited with status \(status): \(output)"
        }
    }

    /// Runs a tool to completion and returns what it printed.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else {
            throw ChildProcess.SpawnFailure(description: "pipe: \(String(cString: strerror(errno)))")
        }
        let (readEnd, writeEnd) = (pipeEnds[0], pipeEnds[1])
        defer { close(readEnd) }

        let process: ChildProcess
        do {
            process = try ChildProcess(executable, arguments, output: writeEnd)
        } catch {
            close(writeEnd)
            throw error
        }
        // Only the child may hold the writing end, or the reads below would
        // wait for this process to close it.
        close(writeEnd)

        var printed = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(readEnd, &chunk, chunk.count)
            if count > 0 {
                printed.append(contentsOf: chunk[..<count])
            } else if count == 0 || errno != EINTR {
                break
            }
        }

        let status = process.waitForExit()
        let text = String(decoding: printed, as: UTF8.self)
        guard status == 0 else {
            throw Failure(
                command: ([executable] + arguments).joined(separator: " "),
                status: status,
                output: text)
        }
        return text
    }

    /// Makes a key pair at `url` (and `url` + `.pub`) with `ssh-keygen`.
    static func generateKey(
        at url: URL,
        type: String,
        bits: Int? = nil,
        passphrase: String = "",
        cipher: String? = nil,
        rounds: Int? = nil,
        comment: String = "test key"
    ) throws {
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", comment, "-f", url.path]
        if let bits { arguments += ["-b", String(bits)] }
        if let cipher { arguments += ["-Z", cipher] }
        if let rounds { arguments += ["-a", String(rounds)] }
        try run(sshKeygen, arguments)
    }

    /// The fingerprint `ssh-keygen -lf` reports for a key file.
    static func fingerprint(ofKeyAt url: URL) throws -> String {
        // "256 SHA256:… comment (ED25519)"
        let fields = try run(sshKeygen, ["-lf", url.path]).split(separator: " ")
        return try String(#require(fields.dropFirst().first))
    }
}

#endif

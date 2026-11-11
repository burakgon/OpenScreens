import Foundation
#if os(macOS)
import Security
#endif
import Testing
@testable import OpenScreensCore

// MARK: - Fixtures

/// What `tailscale status --json` prints, with the field names of the real
/// tool and made-up values. `STATE` and `MAGICDNS` are filled in per test.
private let tailscaleStatusTemplate = #"""
{
  "Version": "1.90.0-t0000000-g0000000",
  "TUN": true,
  "BackendState": "STATE",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
  "Self": {
    "ID": "nSTUDIO11CNTRL",
    "NodeID": 1000000000000001,
    "PublicKey": "nodekey:aaaa",
    "HostName": "Studio",
    "DNSName": "studio.tail-example.ts.net.",
    "OS": "macOS",
    "UserID": 1,
    "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
    "AllowedIPs": ["100.64.0.1/32", "fd7a:115c:a1e0::1/128"],
    "Addrs": ["203.0.113.5:41641"],
    "CurAddr": "",
    "Relay": "fra",
    "PeerRelay": "",
    "RxBytes": 0,
    "TxBytes": 0,
    "Created": "2025-01-02T03:04:05.123456789Z",
    "LastWrite": "0001-01-01T00:00:00Z",
    "LastSeen": "0001-01-01T00:00:00Z",
    "LastHandshake": "0001-01-01T00:00:00Z",
    "Online": true,
    "ExitNode": false,
    "ExitNodeOption": false,
    "Active": false,
    "PeerAPIURL": ["http://100.64.0.1:12345"],
    "TaildropTarget": 0,
    "NoFileSharingReason": "",
    "Capabilities": [],
    "CapMap": {},
    "InNetworkMap": true,
    "InMagicSock": false,
    "InEngine": false,
    "KeyExpiry": "2027-01-02T03:04:05Z"
  },
  "Health": [],
  "MagicDNSSuffix": "tail-example.ts.net",
  "CurrentTailnet": {
    "Name": "example.com",
    "StableID": "T0000CNTRL",
    "MagicDNSSuffix": "tail-example.ts.net",
    "MagicDNSEnabled": MAGICDNS
  },
  "CertDomains": ["studio.tail-example.ts.net"],
  "ExtraRecords": null,
  "Peer": {
    "nodekey:bbbb": {
      "ID": "nMINI000022CNTRL",
      "NodeID": 1000000000000002,
      "PublicKey": "nodekey:bbbb",
      "HostName": "Mini Server",
      "DNSName": "mini-server.tail-example.ts.net.",
      "OS": "macOS",
      "UserID": 1,
      "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.64.0.2"],
      "AllowedIPs": ["100.64.0.2/32", "fd7a:115c:a1e0::2/128"],
      "Addrs": null,
      "CurAddr": "",
      "Relay": "fra",
      "PeerRelay": "",
      "RxBytes": 0,
      "TxBytes": 0,
      "Created": "2025-02-03T04:05:06.123456789Z",
      "LastWrite": "0001-01-01T00:00:00Z",
      "LastSeen": "0001-01-01T00:00:00Z",
      "LastHandshake": "0001-01-01T00:00:00Z",
      "Online": true,
      "ExitNode": false,
      "ExitNodeOption": false,
      "Active": false,
      "PeerAPIURL": null,
      "TaildropTarget": 0,
      "NoFileSharingReason": "",
      "InNetworkMap": true,
      "InMagicSock": true,
      "InEngine": false,
      "KeyExpiry": "2027-02-03T04:05:06Z",
      "Location": {"Country": "Türkiye", "CountryCode": "TR", "City": "Istanbul", "CityCode": "IST"}
    },
    "nodekey:cccc": {
      "ID": "nATLAS0033CNTRL",
      "HostName": "atlas",
      "DNSName": "atlas.tail-example.ts.net.",
      "OS": "linux",
      "TailscaleIPs": ["100.64.0.3", "fd7a:115c:a1e0::3"],
      "LastSeen": "2026-10-01T08:30:00.5Z",
      "Online": false,
      "ExitNode": false,
      "ExitNodeOption": true
    },
    "nodekey:dddd": {
      "ID": "nPHONE0044CNTRL",
      "HostName": "localhost",
      "DNSName": "phone.tail-example.ts.net.",
      "OS": "iOS",
      "TailscaleIPs": ["100.64.0.4", "fd7a:115c:a1e0::4"],
      "LastSeen": "2026-09-01T00:00:00Z",
      "Online": true
    },
    "nodekey:eeee": {
      "ID": "nGUEST0055CNTRL",
      "HostName": "someone-elses-laptop",
      "DNSName": "laptop.tail-other.ts.net.",
      "OS": "windows",
      "TailscaleIPs": ["100.64.0.5"],
      "Online": true,
      "ShareeNode": true
    },
    "nodekey:ffff": {
      "ID": "nEXIT00066CNTRL",
      "HostName": "se-sto-wg-001",
      "DNSName": "se-sto-wg-001.vpn.ts.net.",
      "OS": "linux",
      "TailscaleIPs": ["100.64.0.6"],
      "Online": true,
      "ExitNode": false,
      "ExitNodeOption": true,
      "Location": {"Country": "Sweden", "CountryCode": "SE", "City": "Stockholm", "CityCode": "STO", "Priority": 100}
    },
    "nodekey:fffg": {
      "ID": "nEXIT00067CNTRL",
      "HostName": "us-nyc-wg-301",
      "DNSName": "us-nyc-wg-301.mullvad.ts.net.",
      "OS": "linux",
      "TailscaleIPs": ["100.64.0.8"],
      "Online": true,
      "ExitNode": true,
      "ExitNodeOption": true
    },
    "nodekey:gggg": {
      "HostName": "old-timer",
      "DNSName": "",
      "OS": "linux",
      "TailscaleIPs": ["100.64.0.7"],
      "Online": false
    },
    "nodekey:hhhh": 42
  },
  "User": {
    "1": {"ID": 1, "LoginName": "ada@example.com", "DisplayName": "Ada", "ProfilePicURL": ""}
  },
  "ClientVersion": null
}
"""#

private func tailscaleStatusJSON(state: String = "Running", magicDNS: Bool = true) -> Data {
    Data(tailscaleStatusTemplate
        .replacingOccurrences(of: "STATE", with: state)
        .replacingOccurrences(of: "MAGICDNS", with: magicDNS ? "true" : "false")
        .utf8)
}

private func tailscaleListedDevices(
    state: String = "Running",
    magicDNS: Bool = true
) throws -> [TailscaleDevice] {
    try TailscaleLocalStatus.devices(
        exitCode: 0, output: tailscaleStatusJSON(state: state, magicDNS: magicDNS), errorOutput: Data())
}

// MARK: - Reading the status

@Suite struct TailscaleLocalStatusTests {

    @Test func thisDeviceComesFirstAndIsMarked() throws {
        let devices = try tailscaleListedDevices()
        let studio = try #require(devices.first)
        #expect(studio.id == "nSTUDIO11CNTRL")
        #expect(studio.name == "Studio")
        #expect(studio.dnsName == "studio.tail-example.ts.net")
        #expect(studio.addresses == ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(studio.os == "macOS")
        #expect(studio.isOnline)
        #expect(studio.lastSeen == nil)
        #expect(studio.isSelf)
        #expect(devices.filter(\.isSelf).count == 1)
    }

    @Test func peersAreRead() throws {
        let devices = try tailscaleListedDevices()
        // In the order of the keys they are listed under, after this device.
        #expect(devices.map(\.id) == [
            "nSTUDIO11CNTRL", "nMINI000022CNTRL", "nATLAS0033CNTRL", "nPHONE0044CNTRL",
            "nodekey:gggg",
        ])

        let mini = try #require(devices.first { $0.id == "nMINI000022CNTRL" })
        #expect(mini.name == "Mini Server")
        #expect(mini.dnsName == "mini-server.tail-example.ts.net")
        #expect(mini.addresses == ["100.64.0.2", "fd7a:115c:a1e0::2"])
        #expect(mini.isOnline)
        #expect(mini.lastSeen == nil)
        #expect(!mini.isSelf)
        #expect(mini.kind == .mac)
        #expect(mini.preferredHost == "mini-server.tail-example.ts.net")

        let atlas = try #require(devices.first { $0.id == "nATLAS0033CNTRL" })
        #expect(!atlas.isOnline)
        let lastSeen = try #require(atlas.lastSeen)
        #expect(abs(lastSeen.timeIntervalSince1970 - 1_790_843_400.5) < 0.001)
        #expect(atlas.kind == .linux)
    }

    @Test func aDeviceThatWillNotSayItsNameIsShownByItsDNSLabel() throws {
        let phone = try #require(try tailscaleListedDevices().first { $0.id == "nPHONE0044CNTRL" })
        #expect(phone.name == "phone")
        #expect(!phone.canBeControlled)
    }

    @Test func aDeviceThatIsBackOnlineHasNoLastSeen() throws {
        // The tool keeps reporting when the phone was last seen before it
        // reconnected; for a device that is online that means nothing.
        let phone = try #require(try tailscaleListedDevices().first { $0.id == "nPHONE0044CNTRL" })
        #expect(phone.isOnline)
        #expect(phone.lastSeen == nil)
    }

    @Test func peersTheToolLeavesOutOfItsOwnListingAreLeftOut() throws {
        let devices = try tailscaleListedDevices()
        // Someone else's device that can only connect in.
        #expect(!devices.contains { $0.id == "nGUEST0055CNTRL" })
        // The VPN add-on's exit nodes: one marked by its location, one known
        // by its name — and that one even though it is the exit node in use.
        #expect(!devices.contains { $0.id == "nEXIT00066CNTRL" })
        #expect(!devices.contains { $0.id == "nEXIT00067CNTRL" })
        // An exit node the user runs themselves is one of their computers,
        // and so is a device of theirs that merely has a location.
        #expect(devices.contains { $0.id == "nATLAS0033CNTRL" })
        #expect(devices.contains { $0.id == "nMINI000022CNTRL" })
    }

    @Test func aPeerWithoutAStableIDIsKnownByItsKey() throws {
        let oldTimer = try #require(try tailscaleListedDevices().first { $0.name == "old-timer" })
        #expect(oldTimer.id == "nodekey:gggg")
        #expect(oldTimer.dnsName == "")
        #expect(oldTimer.preferredHost == "100.64.0.7")
    }

    @Test func withMagicDNSOffTheNamesAreLeftOut() throws {
        let devices = try tailscaleListedDevices(magicDNS: false)
        #expect(devices.allSatisfy { $0.dnsName.isEmpty })
        let mini = try #require(devices.first { $0.id == "nMINI000022CNTRL" })
        #expect(mini.preferredHost == "100.64.0.2")
        // The name to show does not depend on DNS.
        let phone = try #require(devices.first { $0.id == "nPHONE0044CNTRL" })
        #expect(phone.name == "phone")
    }

    @Test func aStatusWithoutTailnetDetailsKeepsTheNames() throws {
        let status = #"""
        {"BackendState": "Running",
         "Self": {"ID": "nSTUDIO11CNTRL", "HostName": "Studio", "DNSName": "studio.tail-example.ts.net.",
                  "OS": "macOS", "TailscaleIPs": ["100.64.0.1"], "Online": true}}
        """#
        let devices = try TailscaleLocalStatus.devices(
            exitCode: 0, output: Data(status.utf8), errorOutput: Data())
        #expect(devices.map(\.dnsName) == ["studio.tail-example.ts.net"])
    }

    // MARK: States

    @Test(arguments: [
        ("NeedsLogin", TailscaleError.loggedOut),
        ("NeedsMachineAuth", .awaitingApproval),
        ("Stopped", .notRunning),
        ("NoState", .notRunning),
        ("InUseOtherUser", .commandFailed("Tailscale is being used by another user on this Mac.")),
    ])
    func statesThatHaveNothingToListAreErrors(state: String, expected: TailscaleError) {
        #expect(throws: expected) {
            try tailscaleListedDevices(state: state)
        }
    }

    @Test(arguments: ["Running", "Starting", "SomethingNew"])
    func otherStatesListWhatIsThere(state: String) throws {
        #expect(try tailscaleListedDevices(state: state).count == 5)
    }

    @Test func theStatusIsBelievedBeforeTheExitCode() {
        #expect(throws: TailscaleError.notRunning) {
            try TailscaleLocalStatus.devices(
                exitCode: 1, output: tailscaleStatusJSON(state: "Stopped"), errorOutput: Data("warning".utf8))
        }
    }

    @Test func anEmptyStatusIsAnEmptyList() throws {
        let devices = try TailscaleLocalStatus.devices(
            exitCode: 0, output: Data(#"{"BackendState": "Running"}"#.utf8), errorOutput: Data())
        #expect(devices.isEmpty)
    }

    // MARK: Complaints in words

    @Test(arguments: [
        "failed to connect to local Tailscale service; is Tailscale running?",
        "failed to connect to local tailscaled; it doesn't appear to be running (sudo systemctl start tailscaled ?)",
        "failed to connect to local tailscaled (no tailscaled process found): dial unix: no such file",
        "Tailscale is stopped.",
        "The Tailscale service is not running.",
    ])
    func complaintsAboutNotRunningAreRecognised(message: String) {
        #expect(throws: TailscaleError.notRunning) {
            try TailscaleLocalStatus.devices(
                exitCode: 1, output: Data(), errorOutput: Data(message.utf8))
        }
    }

    @Test(arguments: ["Logged out.", "error: not logged in", "unexpected state: NeedsLogin"])
    func complaintsAboutBeingLoggedOutAreRecognised(message: String) {
        #expect(throws: TailscaleError.loggedOut) {
            try TailscaleLocalStatus.devices(
                exitCode: 1, output: Data(), errorOutput: Data(message.utf8))
        }
    }

    @Test func aServiceThatIsRunningButWillNotAnswerIsNotCalledStopped() {
        let complaint = "failed to connect to local tailscaled (which appears to be running as "
            + "tailscaled, pid 123). Got error: permission denied"
        #expect(throws: TailscaleError.commandFailed(complaint)) {
            try TailscaleLocalStatus.devices(
                exitCode: 1, output: Data(), errorOutput: Data(complaint.utf8))
        }
    }

    @Test func otherComplaintsAreQuotedByTheirFirstLine() {
        #expect(throws: TailscaleError.commandFailed("something unexpected happened")) {
            try TailscaleLocalStatus.devices(
                exitCode: 2,
                output: Data(),
                errorOutput: Data("\n  something unexpected happened  \nmore detail\n".utf8))
        }
        // With nothing on the error stream, what was printed is the complaint.
        #expect(throws: TailscaleError.commandFailed("not json at all")) {
            try TailscaleLocalStatus.devices(
                exitCode: 0, output: Data("not json at all".utf8), errorOutput: Data())
        }
    }

    @Test func silenceIsReportedByExitCode() {
        #expect(throws: TailscaleError.commandFailed("The command exited with code 3.")) {
            try TailscaleLocalStatus.devices(exitCode: 3, output: Data(), errorOutput: Data())
        }
        #expect(throws: TailscaleError.commandFailed("The status it printed could not be read.")) {
            try TailscaleLocalStatus.devices(exitCode: 0, output: Data(), errorOutput: Data())
        }
    }

    @Test func longComplaintsAreCutShort() {
        let failure = TailscaleLocalStatus.failure(
            exitCode: 1, message: String(repeating: "x", count: 5000))
        #expect(failure == .commandFailed(String(repeating: "x", count: 200)))
    }

    /// What the tool printed is shown to the user as it is. Whatever stood
    /// in for the tool may have printed anything.
    @Test func charactersThatAreNotTextAreLeftOutOfAComplaint() {
        let escape = "\u{1B}", bell = "\u{7}", null = "\u{0}"
        let complaint = "\(escape)[31mfatal\(bell): tail\(null)scaled\tis b\u{8}roken\(escape)[0m\r\nsecond line"
        #expect(throws: TailscaleError.commandFailed("[31mfatal: tailscaled is broken[0m")) {
            try TailscaleLocalStatus.devices(exitCode: 1, output: Data(), errorOutput: Data(complaint.utf8))
        }
        // Nothing but such characters is nothing said at all.
        #expect(throws: TailscaleError.commandFailed("The status it printed could not be read.")) {
            try TailscaleLocalStatus.devices(exitCode: 0, output: Data(count: 5000), errorOutput: Data())
        }
        #expect(throws: TailscaleError.commandFailed("The command exited with code 9.")) {
            try TailscaleLocalStatus.devices(
                exitCode: 9, output: Data(), errorOutput: Data("\(escape)\(bell)\n\(null)\(null)\n".utf8))
        }
    }

    /// An explanation is a line or two. However much was printed, only its
    /// beginning is read as one.
    @Test func onlyTheBeginningOfWhatWasPrintedIsReadAsAnExplanation() {
        let limit = TailscaleLocalStatus.explanationLimit
        #expect(limit >= 1024 && limit <= 65536)

        // Megabytes of something that is not a status.
        var flood = Data(repeating: UInt8(ascii: "x"), count: 8 * 1024 * 1024)
        #expect(throws: TailscaleError.commandFailed(String(repeating: "x", count: 200))) {
            try TailscaleLocalStatus.devices(exitCode: 0, output: flood, errorOutput: Data())
        }

        // What decides is at the beginning. A phrase far into the output is
        // not what the tool led with.
        flood.append(Data("\nfailed to connect to local Tailscale service; is Tailscale running?\n".utf8))
        #expect(throws: TailscaleError.commandFailed(String(repeating: "x", count: 200))) {
            try TailscaleLocalStatus.devices(exitCode: 1, output: Data(), errorOutput: flood)
        }
        let early = Data("is Tailscale running?\n".utf8) + flood
        #expect(throws: TailscaleError.notRunning) {
            try TailscaleLocalStatus.devices(exitCode: 1, output: Data(), errorOutput: early)
        }

        // Cut where it may, the text is still text.
        let multibyte = Data(String(repeating: "é", count: limit).utf8)
        #expect(throws: TailscaleError.commandFailed(String(repeating: "é", count: 200))) {
            try TailscaleLocalStatus.devices(exitCode: 1, output: Data(), errorOutput: multibyte)
        }
    }
}

#if os(macOS)

// MARK: - Running the tool

/// Makes a stand-in for the Tailscale command-line tool: a script that
/// checks it was asked for `status --json` and then prints a canned answer.
/// It lives in its own temporary directory, removed when the value goes away.
///
/// The source under test starts the script by its path like any other tool —
/// that the stand-in happens to be written as a shell script is a
/// convenience of the test, not something the source knows or relies on.
private final class FakeTailscale {
    let directory: URL
    let executable: URL

    /// - Parameter preamble: Shell commands to run before anything else.
    init(output: Data, errorOutput: String = "", exitCode: Int = 0, preamble: String = "") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputFile = directory.appending(path: "stdout.txt")
        let errorFile = directory.appending(path: "stderr.txt")
        try output.write(to: outputFile)
        try Data(errorOutput.utf8).write(to: errorFile)

        executable = directory.appending(path: "tailscale")
        let script = """
            #!/bin/sh
            \(preamble)
            if [ "$#" -ne 2 ] || [ "$1" != "status" ] || [ "$2" != "--json" ]; then
              echo "unexpected arguments: $*" >&2
              exit 64
            fi
            /bin/cat '\(outputFile.path)'
            /bin/cat '\(errorFile.path)' >&2
            exit \(exitCode)
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct TailscaleLocalSourceTests {

    /// A source that takes the stand-in for the genuine tool. What the
    /// genuine tool is has tests of its own, further down.
    private func source(
        running executable: URL?,
        lookingIn searchPaths: [String] = [],
        timeout: Duration = .seconds(10)
    ) -> TailscaleLocalSource {
        TailscaleLocalSource(
            executable: executable, searchPaths: searchPaths, timeout: timeout,
            isGenuine: { _ in true })
    }

    @Test func devicesAreListedByRunningTheTool() async throws {
        let tool = try FakeTailscale(output: tailscaleStatusJSON())
        let devices = try await source(running: tool.executable).devices()
        #expect(devices.map(\.name) == ["Studio", "Mini Server", "atlas", "phone", "old-timer"])
        #expect(devices.filter(\.isSelf).map(\.id) == ["nSTUDIO11CNTRL"])
    }

    @Test func aStoppedTailscaleIsATypedError() async throws {
        let tool = try FakeTailscale(output: tailscaleStatusJSON(state: "Stopped"))
        await #expect(throws: TailscaleError.notRunning) {
            try await source(running: tool.executable).devices()
        }
    }

    @Test func aSignedOutTailscaleIsATypedError() async throws {
        let tool = try FakeTailscale(output: tailscaleStatusJSON(state: "NeedsLogin"))
        await #expect(throws: TailscaleError.loggedOut) {
            try await source(running: tool.executable).devices()
        }
    }

    @Test func aToolThatCannotReachItsServiceIsATypedError() async throws {
        let tool = try FakeTailscale(
            output: Data(),
            errorOutput: "failed to connect to local Tailscale service; is Tailscale running?\n",
            exitCode: 1)
        await #expect(throws: TailscaleError.notRunning) {
            try await source(running: tool.executable).devices()
        }
    }

    @Test func aMissingToolMeansNotInstalled() async {
        let source = source(
            running: nil, lookingIn: ["/nonexistent/OpenScreensTests/tailscale"], timeout: .seconds(5))
        await #expect(throws: TailscaleError.notInstalled) {
            try await source.devices()
        }
    }

    @Test func theToolIsFoundAmongTheSearchPaths() async throws {
        let tool = try FakeTailscale(output: tailscaleStatusJSON())
        let source = source(
            running: nil, lookingIn: ["/nonexistent/OpenScreensTests/tailscale", tool.executable.path])
        #expect(try await source.devices().count == 5)
    }

    @Test func aToolThatHangsIsStoppedAndReported() async throws {
        let tool = try FakeHangingTailscale()
        let source = source(running: tool.executable, timeout: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: TailscaleError.timedOut) {
            try await source.devices()
        }
        #expect(clock.now - started < .seconds(5))
    }

    @Test func locatingPicksTheFirstExecutableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appending(path: "missing").path
        let plainFile = directory.appending(path: "plain")
        try Data("not a program".utf8).write(to: plainFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plainFile.path)
        let folder = directory.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = directory.appending(path: "tool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let second = directory.appending(path: "second")
        try Data("#!/bin/sh\n".utf8).write(to: second)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path)

        let found = TailscaleLocalSource.locateCommandLineTool(
            among: [missing, plainFile.path, folder.path, tool.path, second.path],
            isGenuine: { _ in true })
        #expect(found?.path == tool.path)
        #expect(
            TailscaleLocalSource.locateCommandLineTool(
                among: [missing, plainFile.path, folder.path], isGenuine: { _ in true }) == nil)
        #expect(TailscaleLocalSource.locateCommandLineTool(among: [], isGenuine: { _ in true }) == nil)

        // A file that is not the genuine tool is passed over for the next.
        let onlySecond = TailscaleLocalSource.locateCommandLineTool(
            among: [tool.path, second.path], isGenuine: { $0.lastPathComponent == "second" })
        #expect(onlySecond?.path == second.path)
        #expect(
            TailscaleLocalSource.locateCommandLineTool(
                among: [tool.path, second.path], isGenuine: { _ in false }) == nil)

        // A link is followed, and what it leads to is what is checked and run.
        let link = directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        var checked: [String] = []
        let throughLink = TailscaleLocalSource.locateCommandLineTool(among: [link.path]) {
            checked.append($0.lastPathComponent)
            return true
        }
        #expect(throughLink?.lastPathComponent == "second")
        #expect(checked == ["second"])
    }

    /// The Tailscale app's executable is the app and the command-line tool
    /// in one, and takes itself for the app unless it is told otherwise or
    /// finds itself in a terminal. This app is started from the Dock, where
    /// there is no terminal to find.
    @Test func theToolIsToldToBeACommandLineToolAndGetsNothingOfThisProcesssEnvironment() async throws {
        setenv("OPENSCREENS_TEST_ONLY_IN_THE_APP", "must not travel", 1)
        defer { unsetenv("OPENSCREENS_TEST_ONLY_IN_THE_APP") }

        let tool = try FakeTailscale(
            output: tailscaleStatusJSON(),
            preamble: """
                if [ "$TAILSCALE_BE_CLI" != "1" ]; then
                  echo "The Tailscale GUI failed to start: The operation couldn’t be completed."
                  exit 0
                fi
                if [ -n "$OPENSCREENS_TEST_ONLY_IN_THE_APP" ]; then
                  echo "was handed the environment of the app" >&2
                  exit 70
                fi
                """)
        #expect(try await source(running: tool.executable).devices().count == 5)
    }

    @Test func aToolThatPrintsWithoutEndIsStoppedAndReported() async throws {
        // Gigabytes, if it were let.
        let tool = try FakeTailscale(
            output: Data(),
            preamble: "exec /bin/dd if=/dev/zero bs=1048576 count=8192 2>/dev/null")
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: TailscaleError.commandFailed("The status it printed was too large to read.")) {
            try await source(running: tool.executable, timeout: .seconds(120)).devices()
        }
        #expect(clock.now - started < .seconds(30))
    }

    @Test func theToolIsLookedForWhereTailscaleInstallsIt() {
        #expect(TailscaleLocalSource.commandLineToolPaths == [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ])
    }
}

/// A tool that prints nothing and waits far longer than any test.
private final class FakeHangingTailscale {
    let directory: URL
    let executable: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appending(path: "tailscale")
        try Data("#!/bin/sh\nexec /bin/sleep 600\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct TailscaleCodeSignatureTests {
    private static let installedTool = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A program put where the tool is looked for by whoever could write
    /// there. If it were ever run it would leave a mark.
    @Test func aToolThatIsNotTailscalesOwnIsNeverRun() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mark = directory.appending(path: "was-run")
        let planted = directory.appending(path: "tailscale")
        try Data("#!/bin/sh\n/usr/bin/touch '\(mark.path)'\necho '{}'\n".utf8).write(to: planted)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)

        // Named outright, and found where the tool is looked for.
        await #expect(throws: TailscaleError.notInstalled) {
            try await TailscaleLocalSource(executable: planted).devices()
        }
        let found = TailscaleLocalSource(
            executable: nil, searchPaths: [planted.path], timeout: .seconds(10),
            isGenuine: TailscaleCodeSignature.isTailscale)
        await #expect(throws: TailscaleError.notInstalled) {
            try await found.devices()
        }
        #expect(TailscaleLocalSource.locateCommandLineTool(among: [planted.path]) == nil)

        #expect(!FileManager.default.fileExists(atPath: mark.path))
    }

    @Test func onlyTailscalesSignatureMakesAToolGenuine() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "script")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // Not signed at all; signed by Apple, as something else; not there;
        // not a file.
        #expect(!TailscaleCodeSignature.isTailscale(script))
        #expect(!TailscaleCodeSignature.isTailscale(URL(fileURLWithPath: "/bin/ls")))
        #expect(!TailscaleCodeSignature.isTailscale(directory.appending(path: "missing")))
        #expect(!TailscaleCodeSignature.isTailscale(directory))

        // A program that merely calls itself Tailscale: anyone can sign
        // their own under any identifier they like.
        let impostor = directory.appending(path: "tailscale")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: impostor)
        let signing = try await TailscaleCommandLine.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--identifier", "io.tailscale.ipn.macos", impostor.path],
            timeout: .seconds(60))
        try #require(signing.exitCode == 0)
        #expect(!TailscaleCodeSignature.isTailscale(impostor))
    }

    @Test func theRequirementIsOneTheSystemUnderstandsAndNamesTailscale() {
        var requirement: SecRequirement?
        #expect(
            SecRequirementCreateWithString(
                TailscaleCodeSignature.requirement as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
        #expect(TailscaleCodeSignature.teamIdentifier == "W5364U7YZB")
        #expect(TailscaleCodeSignature.requirement.contains(#"subject.OU] = "W5364U7YZB""#))
        #expect(TailscaleCodeSignature.requirement.contains(#"identifier "io.tailscale.ipn.macos""#))
        #expect(TailscaleCodeSignature.identifiers.allSatisfy { $0.hasPrefix("io.tailscale.ipn.") })
    }

    /// Only where the Tailscale app is installed. Nothing is run: its
    /// signature is read.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: installedTool)))
    func theTailscaleAppOnThisMacIsRecognised() {
        #expect(TailscaleCodeSignature.isTailscale(URL(fileURLWithPath: Self.installedTool)))
        #expect(TailscaleLocalSource.locateCommandLineTool()?.path == Self.installedTool)
        #expect(TailscaleLocalSource.isInstalled)
    }
}

@Suite struct TailscaleCommandLineTests {

    @Test func aToolGetsAnEnvironmentOfItsOwn() async throws {
        setenv("OPENSCREENS_TEST_NOT_FOR_ANY_TOOL", "must not travel", 1)
        defer { unsetenv("OPENSCREENS_TEST_NOT_FOR_ANY_TOOL") }
        let printEnvironment = URL(fileURLWithPath: "/usr/bin/env")
        func variables(_ output: TailscaleCommandLine.Output) -> [String: String] {
            var variables: [String: String] = [:]
            for line in String(decoding: output.standardOutput, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                variables[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
            }
            return variables
        }

        // Unless told otherwise: where the system's programs are, and home.
        let plain = variables(try await TailscaleCommandLine.run(printEnvironment, timeout: .seconds(10)))
        #expect(plain == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()])

        // The Tailscale tool gets one thing more.
        let tailscale = variables(try await TailscaleCommandLine.run(
            printEnvironment, environment: TailscaleLocalSource.toolEnvironment, timeout: .seconds(10)))
        #expect(tailscale == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TAILSCALE_BE_CLI": "1",
        ])

        // And exactly what it is given otherwise.
        let chosen = variables(try await TailscaleCommandLine.run(
            printEnvironment, environment: ["ONLY": "this"], timeout: .seconds(10)))
        #expect(chosen == ["ONLY": "this"])
    }

    @Test func outputIsCollectedUpToALimitAndTheToolStoppedBeyondIt() async throws {
        let megabyte = 1 << 20
        let printZeros = URL(fileURLWithPath: "/usr/bin/head")

        // Exactly what is allowed is collected whole.
        let allowed = try await TailscaleCommandLine.run(
            printZeros, arguments: ["-c", "\(megabyte)", "/dev/zero"],
            outputLimit: megabyte, timeout: .seconds(30))
        #expect(allowed.standardOutput.count == megabyte)
        #expect(allowed.exitCode == 0)

        // One byte more is too much.
        await #expect(throws: TailscaleCommandLine.Failure.tooMuchOutput) {
            try await TailscaleCommandLine.run(
                printZeros, arguments: ["-c", "\(megabyte + 1)", "/dev/zero"],
                outputLimit: megabyte, timeout: .seconds(30))
        }

        // A tool that never stops printing is stopped, long before its time
        // is up — and it counts whichever of the two streams it prints to.
        let clock = ContinuousClock()
        let started = clock.now
        for redirection in ["", " >&2"] {
            await #expect(throws: TailscaleCommandLine.Failure.tooMuchOutput) {
                try await TailscaleCommandLine.run(
                    URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "exec /bin/cat /dev/zero\(redirection)"],
                    outputLimit: megabyte, timeout: .seconds(120))
            }
        }
        #expect(clock.now - started < .seconds(30))
        #expect(TailscaleCommandLine.outputLimit >= 4 * megabyte)
        #expect(TailscaleCommandLine.outputLimit <= 64 * megabyte)
    }

    @Test func outputAndExitCodeAreCollected() async throws {
        let result = try await TailscaleCommandLine.run(
            URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "world"], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello world\n")
        #expect(result.standardError.isEmpty)
    }

    @Test func argumentsAreNeverInterpreted() async throws {
        // A shell would expand, substitute or split these. They must arrive untouched.
        let arguments = ["$HOME", "`id`", "a b", "*", ";", "$(id)", "|", ">"]
        let result = try await TailscaleCommandLine.run(
            URL(fileURLWithPath: "/bin/echo"), arguments: arguments, timeout: .seconds(10))
        #expect(
            String(decoding: result.standardOutput, as: UTF8.self)
                == arguments.joined(separator: " ") + "\n")
    }

    @Test func aFailingToolReportsItsExitCodeAndComplaint() async throws {
        let result = try await TailscaleCommandLine.run(
            URL(fileURLWithPath: "/bin/ls"),
            arguments: ["/nonexistent/OpenScreensTests"],
            timeout: .seconds(10))
        #expect(result.exitCode != 0)
        #expect(result.standardOutput.isEmpty)
        #expect(String(decoding: result.standardError, as: UTF8.self).contains("No such file"))
    }

    @Test func outputLargerThanAPipeHoldsIsCollectedWhole() async throws {
        // 2 MiB on standard output, with `dd` reporting on standard error.
        let result = try await TailscaleCommandLine.run(
            URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=65536", "count=32"],
            timeout: .seconds(30))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.count == 32 * 65536)
        #expect(result.standardOutput.allSatisfy { $0 == 0 })
        #expect(!result.standardError.isEmpty)
    }

    @Test func aToolThatOverrunsItsTimeIsStopped() async {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: TailscaleCommandLine.Failure.timedOut) {
            try await TailscaleCommandLine.run(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["600"], timeout: .milliseconds(300))
        }
        // Long before the tool would have finished by itself. How long
        // stopping it takes is the machine's business: a busy one has taken
        // seven seconds over it.
        #expect(clock.now - started < .seconds(60))
    }

    @Test func cancellingTheTaskStopsTheTool() async {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await TailscaleCommandLine.run(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["600"], timeout: .seconds(120))
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) {
            try result.get()
        }
        // Long before either the tool or its time limit would have ended it.
        #expect(clock.now - started < .seconds(60))
    }

    @Test func aTaskCancelledBeforehandNeverStartsTheTool() async {
        let task = Task {
            // Wait to be cancelled before running anything.
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await TailscaleCommandLine.run(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["600"], timeout: .seconds(120))
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) {
            try result.get()
        }
    }

    @Test func aToolThatCannotBeStartedIsReported() async {
        do {
            _ = try await TailscaleCommandLine.run(
                URL(fileURLWithPath: "/nonexistent/OpenScreensTests/tool"), timeout: .seconds(5))
            Issue.record("running a missing tool should fail")
        } catch TailscaleCommandLine.Failure.couldNotStart(let reason) {
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func manyToolsCanRunAtOnce() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let result = try await TailscaleCommandLine.run(
                        URL(fileURLWithPath: "/bin/echo"),
                        arguments: ["run-\(index)"],
                        timeout: .seconds(30))
                    return String(decoding: result.standardOutput, as: UTF8.self)
                }
            }
            var outputs = Set<String>()
            for try await output in group {
                outputs.insert(output)
            }
            #expect(outputs == Set((0..<24).map { "run-\($0)\n" }))
        }
    }
}

#endif

import Foundation

// MARK: - Reading `tailscale status --json`

/// What the Tailscale command-line tool prints for `status --json`, as far
/// as OpenScreens reads it. The field names are the tool's own.
///
/// Reading the output is kept apart from running the tool, so it can be
/// tested anywhere with made-up input.
struct TailscaleLocalStatus: Decodable {
    /// `Running`, `Stopped`, `NeedsLogin`, `NeedsMachineAuth`, `Starting`,
    /// `NoState` or `InUseOtherUser`.
    var backendState: String?
    /// The device the tool runs on.
    var thisDevice: Node?
    /// Every other device, keyed by its public key.
    var peers: [String: TailscaleDevice.Lenient<Node>]?
    var currentTailnet: Tailnet?

    private enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case thisDevice = "Self"
        case peers = "Peer"
        case currentTailnet = "CurrentTailnet"
    }

    struct Node: Decodable {
        /// The stable node ID.
        var id: String?
        var hostName: String?
        /// MagicDNS name, with a trailing dot.
        var dnsName: String?
        var os: String?
        var tailscaleIPs: [String]?
        var online: Bool?
        /// Go's zero time while the device is online.
        var lastSeen: String?
        /// The device belongs to someone this tailnet has shared a device
        /// with; it is known only so that it can connect in.
        var shareeNode: Bool?
        /// Whether the device offers itself as an exit node.
        var exitNodeOption: Bool?
        /// Where the device is. Tailscale fills this in for the exit nodes it
        /// offers by location: the servers of the Mullvad VPN add-on.
        var location: Location?

        struct Location: Decodable {}

        private enum CodingKeys: String, CodingKey {
            case id = "ID"
            case hostName = "HostName"
            case dnsName = "DNSName"
            case os = "OS"
            case tailscaleIPs = "TailscaleIPs"
            case online = "Online"
            case lastSeen = "LastSeen"
            case shareeNode = "ShareeNode"
            case exitNodeOption = "ExitNodeOption"
            case location = "Location"
        }

        /// The domain every Mullvad exit node's name ends in.
        static let mullvadDomain = ".mullvad.ts.net"

        /// Peers that are not computers of the user's to connect to. These
        /// are the ones `tailscale status` leaves out of its own listing:
        /// other people's devices that can only connect in, and the VPN
        /// servers of the Mullvad add-on, of which there are hundreds.
        var isLeftOutOfListings: Bool {
            if shareeNode == true {
                return true
            }
            // Recognised the way the tool does it today (by name) and the
            // way it used to (an exit node that comes with a location).
            let name = TailscaleDevice.trimmedDNSName(dnsName).lowercased()
            return name.hasSuffix(Self.mullvadDomain)
                || (location != nil && exitNodeOption == true)
        }
    }

    struct Tailnet: Decodable {
        var magicDNSEnabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case magicDNSEnabled = "MagicDNSEnabled"
        }
    }

    /// Makes sense of one run of `tailscale status --json`: the devices it
    /// listed, or the reason there are none to list.
    static func devices(
        exitCode: Int32,
        output: Data,
        errorOutput: Data
    ) throws -> [TailscaleDevice] {
        // A stopped or signed-out Tailscale still prints its status, so the
        // status is believed before the exit code is.
        if let status = try? JSONDecoder().decode(TailscaleLocalStatus.self, from: output) {
            return try status.devices()
        }
        // No status: the tool explained itself in words instead.
        let errorText = String(decoding: errorOutput, as: UTF8.self)
        let outputText = String(decoding: output, as: UTF8.self)
        let said = errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? outputText : errorText
        throw failure(exitCode: exitCode, message: said)
    }

    /// The devices in the status, this device included and marked as such.
    func devices() throws -> [TailscaleDevice] {
        switch backendState {
        case "NeedsLogin":
            throw TailscaleError.loggedOut
        case "NeedsMachineAuth":
            throw TailscaleError.awaitingApproval
        case "Stopped", "NoState":
            throw TailscaleError.notRunning
        case "InUseOtherUser":
            throw TailscaleError.commandFailed(
                "Tailscale is being used by another user on this Mac.")
        default:
            // "Running", "Starting" (its peers are already known), and any
            // state a newer Tailscale may add: list what is there.
            break
        }

        // The names exist either way, but they only resolve when MagicDNS is
        // on. Without it the addresses are what there is to connect to.
        let magicDNSIsOn = currentTailnet?.magicDNSEnabled ?? true

        var devices: [TailscaleDevice] = []
        if let thisDevice,
           let device = Self.device(
            thisDevice, key: nil, isSelf: true, magicDNSIsOn: magicDNSIsOn) {
            devices.append(device)
        }
        // Sorted so the result does not depend on dictionary order.
        for (key, entry) in (peers ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let node = entry.value, !node.isLeftOutOfListings,
                  let device = Self.device(
                    node, key: key, isSelf: false, magicDNSIsOn: magicDNSIsOn) else { continue }
            devices.append(device)
        }
        return devices
    }

    private static func device(
        _ node: Node,
        key: String?,
        isSelf: Bool,
        magicDNSIsOn: Bool
    ) -> TailscaleDevice? {
        // Very old clients did not report the stable ID; the public key the
        // peer is listed under is the next most lasting thing.
        guard let id = [node.id, key]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }

        let dnsName = TailscaleDevice.trimmedDNSName(node.dnsName)
        let addresses = TailscaleDevice.orderedAddresses(node.tailscaleIPs)
        let isOnline = node.online ?? false
        return TailscaleDevice(
            id: id,
            name: TailscaleDevice.displayName(
                hostName: node.hostName, dnsName: dnsName, addresses: addresses),
            dnsName: magicDNSIsOn ? dnsName : "",
            addresses: addresses,
            os: node.os ?? "",
            isOnline: isOnline,
            // A device that has come back online can still carry the time it
            // was last seen before that, which no longer means anything.
            lastSeen: isOnline ? nil : TailscaleDevice.timestamp(node.lastSeen),
            isSelf: isSelf)
    }

    /// Reads the plain-text complaint the tool prints when it cannot produce
    /// a status at all.
    static func failure(exitCode: Int32, message: String) -> TailscaleError {
        let lowered = message.lowercased()
        let saysLoggedOut = ["logged out", "not logged in", "needslogin"]
        if saysLoggedOut.contains(where: lowered.contains) {
            return .loggedOut
        }
        // "failed to connect to local Tailscale service; is Tailscale
        // running?" and its variations across platforms and versions. One
        // variation says the opposite — the service was found running but
        // would not answer — and is passed on in the tool's own words.
        let saysNotRunning = [
            "is tailscale running", "doesn't appear to be running", "not running",
            "failed to connect to local tailscale", "tailscale is stopped",
        ]
        let foundItRunning = lowered.contains("appears to be running as")
        if !foundItRunning, saysNotRunning.contains(where: lowered.contains) {
            return .notRunning
        }

        let firstLine = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let firstLine {
            return .commandFailed(String(firstLine.prefix(200)))
        }
        return .commandFailed(
            exitCode == 0
                ? "The status it printed could not be read."
                : "The command exited with code \(exitCode).")
    }
}

#if os(macOS)

// MARK: - Asking the Tailscale client on this Mac

/// Lists the tailnet by asking the Tailscale client installed on this Mac.
///
/// Nothing needs setting up: if Tailscale is installed and connected, its
/// command-line tool already knows every device. The tool is run as
/// `tailscale status --json`, which only reads.
public struct TailscaleLocalSource: TailscaleSource {
    /// Where the command-line tool is looked for, in order: inside the
    /// Tailscale app, then the two places a standalone install puts it.
    public static let commandLineToolPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    private let executable: URL?
    private let searchPaths: [String]
    private let timeout: Duration

    /// - Parameters:
    ///   - executable: The tool to run; `nil` to look for it in
    ///     ``commandLineToolPaths`` each time.
    ///   - timeout: How long the tool may take before it is stopped.
    public init(executable: URL? = nil, timeout: Duration = .seconds(10)) {
        self.init(
            executable: executable, searchPaths: Self.commandLineToolPaths, timeout: timeout)
    }

    init(executable: URL?, searchPaths: [String], timeout: Duration) {
        self.executable = executable
        self.searchPaths = searchPaths
        self.timeout = timeout
    }

    /// The first of `paths` that is a file this process may execute.
    public static func locateCommandLineTool(
        among paths: [String] = commandLineToolPaths
    ) -> URL? {
        let fileManager = FileManager.default
        let path = paths.first { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && fileManager.isExecutableFile(atPath: path)
        }
        return path.map { URL(fileURLWithPath: $0) }
    }

    /// Whether a Tailscale command-line tool is present on this Mac.
    public static var isInstalled: Bool {
        locateCommandLineTool() != nil
    }

    // Looking for the tool and reading what it printed are kept off whichever
    // actor asked, the main actor above all.
    @concurrent
    public func devices() async throws -> [TailscaleDevice] {
        guard let executable = executable ?? Self.locateCommandLineTool(among: searchPaths) else {
            throw TailscaleError.notInstalled
        }
        let result: TailscaleCommandLine.Output
        do {
            result = try await TailscaleCommandLine.run(
                executable, arguments: ["status", "--json"], timeout: timeout)
        } catch TailscaleCommandLine.Failure.timedOut {
            throw TailscaleError.timedOut
        } catch TailscaleCommandLine.Failure.couldNotStart(let reason) {
            throw TailscaleError.commandFailed(reason)
        }
        return try TailscaleLocalStatus.devices(
            exitCode: result.exitCode,
            output: result.standardOutput,
            errorOutput: result.standardError)
    }
}

#endif

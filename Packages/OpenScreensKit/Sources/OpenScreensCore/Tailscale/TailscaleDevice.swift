import Foundation

/// A device in the user's tailnet, as listed by a ``TailscaleSource``.
public struct TailscaleDevice: Identifiable, Hashable, Sendable, Codable {
    /// Tailscale's stable node ID. The same device has the same ID whichever
    /// source lists it, which makes it the value to keep in
    /// ``ComputerOrigin/tailscale(nodeID:)``.
    public var id: String
    /// Short host name to show to the user.
    public var name: String
    /// MagicDNS name without a trailing dot, such as
    /// `studio.example-tailnet.ts.net`. Empty when the device has none, or
    /// when MagicDNS is known to be turned off for the tailnet.
    public var dnsName: String
    /// The device's Tailscale addresses, IPv4 first.
    public var addresses: [String]
    /// Operating system as Tailscale reports it: `macOS`, `iOS`, `linux`,
    /// `windows`, `android`, `tvOS`…
    public var os: String
    public var isOnline: Bool
    /// When the device was last connected. `nil` while it is online, and for
    /// a device that never was.
    public var lastSeen: Date?
    /// Whether this is the device the app is running on.
    public var isSelf: Bool

    public init(
        id: String,
        name: String,
        dnsName: String = "",
        addresses: [String] = [],
        os: String = "",
        isOnline: Bool = false,
        lastSeen: Date? = nil,
        isSelf: Bool = false
    ) {
        self.id = id
        self.name = name
        self.dnsName = dnsName
        self.addresses = addresses
        self.os = os
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.isSelf = isSelf
    }

    /// What kind of computer the operating system makes this. Phones, tablets
    /// and TV boxes are `.other`.
    public var kind: ComputerKind {
        switch TailscaleDevice.osKey(os) {
        case "macos": .mac
        case "windows": .windows
        case "linux": .linux
        default: .other
        }
    }

    /// Whether the device can run a screen sharing server at all. Phones,
    /// tablets and TV boxes cannot; they are listed but not offered for
    /// connection.
    public var canBeControlled: Bool {
        !TailscaleDevice.uncontrollableSystems.contains(TailscaleDevice.osKey(os))
    }

    /// The address to connect to and to save: the MagicDNS name, which
    /// follows the device when its address changes, or failing that its IPv4
    /// address. Empty only for a device that has neither.
    public var preferredHost: String {
        if !dnsName.isEmpty {
            return dnsName
        }
        return addresses.first { !$0.contains(":") } ?? addresses.first ?? ""
    }

    // Decoding tolerates missing keys so a list cached by another version of
    // the app keeps loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        isOnline = try c.decodeIfPresent(Bool.self, forKey: .isOnline) ?? false
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
    }
}

// MARK: - Building devices from what Tailscale reports

extension TailscaleDevice {
    /// Systems that have no screen sharing server to connect to.
    private static let uncontrollableSystems: Set<String> = [
        "ios", "ipados", "tvos", "watchos", "visionos", "android",
    ]

    private static func osKey(_ os: String) -> String {
        os.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A DNS name the way it is stored: trimmed and without the final dot the
    /// Tailscale client prints.
    static func trimmedDNSName(_ name: String?) -> String {
        var name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name
    }

    /// The name to show for a device.
    ///
    /// The host name the device reports is preferred — it is what its owner
    /// called it, and it matches the name the same computer has in the nearby
    /// list. Devices that will not say (`localhost`) fall back to the first
    /// label of the MagicDNS name, and as a last resort to an address.
    static func displayName(hostName: String?, dnsName: String, addresses: [String]) -> String {
        let hostName = (hostName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !hostName.isEmpty, hostName.lowercased() != "localhost" {
            return hostName
        }
        if let label = dnsName.split(separator: ".").first, !label.isEmpty {
            return String(label)
        }
        return hostName.isEmpty ? (addresses.first ?? "") : hostName
    }

    /// Orders addresses IPv4 first, otherwise as given, without blanks.
    static func orderedAddresses(_ addresses: [String]?) -> [String] {
        let addresses = (addresses ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return addresses.filter { !$0.contains(":") } + addresses.filter { $0.contains(":") }
    }

    /// Reads a timestamp as Tailscale writes them: RFC 3339, with or without
    /// fractional seconds. Go's zero time (`0001-01-01T00:00:00Z`), which
    /// Tailscale uses for "never" and for devices that are online, is `nil`.
    static func timestamp(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let date = (try? Date.ISO8601FormatStyle().parse(text))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

extension TailscaleDevice {
    /// Decodes a value if it can and is `nil` if it cannot, so that one
    /// malformed entry is skipped instead of failing the whole list it is in.
    struct Lenient<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

// MARK: - Sources

/// Something that can list the devices in the user's tailnet.
public protocol TailscaleSource: Sendable {
    func devices() async throws -> [TailscaleDevice]
}

/// Why the devices in a tailnet could not be listed.
public enum TailscaleError: LocalizedError, Equatable, Sendable {

    // MARK: HTTP API

    /// HTTP 401 on an API call: the access token is wrong, expired or revoked.
    case accessTokenRejected
    /// The OAuth client ID or secret was refused when asking for a token.
    case oauthClientRejected
    /// HTTP 403: the credentials are valid but may not list devices.
    case accessDenied
    /// HTTP 404: there is no such tailnet, or the credentials cannot see it.
    case tailnetNotFound(String)
    /// HTTP 429.
    case rateLimited
    /// Any other unsuccessful HTTP status, with the server's own message.
    case server(status: Int, message: String?)
    /// A successful response that could not be understood.
    case unreadableResponse

    // MARK: Tailscale on this Mac

    /// The Tailscale app's command-line tool was not found. A tool that is
    /// not Tailscale's own counts as not being there.
    case notInstalled
    /// Tailscale is installed but stopped, or its background service is not
    /// running.
    case notRunning
    /// Tailscale is running but nobody is signed in.
    case loggedOut
    /// This Mac is signed in but a tailnet admin has yet to approve it.
    case awaitingApproval
    /// The command-line tool did not answer in time.
    case timedOut
    /// The command-line tool reported something else; the text is its own.
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessTokenRejected:
            "The access token was rejected. It may have expired or been revoked; create a new one in the Tailscale admin console."
        case .oauthClientRejected:
            "The OAuth client ID or secret was rejected."
        case .accessDenied:
            "These credentials are not allowed to list devices. An OAuth client needs the devices:core:read scope."
        case .tailnetNotFound(let tailnet):
            tailnet == "-"
                ? "Tailnet not found for these credentials."
                : "Tailnet “\(tailnet)” was not found."
        case .rateLimited:
            "Tailscale is receiving too many requests. Try again in a moment."
        case .server(let status, let message):
            if let message, !message.isEmpty {
                "Tailscale returned an error (HTTP \(status)): \(message)"
            } else {
                "Tailscale returned an error (HTTP \(status))."
            }
        case .unreadableResponse:
            "Tailscale sent a response that could not be read."
        case .notInstalled:
            "The Tailscale app is not installed on this Mac."
        case .notRunning:
            "Tailscale is not running. Open Tailscale and connect, then try again."
        case .loggedOut:
            "Tailscale is signed out. Sign in to Tailscale, then try again."
        case .awaitingApproval:
            "This Mac is waiting for a tailnet admin to approve it."
        case .timedOut:
            "Tailscale did not respond in time."
        case .commandFailed(let detail):
            detail.isEmpty ? "Tailscale reported an error." : "Tailscale reported an error: \(detail)"
        }
    }

    /// Whether the failure says nothing about the devices themselves — the
    /// request simply did not get through — so a list fetched earlier is
    /// still the best information there is.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .timedOut:
            true
        case .server(let status, _):
            status >= 500
        default:
            false
        }
    }
}

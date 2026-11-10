import Foundation

/// A saved remote computer.
///
/// `Computer` is a plain value: it is what gets written to disk, synced
/// through iCloud, and exported in backups. Secrets never live here — passwords
/// and private keys are stored in the keychain, keyed by ``id``.
public struct Computer: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Hostname, IP address or MagicDNS name.
    public var host: String
    public var port: Int
    /// Account name for servers that authenticate with a user (macOS,
    /// VeNCrypt Plain). `nil` for password-only VNC servers.
    public var username: String?
    public var kind: ComputerKind
    public var groupID: UUID?
    public var isFavorite: Bool
    public var tags: [String]
    public var tint: ComputerTint
    public var notes: String
    public var settings: ConnectionSettings
    public var ssh: SSHSettings
    /// Hardware address used for Wake-on-LAN, when known.
    public var macAddress: String?
    public var origin: ComputerOrigin
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastConnectedAt: Date?
    /// When the record of connections was last cleared. A connection from
    /// before then does not count, which is what keeps a cleared Recents
    /// list cleared after merging with a copy that still remembers.
    public var connectionsClearedAt: Date?
    /// Position in manually ordered lists.
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = Computer.defaultPort,
        username: String? = nil,
        kind: ComputerKind = .mac,
        groupID: UUID? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        tint: ComputerTint = .automatic,
        notes: String = "",
        settings: ConnectionSettings = ConnectionSettings(),
        ssh: SSHSettings = SSHSettings(),
        macAddress: String? = nil,
        origin: ComputerOrigin = .manual,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        lastConnectedAt: Date? = nil,
        connectionsClearedAt: Date? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.kind = kind
        self.groupID = groupID
        self.isFavorite = isFavorite
        self.tags = tags
        self.tint = tint
        self.notes = notes
        self.settings = settings
        self.ssh = ssh
        self.macAddress = macAddress
        self.origin = origin
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastConnectedAt = lastConnectedAt
        self.connectionsClearedAt = connectionsClearedAt
        self.sortIndex = sortIndex
    }

    public static let defaultPort = 5900

    /// The name to show in lists: the user's name for the computer, falling
    /// back to its address.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    /// `host` with the port appended when it is not the default.
    public var displayAddress: String {
        guard port != Computer.defaultPort else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    // Decoding tolerates missing keys so older library files and records
    // synced from other versions keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Computer.defaultPort
        username = try c.decodeIfPresent(String.self, forKey: .username)
        kind = try c.decodeIfPresent(ComputerKind.self, forKey: .kind) ?? .mac
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        tint = try c.decodeIfPresent(ComputerTint.self, forKey: .tint) ?? .automatic
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        settings = try c.decodeIfPresent(ConnectionSettings.self, forKey: .settings)
            ?? ConnectionSettings()
        ssh = try c.decodeIfPresent(SSHSettings.self, forKey: .ssh) ?? SSHSettings()
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        origin = try c.decodeIfPresent(ComputerOrigin.self, forKey: .origin) ?? .manual
        // A record without a modification date is one nobody vouches for:
        // it is the oldest there is, and loses to any other copy. Dates that
        // are not dates at all are treated the same way.
        modifiedAt = try c.decodeDate(forKey: .modifiedAt) ?? .distantPast
        createdAt = try c.decodeDate(forKey: .createdAt) ?? modifiedAt
        lastConnectedAt = try c.decodeDate(forKey: .lastConnectedAt)
        connectionsClearedAt = try c.decodeDate(forKey: .connectionsClearedAt)
        sortIndex = Computer.clampedSortIndex(try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0)
    }

    /// Keeps a position within a range that arithmetic on it cannot leave.
    static func clampedSortIndex(_ value: Int) -> Int {
        min(max(value, -1_000_000_000), 1_000_000_000)
    }
}

extension KeyedDecodingContainer {
    /// A date, or `nil` when the key is missing or its value is not a point
    /// in time — the infinities and not-a-number that some encodings allow.
    func decodeDate(forKey key: Key) throws -> Date? {
        guard let date = try decodeIfPresent(Date.self, forKey: key),
              date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return date
    }
}

/// What is running on the other end. Decides the default connection mode,
/// how modifier keys are sent, and which icon represents the computer.
public enum ComputerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case mac
    case windows
    case linux
    case raspberryPi
    case other

    public var id: Self { self }

    public var title: String {
        switch self {
        case .mac: "Mac"
        case .windows: "Windows PC"
        case .linux: "Linux"
        case .raspberryPi: "Raspberry Pi"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .mac: "macbook"
        case .windows: "pc"
        case .linux: "desktopcomputer"
        case .raspberryPi: "cpu"
        case .other: "display"
        }
    }

    /// Whether the computer speaks Apple's Screen Sharing dialect, which is
    /// what makes High Performance mode, remote audio and Curtain Mode possible.
    public var isApple: Bool { self == .mac }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ComputerKind(rawValue: raw) ?? .other
    }
}

/// Accent colour shown on a computer's card.
public enum ComputerTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, blue, purple, pink, red, orange, yellow, green, teal, graphite

    public var id: Self { self }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        default: rawValue.capitalized
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ComputerTint(rawValue: raw) ?? .automatic
    }
}

/// Where a saved computer came from. Discovered computers keep a reference to
/// their source so the address can follow the device when it changes.
public enum ComputerOrigin: Codable, Hashable, Sendable {
    case manual
    /// Found on the local network; the payload is the Bonjour service name.
    case bonjour(serviceName: String)
    /// A device in the user's tailnet; the payload is its stable node ID.
    case tailscale(nodeID: String)

    public var isDiscovered: Bool { self != .manual }

    private enum CodingKeys: String, CodingKey {
        case manual, bonjour, tailscale
    }

    private enum BonjourKeys: String, CodingKey {
        case serviceName
    }

    private enum TailscaleKeys: String, CodingKey {
        case nodeID
    }

    /// Reads an origin, taking anything it does not recognise as `manual`.
    /// A newer version may know sources this one does not; that must not
    /// make the computer, and with it the whole library, unreadable.
    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .manual
            return
        }
        if let bonjour = try? container.nestedContainer(keyedBy: BonjourKeys.self, forKey: .bonjour),
           let serviceName = try? bonjour.decode(String.self, forKey: .serviceName) {
            self = .bonjour(serviceName: serviceName)
        } else if let tailscale = try? container.nestedContainer(keyedBy: TailscaleKeys.self, forKey: .tailscale),
                  let nodeID = try? tailscale.decode(String.self, forKey: .nodeID) {
            self = .tailscale(nodeID: nodeID)
        } else {
            self = .manual
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            _ = container.nestedContainer(keyedBy: BonjourKeys.self, forKey: .manual)
        case .bonjour(let serviceName):
            var nested = container.nestedContainer(keyedBy: BonjourKeys.self, forKey: .bonjour)
            try nested.encode(serviceName, forKey: .serviceName)
        case .tailscale(let nodeID):
            var nested = container.nestedContainer(keyedBy: TailscaleKeys.self, forKey: .tailscale)
            try nested.encode(nodeID, forKey: .nodeID)
        }
    }
}

/// A user-defined collection of computers.
public struct ComputerGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var sortIndex: Int
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "folder",
        sortIndex: Int = 0,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.modifiedAt = modifiedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "folder"
        sortIndex = Computer.clampedSortIndex(try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0)
        modifiedAt = try c.decodeDate(forKey: .modifiedAt) ?? .distantPast
    }
}

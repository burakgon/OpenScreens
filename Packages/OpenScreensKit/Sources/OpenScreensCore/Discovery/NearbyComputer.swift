import Foundation

/// A computer on the local network that advertises screen sharing.
///
/// ``NearbyBrowser`` builds these from Bonjour: one per `_rfb._tcp` service,
/// enriched with what the same machine says about itself in its other
/// records. A value is a snapshot — it is replaced, not mutated, as more is
/// learned about the computer.
public struct NearbyComputer: Identifiable, Hashable, Sendable {
    /// Identifies the advertisement: service name, type and domain written the
    /// way DNS-SD writes them (`Studio._rfb._tcp.local.`). It stays the same
    /// for as long as the computer keeps its name, whatever its address.
    public var id: String
    /// The Bonjour service name, which is the computer's human-readable name.
    /// This is the value to keep in ``ComputerOrigin/bonjour(serviceName:)``.
    public var name: String
    /// Host name the service resolved to, such as `Studio.local`, without a
    /// trailing dot. `nil` until the service has been resolved.
    public var host: String?
    /// Port the service resolved to; ``Computer/defaultPort`` until known.
    public var port: Int
    /// Best guess at what is on the other end.
    public var kind: ComputerKind
    /// Apple model identifier from the computer's device-info record, such as
    /// `Mac16,1`, when it publishes one.
    public var model: String?
    /// Whether the same computer also advertises SSH (`_ssh._tcp` or
    /// `_sftp-ssh._tcp`), which makes a secure tunnel likely to work.
    public var supportsSSH: Bool

    /// Creates a value by hand, for previews and tests. `id` defaults to the
    /// identifier a `_rfb._tcp` service of that name has in `local.`.
    public init(
        id: String? = nil,
        name: String,
        host: String? = nil,
        port: Int = Computer.defaultPort,
        kind: ComputerKind = .other,
        model: String? = nil,
        supportsSSH: Bool = false
    ) {
        self.id = id ?? NearbyComputer.makeID(name: name)
        self.name = name
        self.host = host
        self.port = port
        self.kind = kind
        self.model = model
        self.supportsSSH = supportsSSH
    }
}

// MARK: - Naming

extension NearbyComputer {
    /// The service type screen sharing is advertised under.
    static let serviceType = "_rfb._tcp"
    /// The only domain browsed: the local network.
    static let localDomain = "local."

    /// Builds the identifier of a service from the three parts Bonjour reports.
    ///
    /// The name is kept exactly as advertised. Type and domain are brought to
    /// one spelling, because the system reports them with or without the final
    /// dot depending on the API they come from.
    static func makeID(
        name: String,
        type: String = serviceType,
        domain: String = localDomain
    ) -> String {
        let dots = CharacterSet(charactersIn: ".")
        let type = type.trimmingCharacters(in: dots).lowercased()
        let domain = domain.trimmingCharacters(in: dots).lowercased()
        return "\(name).\(type).\(domain.isEmpty ? "local" : domain)."
    }

    /// Turns a host target as DNS-SD reports it (`Studio.local.`) into the
    /// form people type and that can be saved: no final dot, and with DNS
    /// presentation escapes undone (`\032` is a byte in decimal, `\.` is a
    /// literal dot). Returns `nil` when nothing is left.
    static func normalizedHost(_ target: String) -> String? {
        let input = Array(target.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let backslash = UInt8(ascii: "\\")
        let dot = UInt8(ascii: ".")

        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.count)
        var endsWithRootDot = false
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == backslash, index + 1 < input.count {
                if index + 3 < input.count,
                   let value = decimalByte(input[index + 1], input[index + 2], input[index + 3]) {
                    bytes.append(value)
                    index += 4
                } else {
                    bytes.append(input[index + 1])
                    index += 2
                }
                endsWithRootDot = false
            } else {
                bytes.append(byte)
                index += 1
                endsWithRootDot = byte == dot
            }
        }
        if endsWithRootDot {
            bytes.removeLast()
        }
        let host = String(decoding: bytes, as: UTF8.self)
        return host.isEmpty ? nil : host
    }

    private static func decimalByte(_ hundreds: UInt8, _ tens: UInt8, _ ones: UInt8) -> UInt8? {
        let zero = UInt8(ascii: "0")
        let nine = UInt8(ascii: "9")
        guard (zero...nine).contains(hundreds), (zero...nine).contains(tens),
              (zero...nine).contains(ones) else { return nil }
        let value = Int(hundreds - zero) * 100 + Int(tens - zero) * 10 + Int(ones - zero)
        return UInt8(exactly: value)
    }

    /// The form host names are compared in: lowercased, without a final dot
    /// and without the `.local` suffix, so `Studio.local.`, `studio.local` and
    /// `STUDIO` all mean the same machine.
    static func hostKey(_ host: String) -> String {
        var key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix(".") {
            key.removeLast()
        }
        if key.hasSuffix(".local") {
            key.removeLast(".local".count)
        }
        return key
    }
}

// MARK: - Kind

/// What a computer's other Bonjour records say about it. The input to
/// ``NearbyComputer/guessKind(name:host:evidence:)``.
struct NearbyEvidence: Equatable, Sendable {
    /// `model` from the device-info record.
    var model: String?
    /// The device-info record carries `osxvers`, which only macOS publishes.
    var reportsMacOSVersion = false
    /// `_ssh._tcp` is advertised under exactly the computer's name.
    var advertisesSSH = false
    /// `_sftp-ssh._tcp` is advertised under exactly the computer's name.
    var advertisesSFTP = false
}

extension NearbyComputer {
    /// Model identifier families that are Macs: `Mac16,1`, `MacBookPro18,3`,
    /// `Macmini9,1`, `MacPro7,1`, `iMac21,1`, `iMacPro1,1`, `VirtualMac2,1`
    /// and the older `Xserve`, `RackMac`, `PowerMac` and `PowerBook` lines.
    /// Compared as lowercased prefixes.
    private static let macModelPrefixes = [
        "mac", "imac", "virtualmac", "xserve", "rackmac", "powermac", "powerbook",
    ]

    /// Guesses what kind of computer is advertising screen sharing.
    ///
    /// In order of how much each clue can be trusted:
    /// 1. A device-info model from a Mac family, or a device-info record that
    ///    states a macOS version, means a Mac.
    /// 2. A name or host name that spells out Raspberry Pi means one.
    /// 3. With no model to go by, Remote Login advertised the way macOS does
    ///    it — both `_ssh._tcp` and `_sftp-ssh._tcp` under the very name the
    ///    screen is shared under — means a Mac.
    /// 4. Anything else is left as `.other`; the connection will find out.
    static func guessKind(name: String, host: String?, evidence: NearbyEvidence) -> ComputerKind {
        if let model = evidence.model, isMacModel(model) {
            return .mac
        }
        if evidence.reportsMacOSVersion {
            return .mac
        }
        if mentionsRaspberryPi(name) || host.map(mentionsRaspberryPi) == true {
            return .raspberryPi
        }
        // A model that is not a Mac's is a statement, not an absence: it is
        // not overruled by the weaker hint below.
        if evidence.model == nil, evidence.advertisesSSH, evidence.advertisesSFTP {
            return .mac
        }
        return .other
    }

    static func isMacModel(_ model: String) -> Bool {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return macModelPrefixes.contains { model.hasPrefix($0) }
    }

    /// Whether a name clearly says Raspberry Pi: `raspberrypi`, `Raspberry Pi
    /// 5`, `raspi-kitchen`, or `rpi` standing on its own (`rpi4`, `my-rpi`).
    /// A bare `pi` is not enough — too many other things are called that.
    static func mentionsRaspberryPi(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("raspberry") || lowered.contains("raspi") {
            return true
        }
        // "rpi" only counts as a whole word, so "serpico" does not match.
        return lowered
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "rpi" }
    }
}

import Foundation
#if os(macOS)
import SystemConfiguration
#endif

/// The Bonjour service types the nearby browser looks at.
///
/// On iOS every one of these must be listed under `NSBonjourServices` in the
/// app's Info.plist, or the system refuses to browse for it.
enum BonjourServiceType: String, CaseIterable, Sendable {
    /// VNC and Apple Screen Sharing. The services that become nearby computers.
    case screenSharing = "_rfb._tcp"
    /// Remote Login.
    case ssh = "_ssh._tcp"
    /// SFTP over SSH, which macOS advertises alongside Remote Login.
    case sftp = "_sftp-ssh._tcp"
    /// A TXT record describing the hardware. Macs publish it as a bare record
    /// that browsing does not find (it is looked up by name instead); other
    /// systems publish it as a real service, which browsing does find.
    case deviceInfo = "_device-info._tcp"
}

/// What a device-info TXT record says about a computer.
struct BonjourDeviceInfo: Equatable, Sendable {
    /// Hardware model, such as `Mac16,1`.
    var model: String?
    /// The record states a macOS version (`osxvers`), which only macOS does.
    var reportsMacOSVersion: Bool

    init(model: String? = nil, reportsMacOSVersion: Bool = false) {
        self.model = model
        self.reportsMacOSVersion = reportsMacOSVersion
    }

    /// Reads the entries of a device-info TXT record. Keys are matched
    /// without regard to case, as DNS-SD requires.
    init(txt: [String: String]) {
        let entries = Dictionary(
            txt.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        // Some servers append display hints to the model after an "@"
        // (`MacPro7,1@ECOLOR=226,226,224`); only the identifier is wanted.
        let model = entries["model"]?
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }
        reportsMacOSVersion = entries["osxvers"] != nil
    }
}

/// Decoding of DNS TXT record data.
enum BonjourTXT {
    /// Splits TXT record data — a run of length-prefixed `key=value` strings —
    /// into a dictionary. Keys are lowercased; a key without `=` is present
    /// with an empty value; of repeated keys the first wins; a string that is
    /// cut short ends the record. All as RFC 6763 section 6 lays out.
    static func entries(in data: Data) -> [String: String] {
        var entries: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index += 1
            guard length <= data.endIndex - index else { break }
            let string = data[index..<(index + length)]
            index += length

            let equals = UInt8(ascii: "=")
            let keyBytes = string.prefix { $0 != equals }
            guard !keyBytes.isEmpty else { continue }
            let key = String(decoding: keyBytes, as: UTF8.self).lowercased()
            let valueBytes = string.dropFirst(keyBytes.count + 1)
            if entries[key] == nil {
                entries[key] = String(decoding: valueBytes, as: UTF8.self)
            }
        }
        return entries
    }
}

/// The names this device goes by on the local network, used to keep it out of
/// its own list of nearby computers.
struct NearbyLocalIdentity: Equatable, Sendable {
    /// Host names in the form ``NearbyComputer/hostKey(_:)`` produces.
    private(set) var hostKeys: Set<String> = []
    /// Names this device registers its own Bonjour services under.
    private(set) var serviceNameKeys: Set<String> = []

    init(hostNames: [String] = [], serviceNames: [String] = []) {
        hostNames.forEach { addHostName($0) }
        serviceNames.forEach { addServiceName($0) }
    }

    mutating func addHostName(_ name: String) {
        let key = NearbyComputer.hostKey(name)
        // "localhost" is what a device reports when it will not say its name.
        // As a key it would identify nothing, and would hide any other
        // machine that happens to call itself `localhost.local`.
        guard !key.isEmpty, key != "localhost" else { return }
        hostKeys.insert(key)
    }

    mutating func addServiceName(_ name: String) {
        let key = NearbyRecords.nameKey(name)
        guard !key.isEmpty else { return }
        serviceNameKeys.insert(key)
    }

    /// Whether an advertisement is this device's own.
    ///
    /// The host a service resolves to settles it. Before that is known, the
    /// service name is compared instead, so this device does not flash up in
    /// the list for the moment its own service takes to resolve.
    func isThisDevice(serviceName: String, host: String?) -> Bool {
        if let host {
            return Self.isLoopback(host) || hostKeys.contains(NearbyComputer.hostKey(host))
        }
        return serviceNameKeys.contains(NearbyRecords.nameKey(serviceName))
    }

    /// Whether a resolved host is plain `localhost`. That is the target of a
    /// service some app registered for use on this device only; it is never
    /// another computer. (`localhost.local`, by contrast, is a real name on
    /// the network, however unfortunate.)
    static func isLoopback(_ host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name == "localhost"
    }

    /// The names that can be read without waiting: the kernel's host name
    /// and, on a Mac, the Bonjour host name and computer name from the system
    /// configuration. `ProcessInfo`'s host name is not asked for here because
    /// it can take seconds when DNS is slow; ``NearbyEngine`` adds it later.
    static func current() -> NearbyLocalIdentity {
        var identity = NearbyLocalIdentity()

        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buffer, buffer.count - 1) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            identity.addHostName(String(decoding: bytes, as: UTF8.self))
        }

        #if os(macOS)
        // The Bonjour host name ("Studio" of "Studio.local"), which is what
        // this Mac's own services resolve to whatever its DNS name may be.
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            identity.addHostName(name)
        }
        // The computer name, under which macOS registers its services.
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            identity.addServiceName(name)
        }
        #endif
        return identity
    }
}

/// Everything the browsers have learned so far, and the rules for turning it
/// into the list of nearby computers.
struct NearbyRecords: Equatable, Sendable {
    /// One `_rfb._tcp` advertisement and what has been looked up for it.
    struct ScreenSharingService: Equatable, Sendable {
        var name: String
        var type = NearbyComputer.serviceType
        var domain = NearbyComputer.localDomain
        /// Host the service resolved to, already normalised.
        var host: String?
        var port: Int?
        /// The answer to looking up the device-info record of the same name.
        var deviceInfo: BonjourDeviceInfo?

        var id: String {
            NearbyComputer.makeID(name: name, type: type, domain: domain)
        }
    }

    /// Screen sharing services by ``ScreenSharingService/id``.
    var screenSharing: [String: ScreenSharingService] = [:]
    /// Names (as ``nameKey(_:)``) under which `_ssh._tcp` is advertised.
    var sshNames: Set<String> = []
    /// Names (as ``nameKey(_:)``) under which `_sftp-ssh._tcp` is advertised.
    var sftpNames: Set<String> = []
    /// Device-info found by browsing, by the name it is advertised under.
    var advertisedDeviceInfo: [String: BonjourDeviceInfo] = [:]

    /// The form service names are compared in. Bonjour names keep their case
    /// but are matched without regard to it.
    static func nameKey(_ name: String) -> String {
        name.lowercased()
    }

    mutating func insert(_ service: ScreenSharingService) {
        screenSharing[service.id] = service
    }

    /// The nearby computers these records describe: every screen sharing
    /// service except this device's own, each with what the other records add
    /// to it, in name order.
    ///
    /// A record belongs to a computer when it is advertised under the
    /// computer's service name — how macOS names everything it advertises —
    /// or under the first label of the host the computer resolved to, which
    /// is how Avahi names things on Linux.
    func computers(excluding local: NearbyLocalIdentity = NearbyLocalIdentity()) -> [NearbyComputer] {
        screenSharing.values
            .filter { !local.isThisDevice(serviceName: $0.name, host: $0.host) }
            .map { service in
                let nameKey = Self.nameKey(service.name)
                let hostKey = service.host.map(NearbyComputer.hostKey)

                let info = service.deviceInfo
                    ?? advertisedDeviceInfo[nameKey]
                    ?? hostKey.flatMap { advertisedDeviceInfo[$0] }

                let sshUnderName = sshNames.contains(nameKey)
                let sftpUnderName = sftpNames.contains(nameKey)
                let sshUnderHost = hostKey.map { sshNames.contains($0) || sftpNames.contains($0) }
                    ?? false

                let evidence = NearbyEvidence(
                    model: info?.model,
                    reportsMacOSVersion: info?.reportsMacOSVersion ?? false,
                    advertisesSSH: sshUnderName,
                    advertisesSFTP: sftpUnderName)

                return NearbyComputer(
                    id: service.id,
                    name: service.name,
                    host: service.host,
                    port: service.port ?? Computer.defaultPort,
                    kind: NearbyComputer.guessKind(
                        name: service.name, host: service.host, evidence: evidence),
                    model: info?.model,
                    supportsSSH: sshUnderName || sftpUnderName || sshUnderHost)
            }
            .sorted(by: Self.listOrder)
    }

    /// Name order as Finder would show it, with the identifier as a
    /// tie-breaker so the order never depends on what was discovered first.
    static func listOrder(_ lhs: NearbyComputer, _ rhs: NearbyComputer) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id < rhs.id
        }
    }
}

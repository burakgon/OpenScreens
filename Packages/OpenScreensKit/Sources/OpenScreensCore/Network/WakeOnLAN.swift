import Foundation

/// A 48-bit hardware address, as used by Ethernet and Wi-Fi adapters.
public struct MACAddress: Hashable, Sendable {

    /// The address as a number, with the first octet most significant.
    public let rawValue: UInt64

    /// Creates an address from its numeric value, which has to fit in 48 bits.
    public init?(rawValue: UInt64) {
        guard rawValue <= 0xFFFF_FFFF_FFFF else { return nil }
        self.rawValue = rawValue
    }

    /// Creates an address from exactly six octets, in transmission order.
    public init?(octets: some Sequence<UInt8>) {
        var value: UInt64 = 0
        var count = 0
        for octet in octets {
            count += 1
            guard count <= 6 else { return nil }
            value = value << 8 | UInt64(octet)
        }
        guard count == 6 else { return nil }
        rawValue = value
    }

    /// Parses an address the way people and tools write one:
    ///
    /// - `aa:bb:cc:dd:ee:ff` or `AA-BB-CC-DD-EE-FF` — six groups. A group may
    ///   leave out its leading zero, which is how `arp` prints addresses on
    ///   macOS (`0:1c:b3:9:85:15`).
    /// - `aabb.ccdd.eeff` — three groups of four digits.
    /// - `aabbccddeeff` — twelve digits, as printed on many device labels.
    ///
    /// Letter case and surrounding white space do not matter. Separators
    /// cannot be mixed.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let groups: [Substring]
        let digitsPerGroup: ClosedRange<Int>
        if trimmed.contains(":") || trimmed.contains("-") {
            let separator: Character = trimmed.contains(":") ? ":" : "-"
            groups = trimmed.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.count == 6 else { return nil }
            digitsPerGroup = 1...2
        } else if trimmed.contains(".") {
            groups = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard groups.count == 3 else { return nil }
            digitsPerGroup = 4...4
        } else {
            groups = [Substring(trimmed)]
            digitsPerGroup = 12...12
        }

        var value: UInt64 = 0
        for group in groups {
            guard digitsPerGroup.contains(group.count) else { return nil }
            var groupValue: UInt64 = 0
            for character in group {
                // `hexDigitValue` also accepts full-width digits; an address
                // is plain ASCII.
                guard character.isASCII, let digit = character.hexDigitValue else { return nil }
                groupValue = groupValue << 4 | UInt64(digit)
            }
            value = value << UInt64(4 * digitsPerGroup.upperBound) | groupValue
        }
        rawValue = value
    }

    /// The six octets, in transmission order.
    public var octets: [UInt8] {
        (0..<6).map { UInt8(truncatingIfNeeded: rawValue >> UInt64(8 * (5 - $0))) }
    }
}

extension MACAddress: LosslessStringConvertible {
    /// The canonical form: six two-digit uppercase groups separated by
    /// colons, `AA:BB:CC:DD:EE:FF`.
    public var description: String {
        octets
            .map { octet in
                let digits = String(octet, radix: 16, uppercase: true)
                return octet < 0x10 ? "0" + digits : digits
            }
            .joined(separator: ":")
    }
}

extension MACAddress: Codable {
    /// Decodes any spelling ``init(_:)`` accepts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let address = MACAddress(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "“\(text)” is not a hardware address.")
        }
        self = address
    }

    /// Encodes the canonical form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Why a wake-up packet could not be sent.
public enum WakeOnLANError: Error, Equatable, Sendable {
    /// The destination is not an IPv4 address in dotted form.
    case invalidBroadcastAddress(String)
    /// A UDP socket could not be opened or set up. `code` is the `errno`.
    case socketFailed(code: Int32)
    /// No network interface accepted the packet. `code` is the last `errno`.
    case sendFailed(code: Int32)
}

extension WakeOnLANError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBroadcastAddress(let address):
            "“\(address)” is not an IPv4 address the wake-up packet can be sent to."
        case .socketFailed(let code):
            "The network could not be used to send the wake-up packet (\(Self.message(for: code)))."
        case .sendFailed(let code):
            "The wake-up packet could not be sent (\(Self.message(for: code)))."
        }
    }

    private static func message(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard strerror_r(code, &buffer, buffer.count) == 0 else { return "error \(code)" }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Wakes a sleeping or powered-off computer by sending the "magic packet"
/// its network adapter keeps listening for.
public enum WakeOnLAN {

    /// The broadcast address of whatever network the device is attached to.
    public static let limitedBroadcastAddress = "255.255.255.255"

    /// The discard port, the conventional destination for magic packets.
    public static let defaultPort: UInt16 = 9

    // UDP gives no delivery guarantee and an adapter in standby may miss a
    // single frame, so the packet is repeated.
    static let repetitions = 3
    static let interval: Duration = .milliseconds(250)

    /// The magic packet for an adapter: six `0xFF` bytes followed by the
    /// adapter's address sixteen times, 102 bytes in all.
    public static func magicPacket(for address: MACAddress) -> Data {
        let octets = address.octets
        var packet = Data(repeating: 0xFF, count: 6)
        packet.reserveCapacity(6 + 16 * octets.count)
        for _ in 0..<16 {
            packet.append(contentsOf: octets)
        }
        return packet
    }

    /// Sends the magic packet for `address` three times, a quarter of a
    /// second apart.
    ///
    /// With the default destination the packet is broadcast on every network
    /// the device is attached to. Pass a subnet's broadcast address
    /// (`192.168.1.255`) or the address of a router that forwards wake-up
    /// packets to reach a computer on another network.
    ///
    /// On iOS broadcasting needs the user's Local Network permission and the
    /// multicast networking entitlement; without them the system refuses the
    /// packet and this throws ``WakeOnLANError/sendFailed(code:)``.
    ///
    /// - Throws: ``WakeOnLANError`` when the first packet cannot be sent —
    ///   the repeats are best effort — or `CancellationError` when the task
    ///   is cancelled between packets.
    public static func wake(
        _ address: MACAddress,
        broadcastAddress: String = "255.255.255.255",
        port: UInt16 = 9
    ) async throws {
        try await send(
            magicPacket(for: address),
            to: broadcastAddress,
            port: port,
            repetitions: repetitions,
            interval: interval)
    }

    // MARK: - Sending

    // BSD sockets rather than Network.framework: Network.framework does not
    // support UDP broadcast — NWConnection has no equivalent of SO_BROADCAST —
    // and Apple's own guidance (TN3151, "Choosing the right networking API")
    // is to use BSD sockets for it. A datagram send does not block, so
    // calling it straight from an async function is fine.

    static func send(
        _ packet: Data,
        to address: String,
        port: UInt16,
        repetitions: Int,
        interval: Duration
    ) async throws {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inet_pton(AF_INET, trimmed, &destination.sin_addr) == 1 else {
            throw WakeOnLANError.invalidBroadcastAddress(address)
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw WakeOnLANError.socketFailed(code: errno)
        }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_BROADCAST, &enabled,
            socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WakeOnLANError.socketFailed(code: errno)
        }

        try await repeatedly(repetitions, every: interval) {
            try transmit(packet, through: descriptor, to: destination)
        }
    }

    /// Calls `transmit` the given number of times, pausing before each
    /// repeat.
    ///
    /// The first attempt has to succeed. Once the packet has gone out, a
    /// repeat that fails — because the network dropped in between, say — is
    /// no reason to report the whole wake-up as failed.
    static func repeatedly(
        _ repetitions: Int,
        every interval: Duration,
        _ transmit: () throws -> Void
    ) async throws {
        for attempt in 0..<max(1, repetitions) {
            if attempt > 0 {
                try await Task.sleep(for: interval)
            }
            do {
                try transmit()
            } catch where attempt > 0 {
                continue
            }
        }
    }

    /// Sends one copy of the packet, on every suitable interface when it is
    /// addressed to the limited broadcast address.
    private static func transmit(
        _ packet: Data,
        through descriptor: Int32,
        to destination: sockaddr_in
    ) throws {
        var delivered = false
        var lastError: Int32 = 0

        if destination.sin_addr.s_addr == INADDR_BROADCAST {
            // 255.255.255.255 only leaves through the interface of the
            // default route. With a VPN up — Tailscale is one — that is a
            // tunnel that cannot carry broadcasts, and on a Mac with both
            // Ethernet and Wi-Fi it reaches just one of the two networks.
            // Binding the socket to each interface in turn puts the packet
            // on every local network.
            for interface in broadcastInterfaces() {
                var index = interface
                guard setsockopt(
                    descriptor, IPPROTO_IP, IP_BOUND_IF, &index,
                    socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                    lastError = errno
                    continue
                }
                if let code = sendDatagram(packet, through: descriptor, to: destination) {
                    lastError = code
                } else {
                    delivered = true
                }
            }
            var unbound: UInt32 = 0
            setsockopt(
                descriptor, IPPROTO_IP, IP_BOUND_IF, &unbound,
                socklen_t(MemoryLayout<UInt32>.size))
        }

        if !delivered {
            // A specific destination, or no interface took the broadcast:
            // let the routing table choose.
            if let code = sendDatagram(packet, through: descriptor, to: destination) {
                lastError = code
            } else {
                delivered = true
            }
        }

        guard delivered else {
            throw WakeOnLANError.sendFailed(code: lastError)
        }
    }

    /// - Returns: `nil` on success, otherwise the `errno` of the failure.
    private static func sendDatagram(
        _ packet: Data,
        through descriptor: Int32,
        to destination: sockaddr_in
    ) -> Int32? {
        var destination = destination
        while true {
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        sendto(
                            descriptor, bytes.baseAddress, bytes.count, 0, address,
                            socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.count { return nil }
            if sent < 0 {
                let code = errno
                if code == EINTR { continue }
                return code
            }
            // A datagram is sent whole or not at all; anything else means
            // the packet did not fit.
            return EMSGSIZE
        }
    }

    /// Indexes of the interfaces worth broadcasting on: running, with an
    /// IPv4 address, able to broadcast, and neither loopback nor
    /// point-to-point (which rules out cellular and VPN tunnels).
    static func broadcastInterfaces() -> [UInt32] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var indexes: [UInt32] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let index = if_nametoindex(entry.pointee.ifa_name)
            if index != 0, !indexes.contains(index) {
                indexes.append(index)
            }
        }
        return indexes
    }
}

import Foundation
import Testing
@testable import OpenScreensCore

@Suite("MACAddress")
struct MACAddressTests {

    @Test(arguments: [
        "aa:bb:cc:dd:ee:ff", "AA:BB:CC:DD:EE:FF", "Aa:bB:Cc:dD:Ee:fF",
        "AA-BB-CC-DD-EE-FF", "aa-bb-cc-dd-ee-ff",
        "aabb.ccdd.eeff", "AABB.CCDD.EEFF",
        "aabbccddeeff", "AABBCCDDEEFF",
        "  aa:bb:cc:dd:ee:ff\n", "\tAA-BB-CC-DD-EE-FF ",
    ])
    func everyCommonSpellingIsUnderstood(text: String) throws {
        let address = try #require(MACAddress(text))
        #expect(address.octets == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect(address.rawValue == 0xAABB_CCDD_EEFF)
        #expect(address.description == "AA:BB:CC:DD:EE:FF")
    }

    @Test func aGroupMayLeaveOutItsLeadingZero() throws {
        // The way `arp -a` prints addresses on macOS.
        let address = try #require(MACAddress("0:1c:b3:9:85:15"))
        #expect(address.octets == [0x00, 0x1C, 0xB3, 0x09, 0x85, 0x15])
        #expect(address.description == "00:1C:B3:09:85:15")
        #expect(MACAddress("0-1C-B3-9-85-15") == address)
        #expect(MACAddress("00:1c:b3:09:85:15") == address)
        #expect(MACAddress("001c.b309.8515") == address)
    }

    @Test(arguments: [
        "", " ", ":", "-", ".", "::::::",
        // The wrong number of groups.
        "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aabb.ccdd", "aabb.ccdd.eeff.0011",
        "aa.bb.cc.dd.ee.ff", "aabb:ccdd:eeff", "aabb-ccdd-eeff",
        // Groups that are empty, too long or too short.
        "aa:bb:cc:dd:ee:", ":aa:bb:cc:dd:ee:ff", "aa::cc:dd:ee:ff", "aa:bb:cc:dd:ee:fff",
        "aabb.ccdd.eef", "aab.bccd.deeff", "aabbccddeef", "aabbccddeeff0",
        // Characters that are not hexadecimal digits.
        "aa:bb:cc:dd:ee:gg", "aabbccddeegg", "aabb.ccdd.eefg", "+a:bb:cc:dd:ee:ff",
        "-a:bb:cc:dd:ee:ff", "0xaabbccddeeff", "ａａ:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:f f",
        // Mixed separators and extras.
        "aa:bb-cc:dd:ee:ff", "aa-bb-cc-dd-ee:ff", "aa bb cc dd ee ff", "aa:bb:cc:dd:ee:ff/24",
        "aa:bb:cc:dd:ee:ff%en0", "studio.local", "192.168.1.20",
    ])
    func textThatIsNotAHardwareAddressIsRejected(text: String) {
        #expect(MACAddress(text) == nil)
    }

    @Test func theCanonicalFormReadsBackAsTheSameAddress() throws {
        var random = ReplayableRandom(seed: 48)
        for _ in 0..<500 {
            let address = try #require(MACAddress(rawValue: .random(in: 0...0xFFFF_FFFF_FFFF, using: &random)))
            let text = address.description

            #expect(text.count == 17)
            #expect(text == text.uppercased())
            #expect(text.split(separator: ":").map(\.count) == [2, 2, 2, 2, 2, 2])
            #expect(MACAddress(text) == address)
            // LosslessStringConvertible: `String(describing:)` and back.
            #expect(MACAddress(String(describing: address)) == address)
            #expect(MACAddress(octets: address.octets) == address)
        }
    }

    @Test func anAddressIsExactlySixOctets() throws {
        #expect(MACAddress(octets: [1, 2, 3, 4, 5, 6])?.description == "01:02:03:04:05:06")
        #expect(MACAddress(octets: [1, 2, 3, 4, 5]) == nil)
        #expect(MACAddress(octets: [1, 2, 3, 4, 5, 6, 7]) == nil)
        #expect(MACAddress(octets: [UInt8]()) == nil)

        #expect(MACAddress(rawValue: 0)?.description == "00:00:00:00:00:00")
        #expect(MACAddress(rawValue: 0xFFFF_FFFF_FFFF)?.description == "FF:FF:FF:FF:FF:FF")
        #expect(MACAddress(rawValue: 0x1_0000_0000_0000) == nil)
        #expect(try #require(MACAddress(rawValue: 0x0011_2233_4455)).octets == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
    }

    @Test func addressesAreEqualWhateverTheirSpelling() {
        let spellings = [
            "aa:bb:cc:dd:ee:0f", "AA-BB-CC-DD-EE-0F", "aabb.ccdd.ee0f", "AABBCCDDEE0F", "aa:bb:cc:dd:ee:f",
        ]
        #expect(Set(spellings.compactMap { MACAddress($0) }).count == 1)
        #expect(MACAddress("aa:bb:cc:dd:ee:0f") != MACAddress("aa:bb:cc:dd:ee:f0"))
    }

    @Test func anAddressIsEncodedAsItsCanonicalText() throws {
        let address = try #require(MACAddress("aabb.ccdd.eeff"))

        let data = try JSONEncoder().encode([address])
        #expect(String(decoding: data, as: UTF8.self) == #"["AA:BB:CC:DD:EE:FF"]"#)

        // Any accepted spelling can be decoded, so an address typed by the
        // user and saved as it was typed still loads.
        let decoded = try JSONDecoder().decode(
            [MACAddress].self, from: Data(#"["aa-bb-cc-dd-ee-ff", "AABB.CCDD.EEFF"]"#.utf8))
        #expect(decoded == [address, address])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([MACAddress].self, from: Data(#"["not an address"]"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([MACAddress].self, from: Data("[42]".utf8))
        }
    }
}

/// A UDP socket bound to an unused port on the loopback interface, to see
/// what `WakeOnLAN` actually puts on the wire without sending anything to
/// the local network.
private final class LoopbackListener {
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(handle >= 0)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(handle, generic, length) == 0 && getsockname(handle, generic, &length) == 0
            }
        } && fcntl(handle, F_SETFL, O_NONBLOCK) == 0
        if !ready {
            close(handle)
        }
        try #require(ready)

        descriptor = handle
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        close(descriptor)
    }

    /// Every datagram that has arrived so far, without waiting.
    func receiveAll() -> [Data] {
        var packets: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count >= 0 else { return packets }
            packets.append(Data(buffer[..<count]))
        }
    }

    /// Waits for `count` datagrams and returns everything that arrived.
    ///
    /// Even on loopback a datagram reaches the receiving socket a moment
    /// after `sendto` has returned, so the sender being done does not mean
    /// the packets are here yet. Once they are, this lingers briefly so that
    /// a packet too many would be noticed as well.
    func receive(_ count: Int, within timeout: Duration = .seconds(10)) async -> [Data] {
        var packets: [Data] = []
        let deadline = ContinuousClock.now + timeout
        while packets.count < count, ContinuousClock.now < deadline {
            packets += receiveAll()
            if packets.count < count {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        try? await Task.sleep(for: .milliseconds(25))
        return packets + receiveAll()
    }
}

@Suite("WakeOnLAN")
struct WakeOnLANTests {

    /// A locally administered address that no real adapter carries.
    private let address = MACAddress(rawValue: 0x0200_0000_0001)!

    @Test func theMagicPacketIsSixFFBytesAndTheAddressSixteenTimes() throws {
        let address = try #require(MACAddress("00:11:22:33:44:55"))

        let packet = WakeOnLAN.magicPacket(for: address)

        #expect(packet.count == 102)
        #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
        let repeated = Array(packet.dropFirst(6))
        #expect(repeated.count == 96)
        for repetition in 0..<16 {
            #expect(Array(repeated[(repetition * 6)..<(repetition * 6 + 6)])
                == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        }
        #expect(packet == Data(repeating: 0xFF, count: 6)
            + Data((0..<16).flatMap { _ in [0x00, 0x11, 0x22, 0x33, 0x44, 0x55] as [UInt8] }))
    }

    @Test func everyAddressGivesAWellFormedPacket() throws {
        var random = ReplayableRandom(seed: 102)
        for _ in 0..<200 {
            let address = try #require(MACAddress(rawValue: .random(in: 0...0xFFFF_FFFF_FFFF, using: &random)))
            let packet = Array(WakeOnLAN.magicPacket(for: address))

            #expect(packet.count == 102)
            #expect(packet[..<6].allSatisfy { $0 == 0xFF })
            #expect(stride(from: 6, to: 102, by: 6).allSatisfy {
                Array(packet[$0..<($0 + 6)]) == address.octets
            })
        }
    }

    @Test func wakingSendsThePacketThreeTimesSpacedApart() async throws {
        let listener = try LoopbackListener()
        let clock = ContinuousClock()
        let started = clock.now

        try await WakeOnLAN.wake(address, broadcastAddress: "127.0.0.1", port: listener.port)

        let elapsed = clock.now - started
        let packets = await listener.receive(3)
        #expect(packets.count == 3)
        #expect(packets.allSatisfy { $0 == WakeOnLAN.magicPacket(for: address) })
        // Not fired off in one burst: there is a pause before each repeat.
        #expect(elapsed >= WakeOnLAN.interval * 2)
        #expect(WakeOnLAN.repetitions == 3)
        #expect(WakeOnLAN.interval >= .milliseconds(100) && WakeOnLAN.interval <= .milliseconds(500))
    }

    @Test func theDefaultsAreTheLimitedBroadcastAddressAndTheDiscardPort() {
        #expect(WakeOnLAN.limitedBroadcastAddress == "255.255.255.255")
        #expect(WakeOnLAN.defaultPort == 9)
    }

    @Test func surroundingWhiteSpaceInTheDestinationIsIgnored() async throws {
        let listener = try LoopbackListener()

        try await WakeOnLAN.send(
            Data("wake".utf8), to: " 127.0.0.1\n", port: listener.port,
            repetitions: 2, interval: .milliseconds(1))

        #expect(await listener.receive(2) == [Data("wake".utf8), Data("wake".utf8)])
    }

    @Test func cancellingStopsTheRepeats() async throws {
        let listener = try LoopbackListener()
        let port = listener.port
        let waking = Task {
            try await WakeOnLAN.send(
                Data("wake".utf8), to: "127.0.0.1", port: port,
                repetitions: 3, interval: .seconds(120))
        }

        // The first packet goes out at once; the task then waits two minutes
        // for the second.
        var received = await listener.receive(1)
        waking.cancel()

        await #expect(throws: CancellationError.self) {
            try await waking.value
        }
        received += await listener.receive(0)
        #expect(received == [Data("wake".utf8)])
    }

    @Test(arguments: [
        "", "broadcast", "studio.local", "192.168.1", "192.168.1.256", "192.168.1.255.1",
        "192.168.1.255:9", "::1", "fe80::1", "ff02::1",
    ])
    func aDestinationThatIsNotAnIPv4AddressIsRejected(destination: String) async {
        await #expect(throws: WakeOnLANError.invalidBroadcastAddress(destination)) {
            try await WakeOnLAN.wake(address, broadcastAddress: destination)
        }
    }

    @Test func aPacketTheNetworkWillNotTakeIsReportedWithItsErrorCode() async throws {
        // Larger than any UDP datagram can be.
        let oversized = Data(count: 70_000)

        await #expect(throws: WakeOnLANError.sendFailed(code: EMSGSIZE)) {
            try await WakeOnLAN.send(
                oversized, to: "127.0.0.1", port: 9, repetitions: 1, interval: .zero)
        }
    }

    @Test func theFirstPacketHasToGoOutButARepeatMayFail() async throws {
        struct Refused: Error {}

        // Fails on the second and third attempt: the wake-up was sent.
        var attempts = 0
        try await WakeOnLAN.repeatedly(3, every: .milliseconds(1)) {
            attempts += 1
            if attempts > 1 { throw Refused() }
        }
        #expect(attempts == 3)

        // Fails straight away: nothing was sent, and there is no point in
        // waiting to say so.
        attempts = 0
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: Refused.self) {
            try await WakeOnLAN.repeatedly(3, every: .seconds(30)) {
                attempts += 1
                throw Refused()
            }
        }
        #expect(attempts == 1)
        #expect(clock.now - started < .seconds(10))

        // Asking for no repetitions at all still sends once.
        attempts = 0
        try await WakeOnLAN.repeatedly(0, every: .seconds(30)) { attempts += 1 }
        #expect(attempts == 1)
    }

    @Test func errorsExplainThemselves() {
        let invalid = WakeOnLANError.invalidBroadcastAddress("studio.local")
        #expect(invalid.localizedDescription.contains("studio.local"))

        for error in [WakeOnLANError.socketFailed(code: EMFILE), .sendFailed(code: EHOSTUNREACH)] {
            let description = error.localizedDescription
            #expect(description.contains("wake-up packet"))
            // The system's own explanation is included, not just a number.
            #expect(description.contains("("))
        }
        #expect(WakeOnLANError.sendFailed(code: EHOSTUNREACH).localizedDescription
            != WakeOnLANError.sendFailed(code: ENETDOWN).localizedDescription)
        #expect(WakeOnLANError.sendFailed(code: 1) != WakeOnLANError.socketFailed(code: 1))
    }

    @Test func broadcastInterfacesAreRealInterfacesListedOnce() {
        let interfaces = WakeOnLAN.broadcastInterfaces()

        #expect(Set(interfaces).count == interfaces.count)
        #expect(!interfaces.contains(0))
        // The loopback interface cannot broadcast and never qualifies.
        let loopback = if_nametoindex("lo0")
        #expect(loopback == 0 || !interfaces.contains(loopback))
        for index in interfaces {
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            #expect(if_indextoname(index, &name) != nil)
        }
    }
}

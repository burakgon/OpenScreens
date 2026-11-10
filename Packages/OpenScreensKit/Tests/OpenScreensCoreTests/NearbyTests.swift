import Foundation
import Network
import Testing
import dnssd
@testable import OpenScreensCore

// Everything here exercises the pure parts of nearby discovery with made-up
// records. Nothing touches the network or depends on what is on it.

@Suite struct NearbyComputerTests {

    // MARK: Identifier

    @Test func identifierJoinsNameTypeAndDomain() {
        #expect(NearbyComputer.makeID(name: "Studio") == "Studio._rfb._tcp.local.")
        #expect(
            NearbyComputer.makeID(name: "Studio", type: "_rfb._tcp", domain: "local.")
                == "Studio._rfb._tcp.local.")
    }

    @Test(arguments: [
        ("_rfb._tcp", "local."),
        ("_rfb._tcp.", "local."),
        ("_RFB._TCP", "LOCAL."),
        ("_rfb._tcp", "local"),
        ("_rfb._tcp", ""),
    ])
    func identifierIsTheSameHoweverTypeAndDomainAreSpelled(type: String, domain: String) {
        #expect(
            NearbyComputer.makeID(name: "Studio", type: type, domain: domain)
                == "Studio._rfb._tcp.local.")
    }

    @Test func identifierKeepsTheNameAsAdvertised() {
        #expect(
            NearbyComputer.makeID(name: "Ada’s MacBook Pro")
                == "Ada’s MacBook Pro._rfb._tcp.local.")
        #expect(NearbyComputer.makeID(name: "Lab.Mac (2)") == "Lab.Mac (2)._rfb._tcp.local.")
    }

    @Test func identifiersTellServicesApart() {
        let studio = NearbyComputer.makeID(name: "Studio")
        #expect(studio != NearbyComputer.makeID(name: "Studio (2)"))
        #expect(studio != NearbyComputer.makeID(name: "Studio", type: "_ssh._tcp"))
        #expect(studio != NearbyComputer.makeID(name: "Studio", domain: "example.com."))
    }

    @Test func initialiserDerivesTheIdentifierAndDefaults() {
        let computer = NearbyComputer(name: "Studio")
        #expect(computer.id == "Studio._rfb._tcp.local.")
        #expect(computer.host == nil)
        #expect(computer.port == 5900)
        #expect(computer.kind == .other)
        #expect(computer.model == nil)
        #expect(!computer.supportsSSH)

        #expect(NearbyComputer(id: "custom", name: "Studio").id == "custom")
    }

    // MARK: Host normalisation

    @Test(arguments: [
        ("Studio.local.", "Studio.local"),
        ("Studio.local", "Studio.local"),
        ("  Studio.local.\n", "Studio.local"),
        ("studio.example.com.", "studio.example.com"),
        // DNS presentation escapes: a decimal byte, and a literal character.
        ("Lab\\032Mac.local.", "Lab Mac.local"),
        ("Lab\\.Mac.local.", "Lab.Mac.local"),
        ("Caf\\195\\169.local.", "Café.local"),
        // An escaped final dot belongs to the name; it is not the root.
        ("odd\\.", "odd."),
    ])
    func hostIsNormalised(target: String, expected: String) {
        #expect(NearbyComputer.normalizedHost(target) == expected)
    }

    @Test(arguments: ["", ".", "   "])
    func emptyHostTargetsAreNoHost(target: String) {
        #expect(NearbyComputer.normalizedHost(target) == nil)
    }

    /// Whoever advertises a service chooses the host it points at, and can
    /// put any byte into it. A NUL ends the name for the system's resolver,
    /// so what would be shown and saved is not what would be looked up.
    @Test(arguments: [
        "studio\\000.evil.example.com.", "studio\\000", "\\000studio.local.",
        "studio\\010second-line.local.", "studio\\013.local.", "stu\\009dio.local.",
        "studio\\027[2J.local.", "studio\\031.local.", "studio\\127.local.",
        "stu\u{0}dio.local.", "stu\tdio.local.", "stu\ndio.local.", "stu\u{1B}dio.local.",
        "stu\u{7F}dio.local.",
    ])
    func hostTargetsWithControlCharactersAreNoHost(target: String) {
        #expect(NearbyComputer.normalizedHost(target) == nil)
    }

    @Test func aHostThatIsNoHostLeavesTheComputerUnresolved() throws {
        var records = NearbyRecords()
        records.insert(NearbyRecords.ScreenSharingService(
            name: "Studio", host: NearbyComputer.normalizedHost("studio\\000.evil.example.com."),
            port: 5900))
        let studio = try #require(records.computers().first)
        #expect(studio.name == "Studio")
        #expect(studio.host == nil)
    }

    @Test(arguments: [
        ("Studio.local", "studio"),
        ("Studio.local.", "studio"),
        ("STUDIO.LOCAL", "studio"),
        ("studio", "studio"),
        (" Studio.local ", "studio"),
        ("studio.example.com", "studio.example.com"),
        ("Studio-2.local", "studio-2"),
    ])
    func hostsAreComparedWithoutCaseDotOrLocalSuffix(host: String, key: String) {
        #expect(NearbyComputer.hostKey(host) == key)
    }

    // MARK: Kind

    @Test(arguments: [
        "Mac16,1", "Mac13,2", "MacBookPro18,3", "MacBookAir10,1", "MacBook10,1", "Macmini9,1",
        "MacPro7,1", "MacStudio", "iMac21,1", "iMacPro1,1", "VirtualMac2,1", "Xserve3,1",
        "RackMac3,1", "PowerMac11,2", "PowerBook6,8", "macmini", " Mac16,1 ",
    ])
    func macModelFamiliesMeanAMac(model: String) {
        #expect(NearbyComputer.isMacModel(model))
        #expect(
            NearbyComputer.guessKind(
                name: "Server", host: "server.local", evidence: NearbyEvidence(model: model))
                == .mac)
    }

    @Test(arguments: ["AppleTV14,1", "iPad13,4", "iPhone17,1", "TimeCapsule8,119", "AirPort7,120", ""])
    func otherModelsDoNot(model: String) {
        #expect(!NearbyComputer.isMacModel(model))
        #expect(
            NearbyComputer.guessKind(
                name: "Box", host: "box.local", evidence: NearbyEvidence(model: model))
                == .other)
    }

    @Test func aStatedMacOSVersionMeansAMacWhateverTheModel() {
        let unknownModel = NearbyEvidence(model: "Future1,1", reportsMacOSVersion: true)
        #expect(NearbyComputer.guessKind(name: "X", host: nil, evidence: unknownModel) == .mac)

        let noModel = NearbyEvidence(reportsMacOSVersion: true)
        #expect(NearbyComputer.guessKind(name: "X", host: nil, evidence: noModel) == .mac)
    }

    @Test(arguments: [
        ("raspberrypi", nil),
        ("Raspberry Pi 5", nil),
        ("Kitchen", "raspberrypi.local"),
        ("Kitchen", "raspi-kitchen.local"),
        ("rpi4", nil),
        ("my-rpi", nil),
        ("RPi 5 (desk)", nil),
        ("Display", "rpi.local"),
    ] as [(String, String?)])
    func namesThatSayRaspberryPiMeanOne(name: String, host: String?) {
        #expect(
            NearbyComputer.guessKind(name: name, host: host, evidence: NearbyEvidence())
                == .raspberryPi)
    }

    @Test(arguments: [
        ("pi", "pi.local"),
        ("pihole", "pihole.local"),
        ("serpico", "serpico.local"),
        ("Spirit", "sharpie.local"),
        ("Workstation", nil),
    ] as [(String, String?)])
    func namesThatOnlyHintAtItDoNot(name: String, host: String?) {
        #expect(
            NearbyComputer.guessKind(name: name, host: host, evidence: NearbyEvidence())
                == .other)
    }

    @Test func aMacNamedAfterARaspberryPiIsStillAMac() {
        let evidence = NearbyEvidence(model: "Macmini9,1", reportsMacOSVersion: true)
        #expect(
            NearbyComputer.guessKind(name: "raspberrypi", host: "raspberrypi.local", evidence: evidence)
                == .mac)
    }

    @Test func macStyleRemoteLoginMeansAMacWhenThereIsNoModel() {
        let both = NearbyEvidence(advertisesSSH: true, advertisesSFTP: true)
        #expect(NearbyComputer.guessKind(name: "Studio", host: "studio.local", evidence: both) == .mac)

        // Either one alone is what any SSH server might advertise.
        let sshOnly = NearbyEvidence(advertisesSSH: true)
        #expect(NearbyComputer.guessKind(name: "Studio", host: nil, evidence: sshOnly) == .other)
        let sftpOnly = NearbyEvidence(advertisesSFTP: true)
        #expect(NearbyComputer.guessKind(name: "Studio", host: nil, evidence: sftpOnly) == .other)
    }

    @Test func aModelThatIsNotAMacIsNotOverruledByRemoteLogin() {
        let evidence = NearbyEvidence(
            model: "TimeCapsule8,119", advertisesSSH: true, advertisesSFTP: true)
        #expect(NearbyComputer.guessKind(name: "Backup", host: nil, evidence: evidence) == .other)
    }

    @Test func aRaspberryPiWithRemoteLoginIsStillARaspberryPi() {
        let evidence = NearbyEvidence(advertisesSSH: true, advertisesSFTP: true)
        #expect(
            NearbyComputer.guessKind(name: "raspberrypi", host: "raspberrypi.local", evidence: evidence)
                == .raspberryPi)
    }

    @Test func withNothingToGoOnTheKindIsOther() {
        #expect(
            NearbyComputer.guessKind(name: "Workstation", host: "ws.local", evidence: NearbyEvidence())
                == .other)
    }
}

@Suite struct NearbyRecordsTests {
    typealias Service = NearbyRecords.ScreenSharingService

    private func records(_ services: Service...) -> NearbyRecords {
        var records = NearbyRecords()
        services.forEach { records.insert($0) }
        return records
    }

    // MARK: Merging

    @Test func aServiceIsListedBeforeItIsResolved() throws {
        let computers = records(Service(name: "Studio")).computers()
        let studio = try #require(computers.first)
        #expect(computers.count == 1)
        #expect(studio.id == "Studio._rfb._tcp.local.")
        #expect(studio.name == "Studio")
        #expect(studio.host == nil)
        #expect(studio.port == 5900)
        #expect(studio.kind == .other)
        #expect(studio.model == nil)
        #expect(!studio.supportsSSH)
    }

    @Test func resolvedHostAndPortAreCarriedOver() throws {
        let computers = records(Service(name: "Studio", host: "Studio.local", port: 5901)).computers()
        let studio = try #require(computers.first)
        #expect(studio.host == "Studio.local")
        #expect(studio.port == 5901)
    }

    @Test func lookedUpDeviceInfoSuppliesModelAndKind() throws {
        let info = BonjourDeviceInfo(model: "Mac16,1", reportsMacOSVersion: true)
        let computers = records(Service(name: "Studio", deviceInfo: info)).computers()
        let studio = try #require(computers.first)
        #expect(studio.model == "Mac16,1")
        #expect(studio.kind == .mac)
    }

    @Test func advertisedDeviceInfoIsMatchedByServiceNameWithoutRegardToCase() throws {
        var records = records(Service(name: "Media Server"))
        records.advertisedDeviceInfo = [
            NearbyRecords.nameKey("MEDIA SERVER"): BonjourDeviceInfo(model: "Macmini9,1")
        ]
        let server = try #require(records.computers().first)
        #expect(server.model == "Macmini9,1")
        #expect(server.kind == .mac)
    }

    @Test func advertisedDeviceInfoIsMatchedByHostLabel() throws {
        // Avahi names its device-info after the host, not after the VNC server.
        var records = records(Service(name: "VNC on media", host: "Media.local", port: 5900))
        records.advertisedDeviceInfo = ["media": BonjourDeviceInfo(model: "RackMac")]
        let server = try #require(records.computers().first)
        #expect(server.model == "RackMac")
        #expect(server.kind == .mac)
    }

    @Test func lookedUpDeviceInfoWinsOverAdvertised() throws {
        var records = records(
            Service(name: "Studio", deviceInfo: BonjourDeviceInfo(model: "Mac16,1")))
        records.advertisedDeviceInfo = ["studio": BonjourDeviceInfo(model: "Xserve")]
        #expect(try #require(records.computers().first).model == "Mac16,1")
    }

    @Test func sshUnderTheServiceNameMeansSSH() throws {
        var bySSH = records(Service(name: "Studio"))
        bySSH.sshNames = ["studio"]
        #expect(try #require(bySSH.computers().first).supportsSSH)

        var bySFTP = records(Service(name: "Studio"))
        bySFTP.sftpNames = ["studio"]
        #expect(try #require(bySFTP.computers().first).supportsSSH)
    }

    @Test func sshUnderTheHostLabelMeansSSH() throws {
        var records = records(Service(name: "desk:0", host: "Atlas.local", port: 5900))
        records.sshNames = ["atlas"]
        let computer = try #require(records.computers().first)
        #expect(computer.supportsSSH)
        // Not advertised the way macOS does it, so no reason to call it a Mac.
        #expect(computer.kind == .other)
    }

    @Test func recordsOfOtherComputersAreNotMixedIn() throws {
        var records = records(
            Service(name: "Studio", host: "Studio.local", port: 5900),
            Service(name: "Atlas", host: "Atlas.local", port: 5900))
        records.sshNames = ["studio"]
        records.sftpNames = ["studio"]
        records.advertisedDeviceInfo = ["studio": BonjourDeviceInfo(model: "Mac16,1")]

        let computers = records.computers()
        let atlas = try #require(computers.first { $0.name == "Atlas" })
        let studio = try #require(computers.first { $0.name == "Studio" })
        #expect(!atlas.supportsSSH)
        #expect(atlas.model == nil)
        #expect(atlas.kind == .other)
        #expect(studio.supportsSSH)
        #expect(studio.model == "Mac16,1")
        #expect(studio.kind == .mac)
    }

    @Test func remoteLoginUnderTheServiceNameSuggestsAMac() throws {
        var records = records(Service(name: "Studio"))
        records.sshNames = ["studio"]
        records.sftpNames = ["studio"]
        #expect(try #require(records.computers().first).kind == .mac)
    }

    @Test func aRaspberryPiIsRecognisedByItsHost() throws {
        let computers = records(
            Service(name: "Kitchen display", host: "raspberrypi.local", port: 5900)).computers()
        #expect(try #require(computers.first).kind == .raspberryPi)
    }

    @Test func computersAreInNameOrderWhateverOrderTheyWereFoundIn() {
        // Chosen so that only the order Finder would use comes out this way:
        // case does not matter, and 2 sorts before 10.
        let names = ["Mini 10", "atlas", "mini 2", "Studio", "Büro"]
        let orders = [names, Array(names.reversed()), [names[2], names[4], names[0], names[3], names[1]]]
        for shuffled in orders {
            var records = NearbyRecords()
            shuffled.forEach { records.insert(Service(name: $0)) }
            #expect(
                records.computers().map(\.name) == ["atlas", "Büro", "mini 2", "Mini 10", "Studio"])
        }
    }

    @Test func servicesOfTheSameNameInDifferentDomainsAreSeparateAndOrderedByIdentifier() {
        let computers = records(
            Service(name: "Studio", domain: "local."),
            Service(name: "Studio", domain: "example.com.")).computers()
        #expect(computers.map(\.id) == ["Studio._rfb._tcp.example.com.", "Studio._rfb._tcp.local."])
    }

    // MARK: Leaving out this device

    @Test func thisDeviceIsLeftOutOnceItsHostIsKnown() {
        let local = NearbyLocalIdentity(hostNames: ["Studio.local"])
        let computers = records(
            Service(name: "Studio", host: "studio.local", port: 5900),
            Service(name: "Atlas", host: "Atlas.local", port: 5900)
        ).computers(excluding: local)
        #expect(computers.map(\.name) == ["Atlas"])
    }

    @Test func thisDeviceIsLeftOutByNameBeforeItResolves() {
        let local = NearbyLocalIdentity(hostNames: ["Studio.local"], serviceNames: ["Ada’s Studio"])
        let computers = records(Service(name: "ada’s studio"), Service(name: "Atlas"))
            .computers(excluding: local)
        #expect(computers.map(\.name) == ["Atlas"])
    }
}

@Suite struct NearbyLocalIdentityTests {
    @Test(arguments: ["Studio.local", "studio.local.", "STUDIO.LOCAL", "studio", "Studio"])
    func theHostIsMatchedWithoutCaseDotOrLocalSuffix(host: String) {
        let local = NearbyLocalIdentity(hostNames: ["Studio.local"])
        #expect(local.isThisDevice(serviceName: "Anything", host: host))
    }

    @Test(arguments: ["Studio-2.local", "studio.example.com", "atlas.local"])
    func otherHostsAreNotThisDevice(host: String) {
        let local = NearbyLocalIdentity(hostNames: ["Studio.local"], serviceNames: ["Studio"])
        // The resolved host settles it, even when the service name is ours.
        #expect(!local.isThisDevice(serviceName: "Studio", host: host))
    }

    @Test func everyKnownHostNameCounts() {
        // A Mac's DNS name and its Bonjour name can differ.
        let local = NearbyLocalIdentity(hostNames: ["studio.corp.example.com", "Studio"])
        #expect(local.isThisDevice(serviceName: "x", host: "Studio.local."))
        #expect(local.isThisDevice(serviceName: "x", host: "studio.corp.example.com"))
        #expect(!local.isThisDevice(serviceName: "x", host: "corp.example.com"))
    }

    @Test func beforeResolvingTheServiceNameIsCompared() {
        let local = NearbyLocalIdentity(hostNames: ["Studio.local"], serviceNames: ["Ada’s Studio"])
        #expect(local.isThisDevice(serviceName: "Ada’s Studio", host: nil))
        #expect(local.isThisDevice(serviceName: "ADA’S STUDIO", host: nil))
        #expect(!local.isThisDevice(serviceName: "Studio", host: nil))
        #expect(!local.isThisDevice(serviceName: "Ada’s Studio (2)", host: nil))
    }

    @Test func namesThatIdentifyNothingAreIgnored() {
        let local = NearbyLocalIdentity(hostNames: ["localhost", "", "  ", "localhost.local"], serviceNames: [""])
        #expect(local.hostKeys.isEmpty)
        #expect(local.serviceNameKeys.isEmpty)
        #expect(!local.isThisDevice(serviceName: "", host: nil))
        // A machine that really is called localhost.local is someone else.
        #expect(!local.isThisDevice(serviceName: "x", host: "localhost.local"))
        #expect(!local.isThisDevice(serviceName: "x", host: "localhost.local."))
    }

    @Test(arguments: ["localhost", "localhost.", "LOCALHOST", " localhost "])
    func aServiceThatResolvesToLocalhostIsAlwaysThisDevice(host: String) {
        // Services registered for use on this device only resolve like this.
        #expect(NearbyLocalIdentity().isThisDevice(serviceName: "Simulator", host: host))
        #expect(
            NearbyLocalIdentity(hostNames: ["Studio.local"]).isThisDevice(serviceName: "Simulator", host: host))
    }

    @Test func anEmptyIdentityExcludesNothing() {
        let local = NearbyLocalIdentity()
        #expect(!local.isThisDevice(serviceName: "Studio", host: "Studio.local"))
        #expect(!local.isThisDevice(serviceName: "Studio", host: nil))
    }

    @Test func theNamesOfThisMachineAreUsable() {
        // Whatever this machine is called, the keys must be in comparison form.
        let local = NearbyLocalIdentity.current()
        for key in local.hostKeys {
            #expect(!key.isEmpty)
            #expect(key == NearbyComputer.hostKey(key))
            #expect(key != "localhost")
        }
        for key in local.serviceNameKeys {
            #expect(!key.isEmpty)
            #expect(key == key.lowercased())
        }
    }
}

@Suite struct NearbyBonjourRecordTests {
    /// Builds TXT record data: each string prefixed with its length.
    private func txt(_ strings: [String]) -> Data {
        var data = Data()
        for string in strings {
            let bytes = Array(string.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    @Test func txtRecordIsSplitIntoEntries() {
        let entries = BonjourTXT.entries(in: txt(["model=Mac16,1", "osxvers=25", "icolor=0"]))
        #expect(entries == ["model": "Mac16,1", "osxvers": "25", "icolor": "0"])
    }

    @Test func txtKeysAreLowercasedAndValuesKeptAsTheyAre() {
        let entries = BonjourTXT.entries(in: txt(["Model=MacPro7,1", "Note=a=b"]))
        #expect(entries == ["model": "MacPro7,1", "note": "a=b"])
    }

    @Test func txtHandlesTheUnusualForms() {
        let entries = BonjourTXT.entries(in: txt([
            "flag",        // present without a value
            "empty=",      // present with an empty value
            "=nokey",      // no key: ignored
            "",            // empty string: ignored
            "dup=first",
            "dup=second",  // repeated key: the first wins
        ]))
        #expect(entries == ["flag": "", "empty": "", "dup": "first"])
    }

    @Test func txtCutShortKeepsWhatCameBefore() {
        var data = txt(["model=Mac16,1"])
        data.append(20)  // claims 20 bytes, but only 4 follow…
        data.append(txt(["a=b"]))  // …which would read as an entry of their own
        #expect(BonjourTXT.entries(in: data) == ["model": "Mac16,1"])
        #expect(BonjourTXT.entries(in: Data()).isEmpty)
    }

    @Test func txtIsReadFromASliceOfLargerData() {
        // Record data often arrives as a slice whose indices do not start at 0.
        let padded = Data([0xFF, 0xFF]) + txt(["model=Mac16,1"])
        #expect(BonjourTXT.entries(in: padded.dropFirst(2)) == ["model": "Mac16,1"])
    }

    @Test func deviceInfoReadsModelAndMacOSVersion() {
        let mac = BonjourDeviceInfo(txt: ["model": "Mac16,1", "osxvers": "25", "icolor": "0"])
        #expect(mac == BonjourDeviceInfo(model: "Mac16,1", reportsMacOSVersion: true))

        let server = BonjourDeviceInfo(txt: ["MODEL": "RackMac"])
        #expect(server == BonjourDeviceInfo(model: "RackMac", reportsMacOSVersion: false))
    }

    @Test func deviceInfoDropsDisplayHintsAndBlankModels() {
        #expect(BonjourDeviceInfo(txt: ["model": "MacPro7,1@ECOLOR=226,226,224"]).model == "MacPro7,1")
        #expect(BonjourDeviceInfo(txt: ["model": "  "]).model == nil)
        #expect(BonjourDeviceInfo(txt: ["model": "@ECOLOR=1,2,3"]).model == nil)
        #expect(BonjourDeviceInfo(txt: [:]) == BonjourDeviceInfo())
    }

    @Test func fullNamesEscapeWhatAServiceNameMayContain() {
        #expect(
            DNSServiceConnection.fullName(
                service: "Studio", type: "_device-info._tcp", domain: "local.")
                == "Studio._device-info._tcp.local.")
        #expect(
            DNSServiceConnection.fullName(
                service: "Lab Mac.2", type: "_device-info._tcp", domain: "local.")
                == "Lab\\032Mac\\.2._device-info._tcp.local.")
    }
}

@Suite struct NearbyBrowserTests {
    typealias Status = NearbyEngine.Status

    @Test func aPolicyDenialIsReportedAsDenied() {
        let denied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        #expect(Status.problem(denied) == .denied)
    }

    @Test func otherErrorsAreFailuresWithAMessage() {
        let undeclared = Status.problem(.dns(DNSServiceErrorType(kDNSServiceErr_NoAuth)))
        guard case .failed(let undeclaredMessage) = undeclared else {
            Issue.record("expected a failure, got \(undeclared)")
            return
        }
        #expect(undeclaredMessage.contains("NSBonjourServices"))

        let unknown = Status.problem(.dns(DNSServiceErrorType(kDNSServiceErr_Unknown)))
        #expect(unknown == .failed("Looking for nearby computers failed (DNS-SD error -65537)."))

        guard case .failed(let networkMessage) = Status.problem(.posix(.ENETDOWN)) else {
            Issue.record("expected a failure for a POSIX error")
            return
        }
        #expect(!networkMessage.isEmpty)
    }

    @Test func onlyLosingTheDaemonEndsBrowsing() {
        #expect(Status.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)))
        #expect(Status.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_DefunctConnection)))
        #expect(!Status.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)))
        #expect(!Status.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_Timeout)))
        #expect(!Status.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
    }

    // MARK: What has been reported

    @Test func aStatusAndAListAreReportedOnce() {
        var reports = NearbyReports()
        func status(_ status: Status) -> NearbyReports.Consequence? { reports.note(status) }
        func list(_ computers: [NearbyComputer]) -> Bool { reports.note(computers) }
        let atlas = NearbyComputer(name: "Atlas"), studio = NearbyComputer(name: "Studio")

        #expect(status(.searching) == .listStands)
        #expect(status(.searching) == nil)
        // An empty list is what the listener starts with.
        #expect(!list([]))
        #expect(list([atlas]))
        #expect(!list([atlas]))
        #expect(list([atlas, studio]))
        #expect(list([]))
        #expect(status(.failed("broken")) == .listStands)
        #expect(status(.failed("broken")) == nil)
        #expect(status(.failed("broken differently")) == .listStands)
    }

    /// The listener empties its list when it hears that access is denied.
    /// If browsing then picks up with the very computers it had, the list
    /// has not changed — and still has to be published, or the listener is
    /// left with nothing to show.
    @Test func afterADenialTheSameListIsReportedAgain() {
        var reports = NearbyReports()
        func status(_ status: Status) -> NearbyReports.Consequence? { reports.note(status) }
        func list(_ computers: [NearbyComputer]) -> Bool { reports.note(computers) }
        let atlas = NearbyComputer(name: "Atlas")
        #expect(status(.searching) == .listStands)
        #expect(list([atlas]))

        #expect(status(.denied) == .listStands)
        #expect(status(.denied) == nil)
        // Access is granted, and nothing about the network has changed.
        #expect(status(.searching) == .listIsDueAgain)
        #expect(list([atlas]))
        #expect(!list([atlas]))

        // Nothing is published when there is nothing to list.
        #expect(status(.denied) == .listStands)
        #expect(status(.searching) == .listIsDueAgain)
        #expect(!list([]))
        // A failure after a denial calls for the list as well.
        #expect(status(.denied) == .listStands)
        #expect(status(.failed("broken")) == .listIsDueAgain)
    }

    @Test func theServiceTypesBrowsedAreTheDocumentedOnes() {
        // What the app's Info.plist has to declare under NSBonjourServices.
        #expect(
            NearbyBrowser.bonjourServiceTypes
                == ["_rfb._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_device-info._tcp"])
        #expect(BonjourServiceType.allCases.map(\.rawValue) == NearbyBrowser.bonjourServiceTypes)
    }

    @MainActor
    @Test func aBrowserStartsIdleAndStoppingItIsHarmless() {
        let browser = NearbyBrowser()
        #expect(browser.state == .idle)
        #expect(browser.computers.isEmpty)
        browser.stop()
        browser.stop()
        #expect(browser.state == .idle)
        #expect(browser.computers.isEmpty)
    }
}

// MARK: - The browser's own behaviour, with the Bonjour work scripted

/// Stands in for the Bonjour engine: the test decides what it reports.
private final class FakeNearbySearch: NearbySearch, @unchecked Sendable {
    let events: AsyncStream<NearbyEngine.Event>
    private let continuation: AsyncStream<NearbyEngine.Event>.Continuation
    private let lock = NSLock()
    private var starts = 0
    private var shutdowns = 0

    init() {
        (events, continuation) = AsyncStream.makeStream(of: NearbyEngine.Event.self)
    }

    var startCount: Int { lock.withLock { starts } }
    var isShutDown: Bool { lock.withLock { shutdowns > 0 } }

    func start() {
        lock.withLock { starts += 1 }
    }

    func shutdown() {
        lock.withLock { shutdowns += 1 }
        continuation.finish()
    }

    func send(_ event: NearbyEngine.Event) {
        continuation.yield(event)
    }

    /// What the real engine does when it cannot go on: say why, then end.
    func fail(_ message: String) {
        continuation.yield(.status(.failed(message)))
        continuation.finish()
    }
}

@MainActor
private final class FakeNearbySearchFactory {
    private(set) var searches: [FakeNearbySearch] = []

    func make() -> any NearbySearch {
        let search = FakeNearbySearch()
        searches.append(search)
        return search
    }
}

@MainActor
@Suite struct NearbyBrowserSessionTests {
    private let factory = FakeNearbySearchFactory()

    private func makeBrowser(
        firstRetryDelay: Duration = .milliseconds(50),
        longestRetryDelay: Duration = .milliseconds(400)
    ) -> NearbyBrowser {
        NearbyBrowser(
            makeSearch: { [factory] in factory.make() },
            firstRetryDelay: firstRetryDelay,
            longestRetryDelay: longestRetryDelay)
    }

    /// Waits, briefly, for something the browser does a moment later.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private let atlas = NearbyComputer(name: "Atlas")
    private let studio = NearbyComputer(
        name: "Studio", host: "Studio.local", kind: .mac, model: "Mac16,1", supportsSSH: true)

    @Test func startingBeginsOneSearchHoweverOftenItIsAsked() {
        let browser = makeBrowser()
        browser.start()
        #expect(browser.state == .searching)
        #expect(factory.searches.count == 1)
        #expect(factory.searches[0].startCount == 1)

        browser.start()
        browser.start()
        #expect(factory.searches.count == 1)
        #expect(factory.searches[0].startCount == 1)
        #expect(!factory.searches[0].isShutDown)
    }

    @Test func computersArePublishedAsTheSearchReportsThem() async {
        let browser = makeBrowser()
        browser.start()
        factory.searches[0].send(.computers([atlas, studio]))
        #expect(await eventually { browser.computers == [atlas, studio] })
        #expect(browser.state == .searching)

        factory.searches[0].send(.computers([studio]))
        #expect(await eventually { browser.computers == [studio] })
    }

    @Test func aDenialEmptiesTheListUntilSearchingResumes() async {
        let browser = makeBrowser()
        browser.start()
        let search = factory.searches[0]
        search.send(.computers([atlas]))
        #expect(await eventually { browser.computers == [atlas] })

        search.send(.status(.denied))
        #expect(await eventually { browser.state == .denied })
        #expect(browser.computers.isEmpty)
        // The same search is left waiting; it picks up by itself when access is granted.
        #expect(!search.isShutDown)

        search.send(.status(.searching))
        search.send(.computers([atlas]))
        #expect(await eventually { browser.state == .searching && browser.computers == [atlas] })
        #expect(factory.searches.count == 1)
    }

    @Test func startingAgainAfterADenialMakesAFreshAttempt() async {
        let browser = makeBrowser()
        browser.start()
        factory.searches[0].send(.status(.denied))
        #expect(await eventually { browser.state == .denied })

        browser.start()
        #expect(browser.state == .searching)
        #expect(factory.searches.count == 2)
        #expect(factory.searches[0].isShutDown)
        #expect(factory.searches[1].startCount == 1)
    }

    @Test func aFailureIsShownAndThenRetried() async {
        let browser = makeBrowser(firstRetryDelay: .milliseconds(300), longestRetryDelay: .seconds(5))
        browser.start()
        factory.searches[0].send(.computers([atlas]))
        #expect(await eventually { browser.computers == [atlas] })

        factory.searches[0].fail("The system's Bonjour service is not running.")
        #expect(await eventually {
            browser.state == .failed("The system's Bonjour service is not running.")
        })
        #expect(browser.computers.isEmpty)
        #expect(factory.searches.count == 1)

        #expect(await eventually { factory.searches.count == 2 })
        #expect(browser.state == .searching)
        #expect(factory.searches[1].startCount == 1)
    }

    @Test func failuresThatKeepComingAreRetriedMoreSlowly() async {
        let browser = makeBrowser(firstRetryDelay: .milliseconds(20), longestRetryDelay: .seconds(60))
        browser.start()
        #expect(browser.retryDelay == .milliseconds(20))

        var expected: Duration = .milliseconds(20)
        for attempt in 0..<4 {
            factory.searches[attempt].fail("still broken")
            #expect(await eventually { factory.searches.count == attempt + 2 })
            expected *= 2
            #expect(browser.retryDelay == expected)
        }
    }

    @Test func theWaitBetweenRetriesHasACeiling() async {
        let browser = makeBrowser(firstRetryDelay: .milliseconds(20), longestRetryDelay: .milliseconds(30))
        browser.start()
        factory.searches[0].fail("still broken")
        #expect(await eventually { factory.searches.count == 2 })
        #expect(browser.retryDelay == .milliseconds(30))
    }

    @Test func aSearchThatWorkedForAWhileIsRetriedQuicklyAgain() async throws {
        let browser = makeBrowser(firstRetryDelay: .milliseconds(20), longestRetryDelay: .milliseconds(100))
        browser.start()
        factory.searches[0].fail("broken")
        #expect(await eventually { factory.searches.count == 2 })
        #expect(browser.retryDelay == .milliseconds(40))

        // The second search runs for longer than the longest wait before it
        // fails, so the waits start over instead of growing to 80 ms.
        try await Task.sleep(for: .milliseconds(200))
        factory.searches[1].fail("broken again")
        #expect(await eventually { factory.searches.count == 3 })
        #expect(browser.retryDelay == .milliseconds(40))
    }

    @Test func startingAfterAFailureDoesNotWaitForTheRetry() async throws {
        let browser = makeBrowser(firstRetryDelay: .milliseconds(300), longestRetryDelay: .seconds(5))
        browser.start()
        factory.searches[0].fail("broken")
        #expect(await eventually { browser.state == .failed("broken") })

        #expect(browser.retryDelay == .milliseconds(600))
        browser.start()
        #expect(browser.state == .searching)
        #expect(factory.searches.count == 2)
        // Being asked to start is a fresh start for the waits as well.
        #expect(browser.retryDelay == .milliseconds(300))
        // The retry that was pending has been called off.
        try await Task.sleep(for: .milliseconds(600))
        #expect(factory.searches.count == 2)
    }

    @Test func stoppingCallsOffAPendingRetry() async throws {
        let browser = makeBrowser(firstRetryDelay: .milliseconds(200), longestRetryDelay: .seconds(5))
        browser.start()
        factory.searches[0].fail("broken")
        #expect(await eventually { browser.state == .failed("broken") })

        browser.stop()
        #expect(browser.state == .idle)
        try await Task.sleep(for: .milliseconds(500))
        #expect(factory.searches.count == 1)
        #expect(browser.state == .idle)
    }

    @Test func stoppingEndsTheSearchAndEmptiesTheList() async throws {
        let browser = makeBrowser()
        browser.start()
        let search = factory.searches[0]
        search.send(.computers([atlas]))
        #expect(await eventually { browser.computers == [atlas] })

        // Something still on its way when the browser is stopped is dropped.
        search.send(.computers([atlas, studio]))
        browser.stop()
        #expect(search.isShutDown)
        #expect(browser.state == .idle)
        #expect(browser.computers.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.computers.isEmpty)
        #expect(browser.state == .idle)

        // And it can be started again.
        browser.start()
        #expect(browser.state == .searching)
        #expect(factory.searches.count == 2)
    }

    @Test func aBrowserThatIsLetGoEndsItsSearch() {
        var browser: NearbyBrowser? = makeBrowser()
        browser?.start()
        let search = factory.searches[0]
        #expect(!search.isShutDown)

        browser = nil
        #expect(search.isShutDown)
    }
}

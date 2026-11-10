import Foundation
import Testing
@testable import OpenScreensCore

// Every name, address and identifier in the Tailscale tests is made up.

@Suite struct TailscaleDeviceTests {

    private func device(os: String) -> TailscaleDevice {
        TailscaleDevice(id: "nTEST0000CNTRL", name: "test", os: os)
    }

    // MARK: Kind and control

    @Test(arguments: [
        ("macOS", ComputerKind.mac),
        ("macos", .mac),
        (" macOS ", .mac),
        ("windows", .windows),
        ("Windows", .windows),
        ("linux", .linux),
        ("iOS", .other),
        ("iPadOS", .other),
        ("tvOS", .other),
        ("android", .other),
        ("freebsd", .other),
        ("js", .other),
        ("", .other),
    ])
    func kindFollowsTheOperatingSystem(os: String, kind: ComputerKind) {
        #expect(device(os: os).kind == kind)
    }

    @Test(arguments: ["iOS", "ios", "iPadOS", "tvOS", "android", "Android", "visionOS", "watchOS"])
    func phonesTabletsAndTVBoxesCannotBeControlled(os: String) {
        #expect(!device(os: os).canBeControlled)
    }

    @Test(arguments: ["macOS", "windows", "linux", "freebsd", "openbsd", ""])
    func computersCanBeControlled(os: String) {
        #expect(device(os: os).canBeControlled)
    }

    // MARK: Preferred host

    @Test func theMagicDNSNameIsPreferred() {
        let device = TailscaleDevice(
            id: "n1", name: "studio", dnsName: "studio.tail-example.ts.net",
            addresses: ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(device.preferredHost == "studio.tail-example.ts.net")
    }

    @Test func withoutANameTheFirstIPv4AddressIsUsed() {
        let ordered = TailscaleDevice(
            id: "n1", name: "studio", addresses: ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(ordered.preferredHost == "100.64.0.1")

        // Even when a caller built the device with the addresses the other way round.
        let unordered = TailscaleDevice(
            id: "n1", name: "studio", addresses: ["fd7a:115c:a1e0::1", "100.64.0.1"])
        #expect(unordered.preferredHost == "100.64.0.1")
    }

    @Test func anIPv6OnlyDeviceUsesWhatItHas() {
        let v6 = TailscaleDevice(id: "n1", name: "studio", addresses: ["fd7a:115c:a1e0::1"])
        #expect(v6.preferredHost == "fd7a:115c:a1e0::1")
        #expect(TailscaleDevice(id: "n1", name: "studio").preferredHost == "")
    }

    // MARK: Building blocks

    @Test(arguments: [
        ("studio.tail-example.ts.net.", "studio.tail-example.ts.net"),
        ("studio.tail-example.ts.net", "studio.tail-example.ts.net"),
        ("  studio.tail-example.ts.net.\n", "studio.tail-example.ts.net"),
        ("", ""),
        (".", ""),
    ])
    func dnsNamesLoseTheirTrailingDot(reported: String, expected: String) {
        #expect(TailscaleDevice.trimmedDNSName(reported) == expected)
    }

    @Test func aMissingDNSNameIsEmpty() {
        #expect(TailscaleDevice.trimmedDNSName(nil) == "")
    }

    @Test func theReportedHostNameIsTheDisplayName() {
        #expect(
            TailscaleDevice.displayName(
                hostName: "Ada’s Studio", dnsName: "adas-studio.tail-example.ts.net", addresses: [])
                == "Ada’s Studio")
        #expect(
            TailscaleDevice.displayName(hostName: " atlas ", dnsName: "", addresses: [])
                == "atlas")
    }

    @Test func withoutAUsefulHostNameTheDNSLabelIsShown() {
        for hostName in [nil, "", "  ", "localhost", "LOCALHOST"] as [String?] {
            #expect(
                TailscaleDevice.displayName(
                    hostName: hostName, dnsName: "phone.tail-example.ts.net", addresses: ["100.64.0.4"])
                    == "phone")
        }
    }

    @Test func withNothingElseAnAddressIsShown() {
        #expect(
            TailscaleDevice.displayName(hostName: nil, dnsName: "", addresses: ["100.64.0.4"])
                == "100.64.0.4")
        #expect(
            TailscaleDevice.displayName(hostName: "localhost", dnsName: "", addresses: ["100.64.0.4"])
                == "localhost")
        #expect(TailscaleDevice.displayName(hostName: nil, dnsName: "", addresses: []) == "")
    }

    @Test func addressesAreOrderedIPv4First() {
        #expect(
            TailscaleDevice.orderedAddresses(["fd7a:115c:a1e0::1", "100.64.0.1"])
                == ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(
            TailscaleDevice.orderedAddresses(
                ["fd7a:115c:a1e0::2", " 100.64.0.2 ", "", "fd7a:115c:a1e0::1", "100.64.0.1"])
                == ["100.64.0.2", "100.64.0.1", "fd7a:115c:a1e0::2", "fd7a:115c:a1e0::1"])
        #expect(TailscaleDevice.orderedAddresses(nil).isEmpty)
    }

    // MARK: Timestamps

    @Test(arguments: [
        ("2026-10-01T08:30:00Z", 1_790_843_400.0),
        ("2026-10-01T08:30:00.5Z", 1_790_843_400.5),
        ("2026-10-01T08:30:00.250000000Z", 1_790_843_400.25),
        ("2026-10-01T11:30:00+03:00", 1_790_843_400.0),
        (" 2026-10-01T08:30:00Z\n", 1_790_843_400.0),
    ])
    func timestampsAreReadWithOrWithoutFractions(text: String, seconds: Double) throws {
        let date = try #require(TailscaleDevice.timestamp(text))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.001)
    }

    @Test(arguments: ["0001-01-01T00:00:00Z", "", "   ", "yesterday", "2026-13-45T99:99:99Z"])
    func zeroAndUnreadableTimestampsAreNoDate(text: String) {
        #expect(TailscaleDevice.timestamp(text) == nil)
    }

    @Test func aMissingTimestampIsNoDate() {
        #expect(TailscaleDevice.timestamp(nil) == nil)
    }

    // MARK: Coding

    @Test func devicesSurviveCoding() throws {
        let device = TailscaleDevice(
            id: "nSTUDIO11CNTRL",
            name: "Studio",
            dnsName: "studio.tail-example.ts.net",
            addresses: ["100.64.0.1", "fd7a:115c:a1e0::1"],
            os: "macOS",
            isOnline: false,
            lastSeen: Date(timeIntervalSince1970: 1_790_843_400),
            isSelf: true)
        let data = try JSONEncoder().encode([device])
        #expect(try JSONDecoder().decode([TailscaleDevice].self, from: data) == [device])
    }

    @Test func decodingToleratesMissingKeys() throws {
        let device = try JSONDecoder().decode(
            TailscaleDevice.self, from: Data(#"{"id": "nSTUDIO11CNTRL"}"#.utf8))
        #expect(device == TailscaleDevice(id: "nSTUDIO11CNTRL", name: ""))

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TailscaleDevice.self, from: Data(#"{"name": "Studio"}"#.utf8))
        }
    }

    // MARK: Errors

    @Test func errorsExplainThemselves() {
        #expect(
            TailscaleError.accessTokenRejected.errorDescription?
                .hasPrefix("The access token was rejected") == true)
        #expect(
            TailscaleError.tailnetNotFound("example.com").errorDescription
                == "Tailnet “example.com” was not found.")
        #expect(
            TailscaleError.tailnetNotFound("-").errorDescription
                == "Tailnet not found for these credentials.")
        #expect(
            TailscaleError.server(status: 500, message: "internal server error").errorDescription
                == "Tailscale returned an error (HTTP 500): internal server error")
        #expect(
            TailscaleError.server(status: 502, message: nil).errorDescription
                == "Tailscale returned an error (HTTP 502).")
        #expect(TailscaleError.notInstalled.errorDescription == "The Tailscale app is not installed on this Mac.")
        #expect(TailscaleError.notRunning.errorDescription?.hasPrefix("Tailscale is not running") == true)
        #expect(TailscaleError.loggedOut.errorDescription?.hasPrefix("Tailscale is signed out") == true)

        // Every case has something to say, and it reaches `localizedDescription`.
        let all: [TailscaleError] = [
            .accessTokenRejected, .oauthClientRejected, .accessDenied, .tailnetNotFound("x"),
            .rateLimited, .server(status: 500, message: nil), .unreadableResponse, .notInstalled,
            .notRunning, .loggedOut, .awaitingApproval, .timedOut, .commandFailed("boom"),
            .commandFailed(""),
        ]
        for error in all {
            #expect(error.errorDescription?.isEmpty == false)
            #expect((error as any Error).localizedDescription == error.errorDescription)
        }
    }

    @Test func onlyFailuresToGetThroughAreTransient() {
        let transient: [TailscaleError] = [
            .rateLimited, .timedOut, .server(status: 500, message: nil),
            .server(status: 503, message: "busy"),
        ]
        for error in transient {
            #expect(error.isTransient)
        }
        let lasting: [TailscaleError] = [
            .accessTokenRejected, .oauthClientRejected, .accessDenied, .tailnetNotFound("x"),
            .server(status: 400, message: nil), .unreadableResponse, .notInstalled, .notRunning,
            .loggedOut, .awaitingApproval, .commandFailed("boom"),
        ]
        for error in lasting {
            #expect(!error.isTransient)
        }
    }
}

import Foundation
import Testing
@testable import OpenScreensCore

@Suite("ConnectionTarget")
struct ConnectionTargetTests {

    /// Something a person might type or open, and what it should mean.
    struct Form: Sendable, CustomTestStringConvertible {
        var text: String
        var host: String
        var port = 5900
        var username: String?
        var password: String?

        var testDescription: String { text }
    }

    private func expect(_ form: Form, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let target = try #require(ConnectionTarget(text: form.text), sourceLocation: sourceLocation)
        #expect(target.host == form.host, sourceLocation: sourceLocation)
        #expect(target.port == form.port, sourceLocation: sourceLocation)
        #expect(target.username == form.username, sourceLocation: sourceLocation)
        #expect(target.password == form.password, sourceLocation: sourceLocation)
        // An address says nothing about the rest.
        #expect(target.name == nil, sourceLocation: sourceLocation)
        #expect(target.kind == .mac, sourceLocation: sourceLocation)
        #expect(!target.usesSSH, sourceLocation: sourceLocation)
        #expect(!target.observeOnly, sourceLocation: sourceLocation)
    }

    // MARK: Typed addresses

    @Test(arguments: [
        Form(text: "studio.local", host: "studio.local"),
        Form(text: "  studio.local \n", host: "studio.local"),
        Form(text: "STUDIO", host: "STUDIO"),
        Form(text: "my-mac_2.example.com", host: "my-mac_2.example.com"),
        Form(text: "bücher.example", host: "bücher.example"),
        Form(text: "192.168.1.20", host: "192.168.1.20"),
    ])
    func aBareHostUsesTheDefaultPort(_ form: Form) throws {
        try expect(form)
    }

    @Test(arguments: [
        Form(text: "studio.local:5901", host: "studio.local", port: 5901),
        Form(text: "studio.local:5900", host: "studio.local", port: 5900),
        Form(text: "studio.local:100", host: "studio.local", port: 100),
        Form(text: "studio.local:443", host: "studio.local", port: 443),
        Form(text: "studio.local:65535", host: "studio.local", port: 65535),
        Form(text: "192.168.1.20:5902", host: "192.168.1.20", port: 5902),
    ])
    func aPortFollowsTheHostAfterAColon(_ form: Form) throws {
        try expect(form)
    }

    @Test(arguments: [
        Form(text: "studio.local:0", host: "studio.local", port: 5900),
        Form(text: "studio.local:1", host: "studio.local", port: 5901),
        Form(text: "studio.local:22", host: "studio.local", port: 5922),
        Form(text: "studio.local:99", host: "studio.local", port: 5999),
        Form(text: "10.0.0.5:2", host: "10.0.0.5", port: 5902),
        Form(text: "[::1]:3", host: "::1", port: 5903),
    ])
    func aSmallNumberIsAVNCDisplayNumber(_ form: Form) throws {
        try expect(form)
    }

    @Test(arguments: [
        Form(text: "[fe80::1]", host: "fe80::1"),
        Form(text: "[fe80::1]:5901", host: "fe80::1", port: 5901),
        Form(text: "[2001:db8::8a2e:370:7334]:5902", host: "2001:db8::8a2e:370:7334", port: 5902),
        Form(text: "[fe80::1%en0]:5900", host: "fe80::1%en0", port: 5900),
        // Without brackets every colon belongs to the address.
        Form(text: "fe80::1", host: "fe80::1"),
        Form(text: "::1", host: "::1"),
        Form(text: "2001:db8::8a2e:370:7334", host: "2001:db8::8a2e:370:7334"),
        Form(text: "fe80::1%en0", host: "fe80::1%en0"),
    ])
    func ipv6AddressesWorkWithAndWithoutBrackets(_ form: Form) throws {
        try expect(form)
    }

    @Test(arguments: [
        Form(text: "admin@studio.local", host: "studio.local", username: "admin"),
        Form(text: "first.last@studio.local:5901", host: "studio.local", port: 5901, username: "first.last"),
        Form(text: "admin@192.168.1.20:1", host: "192.168.1.20", port: 5901, username: "admin"),
        Form(text: "admin@[fe80::1]:5901", host: "fe80::1", port: 5901, username: "admin"),
        Form(text: "admin@fe80::1", host: "fe80::1", username: "admin"),
        Form(text: "admin:secret@studio.local", host: "studio.local", username: "admin", password: "secret"),
        Form(text: "admin:secret@studio.local:2", host: "studio.local", port: 5902, username: "admin", password: "secret"),
        // Only the last @ separates the host; a password may contain the rest.
        Form(text: "admin:p@ss:word@studio.local", host: "studio.local", username: "admin", password: "p@ss:word"),
        // Empty parts are no credentials at all.
        Form(text: "@studio.local", host: "studio.local"),
        Form(text: "admin:@studio.local", host: "studio.local", username: "admin"),
        Form(text: ":secret@studio.local", host: "studio.local", password: "secret"),
    ])
    func credentialsComeBeforeAnAtSign(_ form: Form) throws {
        try expect(form)
    }

    // MARK: Links

    @Test(arguments: [
        Form(text: "vnc://studio.local", host: "studio.local"),
        Form(text: "  vnc://studio.local\n", host: "studio.local"),
        Form(text: "vnc://studio.local/", host: "studio.local"),
        Form(text: "VNC://Studio.local", host: "Studio.local"),
        Form(text: "vnc://studio.local:5901", host: "studio.local", port: 5901),
        Form(text: "vnc://studio.local:1", host: "studio.local", port: 5901),
        Form(text: "vnc://192.168.1.20:5902", host: "192.168.1.20", port: 5902),
        Form(text: "vnc://admin@studio.local", host: "studio.local", username: "admin"),
        Form(text: "vnc://admin:secret@studio.local:5902", host: "studio.local", port: 5902, username: "admin", password: "secret"),
        Form(text: "vnc://admin:p%40ss%3Aword@studio.local", host: "studio.local", username: "admin", password: "p@ss:word"),
        Form(text: "vnc://first%20last@studio.local", host: "studio.local", username: "first last"),
        Form(text: "vnc://[fe80::1]", host: "fe80::1"),
        Form(text: "vnc://[fe80::1]:5901", host: "fe80::1", port: 5901),
        Form(text: "vnc://admin@[::1]:2", host: "::1", port: 5902, username: "admin"),
        Form(text: "vnc://[fe80::1%25en0]:5901", host: "fe80::1%en0", port: 5901),
        Form(text: "openscreens://studio.local:5901", host: "studio.local", port: 5901),
    ])
    func linksAreUnderstoodAsText(_ form: Form) throws {
        try expect(form)
        // Opening the link directly means the same as typing it.
        let url = try #require(URL(string: form.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(ConnectionTarget(url: url) == ConnectionTarget(text: form.text))
    }

    @Test func anOpenScreensLinkCarriesOptions() throws {
        let link = "openscreens://admin@studio.local:5901?name=Studio%20Mac&kind=windows&ssh=1&observe=1"
        let target = try #require(ConnectionTarget(text: link))

        #expect(target == ConnectionTarget(
            host: "studio.local", port: 5901, username: "admin", password: nil,
            name: "Studio Mac", kind: .windows, usesSSH: true, observeOnly: true))
    }

    @Test(arguments: [
        ("", false), ("?other=1", false),
        ("?ssh", true), ("?ssh=", true), ("?ssh=1", true), ("?ssh=true", true),
        ("?ssh=TRUE", true), ("?ssh=yes", true), ("?SSH=1", true),
        ("?ssh=0", false), ("?ssh=no", false), ("?ssh=false", false), ("?ssh=2", false),
    ])
    func flagsAreOnWhenPresentOrTruthy(query: String, expected: Bool) throws {
        let ssh = try #require(ConnectionTarget(text: "openscreens://studio.local\(query)"))
        #expect(ssh.usesSSH == expected)
        #expect(!ssh.observeOnly)

        let observeQuery = query.replacing("ssh", with: "observe").replacing("SSH", with: "OBSERVE")
        let observe = try #require(ConnectionTarget(text: "openscreens://studio.local\(observeQuery)"))
        #expect(observe.observeOnly == expected)
        #expect(!observe.usesSSH)
    }

    @Test func theSSHSchemeAlwaysTunnels() throws {
        #expect(try #require(ConnectionTarget(text: "openscreens-ssh://studio.local")).usesSSH)
        #expect(try #require(ConnectionTarget(text: "openscreens-ssh://studio.local?ssh=0")).usesSSH)
        #expect(try #require(ConnectionTarget(text: "OpenScreens-SSH://admin@studio.local:1")).port == 5901)
    }

    @Test func theKindOptionNamesTheRemoteSystem() throws {
        for kind in ComputerKind.allCases {
            let target = try #require(ConnectionTarget(text: "openscreens://studio.local?kind=\(kind.rawValue)"))
            #expect(target.kind == kind)
        }
        // Anything unrecognised leaves the default in place.
        #expect(try #require(ConnectionTarget(text: "openscreens://studio.local?kind=amiga")).kind == .mac)
        #expect(try #require(ConnectionTarget(text: "openscreens://studio.local?kind=")).kind == .mac)
    }

    @Test func theNameOptionIsDecodedAndOptional() throws {
        func name(_ query: String) throws -> String? {
            try #require(ConnectionTarget(text: "openscreens://studio.local?\(query)")).name
        }
        #expect(try name("name=B%C3%BCro%20%231") == "Büro #1")
        #expect(try name("name=") == nil)
        #expect(try name("NAME=Studio") == "Studio")
        // The first of two wins rather than crashing on the duplicate.
        #expect(try name("name=First&name=Second") == "First")
    }

    @Test func onlyRegisteredSchemesAreLinks() throws {
        #expect(ConnectionTarget.urlSchemes == ["vnc", "openscreens", "openscreens-ssh"])
        for scheme in ConnectionTarget.urlSchemes {
            let url = try #require(URL(string: "\(scheme)://studio.local"))
            #expect(ConnectionTarget(url: url)?.host == "studio.local")
        }
        for other in ["https://studio.local", "ssh://studio.local", "rdp://studio.local", "file:///tmp/x"] {
            let url = try #require(URL(string: other))
            #expect(ConnectionTarget(url: url) == nil)
        }
        // A link has to name a host.
        #expect(ConnectionTarget(url: try #require(URL(string: "vnc://"))) == nil)
        #expect(ConnectionTarget(url: try #require(URL(string: "vnc:studio.local"))) == nil)
        #expect(ConnectionTarget(url: try #require(URL(string: "vnc:///studio.local"))) == nil)
    }

    // MARK: Garbage

    @Test(arguments: [
        "", "   ", "\n",
        "studio local", "studio\tlocal",
        "studio.local:", ":5900", "studio.local:port", "studio.local:59x",
        "studio.local:65536", "studio.local:99999", "studio.local:-1",
        "admin@", "admin:secret@", "admin@studio.local@",
        "studio.local/screen", "studio$local", "studio.local?ssh=1", "stud#io", "\"studio\"",
        "[fe80::1", "[]", "[]:5900", "[fe80::1]5900", "[fe80::1]:", "[fe80::1]:port",
        "[fe80::1]:99999", "[fe80::1]:5900:1",
        "http://studio.local", "https://studio.local:5900", "ssh://studio.local",
        "://studio.local", "vnc://", "vnc:///", "vnc://:5900", "vnc://admin@",
        "vnc://studio local", "vnc:studio.local",
    ])
    func textThatIsNotAnAddressIsRejected(text: String) {
        #expect(ConnectionTarget(text: text) == nil)
    }

    @Test func aHostNameHasALengthLimit() {
        #expect(ConnectionTarget(text: String(repeating: "a", count: 255)) != nil)
        #expect(ConnectionTarget(text: String(repeating: "a", count: 256)) == nil)
    }

    // MARK: Sharing

    @Test func aSharedLinkDescribesTheComputer() {
        let links: [(Computer, String)] = [
            (Computer(name: "Studio", host: "studio.local"), "vnc://studio.local"),
            (Computer(name: "Studio", host: "studio.local", port: 5901), "vnc://studio.local:5901"),
            (Computer(name: "Studio", host: "studio.local", username: "me"), "vnc://me@studio.local"),
            (Computer(name: "Studio", host: "studio.local", username: ""), "vnc://studio.local"),
            (Computer(name: "Studio", host: "192.168.1.20", port: 5902, username: "me"), "vnc://me@192.168.1.20:5902"),
            (Computer(name: "Studio", host: "fe80::1"), "vnc://[fe80::1]"),
            (Computer(name: "Studio", host: "fe80::1", port: 5901, username: "me"), "vnc://me@[fe80::1]:5901"),
        ]
        for (computer, expected) in links {
            #expect(ConnectionTarget.url(for: computer)?.absoluteString == expected)
        }
    }

    @Test func aSharedLinkOpensTheSameComputer() throws {
        let computers = [
            Computer(name: "Studio", host: "studio.local"),
            Computer(name: "Studio", host: "Studio.local", port: 5901, username: "me"),
            Computer(name: "Studio", host: "192.168.1.20", port: 5999),
            Computer(name: "Studio", host: "fe80::1", port: 5901, username: "me"),
            Computer(name: "Studio", host: "fe80::1%en0"),
            Computer(name: "Studio", host: "studio.local", username: "first last@corp"),
            Computer(name: "Studio", host: "studio.local", port: 2222, username: "domain\\user"),
        ]
        for computer in computers {
            let url = try #require(ConnectionTarget.url(for: computer), "\(computer.host)")
            let target = try #require(ConnectionTarget(url: url), "\(url)")
            #expect(target.host == computer.host)
            #expect(target.port == computer.port)
            #expect(target.username == computer.username)
            #expect(target.password == nil)
            // And pasting the link into the address field works as well.
            #expect(ConnectionTarget(text: url.absoluteString) == target)
        }
    }

    @Test func aSharedLinkNeverContainsAPassword() throws {
        // The password of a saved computer lives in the keychain and has no
        // way into the link. A user name that looks like "user:password"
        // must not turn into one either.
        let credentials = CredentialStore(storage: InMemorySecretStorage())
        let computers = [
            Computer(name: "Studio", host: "studio.local", username: "admin"),
            Computer(name: "Studio", host: "studio.local", port: 5901, username: "admin:hunter2"),
            Computer(name: "Studio", host: "fe80::1", username: "admin:hunter2@corp"),
            Computer(name: "Studio", host: "studio.local"),
        ]
        for computer in computers {
            try credentials.setPassword("hunter2-keychain", for: computer.id)
            try credentials.setPassword("hunter2-ssh", for: computer.id, kind: .ssh)

            let url = try #require(ConnectionTarget.url(for: computer))
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

            #expect(components.password == nil)
            #expect(url.password == nil)
            #expect(components.user == computer.username)
            #expect(!url.absoluteString.contains("keychain"))
            #expect(!url.absoluteString.contains("hunter2-ssh"))
            #expect(ConnectionTarget(url: url)?.password == nil)
        }
    }

    @Test func aHostThatCannotBeWrittenAsALinkGivesNone() {
        #expect(ConnectionTarget.url(for: Computer(name: "Studio", host: "my studio.local")) == nil)
    }

    // MARK: - Addresses that cannot exist

    /// A port has to be one in typed text and in a link alike; a link's was
    /// once taken as it came and clamped when connecting.
    @Test func aLinkWithAPortThatCannotExistIsRejected() throws {
        #expect(ConnectionTarget(text: "studio.local:99999") == nil)
        #expect(ConnectionTarget(text: "vnc://studio.local:99999") == nil)
        #expect(ConnectionTarget(url: try #require(URL(string: "vnc://studio.local:70000"))) == nil)
        #expect(ConnectionTarget(text: "vnc://studio.local:65535")?.port == 65535)
    }

    /// Brackets are for IPv6 addresses and hold nothing else, and text with
    /// several colons is an IPv6 address or a mistake.
    @Test func addressesThatCannotExistAreRejectedInEveryForm() {
        #expect(ConnectionTarget(text: "stu$dio") == nil)
        #expect(ConnectionTarget(text: "[stu$dio]") == nil)
        #expect(ConnectionTarget(text: "[stu$dio]:5900") == nil)
        #expect(ConnectionTarget(text: "[studio.local]:5900") == nil)

        #expect(ConnectionTarget(text: "studio.local:5900:1") == nil)
        #expect(ConnectionTarget(text: "studio.local::5900") == nil)
        #expect(ConnectionTarget(text: "fe80::1%") == nil)
        #expect(ConnectionTarget(text: "fe80::1%en$0") == nil)
    }
}

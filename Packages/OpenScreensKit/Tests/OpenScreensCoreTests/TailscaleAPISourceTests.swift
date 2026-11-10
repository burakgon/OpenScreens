import Foundation
import Testing
@testable import OpenScreensCore

// MARK: - Fixtures

/// A device listing in the shape `GET /api/v2/tailnet/{tailnet}/devices?fields=all`
/// answers with. Every value is made up.
private let tailscaleDevicesResponse = #"""
{
  "devices": [
    {
      "addresses": ["fd7a:115c:a1e0::1", "100.64.0.1"],
      "id": "1000000000000001",
      "nodeId": "nSTUDIO11CNTRL",
      "user": "ada@example.com",
      "name": "studio.tail-example.ts.net",
      "hostname": "Studio",
      "clientVersion": "1.90.0-t0000000-g0000000",
      "updateAvailable": false,
      "os": "macOS",
      "created": "2025-01-02T03:04:05Z",
      "connectedToControl": true,
      "lastSeen": "2026-09-01T00:00:00Z",
      "keyExpiryDisabled": false,
      "expires": "2027-01-02T03:04:05Z",
      "authorized": true,
      "isExternal": false,
      "machineKey": "mkey:0000",
      "nodeKey": "nodekey:0000",
      "blocksIncomingConnections": false,
      "enabledRoutes": [],
      "advertisedRoutes": ["192.0.2.0/24"],
      "clientConnectivity": {
        "endpoints": ["203.0.113.5:41641"],
        "mappingVariesByDestIP": false,
        "latency": {"Frankfurt": {"preferred": true, "latencyMs": 12.5}},
        "clientSupports": {"hairPinning": null, "ipv6": true, "pcp": false, "pmp": false, "udp": true, "upnp": false}
      },
      "tags": ["tag:desk"],
      "tailnetLockError": "",
      "tailnetLockKey": "",
      "isEphemeral": false
    },
    {
      "addresses": ["100.64.0.2", "fd7a:115c:a1e0::2"],
      "id": "1000000000000002",
      "nodeId": "nPIXEL0022CNTRL",
      "name": "pixel.tail-example.ts.net",
      "hostname": "Pixel",
      "os": "android",
      "connectedToControl": false,
      "lastSeen": "2026-10-01T08:30:00Z"
    },
    {
      "addresses": ["100.64.0.3", "FD7A:115C:A1E0:0:0:0:0:3"],
      "id": "1000000000000003",
      "nodeId": "nATLAS0033CNTRL",
      "name": "atlas.tail-example.ts.net.",
      "hostname": "atlas",
      "os": "linux",
      "connectedToControl": false,
      "lastSeen": "2026-10-01T08:30:00.5Z"
    },
    {
      "addresses": ["100.64.0.4"],
      "id": "1000000000000004",
      "name": "tower.tail-example.ts.net",
      "hostname": "",
      "os": "windows"
    },
    {
      "addresses": ["100.64.0.5"],
      "nodeId": 42,
      "hostname": "malformed"
    },
    {
      "addresses": ["100.64.0.6"],
      "hostname": "nameless"
    },
    "not a device"
  ]
}
"""#

/// Answers requests from a closure and remembers what was asked.
private final class TailscaleStubTransport: TailscaleHTTPTransport, @unchecked Sendable {
    typealias Reply = (status: Int, body: String)

    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private let reply: @Sendable (URLRequest, Int) throws -> Reply

    /// - Parameter reply: Given the request and how many came before it.
    init(reply: @escaping @Sendable (URLRequest, Int) throws -> Reply) {
        self.reply = reply
    }

    var requests: [URLRequest] {
        lock.withLock { sent }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = lock.withLock {
            sent.append(request)
            return sent.count - 1
        }
        let reply = try reply(request, index)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badURL)
        }
        return (Data(reply.body.utf8), response)
    }
}

/// A clock the test moves by hand.
private final class TailscaleTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private func isTailscaleTokenRequest(_ request: URLRequest) -> Bool {
    request.url?.path.hasSuffix("/oauth/token") == true
}

private func tailscaleTokenReply(_ token: String, expiresIn: String = "3600") -> TailscaleStubTransport.Reply {
    (200, #"{"access_token":"\#(token)","token_type":"Bearer","expires_in":\#(expiresIn),"scope":"devices:core:read"}"#)
}

private func makeTailscaleSource(
    tailnet: String = "-",
    credentials: TailscaleCredentials = .accessToken("tskey-api-test"),
    transport: TailscaleStubTransport,
    clock: TailscaleTestClock = TailscaleTestClock(),
    localAddresses: Set<String> = []
) -> TailscaleAPISource {
    TailscaleAPISource(
        tailnet: tailnet,
        credentials: credentials,
        transport: transport,
        baseURL: TailscaleAPISource.defaultBaseURL,
        localAddresses: { localAddresses },
        now: { clock.now })
}

// MARK: - Reading the response

@Suite struct TailscaleAPIResponseTests {

    @Test func devicesAreReadFromTheResponse() throws {
        let devices = try TailscaleAPISource.devices(fromResponse: Data(tailscaleDevicesResponse.utf8))
        #expect(devices.map(\.id) == [
            "nSTUDIO11CNTRL", "nPIXEL0022CNTRL", "nATLAS0033CNTRL", "1000000000000004",
        ])

        let studio = try #require(devices.first)
        #expect(studio.name == "Studio")
        #expect(studio.dnsName == "studio.tail-example.ts.net")
        #expect(studio.addresses == ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(studio.os == "macOS")
        #expect(studio.isOnline)
        // A connected device has no "last seen", whatever the response carries.
        #expect(studio.lastSeen == nil)
        #expect(!studio.isSelf)
        #expect(studio.kind == .mac)
        #expect(studio.canBeControlled)
        #expect(studio.preferredHost == "studio.tail-example.ts.net")
    }

    @Test func offlineDevicesCarryWhenTheyWereLastSeen() throws {
        let devices = try TailscaleAPISource.devices(fromResponse: Data(tailscaleDevicesResponse.utf8))
        let pixel = try #require(devices.first { $0.id == "nPIXEL0022CNTRL" })
        #expect(!pixel.isOnline)
        #expect(pixel.lastSeen == Date(timeIntervalSince1970: 1_790_843_400))
        #expect(pixel.kind == .other)
        #expect(!pixel.canBeControlled)

        let atlas = try #require(devices.first { $0.id == "nATLAS0033CNTRL" })
        let atlasLastSeen = try #require(atlas.lastSeen)
        #expect(abs(atlasLastSeen.timeIntervalSince1970 - 1_790_843_400.5) < 0.001)
        #expect(atlas.dnsName == "atlas.tail-example.ts.net")
        #expect(atlas.kind == .linux)
    }

    @Test func sparseEntriesAreFilledInAndUnusableOnesSkipped() throws {
        let devices = try TailscaleAPISource.devices(fromResponse: Data(tailscaleDevicesResponse.utf8))
        // No stable ID: the legacy one stands in. No host name: the DNS label does.
        let tower = try #require(devices.last)
        #expect(tower.id == "1000000000000004")
        #expect(tower.name == "tower")
        #expect(!tower.isOnline)
        #expect(tower.lastSeen == nil)
        #expect(tower.kind == .windows)
        // The entry with a numeric nodeId, the one without any ID and the
        // stray string are left out without failing the rest.
        #expect(devices.count == 4)
        #expect(!devices.contains { $0.name == "malformed" || $0.name == "nameless" })
    }

    @Test func thisDeviceIsRecognisedByItsAddress() throws {
        let data = Data(tailscaleDevicesResponse.utf8)

        let byIPv4 = try TailscaleAPISource.devices(
            fromResponse: data, localAddresses: ["192.168.1.20", "100.64.0.1"])
        #expect(byIPv4.filter(\.isSelf).map(\.id) == ["nSTUDIO11CNTRL"])

        // The response spells this address out in full and in capitals.
        let byIPv6 = try TailscaleAPISource.devices(
            fromResponse: data, localAddresses: ["fd7a:115c:a1e0::3"])
        #expect(byIPv6.filter(\.isSelf).map(\.id) == ["nATLAS0033CNTRL"])

        let neither = try TailscaleAPISource.devices(
            fromResponse: data, localAddresses: ["192.168.1.20", "fe80::1"])
        #expect(neither.filter(\.isSelf).isEmpty)
    }

    @Test(arguments: [#"{"devices": []}"#, #"{"devices": null}"#, "{}"])
    func anEmptyTailnetIsAnEmptyList(body: String) throws {
        #expect(try TailscaleAPISource.devices(fromResponse: Data(body.utf8)).isEmpty)
    }

    @Test(arguments: ["", "<html>Sign in to the network</html>", "[]", #"{"devices": {}}"#])
    func somethingElseEntirelyIsUnreadable(body: String) {
        #expect(throws: TailscaleError.unreadableResponse) {
            try TailscaleAPISource.devices(fromResponse: Data(body.utf8))
        }
    }

    @Test func addressesAreBroughtToOneSpelling() {
        #expect(LocalInterfaceAddresses.canonical("100.64.0.1") == "100.64.0.1")
        #expect(LocalInterfaceAddresses.canonical("FD7A:115C:A1E0:0:0:0:0:3") == "fd7a:115c:a1e0::3")
        #expect(LocalInterfaceAddresses.canonical("fd7a:115c:a1e0::3") == "fd7a:115c:a1e0::3")
        #expect(LocalInterfaceAddresses.canonical("studio.tail-example.ts.net") == nil)
        #expect(LocalInterfaceAddresses.canonical("") == nil)
    }

    @Test func thisMachinesAddressesAreInCanonicalForm() {
        // Whatever interfaces this machine has, each address must read back as itself.
        for address in LocalInterfaceAddresses.current() {
            #expect(LocalInterfaceAddresses.canonical(address) == address)
        }
    }
}

// MARK: - Talking to the API

@Suite struct TailscaleAPISourceTests {

    @Test func anAccessTokenIsSentAsABearerToken() async throws {
        let transport = TailscaleStubTransport { _, _ in (200, tailscaleDevicesResponse) }
        let devices = try await makeTailscaleSource(transport: transport).devices()
        #expect(devices.count == 4)

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tskey-api-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test(arguments: [
        ("example.com", "/api/v2/tailnet/example.com/devices"),
        ("T1234CNTRL", "/api/v2/tailnet/T1234CNTRL/devices"),
        ("ada@example.com", "/api/v2/tailnet/ada%40example.com/devices"),
        ("odd/name here", "/api/v2/tailnet/odd%2Fname%20here/devices"),
        ("  example.com\n", "/api/v2/tailnet/example.com/devices"),
        ("", "/api/v2/tailnet/-/devices"),
        ("   ", "/api/v2/tailnet/-/devices"),
    ])
    func theTailnetIsOnePathComponent(tailnet: String, path: String) async throws {
        let transport = TailscaleStubTransport { _, _ in (200, #"{"devices": []}"#) }
        _ = try await makeTailscaleSource(tailnet: tailnet, transport: transport).devices()
        let url = try #require(transport.requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == path)
        #expect(components.percentEncodedQuery == "fields=all")
        #expect(components.host == "api.tailscale.com")
    }

    @Test func aBaseURLWithATrailingSlashStillMakesACleanPath() {
        let url = TailscaleAPISource.devicesURL(
            baseURL: URL(string: "https://api.example.test/api/v2/")!, tailnet: "-")
        #expect(url.absoluteString == "https://api.example.test/api/v2/tailnet/-/devices?fields=all")
    }

    @Test func thisDeviceIsMarkedFromTheLocalAddresses() async throws {
        let transport = TailscaleStubTransport { _, _ in (200, tailscaleDevicesResponse) }
        let devices = try await makeTailscaleSource(transport: transport, localAddresses: ["100.64.0.3"]).devices()
        #expect(devices.filter(\.isSelf).map(\.id) == ["nATLAS0033CNTRL"])
    }

    // MARK: Errors

    @Test(arguments: [
        (401, TailscaleError.accessTokenRejected),
        (403, .accessDenied),
        (404, .tailnetNotFound("example.com")),
        (429, .rateLimited),
        (500, .server(status: 500, message: "internal server error")),
        (400, .server(status: 400, message: "internal server error")),
    ])
    func httpStatusesBecomeTypedErrors(status: Int, expected: TailscaleError) async {
        let transport = TailscaleStubTransport { _, _ in (status, #"{"message": "internal server error"}"#) }
        await #expect(throws: expected) {
            try await makeTailscaleSource(tailnet: "example.com", transport: transport).devices()
        }
        // A rejected access token is not something asking again can fix.
        #expect(transport.requests.count == 1)
    }

    @Test func anErrorBodyThatIsNotJSONLeavesTheMessageOut() async {
        let transport = TailscaleStubTransport { _, _ in (502, "<html>Bad Gateway</html>") }
        await #expect(throws: TailscaleError.server(status: 502, message: nil)) {
            try await makeTailscaleSource(transport: transport).devices()
        }
    }

    @Test func aSuccessfulAnswerThatIsNotAListingIsUnreadable() async {
        let transport = TailscaleStubTransport { _, _ in (200, "<html>Welcome to the hotel Wi-Fi</html>") }
        await #expect(throws: TailscaleError.unreadableResponse) {
            try await makeTailscaleSource(transport: transport).devices()
        }
    }

    @Test func networkFailuresComeThroughAsTheyAre() async {
        let transport = TailscaleStubTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) {
            try await makeTailscaleSource(transport: transport).devices()
        }
    }

    @Test func anEmptyAccessTokenIsRejectedWithoutAsking() async {
        let transport = TailscaleStubTransport { _, _ in (200, tailscaleDevicesResponse) }
        await #expect(throws: TailscaleError.accessTokenRejected) {
            try await makeTailscaleSource(credentials: .accessToken("  "), transport: transport).devices()
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: OAuth

    private let client = TailscaleCredentials.oauthClient(id: "client-id", secret: "tskey-client-secret")

    @Test func anOAuthClientIsTradedForAToken() async throws {
        let transport = TailscaleStubTransport { request, _ in
            isTailscaleTokenRequest(request) ? tailscaleTokenReply("token-1") : (200, tailscaleDevicesResponse)
        }
        let devices = try await makeTailscaleSource(credentials: client, transport: transport).devices()
        #expect(devices.count == 4)
        #expect(transport.requests.count == 2)

        let exchange = transport.requests[0]
        #expect(exchange.httpMethod == "POST")
        #expect(exchange.url?.absoluteString == "https://api.tailscale.com/api/v2/oauth/token")
        #expect(
            exchange.value(forHTTPHeaderField: "Content-Type")
                == "application/x-www-form-urlencoded")
        #expect(exchange.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(decoding: try #require(exchange.httpBody), as: UTF8.self)
        #expect(
            body == "client_id=client-id&client_secret=tskey-client-secret&grant_type=client_credentials")

        let listing = transport.requests[1]
        #expect(listing.httpMethod == "GET")
        #expect(listing.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test func formValuesAreEscaped() {
        let body = TailscaleAPISource.formEncoded([
            ("client_id", "id with space"),
            ("client_secret", "a&b=c+d/é"),
        ])
        #expect(
            String(decoding: body, as: UTF8.self)
                == "client_id=id%20with%20space&client_secret=a%26b%3Dc%2Bd%2F%C3%A9")
    }

    @Test func theTokenIsReusedUntilShortlyBeforeItExpires() async throws {
        let clock = TailscaleTestClock()
        let transport = TailscaleStubTransport { request, index in
            isTailscaleTokenRequest(request) ? tailscaleTokenReply("token-at-request-\(index)") : (200, tailscaleDevicesResponse)
        }
        let source = makeTailscaleSource(credentials: client, transport: transport, clock: clock)
        func tokenRequests() -> Int { transport.requests.filter(isTailscaleTokenRequest).count }
        func lastBearer() -> String? {
            transport.requests.last?.value(forHTTPHeaderField: "Authorization")
        }

        _ = try await source.devices()
        #expect(tokenRequests() == 1)
        #expect(lastBearer() == "Bearer token-at-request-0")

        // Well within the hour: the same token, no new exchange.
        clock.advance(by: 1800)
        _ = try await source.devices()
        clock.advance(by: 1739)  // 3539 s after the token was requested
        _ = try await source.devices()
        #expect(tokenRequests() == 1)
        #expect(lastBearer() == "Bearer token-at-request-0")
        #expect(transport.requests.count == 4)

        // One minute before it expires the token is replaced.
        clock.advance(by: 1)  // 3540 s
        _ = try await source.devices()
        #expect(tokenRequests() == 2)
        #expect(lastBearer() == "Bearer token-at-request-4")

        // And the replacement is cached in its turn.
        clock.advance(by: 60)
        _ = try await source.devices()
        #expect(tokenRequests() == 2)
    }

    @Test func aLifetimeGivenAsTextCountsToo() async throws {
        let transport = TailscaleStubTransport { request, _ in
            isTailscaleTokenRequest(request) ? tailscaleTokenReply("token", expiresIn: #""3600""#) : (200, tailscaleDevicesResponse)
        }
        let source = makeTailscaleSource(credentials: client, transport: transport)
        _ = try await source.devices()
        _ = try await source.devices()
        #expect(transport.requests.filter(isTailscaleTokenRequest).count == 1)
    }

    @Test(arguments: [
        #"{"access_token":"token","token_type":"Bearer"}"#,
        #"{"access_token":"token","expires_in":60}"#,
        #"{"access_token":"token","expires_in":0}"#,
    ])
    func aTokenWithoutUsefulLifetimeIsNotKept(grant: String) async throws {
        let transport = TailscaleStubTransport { request, _ in
            isTailscaleTokenRequest(request) ? (200, grant) : (200, tailscaleDevicesResponse)
        }
        let source = makeTailscaleSource(credentials: client, transport: transport)
        _ = try await source.devices()
        _ = try await source.devices()
        #expect(transport.requests.filter(isTailscaleTokenRequest).count == 2)
    }

    @Test func aCachedTokenThatIsRejectedIsReplacedOnce() async throws {
        // The first token works once, then the server stops accepting it.
        let transport = TailscaleStubTransport { request, index in
            if isTailscaleTokenRequest(request) {
                return tailscaleTokenReply(index == 0 ? "first" : "second")
            }
            let bearer = request.value(forHTTPHeaderField: "Authorization")
            if bearer == "Bearer first", index > 1 {
                return (401, #"{"message": "invalid token"}"#)
            }
            return (200, tailscaleDevicesResponse)
        }
        let source = makeTailscaleSource(credentials: client, transport: transport)

        _ = try await source.devices()  // exchange, listing
        let devices = try await source.devices()  // listing refused, exchange, listing
        #expect(devices.count == 4)
        #expect(transport.requests.map(isTailscaleTokenRequest) == [true, false, false, true, false])
        #expect(
            transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer second")

        // The new token is the cached one from here on.
        _ = try await source.devices()
        #expect(transport.requests.count == 6)
        #expect(transport.requests.filter(isTailscaleTokenRequest).count == 2)
    }

    @Test func aFreshTokenThatIsRejectedIsNotTriedAgain() async {
        let transport = TailscaleStubTransport { request, _ in
            isTailscaleTokenRequest(request) ? tailscaleTokenReply("token") : (401, #"{"message": "invalid token"}"#)
        }
        let source = makeTailscaleSource(credentials: client, transport: transport)
        await #expect(throws: TailscaleError.accessTokenRejected) {
            try await source.devices()
        }
        #expect(transport.requests.map(isTailscaleTokenRequest) == [true, false])

        // Next time the cached token is refused once more, a new one is
        // fetched, and when that fails too the error stands.
        await #expect(throws: TailscaleError.accessTokenRejected) {
            try await source.devices()
        }
        #expect(transport.requests.map(isTailscaleTokenRequest) == [true, false, false, true, false])
    }

    @Test(arguments: [
        (400, TailscaleError.oauthClientRejected),
        (401, .oauthClientRejected),
        (403, .accessDenied),
        (429, .rateLimited),
        (500, .server(status: 500, message: "oops")),
    ])
    func aRefusedExchangeIsATypedError(status: Int, expected: TailscaleError) async {
        let transport = TailscaleStubTransport { _, _ in (status, #"{"message": "oops"}"#) }
        await #expect(throws: expected) {
            try await makeTailscaleSource(credentials: client, transport: transport).devices()
        }
        // The listing is never attempted without a token.
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: ["{}", #"{"access_token": ""}"#, "not json"])
    func anExchangeThatGrantsNothingIsUnreadable(grant: String) async {
        let transport = TailscaleStubTransport { _, _ in (200, grant) }
        await #expect(throws: TailscaleError.unreadableResponse) {
            try await makeTailscaleSource(credentials: client, transport: transport).devices()
        }
    }
}

// MARK: - Credentials

@Suite struct TailscaleCredentialsTests {
    private func makeStore(_ secrets: [String: String]) throws -> CredentialStore {
        let store = CredentialStore(storage: InMemorySecretStorage())
        for (name, value) in secrets {
            try store.setSecret(value, named: name)
        }
        return store
    }

    @Test func theSecretNamesAreTheAgreedOnes() {
        #expect(TailscaleCredentials.SecretName.accessToken == "tailscale.apiToken")
        #expect(TailscaleCredentials.SecretName.oauthClientID == "tailscale.oauthClientID")
        #expect(TailscaleCredentials.SecretName.oauthClientSecret == "tailscale.oauthClientSecret")
    }

    @Test func nothingSavedMeansNoCredentials() throws {
        #expect(TailscaleCredentials.saved(in: try makeStore([:])) == nil)
    }

    @Test func aSavedTokenIsReadAndTrimmed() throws {
        let store = try makeStore(["tailscale.apiToken": "  tskey-api-test\n"])
        #expect(TailscaleCredentials.saved(in: store) == .accessToken("tskey-api-test"))
    }

    @Test func aCompleteOAuthClientIsPreferredToAToken() throws {
        let store = try makeStore([
            "tailscale.apiToken": "tskey-api-test",
            "tailscale.oauthClientID": "client-id",
            "tailscale.oauthClientSecret": "tskey-client-secret",
        ])
        #expect(
            TailscaleCredentials.saved(in: store)
                == .oauthClient(id: "client-id", secret: "tskey-client-secret"))
    }

    @Test func halfAnOAuthClientIsNoClient() throws {
        let withToken = try makeStore([
            "tailscale.apiToken": "tskey-api-test",
            "tailscale.oauthClientID": "client-id",
        ])
        #expect(TailscaleCredentials.saved(in: withToken) == .accessToken("tskey-api-test"))

        let alone = try makeStore(["tailscale.oauthClientSecret": "tskey-client-secret"])
        #expect(TailscaleCredentials.saved(in: alone) == nil)

        let blank = try makeStore(["tailscale.oauthClientID": "client-id", "tailscale.oauthClientSecret": "   "])
        #expect(TailscaleCredentials.saved(in: blank) == nil)
    }

    @Test func secretsStayOutOfDescriptions() {
        let token = TailscaleCredentials.accessToken("tskey-api-test")
        let client = TailscaleCredentials.oauthClient(id: "client-id", secret: "tskey-client-secret")
        for text in ["\(token)", "\(client)", String(reflecting: token), String(reflecting: client)] {
            #expect(!text.contains("tskey"))
            #expect(!text.contains("client-id"))
        }
    }
}

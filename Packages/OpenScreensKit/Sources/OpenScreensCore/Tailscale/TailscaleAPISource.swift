import Foundation

// MARK: - Credentials

/// What a ``TailscaleAPISource`` signs its requests with.
public enum TailscaleCredentials: Hashable, Sendable {
    /// An API access token (`tskey-api-…`) created in the Tailscale admin
    /// console. It acts as the user who created it and expires after at most
    /// 90 days.
    case accessToken(String)
    /// An OAuth client. It does not expire; the source trades it for
    /// short-lived access tokens as needed. Listing devices needs the
    /// `devices:core:read` scope.
    case oauthClient(id: String, secret: String)

    /// The names the credentials are kept under in the keychain, for use with
    /// ``CredentialStore/secret(named:)`` and
    /// ``CredentialStore/setSecret(_:named:)``.
    public enum SecretName {
        public static let accessToken = "tailscale.apiToken"
        public static let oauthClientID = "tailscale.oauthClientID"
        public static let oauthClientSecret = "tailscale.oauthClientSecret"
    }

    /// The credentials saved in the keychain, if any. An OAuth client is
    /// preferred when both its parts are saved, because it never expires;
    /// otherwise the access token is used.
    ///
    /// This reads the keychain, so call it off the main thread.
    public static func saved(in store: CredentialStore) -> TailscaleCredentials? {
        func secret(_ name: String) -> String? {
            let value = store.secret(named: name)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let id = secret(SecretName.oauthClientID),
           let clientSecret = secret(SecretName.oauthClientSecret) {
            return .oauthClient(id: id, secret: clientSecret)
        }
        if let token = secret(SecretName.accessToken) {
            return .accessToken(token)
        }
        return nil
    }
}

// Secrets must not end up in logs or crash reports because a value was
// printed or interpolated into a string somewhere.
extension TailscaleCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .accessToken: "TailscaleCredentials.accessToken(redacted)"
        case .oauthClient: "TailscaleCredentials.oauthClient(redacted)"
        }
    }

    public var debugDescription: String { description }
}

// MARK: - Transport

/// The one thing ``TailscaleAPISource`` needs from the network. Tests supply
/// their own to answer with canned responses.
public protocol TailscaleHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Sends requests with a `URLSession`.
public struct URLSessionTailscaleTransport: TailscaleHTTPTransport {
    /// A session that keeps nothing on disk — no cache, no cookies — since
    /// the responses describe the user's devices.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    public init(session: URLSession = URLSessionTailscaleTransport.defaultSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

// MARK: - Source

/// Lists a tailnet's devices through Tailscale's HTTP API.
///
/// This works from anywhere with the right credentials, including on iPhone
/// and iPad, where there is no local Tailscale client to ask.
///
/// Keep one instance for as long as its configuration stays the same: with an
/// OAuth client, the access token it obtains is reused until shortly before
/// it expires.
public actor TailscaleAPISource: TailscaleSource {
    public static let defaultBaseURL = URL(string: "https://api.tailscale.com/api/v2")!

    /// A token is replaced this long before it expires, so a request never
    /// goes out with one that lapses on the way.
    static let tokenRenewalMargin: TimeInterval = 60

    private let tailnet: String
    private let credentials: TailscaleCredentials
    private let transport: any TailscaleHTTPTransport
    private let baseURL: URL
    private let localAddresses: @Sendable () -> Set<String>
    private let now: @Sendable () -> Date

    private var cachedToken: (value: String, renewAt: Date)?

    /// - Parameters:
    ///   - tailnet: The tailnet ID from the admin console's General settings,
    ///     or `-` for the tailnet the credentials belong to.
    public init(
        tailnet: String = "-",
        credentials: TailscaleCredentials,
        transport: any TailscaleHTTPTransport = URLSessionTailscaleTransport()
    ) {
        self.init(
            tailnet: tailnet,
            credentials: credentials,
            transport: transport,
            baseURL: Self.defaultBaseURL,
            localAddresses: LocalInterfaceAddresses.current,
            now: { .now })
    }

    /// The initializer tests use, with every outside influence injectable.
    init(
        tailnet: String,
        credentials: TailscaleCredentials,
        transport: any TailscaleHTTPTransport,
        baseURL: URL,
        localAddresses: @escaping @Sendable () -> Set<String>,
        now: @escaping @Sendable () -> Date
    ) {
        let tailnet = tailnet.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tailnet = tailnet.isEmpty ? "-" : tailnet
        self.credentials = credentials
        self.transport = transport
        self.baseURL = baseURL
        self.localAddresses = localAddresses
        self.now = now
    }

    public func devices() async throws -> [TailscaleDevice] {
        var token = try await bearerToken(forceNew: false)
        var (data, response) = try await transport.send(devicesRequest(token: token.value))

        // A token from the cache can have been revoked, or expired early.
        // That is worth one attempt with a new one before giving up.
        if response.statusCode == 401, token.cameFromCache {
            token = try await bearerToken(forceNew: true)
            (data, response) = try await transport.send(devicesRequest(token: token.value))
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(forStatus: response.statusCode, body: data, tailnet: tailnet)
        }
        return try Self.devices(fromResponse: data, localAddresses: localAddresses())
    }

    // MARK: Requests

    private func devicesRequest(token: String) -> URLRequest {
        var request = URLRequest(url: Self.devicesURL(baseURL: baseURL, tailnet: tailnet))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `…/tailnet/{tailnet}/devices?fields=all`, with the tailnet escaped so
    /// a name containing `@` or `/` stays a single path component.
    static func devicesURL(baseURL: URL, tailnet: String) -> URL {
        let component = tailnet.addingPercentEncoding(withAllowedCharacters: unreserved) ?? tailnet
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/tailnet/\(component)/devices"
        components.queryItems = [URLQueryItem(name: "fields", value: "all")]
        return components.url ?? baseURL
    }

    /// The characters that never need escaping in a URL component or a form
    /// body (RFC 3986 "unreserved").
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Tokens

    private func bearerToken(forceNew: Bool) async throws -> (value: String, cameFromCache: Bool) {
        switch credentials {
        case .accessToken(let token):
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw TailscaleError.accessTokenRejected }
            return (token, false)

        case .oauthClient(let id, let secret):
            if !forceNew, let cachedToken, now() < cachedToken.renewAt {
                return (cachedToken.value, true)
            }
            cachedToken = nil
            // Measured from before the request, so time spent on the network
            // only ever makes the token look older than it is.
            let requestedAt = now()
            let granted = try await requestToken(clientID: id, clientSecret: secret)
            let lifetime = max(0, granted.lifetime - Self.tokenRenewalMargin)
            if lifetime > 0 {
                cachedToken = (granted.value, requestedAt.addingTimeInterval(lifetime))
            }
            return (granted.value, false)
        }
    }

    /// Trades the OAuth client for an access token (the OAuth 2.0 client
    /// credentials grant).
    private func requestToken(
        clientID: String,
        clientSecret: String
    ) async throws -> (value: String, lifetime: TimeInterval) {
        var request = URLRequest(url: baseURL.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("grant_type", "client_credentials"),
        ])

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            // OAuth answers a bad client with 400 or 401.
            if response.statusCode == 400 || response.statusCode == 401 {
                throw TailscaleError.oauthClientRejected
            }
            throw Self.error(forStatus: response.statusCode, body: data, tailnet: tailnet)
        }
        guard let grant = try? JSONDecoder().decode(TokenGrant.self, from: data),
              !grant.accessToken.isEmpty else {
            throw TailscaleError.unreadableResponse
        }
        return (grant.accessToken, grant.expiresIn)
    }

    static func formEncoded(_ fields: [(name: String, value: String)]) -> Data {
        let body = fields
            .map { field in
                let name = field.name.addingPercentEncoding(withAllowedCharacters: unreserved)
                let value = field.value.addingPercentEncoding(withAllowedCharacters: unreserved)
                return "\(name ?? field.name)=\(value ?? field.value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private struct TokenGrant: Decodable {
        var accessToken: String
        /// Seconds the token is good for. Zero when the server does not say,
        /// which means the token is used once and not kept.
        var expiresIn: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            // A number by the standard, but some servers send it as text.
            if let seconds = try? c.decode(TimeInterval.self, forKey: .expiresIn) {
                expiresIn = seconds
            } else if let text = try? c.decode(String.self, forKey: .expiresIn) {
                expiresIn = TimeInterval(text) ?? 0
            } else {
                expiresIn = 0
            }
        }
    }

    // MARK: Reading responses

    /// Turns an unsuccessful HTTP status into the error to show for it.
    static func error(forStatus status: Int, body: Data, tailnet: String) -> TailscaleError {
        switch status {
        case 401: .accessTokenRejected
        case 403: .accessDenied
        case 404: .tailnetNotFound(tailnet)
        case 429: .rateLimited
        default: .server(status: status, message: serverMessage(in: body))
        }
    }

    /// The explanation Tailscale puts in an error body: `{"message": "…"}`.
    private static func serverMessage(in body: Data) -> String? {
        struct ErrorBody: Decodable {
            var message: String?
        }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reads the body of a successful device listing.
    ///
    /// - Parameter localAddresses: This device's own addresses in canonical
    ///   form. The API has no notion of "this device", so the one that owns
    ///   any of these addresses is marked as it.
    static func devices(
        fromResponse data: Data,
        localAddresses: Set<String> = []
    ) throws -> [TailscaleDevice] {
        guard let list = try? JSONDecoder().decode(DeviceList.self, from: data) else {
            throw TailscaleError.unreadableResponse
        }
        return (list.devices ?? []).compactMap { entry in
            guard let device = entry.value else { return nil }
            // `nodeId` is the stable ID, the one a local Tailscale client
            // reports too; `id` is the older numeric one.
            guard let id = [device.nodeId, device.id]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else { return nil }

            let dnsName = TailscaleDevice.trimmedDNSName(device.name)
            let addresses = TailscaleDevice.orderedAddresses(device.addresses)
            let isSelf = addresses.contains { address in
                LocalInterfaceAddresses.canonical(address).map(localAddresses.contains) ?? false
            }
            let isOnline = device.connectedToControl ?? false
            return TailscaleDevice(
                id: id,
                name: TailscaleDevice.displayName(
                    hostName: device.hostname, dnsName: dnsName, addresses: addresses),
                dnsName: dnsName,
                addresses: addresses,
                os: device.os ?? "",
                isOnline: isOnline,
                // The API leaves this out for connected devices; should it
                // ever not, a time in the past says nothing about one.
                lastSeen: isOnline ? nil : TailscaleDevice.timestamp(device.lastSeen),
                isSelf: isSelf)
        }
    }

    private struct DeviceList: Decodable {
        var devices: [TailscaleDevice.Lenient<Device>]?
    }

    /// The fields of the API's device object that are used here.
    private struct Device: Decodable {
        var id: String?
        var nodeId: String?
        /// The MagicDNS name, despite the plain key.
        var name: String?
        var hostname: String?
        var addresses: [String]?
        var os: String?
        /// Left out by the API while the device is connected.
        var lastSeen: String?
        var connectedToControl: Bool?
    }
}

// MARK: - This device's addresses

/// The IP addresses of this device's network interfaces.
///
/// A device that is connected to a tailnet has its Tailscale address on one
/// of its interfaces, which is how the device the app runs on is recognised
/// in a list that came from the HTTP API.
enum LocalInterfaceAddresses {
    /// Every address currently assigned to an interface, in canonical form.
    @Sendable
    static func current() -> Set<String> {
        var addresses = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return addresses }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                    var value = socket.pointee.sin_addr
                    if let text = text(AF_INET, &value) {
                        addresses.insert(text)
                    }
                }
            case AF_INET6:
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                    var value = socket.pointee.sin6_addr
                    if let text = text(AF_INET6, &value) {
                        addresses.insert(text)
                    }
                }
            default:
                break
            }
        }
        return addresses
    }

    /// One spelling per address, so `FD7A:115C:A1E0:0:0:0:0:1` and
    /// `fd7a:115c:a1e0::1` compare equal. `nil` for text that is not an IP
    /// address.
    static func canonical(_ address: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return text(AF_INET, &v4)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return text(AF_INET6, &v6)
        }
        return nil
    }

    private static func text(_ family: Int32, _ address: UnsafeRawPointer) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

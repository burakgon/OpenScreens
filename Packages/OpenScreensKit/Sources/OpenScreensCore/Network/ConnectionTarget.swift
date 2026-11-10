import Foundation

/// An address to connect to that did not come from the library: something the
/// user typed into Quick Connect, or a `vnc://` link they opened.
public struct ConnectionTarget: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    public var name: String?
    public var kind: ComputerKind
    /// Route the connection through an SSH tunnel.
    public var usesSSH: Bool
    public var observeOnly: Bool
    /// Where the address was found, kept if the connection is saved.
    public var origin: ComputerOrigin

    public init(
        host: String,
        port: Int = Computer.defaultPort,
        username: String? = nil,
        password: String? = nil,
        name: String? = nil,
        kind: ComputerKind = .mac,
        usesSSH: Bool = false,
        observeOnly: Bool = false,
        origin: ComputerOrigin = .manual
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.name = name
        self.kind = kind
        self.usesSSH = usesSSH
        self.observeOnly = observeOnly
        self.origin = origin
    }

    /// Schemes OpenScreens registers for.
    public static let urlSchemes: Set<String> = ["vnc", "openscreens", "openscreens-ssh"]

    // MARK: - Parsing

    /// Parses what a person might type into an address field.
    ///
    /// Accepts bare hosts and addresses, `host:port`, `user@host`, bracketed
    /// and bare IPv6, VNC display numbers (`host:1` means port 5901), and full
    /// `vnc://` URLs.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
            guard ConnectionTarget.urlSchemes.contains(scheme),
                  let url = URL(string: trimmed) else { return nil }
            self.init(url: url)
            return
        }

        var remainder = Substring(trimmed)
        var username: String?
        var password: String?
        if let at = remainder.lastIndex(of: "@") {
            let credentials = remainder[..<at]
            remainder = remainder[remainder.index(after: at)...]
            if let colon = credentials.firstIndex(of: ":") {
                username = String(credentials[..<colon])
                password = String(credentials[credentials.index(after: colon)...])
            } else {
                username = String(credentials)
            }
        }

        guard let (host, port) = ConnectionTarget.splitHostAndPort(remainder) else { return nil }
        self.init(
            host: host,
            port: port ?? Computer.defaultPort,
            username: username.flatMap { $0.isEmpty ? nil : $0 },
            password: password.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Parses a connection link.
    ///
    /// `vnc://[user[:password]@]host[:port]` is the conventional form.
    /// `openscreens://` accepts the same and adds query options:
    /// `name`, `kind`, `ssh=1`, `observe=1`.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              ConnectionTarget.urlSchemes.contains(scheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.host, !rawHost.isEmpty else { return nil }

        // URLComponents keeps IPv6 brackets and percent-encodes zone IDs.
        var host = rawHost
        let isBracketed = host.hasPrefix("[") && host.hasSuffix("]")
        if isBracketed {
            host = String(host.dropFirst().dropLast())
        }
        host = host.removingPercentEncoding ?? host
        guard isBracketed || host.contains(":")
            ? ConnectionTarget.isIPv6Address(host)
            : ConnectionTarget.isPlausibleHost(host) else { return nil }
        if let port = components.port, !ConnectionTarget.isValidPort(port) {
            return nil
        }

        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
        func flag(_ name: String) -> Bool {
            guard let value = query[name]?.lowercased() else { return false }
            return value.isEmpty || value == "1" || value == "true" || value == "yes"
        }

        self.init(
            host: host,
            port: components.port.map(ConnectionTarget.normalizedPort) ?? Computer.defaultPort,
            username: components.user.flatMap { $0.isEmpty ? nil : $0 },
            password: components.password.flatMap { $0.isEmpty ? nil : $0 },
            name: query["name"].flatMap { $0.isEmpty ? nil : $0 },
            kind: query["kind"].flatMap(ComputerKind.init(rawValue:)) ?? .mac,
            usesSSH: scheme == "openscreens-ssh" || flag("ssh"),
            observeOnly: flag("observe"))
    }

    /// A shareable link for a computer. Never includes a password.
    public static func url(for computer: Computer) -> URL? {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = computer.host.contains(":") ? "[\(computer.host)]" : computer.host
        if let username = computer.username, !username.isEmpty {
            components.user = username
        }
        if computer.port != Computer.defaultPort {
            components.port = computer.port
        }
        return components.url
    }

    // MARK: - Helpers

    /// VNC convention: small numbers are display numbers, offset from 5900.
    static func normalizedPort(_ value: Int) -> Int {
        (0..<100).contains(value) ? Computer.defaultPort + value : value
    }

    static func splitHostAndPort(_ text: Substring) -> (host: String, port: Int?)? {
        guard !text.isEmpty else { return nil }

        // [v6]:port
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard isIPv6Address(host) else { return nil }
            if rest.isEmpty { return (host, nil) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), isValidPort(port) else {
                return nil
            }
            return (host, normalizedPort(port))
        }

        let colons = text.filter { $0 == ":" }.count
        // Several colons can only be a bare IPv6 address, which cannot
        // carry a port.
        if colons > 1 {
            return isIPv6Address(String(text)) ? (String(text), nil) : nil
        }
        if colons == 1, let colon = text.firstIndex(of: ":") {
            let host = String(text[..<colon])
            let portText = text[text.index(after: colon)...]
            guard !host.isEmpty, let port = Int(portText), isValidPort(port),
                  isPlausibleHost(host) else { return nil }
            return (host, normalizedPort(port))
        }
        return isPlausibleHost(String(text)) ? (String(text), nil) : nil
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (0...65535).contains(port)
    }

    /// A host name or IPv4 address, going by the characters it is made of.
    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255 else { return false }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// An IPv6 address, with or without a `%zone` naming the interface.
    private static func isIPv6Address(_ text: String) -> Bool {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._")
            guard !parts[1].isEmpty, parts[1].unicodeScalars.allSatisfy(allowed.contains) else {
                return false
            }
        }
        var address = in6_addr()
        return inet_pton(AF_INET6, String(parts[0]), &address) == 1
    }
}

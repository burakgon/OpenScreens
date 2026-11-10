import Foundation

/// Something the app was asked to open from outside: a link, a Shortcut,
/// Siri, Spotlight or a widget.
public enum AppLink: Hashable, Sendable {
    /// A computer in the library.
    case computer(UUID)
    /// An address that may not be in the library.
    case target(ConnectionTarget)

    /// Parses a link.
    ///
    /// `openscreens://open?id=<uuid>` refers to a saved computer; anything
    /// else is treated as an address — see ``ConnectionTarget/init(url:)``.
    public init?(url: URL) {
        if url.scheme?.lowercased() == "openscreens",
           url.host(percentEncoded: false)?.lowercased() == "open" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: value) else { return nil }
            self = .computer(id)
            return
        }
        guard let target = ConnectionTarget(url: url) else { return nil }
        self = .target(target)
    }

    /// The link that opens a saved computer.
    public static func url(forComputer id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = "openscreens"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        // The components above are always valid; the fallback is unreachable.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

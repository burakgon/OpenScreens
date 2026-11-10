import Foundation

/// Where the app points people for more.
public enum AppLinks {
    public static let repository = URL(string: "https://github.com/burakgon/OpenScreens")!
    public static let issues = URL(string: "https://github.com/burakgon/OpenScreens/issues")!
    public static let documentation = URL(string: "https://github.com/burakgon/OpenScreens#readme")!
    public static let releases = URL(string: "https://github.com/burakgon/OpenScreens/releases")!
    /// Where Tailscale access tokens and OAuth clients are created.
    public static let tailscaleKeys = URL(string: "https://login.tailscale.com/admin/settings/keys")!
}

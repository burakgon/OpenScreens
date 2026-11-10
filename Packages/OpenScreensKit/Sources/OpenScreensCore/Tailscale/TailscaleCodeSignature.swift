#if os(macOS)

import Foundation
import Security

/// Tells Tailscale's own command-line tool from anything else that may be
/// sitting where the tool is expected.
///
/// The tool is run without the user asking for it, on a schedule, as a child
/// of this app — with this app's standing where the system's privacy
/// permissions are concerned. A file at one of the usual paths is not enough
/// to earn that: some of those paths can be written to by any program the
/// user runs. What is run has to be signed by Tailscale.
enum TailscaleCodeSignature {
    /// Tailscale Inc.'s Apple developer team.
    static let teamIdentifier = "W5364U7YZB"

    /// The Mac client as the App Store distributes it, and as Tailscale
    /// distributes it directly. Its main executable is the command-line tool.
    static let identifiers = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]

    /// What the code's signature has to satisfy, in the code requirement
    /// language: issued through the Mac App Store, or signed with a
    /// Developer ID belonging to Tailscale's team; and one of the client's
    /// identifiers either way.
    static let requirement: String = {
        let named = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return """
            (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] \
            or anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] \
            and certificate leaf[subject.OU] = "\(teamIdentifier)") \
            and (\(named))
            """
    }()

    /// Whether the file at `executable` is Tailscale's tool: its signature
    /// is valid, satisfies ``requirement`` and names Tailscale's team.
    ///
    /// Anything that cannot be checked — a missing file, a script, a binary
    /// that is not signed or is signed by someone else — is not.
    static func isTailscale(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement)
                == errSecSuccess,
              let requirement else { return false }

        // The executable is what is run, in whichever architecture the
        // system picks. The rest of the bundle it sits in is not checked:
        // that would mean hashing the whole app before every listing.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            return false
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signing = information as? [String: Any],
              let team = signing[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return team == teamIdentifier
    }
}

#endif

import CryptoKit
import Foundation
import NIOSSH

/// A private key for signing in to SSH servers.
///
/// Covers the algorithms swift-nio-ssh can authenticate with: Ed25519, and
/// ECDSA over the NIST P-256, P-384 and P-521 curves. RSA and DSA keys are
/// recognised only so they can be turned away with a clear explanation.
///
/// A value holds the key material unprotected in memory. Keys that should
/// outlive the moment they are used belong in an ``SSHKeyStore``.
public struct SSHPrivateKey: Sendable {

    /// The key itself, in the CryptoKit type for its algorithm.
    enum Material: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
    }

    let material: Material

    /// The free-form label kept inside the key file, usually `user@host`.
    public var comment: String

    init(material: Material, comment: String = "") {
        self.material = material
        self.comment = comment
    }

    // MARK: Creating

    /// Makes a new Ed25519 key, the kind to prefer for new keys: small, fast
    /// and accepted by every current SSH server.
    public static func generateEd25519() -> SSHPrivateKey {
        SSHPrivateKey(material: .ed25519(Curve25519.Signing.PrivateKey()))
    }

    /// Reads a private key in OpenSSH's own format, the one `ssh-keygen` has
    /// written by default since OpenSSH 7.8 (`-----BEGIN OPENSSH PRIVATE
    /// KEY-----`).
    ///
    /// Passphrase-protected keys are supported when they use the `bcrypt` key
    /// derivation with an AES cipher in CTR, CBC or GCM mode; `ssh-keygen`
    /// uses `aes256-ctr` unless told otherwise. Unlocking such a key
    /// deliberately takes a noticeable fraction of a second, so call this
    /// away from the main actor.
    ///
    /// - Parameters:
    ///   - text: The contents of the key file.
    ///   - passphrase: The passphrase, for a protected key. Ignored when the
    ///     key is not protected.
    /// - Throws: ``SSHKeyError``. `.passphraseRequired` means the key is
    ///   protected and `passphrase` was `nil` or empty, so it doubles as the
    ///   way to find out whether to ask for one.
    public init(openSSH text: String, passphrase: String?) throws(SSHKeyError) {
        do {
            self = try OpenSSHPrivateKeyFile.decode(text, passphrase: passphrase)
        } catch let error as SSHKeyError {
            throw error
        } catch {
            // The only other error is the wire reader running out of bytes.
            throw .malformed("The key data ends unexpectedly.")
        }
    }

    // MARK: Describing

    /// The SSH name of the key's algorithm, such as `ssh-ed25519`.
    public var keyType: String {
        switch material {
        case .ed25519: "ssh-ed25519"
        case .p256: "ecdsa-sha2-nistp256"
        case .p384: "ecdsa-sha2-nistp384"
        case .p521: "ecdsa-sha2-nistp521"
        }
    }

    /// The algorithm as people refer to it: "Ed25519", "ECDSA P-256", …
    public var algorithmName: String {
        switch material {
        case .ed25519: "Ed25519"
        case .p256: "ECDSA P-256"
        case .p384: "ECDSA P-384"
        case .p521: "ECDSA P-521"
        }
    }

    /// The public key's SHA-256 fingerprint, written the way
    /// `ssh-keygen -lf` prints it: `SHA256:` and unpadded base64.
    public var fingerprint: String {
        SSHFingerprint.sha256(ofPublicKeyBlob: publicKeyBlob)
    }

    // MARK: Exporting

    /// The public key as a line for a server's `authorized_keys` file,
    /// without a comment.
    public var openSSHPublicKey: String {
        "\(keyType) \(publicKeyBlob.base64EncodedString())"
    }

    /// The public key as an `authorized_keys` line ending in `comment`.
    public func openSSHPublicKey(comment: String) -> String {
        // The comment runs to the end of the line, so it must not contain one.
        let label = comment
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? openSSHPublicKey : "\(openSSHPublicKey) \(label)"
    }

    /// The private key in OpenSSH format with no passphrase: what
    /// ``init(openSSH:passphrase:)`` reads and what `ssh -i` accepts. Treat
    /// the result as the secret it is.
    public var openSSHPrivateKey: String {
        OpenSSHPrivateKeyFile.encode(self)
    }

    // MARK: Authenticating

    /// The key in the form swift-nio-ssh signs authentication requests with.
    public var nioSSHPrivateKey: NIOSSHPrivateKey {
        switch material {
        case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): NIOSSHPrivateKey(p521Key: key)
        }
    }

    // MARK: Wire encoding

    /// The name of the key's elliptic curve in ECDSA encodings; `nil` for
    /// Ed25519, whose encoding does not name a curve.
    var curveName: String? {
        switch material {
        case .ed25519: nil
        case .p256: "nistp256"
        case .p384: "nistp384"
        case .p521: "nistp521"
        }
    }

    /// The public key on its own: the 32-byte point for Ed25519, the
    /// uncompressed point (`04 ‖ x ‖ y`) for ECDSA.
    var publicKeyBytes: Data {
        switch material {
        case .ed25519(let key): key.publicKey.rawRepresentation
        case .p256(let key): key.publicKey.x963Representation
        case .p384(let key): key.publicKey.x963Representation
        case .p521(let key): key.publicKey.x963Representation
        }
    }

    /// The secret on its own: the 32-byte seed for Ed25519, the scalar padded
    /// to the size of the curve's field for ECDSA.
    var privateKeyBytes: Data {
        switch material {
        case .ed25519(let key): key.rawRepresentation
        case .p256(let key): key.rawRepresentation
        case .p384(let key): key.rawRepresentation
        case .p521(let key): key.rawRepresentation
        }
    }

    /// The public key in SSH wire encoding (RFC 4253 §6.6, RFC 5656 §3.1,
    /// RFC 8709 §4). This is what is base64-encoded in `authorized_keys` and
    /// hashed for the fingerprint.
    var publicKeyBlob: Data {
        var writer = SSHWireWriter()
        writer.writeString(keyType)
        if let curveName {
            writer.writeString(curveName)
        }
        writer.writeString(publicKeyBytes)
        return writer.data
    }
}

// MARK: - Errors

/// Why a private key could not be read.
public enum SSHKeyError: Error, Equatable, Sendable {
    /// The text is not a well-formed OpenSSH private key. The associated
    /// value says what is wrong with it.
    case malformed(String)

    /// The key uses an algorithm that cannot be used to sign in. The
    /// associated value names it, for example "RSA".
    case unsupportedKeyType(String)

    /// The key is stored in a container other than OpenSSH's.
    case unsupportedFormat(Format)

    /// The key is protected with a cipher or key derivation this build
    /// cannot undo. The associated value names it.
    case unsupportedCipher(String)

    /// The key is protected by a passphrase and none was given.
    case passphraseRequired

    /// The passphrase does not unlock the key.
    case wrongPassphrase

    /// Key file formats that are recognised but not read.
    public enum Format: Equatable, Sendable {
        /// The PEM formats OpenSSH wrote before 7.8 and OpenSSL still does
        /// (`BEGIN EC PRIVATE KEY`, `BEGIN PRIVATE KEY`, …).
        case pem
        /// A PuTTY `.ppk` file.
        case putty
    }
}

extension SSHKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            "This is not a usable OpenSSH private key. \(detail)"
        case .unsupportedKeyType(let kind):
            "\(kind) keys are not supported; use an Ed25519 or ECDSA key."
        case .unsupportedFormat(.pem):
            "This key is in the older PEM format. Convert it to OpenSSH format with "
                + "“ssh-keygen -p -f <key file>” and try again."
        case .unsupportedFormat(.putty):
            "PuTTY key files are not supported. Export the key from PuTTYgen in "
                + "OpenSSH format and try again."
        case .unsupportedCipher(let name):
            "This key is protected with \(name), which is not supported. Protect it "
                + "with “ssh-keygen -p -f <key file>” using the default settings and try again."
        case .passphraseRequired:
            "This key is protected by a passphrase."
        case .wrongPassphrase:
            "The passphrase is not correct."
        }
    }
}

import CommonCrypto
import CryptoKit
import Foundation

/// Reads and writes OpenSSH's private key container, `openssh-key-v1`.
///
/// The layout, from OpenSSH's `PROTOCOL.key`, is base64 between the armour
/// lines of:
///
///     "openssh-key-v1" 0x00        magic
///     string  cipher name          "none" for an unprotected key
///     string  KDF name             "none" or "bcrypt"
///     string  KDF options          for bcrypt: string salt, uint32 rounds
///     uint32  number of keys       always 1 in practice
///     string  public key
///     string  private section      encrypted with the cipher above
///     bytes   authentication tag   only for AEAD ciphers; not length-prefixed
///
/// and the private section, once decrypted, holds:
///
///     uint32  check                the same random value twice; a mismatch
///     uint32  check                means the passphrase was wrong
///     string  key type
///     …       key-specific fields
///     string  comment
///     bytes   padding              1, 2, 3, … up to the cipher's block size
enum OpenSSHPrivateKeyFile {
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Data("openssh-key-v1".utf8) + [0]

    /// Padding granularity of the "none" cipher.
    private static let unencryptedBlockSize = 8

    /// A sanity limit on the cost a key file may ask for. `ssh-keygen` uses 16
    /// or 24 rounds and people who raise it stay in the hundreds; a file
    /// asking for more than this is either damaged or trying to stall the app.
    private static let maximumKDFRounds: UInt32 = 4096

    // MARK: Decoding

    static func decode(_ text: String, passphrase: String?) throws -> SSHPrivateKey {
        let container = try unarmor(text)
        guard container.starts(with: magic) else {
            throw SSHKeyError.malformed("It does not start with the OpenSSH key header.")
        }

        var reader = SSHWireReader(container.dropFirst(magic.count))
        let cipherName = try reader.readText()
        let kdfName = try reader.readText()
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw SSHKeyError.malformed("It holds \(keyCount) keys; exactly one is expected.")
        }
        let publicKeyBlob = try reader.readString()
        let privateSection = try reader.readString()
        let authenticationTag = reader.readRemaining()

        // The public half is stored in the clear, so a key of a kind that
        // cannot be used is reported without first asking for its passphrase.
        var publicReader = SSHWireReader(publicKeyBlob)
        let publicKeyType = try publicReader.readText()
        guard supportedKeyTypes.contains(publicKeyType) else {
            throw SSHKeyError.unsupportedKeyType(displayName(forKeyType: publicKeyType))
        }

        if cipherName == "none" {
            guard kdfName == "none", authenticationTag.isEmpty else {
                throw SSHKeyError.malformed("Its header is inconsistent.")
            }
            return try decodePrivateSection(
                privateSection,
                expectedPublicKeyBlob: publicKeyBlob,
                blockSize: unencryptedBlockSize,
                isEncrypted: false)
        }

        guard let cipher = Cipher.named(cipherName) else {
            throw SSHKeyError.unsupportedCipher(cipherName)
        }
        guard kdfName == "bcrypt" else {
            throw SSHKeyError.unsupportedCipher("the “\(kdfName)” key derivation")
        }
        guard let passphrase, !passphrase.isEmpty else {
            throw SSHKeyError.passphraseRequired
        }
        let plaintext = try decrypt(
            privateSection,
            authenticationTag: authenticationTag,
            cipher: cipher,
            kdfOptions: kdfOptions,
            passphrase: passphrase)
        return try decodePrivateSection(
            plaintext,
            expectedPublicKeyBlob: publicKeyBlob,
            blockSize: cipher.blockSize,
            isEncrypted: true)
    }

    private static let supportedKeyTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    /// Turns an SSH key type into the word that fits "… keys are not supported".
    private static func displayName(forKeyType type: String) -> String {
        switch type {
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case _ where type.hasPrefix("sk-"): "FIDO security"
        default: type
        }
    }

    /// Strips the armour lines and base64 from a key file.
    private static func unarmor(_ text: String) throws(SSHKeyError) -> Data {
        guard let begin = text.range(of: beginMarker) else {
            throw explainMissingHeader(in: text)
        }
        guard let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) else {
            throw .malformed("Its last line is missing; the file may have been cut short.")
        }
        // Keys get pasted from terminals and mail, so tolerate any mix of line
        // endings, indentation and stray spaces inside the body.
        let body = String(text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace })
        guard !body.isEmpty, let data = Data(base64Encoded: body) else {
            throw .malformed("Its contents are not valid base64.")
        }
        return data
    }

    /// Works out what the user handed over instead of an OpenSSH private key.
    private static func explainMissingHeader(in text: String) -> SSHKeyError {
        if text.contains("-----BEGIN RSA PRIVATE KEY-----") {
            return .unsupportedKeyType("RSA")
        }
        if text.contains("-----BEGIN DSA PRIVATE KEY-----") {
            return .unsupportedKeyType("DSA")
        }
        let pemHeaders = [
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----",
        ]
        if pemHeaders.contains(where: text.contains) {
            return .unsupportedFormat(.pem)
        }
        if text.contains("PuTTY-User-Key-File") {
            return .unsupportedFormat(.putty)
        }
        if SSHHostKey(openSSHPublicKey: text) != nil {
            return .malformed("This is a public key. Choose the private key that goes with it.")
        }
        return .malformed("The “BEGIN OPENSSH PRIVATE KEY” line is missing.")
    }

    private static func decodePrivateSection(
        _ section: Data,
        expectedPublicKeyBlob: Data,
        blockSize: Int,
        isEncrypted: Bool
    ) throws -> SSHPrivateKey {
        guard section.count % blockSize == 0 else {
            throw SSHKeyError.malformed("Its private section has the wrong length.")
        }
        var reader = SSHWireReader(section)
        let firstCheck = try reader.readUInt32()
        let secondCheck = try reader.readUInt32()
        guard firstCheck == secondCheck else {
            // Decrypting with the wrong key yields noise, and the two check
            // values are how that is noticed for ciphers without a tag.
            throw isEncrypted
                ? SSHKeyError.wrongPassphrase
                : SSHKeyError.malformed("Its check values do not match.")
        }

        let keyType = try reader.readText()
        let material: SSHPrivateKey.Material
        switch keyType {
        case "ssh-ed25519":
            let publicKey = try reader.readString()
            // OpenSSH stores the 32-byte seed followed by a copy of the public key.
            let secret = try reader.readString()
            guard publicKey.count == 32, secret.count == 64, secret.suffix(32) == publicKey,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
            else {
                throw SSHKeyError.malformed("Its Ed25519 key is not valid.")
            }
            material = .ed25519(key)
        case "ecdsa-sha2-nistp256":
            let scalar = try readECDSAScalar(from: &reader, curve: "nistp256", byteCount: 32)
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar) else {
                throw SSHKeyError.malformed("Its ECDSA key is not valid.")
            }
            material = .p256(key)
        case "ecdsa-sha2-nistp384":
            let scalar = try readECDSAScalar(from: &reader, curve: "nistp384", byteCount: 48)
            guard let key = try? P384.Signing.PrivateKey(rawRepresentation: scalar) else {
                throw SSHKeyError.malformed("Its ECDSA key is not valid.")
            }
            material = .p384(key)
        case "ecdsa-sha2-nistp521":
            let scalar = try readECDSAScalar(from: &reader, curve: "nistp521", byteCount: 66)
            guard let key = try? P521.Signing.PrivateKey(rawRepresentation: scalar) else {
                throw SSHKeyError.malformed("Its ECDSA key is not valid.")
            }
            material = .p521(key)
        default:
            throw SSHKeyError.unsupportedKeyType(displayName(forKeyType: keyType))
        }

        let comment = try reader.readText()
        let padding = reader.readRemaining()
        let paddingIsValid = padding.count < blockSize
            && padding.enumerated().allSatisfy { $0.element == UInt8(truncatingIfNeeded: $0.offset + 1) }
        guard paddingIsValid else {
            throw SSHKeyError.malformed("Its padding is not valid.")
        }

        // The public key is derived from the secret here, so comparing it with
        // the copy stored in the clear proves the two halves belong together.
        let key = SSHPrivateKey(material: material, comment: comment)
        guard key.publicKeyBlob == expectedPublicKeyBlob else {
            throw SSHKeyError.malformed("Its public and private halves do not match.")
        }
        return key
    }

    /// Reads the fields of an ECDSA private key and returns the secret scalar
    /// at exactly the size of the curve's field, as CryptoKit wants it.
    private static func readECDSAScalar(
        from reader: inout SSHWireReader,
        curve: String,
        byteCount: Int
    ) throws -> Data {
        let curveName = try reader.readText()
        // The public point is skipped: it is recomputed from the scalar and
        // checked against the unencrypted copy once the key is built.
        _ = try reader.readString()
        // An mpint drops leading zero bytes, so the scalar can come up short.
        let magnitude = try reader.readMagnitude()
        guard curveName == curve, !magnitude.isEmpty, magnitude.count <= byteCount else {
            throw SSHKeyError.malformed("Its ECDSA key is not valid.")
        }
        return Data(repeating: 0, count: byteCount - magnitude.count) + magnitude
    }

    // MARK: Decrypting

    /// The ciphers OpenSSH can protect a key file with, less the two this
    /// build does not implement (`3des-cbc` and `chacha20-poly1305@openssh.com`).
    private struct Cipher {
        enum Mode {
            case ctr
            case cbc
            case gcm
        }

        let mode: Mode
        let keyLength: Int
        let ivLength: Int
        /// Length of the authentication tag that follows the ciphertext.
        let tagLength: Int
        let blockSize = kCCBlockSizeAES128

        static func named(_ name: String) -> Cipher? {
            switch name {
            case "aes128-ctr": Cipher(mode: .ctr, keyLength: 16, ivLength: 16, tagLength: 0)
            case "aes192-ctr": Cipher(mode: .ctr, keyLength: 24, ivLength: 16, tagLength: 0)
            case "aes256-ctr": Cipher(mode: .ctr, keyLength: 32, ivLength: 16, tagLength: 0)
            case "aes128-cbc": Cipher(mode: .cbc, keyLength: 16, ivLength: 16, tagLength: 0)
            case "aes192-cbc": Cipher(mode: .cbc, keyLength: 24, ivLength: 16, tagLength: 0)
            case "aes256-cbc": Cipher(mode: .cbc, keyLength: 32, ivLength: 16, tagLength: 0)
            case "aes128-gcm@openssh.com": Cipher(mode: .gcm, keyLength: 16, ivLength: 12, tagLength: 16)
            case "aes256-gcm@openssh.com": Cipher(mode: .gcm, keyLength: 32, ivLength: 12, tagLength: 16)
            default: nil
            }
        }
    }

    private static func decrypt(
        _ ciphertext: Data,
        authenticationTag: Data,
        cipher: Cipher,
        kdfOptions: Data,
        passphrase: String
    ) throws -> Data {
        var options = SSHWireReader(kdfOptions)
        let salt = try options.readString()
        let rounds = try options.readUInt32()
        guard !salt.isEmpty, rounds >= 1 else {
            throw SSHKeyError.malformed("Its key derivation settings are not valid.")
        }
        guard rounds <= maximumKDFRounds else {
            throw SSHKeyError.unsupportedCipher("\(rounds) rounds of key derivation")
        }
        guard !ciphertext.isEmpty, ciphertext.count % cipher.blockSize == 0,
              authenticationTag.count == cipher.tagLength else {
            throw SSHKeyError.malformed("Its private section has the wrong length.")
        }

        // One derivation yields the key followed by the IV.
        guard let derived = BcryptPBKDF.deriveKey(
            password: [UInt8](passphrase.utf8),
            salt: [UInt8](salt),
            rounds: Int(rounds),
            length: cipher.keyLength + cipher.ivLength)
        else {
            throw SSHKeyError.malformed("Its key derivation settings are not valid.")
        }
        let key = Data(derived[..<cipher.keyLength])
        let iv = Data(derived[cipher.keyLength...])

        switch cipher.mode {
        case .gcm:
            // The whole private section is one AEAD message with no
            // associated data, and the derived IV is its nonce.
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: iv),
                    ciphertext: ciphertext,
                    tag: authenticationTag)
                return try AES.GCM.open(box, using: SymmetricKey(data: key))
            } catch {
                // A tag that does not verify means the key is wrong.
                throw SSHKeyError.wrongPassphrase
            }
        case .ctr:
            // The IV is the initial 128-bit big-endian counter, as OpenSSH runs it.
            return try aesDecrypt(
                ciphertext, key: key, iv: iv,
                mode: CCMode(kCCModeCTR), options: CCModeOptions(kCCModeOptionCTR_BE))
        case .cbc:
            return try aesDecrypt(
                ciphertext, key: key, iv: iv,
                mode: CCMode(kCCModeCBC), options: 0)
        }
    }

    /// Decrypts with AES in a mode CryptoKit does not offer. The input is
    /// always a whole number of blocks, so no padding is involved.
    private static func aesDecrypt(
        _ input: Data,
        key: Data,
        iv: Data,
        mode: CCMode,
        options: CCModeOptions
    ) throws -> Data {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress,
                    keyBytes.count, nil, 0, 0, options, &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else {
            throw SSHKeyError.malformed("Its private section could not be decrypted.")
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: input.count)
        var producedCount = 0
        let updated = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor, inputBytes.baseAddress, inputBytes.count,
                    outputBytes.baseAddress, outputBytes.count, &producedCount)
            }
        }
        guard updated == kCCSuccess, producedCount == input.count else {
            throw SSHKeyError.malformed("Its private section could not be decrypted.")
        }
        return output
    }

    // MARK: Encoding

    /// Writes `key` as an unprotected OpenSSH private key file.
    static func encode(_ key: SSHPrivateKey) -> String {
        var section = SSHWireWriter()
        let check = UInt32.random(in: UInt32.min...UInt32.max)
        section.writeUInt32(check)
        section.writeUInt32(check)
        section.writeString(key.keyType)
        if let curveName = key.curveName {
            // ECDSA: curve name, public point, then the scalar as an mpint.
            section.writeString(curveName)
            section.writeString(key.publicKeyBytes)
            section.writeMagnitude(key.privateKeyBytes)
        } else {
            // Ed25519: public key, then the seed with the public key appended.
            section.writeString(key.publicKeyBytes)
            section.writeString(key.privateKeyBytes + key.publicKeyBytes)
        }
        section.writeString(key.comment)
        var padding: UInt8 = 1
        while section.data.count % unencryptedBlockSize != 0 {
            section.writeBytes(Data([padding]))
            padding += 1
        }

        var file = SSHWireWriter()
        file.writeBytes(magic)
        file.writeString("none")
        file.writeString("none")
        file.writeString(Data())
        file.writeUInt32(1)
        file.writeString(key.publicKeyBlob)
        file.writeString(section.data)

        // ssh-keygen wraps the base64 at 70 columns; match it so that exported
        // files look like the ones people already have.
        let encoded = file.data.base64EncodedString()
        var lines = [beginMarker]
        var lineStart = encoded.startIndex
        while lineStart < encoded.endIndex {
            let lineEnd = encoded.index(lineStart, offsetBy: 70, limitedBy: encoded.endIndex)
                ?? encoded.endIndex
            lines.append(String(encoded[lineStart..<lineEnd]))
            lineStart = lineEnd
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }
}

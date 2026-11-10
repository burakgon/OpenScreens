import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSHPrivateKey")
    struct SSHPrivateKeyTests {

        // MARK: Keys written by ssh-keygen

        @Test(arguments: SSHKeyFixtures.all)
        func readsAKeyWrittenBySSHKeygen(_ fixture: SSHKeyFixtures.Key) throws {
            let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: fixture.passphrase)

            #expect(key.openSSHPublicKey == fixture.publicKey)
            #expect(key.fingerprint == fixture.fingerprint)
            #expect(key.algorithmName == fixture.algorithmName)
            #expect(key.comment == fixture.comment)
            #expect(fixture.publicKey.hasPrefix(key.keyType + " "))
        }

        @Test(arguments: SSHKeyFixtures.all)
        func exportsAKeyItCanReadBack(_ fixture: SSHKeyFixtures.Key) throws {
            let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: fixture.passphrase)
            // The export carries no passphrase, whatever the original had.
            let copy = try SSHPrivateKey(openSSH: key.openSSHPrivateKey, passphrase: nil)

            // The public key is derived from the secret, so equal public keys
            // mean the secret survived the round trip.
            #expect(copy.openSSHPublicKey == fixture.publicKey)
            #expect(copy.fingerprint == fixture.fingerprint)
            #expect(copy.comment == fixture.comment)
        }

        @Test func aPassphraseIsIgnoredForAnUnprotectedKey() throws {
            let fixture = SSHKeyFixtures.ed25519
            let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: "not needed")
            #expect(key.fingerprint == fixture.fingerprint)
        }

        @Test func toleratesTheWaysKeysGetMangledInTransit() throws {
            let fixture = SSHKeyFixtures.p256
            let windowsLineEndings = fixture.privateKey.replacingOccurrences(of: "\n", with: "\r\n")
            let indented = fixture.privateKey
                .split(separator: "\n").map { "    \($0)  " }.joined(separator: "\n")
            let surrounded = "Here is my key:\n\n\(fixture.privateKey)\n\nThanks!"
            let onOneLine = fixture.privateKey.replacingOccurrences(of: "\n", with: " ")

            for text in [windowsLineEndings, indented, surrounded, onOneLine] {
                let key = try SSHPrivateKey(openSSH: text, passphrase: nil)
                #expect(key.fingerprint == fixture.fingerprint)
            }
        }

        // MARK: Generated keys

        @Test func generatesDistinctEd25519Keys() {
            let first = SSHPrivateKey.generateEd25519()
            let second = SSHPrivateKey.generateEd25519()

            #expect(first.keyType == "ssh-ed25519")
            #expect(first.algorithmName == "Ed25519")
            #expect(first.fingerprint.hasPrefix("SHA256:"))
            // 32 bytes of digest are 43 base64 characters once the padding is dropped.
            #expect(first.fingerprint.count == "SHA256:".count + 43)
            #expect(first.fingerprint != second.fingerprint)
        }

        @Test func aGeneratedKeySurvivesExportAndImport() throws {
            var key = SSHPrivateKey.generateEd25519()
            key.comment = "laptop"

            let exported = key.openSSHPrivateKey
            #expect(exported.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
            #expect(exported.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
            #expect(exported.split(separator: "\n").allSatisfy { $0.count <= 70 })

            let copy = try SSHPrivateKey(openSSH: exported, passphrase: nil)
            #expect(copy.openSSHPublicKey == key.openSSHPublicKey)
            #expect(copy.fingerprint == key.fingerprint)
            #expect(copy.comment == "laptop")
            // Exporting again describes the same key, though not byte for
            // byte: every export draws fresh check values.
            let again = try SSHPrivateKey(openSSH: copy.openSSHPrivateKey, passphrase: nil)
            #expect(again.fingerprint == key.fingerprint)
        }

        @Test func writesThePublicKeyAsAnAuthorizedKeysLine() throws {
            let fixture = SSHKeyFixtures.ed25519
            let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: nil)

            #expect(key.openSSHPublicKey(comment: "me@laptop") == fixture.publicKey + " me@laptop")
            #expect(key.openSSHPublicKey(comment: "") == fixture.publicKey)
            #expect(key.openSSHPublicKey(comment: "   ") == fixture.publicKey)
            // A comment cannot be allowed to start a second line of the file.
            #expect(key.openSSHPublicKey(comment: "two\nlines") == fixture.publicKey + " two lines")
        }

        @Test(arguments: SSHKeyFixtures.all)
        func thePublicKeyLineDescribesTheSameHostKey(_ fixture: SSHKeyFixtures.Key) throws {
            // The same parser reads server host keys, so check it against
            // keys whose fingerprints ssh-keygen vouched for.
            let key = try #require(SSHHostKey(openSSHPublicKey: fixture.publicKey + " a comment"))
            #expect(key.fingerprint == fixture.fingerprint)
            #expect(fixture.publicKey.hasPrefix(key.type + " "))
        }

        // MARK: Passphrases

        @Test func aProtectedKeyAsksForItsPassphrase() {
            let fixture = SSHKeyFixtures.ed25519Protected
            #expect(throws: SSHKeyError.passphraseRequired) {
                try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: nil)
            }
            #expect(throws: SSHKeyError.passphraseRequired) {
                try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: "")
            }
        }

        @Test(arguments: [SSHKeyFixtures.ed25519Protected, SSHKeyFixtures.p384Protected])
        func theWrongPassphraseIsReportedAsSuch(_ fixture: SSHKeyFixtures.Key) {
            // One fixture is checked by its check values (CTR), the other by
            // its authentication tag (GCM).
            #expect(throws: SSHKeyError.wrongPassphrase) {
                try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: "not the passphrase")
            }
        }

        // MARK: Keys that cannot be used

        @Test func rsaKeysAreTurnedAwayWithAnExplanation() {
            let error = #expect(throws: SSHKeyError.self) {
                try SSHPrivateKey(openSSH: SSHKeyFixtures.rsaPrivateKey, passphrase: nil)
            }
            #expect(error == .unsupportedKeyType("RSA"))
            #expect(error?.errorDescription
                == "RSA keys are not supported; use an Ed25519 or ECDSA key.")
        }

        @Test func aProtectedRSAKeyIsTurnedAwayWithoutAskingForItsPassphrase() {
            // The key's type is in the unencrypted part of the file. Asking
            // for a passphrase first would only postpone the bad news.
            #expect(throws: SSHKeyError.unsupportedKeyType("RSA")) {
                try SSHPrivateKey(openSSH: SSHKeyFixtures.protectedRSAPrivateKey, passphrase: nil)
            }
        }

        @Test func otherKeyFileFormatsAreRecognised() {
            let pemBody = "MHcCAQEEIBzQq0g6\n"
            let cases: [(text: String, error: SSHKeyError)] = [
                ("-----BEGIN RSA PRIVATE KEY-----\n\(pemBody)-----END RSA PRIVATE KEY-----\n",
                 .unsupportedKeyType("RSA")),
                ("-----BEGIN DSA PRIVATE KEY-----\n\(pemBody)-----END DSA PRIVATE KEY-----\n",
                 .unsupportedKeyType("DSA")),
                ("-----BEGIN EC PRIVATE KEY-----\n\(pemBody)-----END EC PRIVATE KEY-----\n",
                 .unsupportedFormat(.pem)),
                ("-----BEGIN PRIVATE KEY-----\n\(pemBody)-----END PRIVATE KEY-----\n",
                 .unsupportedFormat(.pem)),
                ("-----BEGIN ENCRYPTED PRIVATE KEY-----\n\(pemBody)-----END ENCRYPTED PRIVATE KEY-----\n",
                 .unsupportedFormat(.pem)),
                ("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n",
                 .unsupportedFormat(.putty)),
            ]
            for (text, expected) in cases {
                #expect(throws: expected) {
                    try SSHPrivateKey(openSSH: text, passphrase: nil)
                }
            }
        }

        // MARK: Damaged input

        @Test func aPublicKeyIsNotMistakenForAPrivateOne() throws {
            let error = try #require(throws: SSHKeyError.self) {
                try SSHPrivateKey(openSSH: SSHKeyFixtures.ed25519.publicKey + " me@laptop", passphrase: nil)
            }
            guard case .malformed(let detail) = error else {
                Issue.record("expected .malformed, got \(error)")
                return
            }
            #expect(detail.contains("public key"))
        }

        @Test(arguments: [
            "",
            "not a key at all",
            "-----BEGIN OPENSSH PRIVATE KEY-----\n-----END OPENSSH PRIVATE KEY-----\n",
            "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!! not base64 !!!!\n-----END OPENSSH PRIVATE KEY-----\n",
            // Valid base64 of something else entirely.
            "-----BEGIN OPENSSH PRIVATE KEY-----\naGVsbG8gd29ybGQ=\n-----END OPENSSH PRIVATE KEY-----\n",
            // The right header and nothing after it.
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----\n",
        ])
        func rejectsTextThatIsNotAKey(_ text: String) {
            let error = #expect(throws: SSHKeyError.self) {
                try SSHPrivateKey(openSSH: text, passphrase: nil)
            }
            guard case .malformed = error else {
                Issue.record("expected .malformed, got \(String(describing: error))")
                return
            }
        }

        @Test func rejectsAKeyWhoseLastLineIsMissing() {
            let truncated = SSHKeyFixtures.ed25519.privateKey
                .split(separator: "\n").dropLast().joined(separator: "\n")
            let error = #expect(throws: SSHKeyError.self) {
                try SSHPrivateKey(openSSH: truncated, passphrase: nil)
            }
            guard case .malformed = error else {
                Issue.record("expected .malformed, got \(String(describing: error))")
                return
            }
        }

        @Test func rejectsEveryTruncationOfAKeyFile() throws {
            // Cut the decoded file short at every length. None of the cuts
            // may crash or produce a key.
            let lines = SSHKeyFixtures.p256.privateKey.split(separator: "\n")
            let contents = try #require(Data(base64Encoded: lines.dropFirst().dropLast().joined()))

            for length in 0..<contents.count {
                let text = """
                -----BEGIN OPENSSH PRIVATE KEY-----
                \(contents.prefix(length).base64EncodedString())
                -----END OPENSSH PRIVATE KEY-----
                """
                #expect(throws: SSHKeyError.self, "cut to \(length) bytes") {
                    try SSHPrivateKey(openSSH: text, passphrase: nil)
                }
            }
        }

        @Test func rejectsAKeyWhoseHalvesDoNotMatch() throws {
            // Splice one key's public half onto another key's private half.
            // The file is well formed; it just does not describe one key.
            func decoded(_ fixture: SSHKeyFixtures.Key) throws -> Data {
                let lines = fixture.privateKey.split(separator: "\n")
                return try #require(Data(base64Encoded: lines.dropFirst().dropLast().joined()))
            }
            let first = try decoded(SSHKeyFixtures.ed25519)
            let other = try SSHPrivateKey(
                openSSH: SSHPrivateKey.generateEd25519().openSSHPrivateKey, passphrase: nil)
            // An unprotected Ed25519 file keeps its public key at a fixed
            // place: after the magic, two "none" strings, an empty string,
            // the key count and the length of the public key blob.
            let publicKeyOffset = 15 + 8 + 8 + 4 + 4 + 4
            let blob = other.publicKeyBlob
            var spliced = first
            spliced.replaceSubrange(publicKeyOffset..<publicKeyOffset + blob.count, with: blob)

            let text = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(spliced.base64EncodedString())
            -----END OPENSSH PRIVATE KEY-----
            """
            let error = #expect(throws: SSHKeyError.self) {
                try SSHPrivateKey(openSSH: text, passphrase: nil)
            }
            guard case .malformed(let detail) = error else {
                Issue.record("expected .malformed, got \(String(describing: error))")
                return
            }
            #expect(detail.contains("do not match"))
        }
    }
}

// MARK: - Against the installed OpenSSH

#if os(macOS)

extension SSHTests {
    /// Checks this module against the `ssh-keygen` on this machine rather
    /// than against fixtures, so that a change in what OpenSSH writes is
    /// noticed.
    @Suite("SSHPrivateKey and ssh-keygen")
    struct SSHKeygenInteroperabilityTests {

        struct KeyKind: Sendable, CustomTestStringConvertible {
            var type: String
            var bits: Int?
            var passphrase = ""
            var cipher: String?
            /// Key derivation rounds. Kept low where the cipher is the thing
            /// under test, because every round costs real time.
            var rounds: Int?

            var testDescription: String {
                [type, bits.map(String.init), cipher, passphrase.isEmpty ? nil : "with passphrase"]
                    .compactMap { $0 }.joined(separator: " ")
            }
        }

        static let kinds = [
            KeyKind(type: "ed25519"),
            KeyKind(type: "ecdsa", bits: 256),
            KeyKind(type: "ecdsa", bits: 384),
            KeyKind(type: "ecdsa", bits: 521),
            // ssh-keygen's defaults for a protected key.
            KeyKind(type: "ed25519", passphrase: "open sesame"),
            KeyKind(type: "ecdsa", bits: 256, passphrase: "open sesame", rounds: 2),
            KeyKind(type: "ed25519", passphrase: "open sesame", cipher: "aes128-ctr", rounds: 2),
            KeyKind(type: "ed25519", passphrase: "open sesame", cipher: "aes192-ctr", rounds: 2),
            KeyKind(type: "ed25519", passphrase: "open sesame", cipher: "aes256-ctr", rounds: 2),
            KeyKind(type: "ed25519", passphrase: "open sesame", cipher: "aes128-cbc", rounds: 2),
            KeyKind(type: "ed25519", passphrase: "open sesame", cipher: "aes192-cbc", rounds: 2),
            KeyKind(type: "ed25519", passphrase: "open sesame", cipher: "aes256-cbc", rounds: 2),
            KeyKind(
                type: "ecdsa", bits: 521, passphrase: "open sesame",
                cipher: "aes128-gcm@openssh.com", rounds: 2),
            KeyKind(
                type: "ed25519", passphrase: "open sesame",
                cipher: "aes256-gcm@openssh.com", rounds: 2),
        ]

        @Test(arguments: kinds)
        func readsAFreshlyGeneratedKey(_ kind: KeyKind) throws {
            let directory = try TemporaryDirectory()
            let keyFile = directory.file("key")
            try CommandLineTool.generateKey(
                at: keyFile, type: kind.type, bits: kind.bits, passphrase: kind.passphrase,
                cipher: kind.cipher, rounds: kind.rounds, comment: "someone@somewhere")

            let key = try SSHPrivateKey(
                openSSH: String(contentsOf: keyFile, encoding: .utf8),
                passphrase: kind.passphrase.isEmpty ? nil : kind.passphrase)

            let publicKeyFile = try String(
                contentsOf: keyFile.appendingPathExtension("pub"), encoding: .utf8)
            #expect(key.openSSHPublicKey(comment: key.comment)
                == publicKeyFile.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(key.comment == "someone@somewhere")
            #expect(try key.fingerprint == CommandLineTool.fingerprint(ofKeyAt: keyFile))
        }

        @Test func sshKeygenReadsAKeyThisModuleExported() throws {
            let directory = try TemporaryDirectory()
            let keys = try [SSHPrivateKey.generateEd25519()] + [SSHKeyFixtures.p256, SSHKeyFixtures.p521]
                .map { try SSHPrivateKey(openSSH: $0.privateKey, passphrase: nil) }

            for (index, key) in keys.enumerated() {
                let keyFile = directory.file("exported-\(index)")
                try Data(key.openSSHPrivateKey.utf8).write(to: keyFile)
                // ssh-keygen refuses private keys that others could read.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: keyFile.path)

                // `-y` makes ssh-keygen read the private key and print the
                // public key it works out from it.
                let derived = try CommandLineTool.run(
                    CommandLineTool.sshKeygen, ["-y", "-f", keyFile.path])
                #expect(derived.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix(key.openSSHPublicKey))
                #expect(try CommandLineTool.fingerprint(ofKeyAt: keyFile) == key.fingerprint)
            }
        }
    }
}

#endif

import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSHCredential")
    struct SSHCredentialTests {
        static let secret = "correct-horse-battery"
        static let password = SSHCredential.password(secret)

        /// What a tunnel is made with, password and all.
        static var factory: SSHTunnelFactory {
            SSHTunnelFactory(
                sshHost: "gateway.example", username: "me", credential: password,
                knownHosts: KnownHostsStore(fileURL: nil),
                hostKeyPolicy: { _ in true })
        }

        @Test func aPasswordStaysOutOfDescriptions() {
            // Printing, interpolating into a string and the debugger's
            // description all ask a value to describe itself.
            #expect(String(describing: Self.password) == "SSHCredential.password(redacted)")
            #expect(String(reflecting: Self.password) == "SSHCredential.password(redacted)")
            #expect("\(Self.password)" == "SSHCredential.password(redacted)")

            // So does whatever holds one.
            for described in [
                String(describing: Self.factory),
                String(reflecting: Self.factory),
                String(describing: Optional(Self.password)),
                String(describing: [Self.password]),
                String(describing: ["credential": Self.password]),
            ] {
                #expect(!described.contains(Self.secret))
                #expect(described.contains("password(redacted)"))
            }
            // The rest of a value is still shown.
            #expect(String(describing: Self.factory).contains("gateway.example"))
        }

        /// `dump`, the debugger and test failures do not ask a value to
        /// describe itself: they look inside it.
        @Test func aPasswordStaysOutOfWhatLooksInsideAValue() {
            #expect(Mirror(reflecting: Self.password).children.isEmpty)

            var dumped = ""
            dump(Self.password, to: &dumped)
            dump(Self.factory, to: &dumped)
            dump(Optional(Self.password), to: &dumped)
            dump([Self.password], to: &dumped)
            dump(["credential": Self.password], to: &dumped)
            #expect(!dumped.contains(Self.secret))
            // What it is is still said, and the rest of a value still shown.
            #expect(dumped.contains("password(redacted)"))
            #expect(dumped.contains("gateway.example"))

            // The credential inside a factory is reached by looking, too.
            let credential = Mirror(reflecting: Self.factory).children.first { $0.label == "credential" }
            #expect(credential.map { String(reflecting: $0.value) } == "SSHCredential.password(redacted)")
        }

        @Test func aKeyIsNotLaidOpenEither() throws {
            let key = SSHPrivateKey.generateEd25519()
            let credential = SSHCredential.key(key)
            #expect(String(describing: credential) == "SSHCredential.key(redacted)")
            #expect(String(reflecting: credential) == "SSHCredential.key(redacted)")
            #expect(Mirror(reflecting: credential).children.isEmpty)

            var dumped = ""
            dump(credential, to: &dumped)
            #expect(dumped.contains("key(redacted)"))
            // Neither the file it would be saved as nor its bytes.
            let seed = key.privateKeyBytes
            #expect(!dumped.contains("PRIVATE KEY"))
            #expect(!dumped.contains(seed.base64EncodedString()))
            #expect(!dumped.lowercased().contains(seed.map { String(format: "%02x", $0) }.joined()))
        }
    }
}

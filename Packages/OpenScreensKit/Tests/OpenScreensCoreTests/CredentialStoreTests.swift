import Foundation
import Testing
@testable import OpenScreensCore

@Suite("CredentialStore")
struct CredentialStoreTests {

    private let storage = InMemorySecretStorage()
    private var credentials: CredentialStore { CredentialStore(storage: storage) }

    @Test func aPasswordIsKeptPerComputer() throws {
        let studio = UUID(), server = UUID()

        try credentials.setPassword("open sesame", for: studio)

        #expect(credentials.password(for: studio) == "open sesame")
        #expect(credentials.hasPassword(for: studio))
        #expect(credentials.password(for: server) == nil)
        #expect(!credentials.hasPassword(for: server))

        try credentials.setPassword("changed", for: studio)
        #expect(credentials.password(for: studio) == "changed")
    }

    @Test func screenSharingAndSSHPasswordsAreSeparate() throws {
        let computer = UUID()

        try credentials.setPassword("for the screen", for: computer)
        #expect(credentials.password(for: computer, kind: .screenSharing) == "for the screen")
        #expect(credentials.password(for: computer, kind: .ssh) == nil)
        #expect(!credentials.hasPassword(for: computer, kind: .ssh))

        try credentials.setPassword("for the tunnel", for: computer, kind: .ssh)
        #expect(credentials.password(for: computer) == "for the screen")
        #expect(credentials.password(for: computer, kind: .ssh) == "for the tunnel")
    }

    @Test func savingNothingRemovesThePassword() throws {
        let computer = UUID()

        try credentials.setPassword("secret", for: computer)
        try credentials.setPassword(nil, for: computer)
        #expect(credentials.password(for: computer) == nil)
        #expect(!credentials.hasPassword(for: computer))

        try credentials.setPassword("secret", for: computer)
        try credentials.setPassword("", for: computer)
        #expect(!credentials.hasPassword(for: computer))
        #expect(storage.accounts().isEmpty)
    }

    @Test(arguments: [
        " leading and trailing spaces ",
        "pässwörd — with “quotes” and 日本語 and 🔐",
        "line one\nline two\ttabbed",
        String(repeating: "long", count: 2_000),
        " ",
    ])
    func aPasswordComesBackExactlyAsItWasSaved(password: String) throws {
        let computer = UUID()
        try credentials.setPassword(password, for: computer)
        #expect(credentials.password(for: computer) == password)
    }

    @Test func forgettingAComputerRemovesBothOfItsPasswordsAndNothingElse() throws {
        let doomed = UUID(), kept = UUID()
        try credentials.setPassword("a", for: doomed)
        try credentials.setPassword("b", for: doomed, kind: .ssh)
        try credentials.setPassword("c", for: kept)
        try credentials.setSecret("token", named: "tailscale")

        credentials.deleteAll(for: doomed)

        #expect(!credentials.hasPassword(for: doomed))
        #expect(!credentials.hasPassword(for: doomed, kind: .ssh))
        #expect(credentials.password(for: kept) == "c")
        #expect(credentials.secret(named: "tailscale") == "token")

        // Forgetting a computer that has no passwords is not an error.
        credentials.deleteAll(for: UUID())
        #expect(storage.accounts().count == 2)
    }

    @Test func namedSecretsAreKeptApartFromPasswords() throws {
        let computer = UUID()
        try credentials.setPassword("password", for: computer)

        try credentials.setSecret("tskey-123", named: "tailscale")
        #expect(credentials.secret(named: "tailscale") == "tskey-123")
        #expect(credentials.secret(named: "other") == nil)
        #expect(credentials.password(for: computer) == "password")

        try credentials.setSecret("", named: "tailscale")
        #expect(credentials.secret(named: "tailscale") == nil)
        try credentials.setSecret("again", named: "tailscale")
        try credentials.setSecret(nil, named: "tailscale")
        #expect(credentials.secret(named: "tailscale") == nil)
        #expect(credentials.password(for: computer) == "password")
    }

    @Test func erasingEverythingLeavesNothingBehind() throws {
        for _ in 0..<5 {
            let computer = UUID()
            try credentials.setPassword("p", for: computer)
            try credentials.setPassword("s", for: computer, kind: .ssh)
        }
        try credentials.setSecret("token", named: "tailscale")
        #expect(storage.accounts().count == 11)

        credentials.eraseEverything()

        #expect(storage.accounts().isEmpty)
        #expect(credentials.secret(named: "tailscale") == nil)
    }

    @Test func everySecretHasItsOwnAccount() throws {
        // The account names are what is in the user's keychain: they must
        // not change between versions, or saved passwords are orphaned.
        let computer = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        try credentials.setPassword("a", for: computer)
        try credentials.setPassword("b", for: computer, kind: .ssh)
        try credentials.setSecret("c", named: "tailscale")

        #expect(storage.accounts() == [
            "computer.11111111-2222-3333-4444-555555555555.ssh",
            "computer.11111111-2222-3333-4444-555555555555.vnc",
            "secret.tailscale",
        ])
        #expect(storage.data(account: "computer.11111111-2222-3333-4444-555555555555.vnc") == Data("a".utf8))
    }

    @Test func storesOnTheSameStorageSeeTheSameSecrets() throws {
        let computer = UUID()
        try CredentialStore(storage: storage).setPassword("shared", for: computer)

        #expect(CredentialStore(storage: storage).password(for: computer) == "shared")
        #expect(CredentialStore(storage: InMemorySecretStorage()).password(for: computer) == nil)
    }

    @Test func aStoredValueThatIsNotTextIsNotAPassword() throws {
        let computer = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        try storage.set(
            Data([0xFF, 0xFE, 0xFD]),
            account: "computer.11111111-2222-3333-4444-555555555555.vnc")

        #expect(credentials.password(for: computer) == nil)
    }
}

@Suite("InMemorySecretStorage")
struct InMemorySecretStorageTests {

    @Test func valuesAreStoredReplacedAndRemoved() throws {
        let storage = InMemorySecretStorage()
        #expect(storage.accounts().isEmpty)
        #expect(storage.data(account: "a") == nil)

        try storage.set(Data([1]), account: "b")
        try storage.set(Data([2]), account: "a")
        #expect(storage.accounts() == ["a", "b"])
        #expect(storage.data(account: "a") == Data([2]))

        try storage.set(Data([3]), account: "a")
        #expect(storage.data(account: "a") == Data([3]))

        try storage.set(nil, account: "a")
        try storage.set(nil, account: "never stored")
        #expect(storage.accounts() == ["b"])
    }

    @Test func itCanBeUsedFromManyTasksAtOnce() async throws {
        let storage = InMemorySecretStorage()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    try? storage.set(Data("\(index)".utf8), account: "account-\(index)")
                    _ = storage.accounts()
                    _ = storage.data(account: "account-\(index / 2)")
                }
            }
        }

        #expect(storage.accounts().count == 200)
        #expect(storage.data(account: "account-123") == Data("123".utf8))
    }
}

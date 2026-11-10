import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSHKeyStore")
    struct SSHKeyStoreTests {
        let storage = InMemorySecretStorage()
        var store: SSHKeyStore { SSHKeyStore(storage: storage) }

        @Test func startsEmpty() {
            #expect(store.keys().isEmpty)
            #expect(store.privateKey(for: UUID()) == nil)
        }

        @Test func aSavedKeyCanBeListedAndLoaded() throws {
            let key = SSHPrivateKey.generateEd25519()
            let saved = try store.add(name: "Work laptop", key: key)

            #expect(saved.name == "Work laptop")
            #expect(saved.algorithm == "Ed25519")
            #expect(saved.fingerprint == key.fingerprint)
            #expect(saved.publicKey == key.openSSHPublicKey)
            #expect(saved.authorizedKeysLine == key.openSSHPublicKey + " Work laptop")
            #expect(abs(saved.createdAt.timeIntervalSinceNow) < 5)

            // A second store on the same storage sees exactly what was saved.
            #expect(SSHKeyStore(storage: storage).keys() == [saved])
            let loaded = try #require(store.privateKey(for: saved.id))
            #expect(loaded.fingerprint == key.fingerprint)
        }

        @Test func keysOfEveryAlgorithmAreStored() throws {
            for fixture in SSHKeyFixtures.all {
                let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: fixture.passphrase)
                let saved = try store.add(name: fixture.name, key: key)
                #expect(saved.algorithm == fixture.algorithmName)
                #expect(saved.fingerprint == fixture.fingerprint)
                #expect(store.privateKey(for: saved.id)?.openSSHPublicKey == fixture.publicKey)
            }
            #expect(store.keys().count == SSHKeyFixtures.all.count)
        }

        @Test func eachKeyIsOneEntryUnderItsOwnAccount() throws {
            let saved = try store.add(name: "Server key", key: .generateEd25519())

            #expect(storage.accounts() == ["sshkey.\(saved.id.uuidString)"])
            // The entry is a small JSON record holding the key as an
            // unprotected OpenSSH key file.
            let data = try #require(storage.data(account: "sshkey.\(saved.id.uuidString)"))
            let record = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(record.keys) == ["id", "name", "createdAt", "privateKey"])
            #expect(record["name"] as? String == "Server key")
            #expect((record["privateKey"] as? String)?
                .hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") == true)
        }

        @Test func keysAreListedOldestFirst() throws {
            // Write the records directly to control their dates.
            let dates = ["2026-03-01T10:00:00Z", "2025-01-15T08:30:00Z", "2026-11-10T22:00:00Z"]
            for (index, date) in dates.enumerated() {
                let id = UUID()
                let record: [String: String] = [
                    "id": id.uuidString,
                    "name": "Key \(index)",
                    "createdAt": date,
                    "privateKey": SSHPrivateKey.generateEd25519().openSSHPrivateKey,
                ]
                try storage.set(
                    JSONSerialization.data(withJSONObject: record),
                    account: "sshkey.\(id.uuidString)")
            }
            #expect(store.keys().map(\.name) == ["Key 1", "Key 0", "Key 2"])
        }

        @Test func renamingKeepsTheKey() throws {
            let key = SSHPrivateKey.generateEd25519()
            let saved = try store.add(name: "Old name", key: key)

            let renamed = try #require(try store.rename(saved.id, to: "New name"))
            #expect(renamed.name == "New name")
            #expect(renamed.id == saved.id)
            #expect(renamed.createdAt == saved.createdAt)
            #expect(renamed.fingerprint == key.fingerprint)
            #expect(store.keys() == [renamed])

            #expect(try store.rename(UUID(), to: "Nobody") == nil)
        }

        @Test func deletingRemovesOnlyThatKey() throws {
            let kept = try store.add(name: "Kept", key: .generateEd25519())
            let removed = try store.add(name: "Removed", key: .generateEd25519())

            try store.delete(removed.id)
            #expect(store.keys() == [kept])
            #expect(store.privateKey(for: removed.id) == nil)
            #expect(store.privateKey(for: kept.id) != nil)
            // Deleting what is not there is not an error.
            try store.delete(removed.id)
        }

        @Test func otherSecretsAreLeftAlone() throws {
            // Passwords live in the same storage under other account names.
            try storage.set(Data("hunter2".utf8), account: "computer.1234.vnc")
            try storage.set(Data("not json".utf8), account: "sshkey.damaged")
            let saved = try store.add(name: "Mine", key: .generateEd25519())

            // The damaged record is skipped rather than failing the listing.
            #expect(store.keys() == [saved])
            try store.delete(saved.id)
            #expect(storage.accounts() == ["computer.1234.vnc", "sshkey.damaged"])
        }
    }
}

import Foundation
import Security
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("SSHKeyStore")
    struct SSHKeyStoreTests {
        let storage = InMemorySecretStorage()
        var store: SSHKeyStore { SSHKeyStore(storage: storage) }

        @Test func startsEmpty() throws {
            #expect(try store.keys().isEmpty)
            #expect(try store.privateKey(for: UUID()) == nil)
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
            #expect(try SSHKeyStore(storage: storage).keys() == [saved])
            let loaded = try #require(try store.privateKey(for: saved.id))
            #expect(loaded.fingerprint == key.fingerprint)
        }

        @Test func keysOfEveryAlgorithmAreStored() throws {
            for fixture in SSHKeyFixtures.all {
                let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: fixture.passphrase)
                let saved = try store.add(name: fixture.name, key: key)
                #expect(saved.algorithm == fixture.algorithmName)
                #expect(saved.fingerprint == fixture.fingerprint)
                #expect(try store.privateKey(for: saved.id)?.openSSHPublicKey == fixture.publicKey)
            }
            #expect(try store.keys().count == SSHKeyFixtures.all.count)
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
            #expect(try store.keys().map(\.name) == ["Key 1", "Key 0", "Key 2"])
        }

        @Test func renamingKeepsTheKey() throws {
            let key = SSHPrivateKey.generateEd25519()
            let saved = try store.add(name: "Old name", key: key)

            let renamed = try #require(try store.rename(saved.id, to: "New name"))
            #expect(renamed.name == "New name")
            #expect(renamed.id == saved.id)
            #expect(renamed.createdAt == saved.createdAt)
            #expect(renamed.fingerprint == key.fingerprint)
            #expect(try store.keys() == [renamed])

            #expect(try store.rename(UUID(), to: "Nobody") == nil)
        }

        @Test func deletingRemovesOnlyThatKey() throws {
            let kept = try store.add(name: "Kept", key: .generateEd25519())
            let removed = try store.add(name: "Removed", key: .generateEd25519())

            try store.delete(removed.id)
            #expect(try store.keys() == [kept])
            #expect(try store.privateKey(for: removed.id) == nil)
            #expect(try store.privateKey(for: kept.id) != nil)
            // Deleting what is not there is not an error.
            try store.delete(removed.id)
        }

        // MARK: In the keychain

        /// A store on a keychain that is not the real one, set up the way
        /// the real one is.
        static func storeInKeychain() -> (store: SSHKeyStore, keychain: FakeKeychain) {
            let keychain = FakeKeychain()
            let real = SSHKeyStore.keychain
            let storage = KeychainStorage(
                service: "test", synchronizes: real.synchronizes,
                accessibility: real.accessibility, items: keychain)
            return (SSHKeyStore(storage: storage), keychain)
        }

        @Test func aKeyIsKeptForUseWhileTheDeviceIsUnlocked() throws {
            let (store, keychain) = Self.storeInKeychain()
            let saved = try store.add(name: "Laptop", key: .generateEd25519())

            // It follows the user to their other devices, and can be read
            // on any of them only with the device unlocked.
            let item = try #require(keychain.item("sshkey.\(saved.id.uuidString)", in: .dataProtection))
            #expect(item.isSynchronizable == true)
            #expect(item.accessibility == kSecAttrAccessibleWhenUnlocked as String)
        }

        @Test func renamingAKeyThatCannotBeSavedAgainKeepsTheKey() throws {
            let (store, keychain) = Self.storeInKeychain()
            let key = SSHPrivateKey.generateEd25519()
            let saved = try store.add(name: "Old name", key: key)

            // The keychain takes nothing new for the moment.
            for call in [FakeKeychain.Call.update, .add] {
                keychain.make(call, on: .dataProtection, answer: errSecInteractionNotAllowed)
            }
            #expect(throws: SecretStorageError(status: errSecInteractionNotAllowed)) {
                try store.rename(saved.id, to: "New name")
            }

            // The private key is the one thing that cannot be had again. It
            // is where it was, under the name it had.
            for call in [FakeKeychain.Call.update, .add] {
                keychain.make(call, on: .dataProtection, answer: nil)
            }
            #expect(try store.keys() == [saved])
            #expect(try store.privateKey(for: saved.id)?.fingerprint == key.fingerprint)
        }

        @Test func aKeychainThatCannotBeReadIsNotTakenForOneWithoutKeys() throws {
            let (store, keychain) = Self.storeInKeychain()
            let saved = try store.add(name: "Laptop", key: .generateEd25519())
            let locked = SecretStorageError(status: errSecInteractionNotAllowed)
            keychain.make(.copyMatching, on: .dataProtection, answer: locked.status)

            // "No keys" and "no such key" would both be wrong, and would
            // send the user off to make a key they already have.
            #expect(throws: locked) { try store.keys() }
            #expect(throws: locked) { try store.privateKey(for: saved.id) }
            #expect(throws: locked) { try store.rename(saved.id, to: "Renamed") }

            keychain.make(.copyMatching, on: .dataProtection, answer: nil)
            #expect(try store.keys() == [saved])
        }

        @Test func aKeyThatCouldNotBeDeletedIsStillThere() throws {
            let (store, keychain) = Self.storeInKeychain()
            let saved = try store.add(name: "Laptop", key: .generateEd25519())
            keychain.make(.delete, on: .dataProtection, answer: errSecInteractionNotAllowed)

            #expect(throws: SecretStorageError(status: errSecInteractionNotAllowed)) {
                try store.delete(saved.id)
            }
            #expect(try store.keys() == [saved])
        }

        @Test func otherSecretsAreLeftAlone() throws {
            // Passwords live in the same storage under other account names.
            try storage.set(Data("hunter2".utf8), account: "computer.1234.vnc")
            try storage.set(Data("not json".utf8), account: "sshkey.damaged")
            let saved = try store.add(name: "Mine", key: .generateEd25519())

            // The damaged record is skipped rather than failing the listing.
            #expect(try store.keys() == [saved])
            try store.delete(saved.id)
            #expect(storage.accounts() == ["computer.1234.vnc", "sshkey.damaged"])
        }
    }
}

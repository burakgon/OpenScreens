import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    @Suite("KnownHostsStore")
    struct KnownHostsStoreTests {
        static let ed25519 = SSHHostKey(type: "ssh-ed25519", fingerprint: "SHA256:first")
        static let otherEd25519 = SSHHostKey(type: "ssh-ed25519", fingerprint: "SHA256:second")
        static let ecdsa = SSHHostKey(type: "ecdsa-sha2-nistp256", fingerprint: "SHA256:third")

        /// A store with no file behind it.
        let store = KnownHostsStore(fileURL: nil)

        // MARK: Verdicts

        @Test func aHostSeenForTheFirstTimeIsUnknown() {
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
            #expect(store.all().isEmpty)
        }

        @Test func aTrustedKeyIsRecognised() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519) == .trusted)
        }

        @Test func aDifferentKeyOfTheSameTypeIsAMismatch() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519)
                == .mismatch(expected: "SHA256:first", presented: "SHA256:second"))
        }

        @Test func aKeyOfAnotherTypeIsAMismatchNotAFirstEncounter() throws {
            // Otherwise an impostor would only need to present a key of a
            // type the store has not seen for this host.
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ecdsa)
                == .mismatch(expected: "SHA256:first", presented: "SHA256:third"))
        }

        @Test func aMismatchNamesTheKeyOfTheSameTypeWhenThereIsOne() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ecdsa)
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519)
                == .mismatch(expected: "SHA256:first", presented: "SHA256:second"))
        }

        @Test func theSameNameOnAnotherPortIsAnotherHost() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: "mac.example", port: 2222, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
        }

        @Test(arguments: ["MAC.Example", "mac.example.", " mac.example ", "Mac.Example."])
        func spellingsOfOneNameShareARecord(_ spelling: String) throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: spelling, port: 22, key: Self.ed25519) == .trusted)
            #expect(store.check(host: spelling, port: 22, key: Self.otherEd25519)
                == .mismatch(expected: "SHA256:first", presented: "SHA256:second"))
        }

        @Test func bracketsAroundAnIPv6AddressDoNotMatter() throws {
            try store.trust(host: "[FE80::1]", port: 22, key: Self.ed25519)
            #expect(store.check(host: "fe80::1", port: 22, key: Self.ed25519) == .trusted)
            #expect(store.all().map(\.host) == ["fe80::1"])
        }

        // MARK: Changing

        @Test func trustingAChangedKeyReplacesTheOldOne() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "mac.example", port: 22, key: Self.otherEd25519)

            #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519) == .trusted)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .mismatch(expected: "SHA256:second", presented: "SHA256:first"))
            #expect(store.all() == [
                KnownHostsStore.Entry(host: "mac.example", port: 22, keys: [Self.otherEd25519]),
            ])
        }

        @Test func aHostCanHaveOneKeyPerType() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "mac.example", port: 22, key: Self.ecdsa)

            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519) == .trusted)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ecdsa) == .trusted)
            #expect(store.all().map(\.keys) == [[Self.ed25519, Self.ecdsa]])
        }

        @Test func trustingTwiceChangesNothing() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "MAC.example.", port: 22, key: Self.ed25519)
            #expect(store.all() == [
                KnownHostsStore.Entry(host: "mac.example", port: 22, keys: [Self.ed25519]),
            ])
        }

        @Test func aRemovedHostIsUnknownAgain() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "other.example", port: 22, key: Self.ecdsa)

            try store.remove(host: "Mac.Example", port: 22)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
            #expect(store.check(host: "other.example", port: 22, key: Self.ecdsa) == .trusted)
            // Removing what is not on record is not an error.
            try store.remove(host: "mac.example", port: 22)
        }

        @Test func hostsAreListedInOrder() throws {
            try store.trust(host: "zebra.example", port: 22, key: Self.ed25519)
            try store.trust(host: "apple.example", port: 2222, key: Self.ed25519)
            try store.trust(host: "apple.example", port: 22, key: Self.ed25519)

            #expect(store.all().map(\.id) == [
                "apple.example:22", "apple.example:2222", "zebra.example:22",
            ])
        }

        // MARK: On disk

        @Test func recordsPersistAndAreSharedBetweenInstances() throws {
            let directory = try TemporaryDirectory()
            // The store creates folders that do not exist yet.
            let file = directory.file("nested/KnownHosts.json")

            let first = KnownHostsStore(fileURL: file)
            #expect(first.all().isEmpty)
            try first.trust(host: "mac.example", port: 22, key: Self.ed25519)

            // A second instance sees the record, and its changes are seen by
            // the first: the file is the single source of truth.
            let second = KnownHostsStore(fileURL: file)
            #expect(second.check(host: "mac.example", port: 22, key: Self.ed25519) == .trusted)
            try second.trust(host: "other.example", port: 2222, key: Self.ecdsa)
            #expect(first.check(host: "other.example", port: 2222, key: Self.ecdsa) == .trusted)
            try second.remove(host: "mac.example", port: 22)
            #expect(first.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
        }

        @Test func theFileIsReadableJSON() throws {
            let directory = try TemporaryDirectory()
            let file = directory.file("KnownHosts.json")
            try KnownHostsStore(fileURL: file).trust(host: "mac.example", port: 22, key: Self.ed25519)

            let document = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let hosts = try #require(document["hosts"] as? [[String: Any]])
            #expect(hosts.count == 1)
            #expect(hosts.first?["host"] as? String == "mac.example")
            #expect(hosts.first?["port"] as? Int == 22)
            let keys = try #require(hosts.first?["keys"] as? [[String: String]])
            #expect(keys == [["type": "ssh-ed25519", "fingerprint": "SHA256:first"]])
        }

        @Test func anUnreadableFileIsSetAsideNotOverwritten() throws {
            let directory = try TemporaryDirectory()
            let file = directory.file("KnownHosts.json")
            try Data("this is not JSON".utf8).write(to: file)

            let store = KnownHostsStore(fileURL: file)
            // Nothing can be trusted from a file that cannot be read, so
            // every host is unknown again.
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519) == .trusted)

            // The damaged file is still there under another name.
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            let aside = try #require(names.first { $0.hasPrefix("KnownHosts.unreadable-") })
            #expect(try Data(contentsOf: directory.file(aside)) == Data("this is not JSON".utf8))
        }

        @Test func concurrentChangesAreNotLost() async throws {
            let directory = try TemporaryDirectory()
            let file = directory.file("KnownHosts.json")

            // Many writers, each through its own instance, as happens when
            // several connections are made at once.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<40 {
                    group.addTask {
                        try KnownHostsStore(fileURL: file).trust(
                            host: "host-\(index).example", port: 22, key: Self.ed25519)
                    }
                }
                try await group.waitForAll()
            }
            #expect(KnownHostsStore(fileURL: file).all().count == 40)
        }
    }
}

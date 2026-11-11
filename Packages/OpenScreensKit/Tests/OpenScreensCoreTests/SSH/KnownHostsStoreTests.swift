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

        @Test func aHostSeenForTheFirstTimeIsUnknown() throws {
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
            #expect(try store.all().isEmpty)
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
            #expect(try store.all().map(\.host) == ["fe80::1"])
        }

        // MARK: Changing

        @Test func trustingAChangedKeyReplacesTheOldOne() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "mac.example", port: 22, key: Self.otherEd25519)

            #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519) == .trusted)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .mismatch(expected: "SHA256:second", presented: "SHA256:first"))
            #expect(try store.all() == [
                KnownHostsStore.Entry(host: "mac.example", port: 22, keys: [Self.otherEd25519]),
            ])
        }

        @Test func aHostCanHaveOneKeyPerType() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "mac.example", port: 22, key: Self.ecdsa)

            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519) == .trusted)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ecdsa) == .trusted)
            #expect(try store.all().map(\.keys) == [[Self.ed25519, Self.ecdsa]])
        }

        @Test func trustingTwiceChangesNothing() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "MAC.example.", port: 22, key: Self.ed25519)
            #expect(try store.all() == [
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

            #expect(try store.all().map(\.id) == [
                "apple.example:22", "apple.example:2222", "zebra.example:22",
            ])
        }

        // MARK: Decisions that took a while

        /// What a host key policy is handed when `mac.example` presents `key`.
        func challenge(for key: SSHHostKey, on store: KnownHostsStore? = nil) -> SSHHostKeyChallenge {
            let store = store ?? self.store
            return SSHHostKeyChallenge(
                host: "mac.example", port: 22, key: key,
                verdict: store.check(host: "mac.example", port: 22, key: key),
                knownHosts: store)
        }

        /// What is on record for `mac.example` when it is trusted with `keys`.
        static func entry(_ keys: [SSHHostKey]) -> KnownHostsStore.Entry {
            KnownHostsStore.Entry(host: "mac.example", port: 22, keys: keys)
        }

        @Test func aDecisionOvertakenByAnotherConnectionRecordsNothing() throws {
            // Two connections to a server met for the first time, both
            // checked before either is answered, as happens when a session
            // and a file browser are opened together. One of them is not
            // talking to the real server.
            let honest = challenge(for: Self.ed25519)
            let intercepted = challenge(for: Self.otherEd25519)
            #expect(honest.verdict == .unknown(fingerprint: "SHA256:first"))
            #expect(intercepted.verdict == .unknown(fingerprint: "SHA256:second"))

            #expect(try honest.trust() == .trusted)
            // The server has a key on record now, and the other key is a
            // mismatch whatever was decided about it earlier. It does not go
            // on record in place of the first.
            #expect(try intercepted.trust()
                == .mismatch(expected: "SHA256:first", presented: "SHA256:second"))
            #expect(try store.all() == [Self.entry([Self.ed25519])])
        }

        @Test func theStandardPolicyTurnsAwayAKeyThatCameTooLate() async throws {
            let policy = SSHClient.knownHostsPolicy(trustUnknownHosts: true)
            let honest = challenge(for: Self.ed25519)
            let intercepted = challenge(for: Self.otherEd25519)
            let again = challenge(for: Self.ed25519)

            #expect(await policy(honest))
            #expect(await policy(intercepted) == false)
            // A second connection that met the same key is as welcome as the
            // first.
            #expect(await policy(again))
            #expect(try store.all() == [Self.entry([Self.ed25519])])
        }

        @Test func acceptingAChangedKeyPutsItInPlaceOfWhatWasOnRecord() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "mac.example", port: 22, key: Self.ecdsa)
            let changed = challenge(for: Self.otherEd25519)
            #expect(changed.verdict == .mismatch(expected: "SHA256:first", presented: "SHA256:second"))

            // Someone looked at both fingerprints and said the new key is
            // the server's. The keys it had no longer speak for it, the one
            // of the other kind included.
            #expect(try changed.trust() == .trusted)
            #expect(try store.all() == [Self.entry([Self.otherEd25519])])
            #expect(store.check(host: "mac.example", port: 22, key: Self.ecdsa)
                == .mismatch(expected: "SHA256:second", presented: "SHA256:third"))
        }

        @Test func aChangedKeyIsNotRecordedOverAConflictNobodyWasShown() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            let changed = challenge(for: Self.otherEd25519)

            // While the question is open, the record moves on to a third key.
            let third = SSHHostKey(type: "ssh-ed25519", fingerprint: "SHA256:fourth")
            try store.trust(host: "mac.example", port: 22, key: third)

            // The yes was to replacing the first key, not this one.
            #expect(try changed.trust()
                == .mismatch(expected: "SHA256:fourth", presented: "SHA256:second"))
            #expect(try store.all() == [Self.entry([third])])
        }

        @Test func aChangedKeyIsRecordedWhenTheOldOneWasForgottenMeanwhile() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            let changed = challenge(for: Self.otherEd25519)
            try store.remove(host: "mac.example", port: 22)

            // Nothing stands against the key any more.
            #expect(try changed.trust() == .trusted)
            #expect(try store.all() == [Self.entry([Self.otherEd25519])])
        }

        @Test func aKeyAlreadyOnRecordStaysAsItIs() throws {
            try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            try store.trust(host: "mac.example", port: 22, key: Self.ecdsa)
            // Trusting what is trusted changes nothing, the other key
            // included.
            #expect(try challenge(for: Self.ecdsa).trust() == .trusted)
            #expect(try store.all() == [Self.entry([Self.ed25519, Self.ecdsa])])
        }

        @Test func ofManyFirstConnectionsAtOnceOneKeyGoesOnRecord() async throws {
            let directory = try TemporaryDirectory()
            let file = directory.file("KnownHosts.json")
            let keys = (0..<32).map { SSHHostKey(type: "ssh-ed25519", fingerprint: "SHA256:key-\($0)") }

            // Every connection sees a server nobody has met, and every one
            // of them decides to trust the key it was shown.
            let verdicts = try await withThrowingTaskGroup(of: KnownHostsStore.Verdict.self) { group in
                let challenges = keys.map { challenge(for: $0, on: KnownHostsStore(fileURL: file)) }
                #expect(challenges.allSatisfy { $0.verdict == .unknown(fingerprint: $0.key.fingerprint) })
                for challenge in challenges {
                    group.addTask { try challenge.trust() }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }

            // One of them got there first. The rest learn that the server
            // now has a key, and that theirs is not it.
            let recorded = try #require(try KnownHostsStore(fileURL: file).all().first?.keys)
            let winner = try #require(recorded.first)
            #expect(recorded.count == 1)
            #expect(verdicts.count { $0 == .trusted } == 1)
            #expect(verdicts.count { verdict in
                guard case .mismatch(expected: winner.fingerprint, presented: _) = verdict else { return false }
                return true
            } == keys.count - 1)
        }

        @Test func whileTheRecordCannotBeReadTheStandardPolicyRefusesEveryKey() async throws {
            let directory = try TemporaryDirectory()
            let (store, _) = try Self.unreadableStore(in: directory) { file in
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            }
            let policy = SSHClient.knownHostsPolicy(trustUnknownHosts: true)

            // The key on record, another key for the same server, and a
            // server that was never met: none can be told from the others.
            for key in [Self.ed25519, Self.otherEd25519] {
                #expect(await policy(challenge(for: key, on: store)) == false)
            }
            let stranger = SSHHostKeyChallenge(
                host: "other.example", port: 22, key: Self.ecdsa,
                verdict: store.check(host: "other.example", port: 22, key: Self.ecdsa),
                knownHosts: store)
            #expect(await policy(stranger) == false)
        }

        @Test func aKeyThatCannotBeSavedIsAcceptedAllTheSame() async throws {
            let directory = try TemporaryDirectory()
            let folder = directory.file("read-only")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
            let store = KnownHostsStore(fileURL: folder.appending(path: "KnownHosts.json"))

            // There is no list yet, which can be seen, and none can be
            // started here. The server stays unknown: it is let in when
            // unknown servers are, and asked about again next time.
            let first = challenge(for: Self.ed25519, on: store)
            #expect(first.verdict == .unknown(fingerprint: "SHA256:first"))
            #expect(throws: (any Error).self) { try first.trust() }
            #expect(await SSHClient.knownHostsPolicy(trustUnknownHosts: true)(first))
            #expect(await SSHClient.knownHostsPolicy(trustUnknownHosts: false)(first) == false)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
        }

        // MARK: On disk

        @Test func recordsPersistAndAreSharedBetweenInstances() throws {
            let directory = try TemporaryDirectory()
            // The store creates folders that do not exist yet.
            let file = directory.file("nested/KnownHosts.json")

            let first = KnownHostsStore(fileURL: file)
            #expect(try first.all().isEmpty)
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

        // MARK: A file that cannot be read

        /// A store on a file that holds one record and has then been made
        /// unreadable in the way `damage` chooses.
        static func unreadableStore(
            in directory: TemporaryDirectory,
            damage: (URL) throws -> Void
        ) throws -> (store: KnownHostsStore, file: URL) {
            let file = directory.file("KnownHosts.json")
            let store = KnownHostsStore(fileURL: file)
            try store.trust(host: "mac.example", port: 22, key: ed25519)
            try damage(file)
            return (store, file)
        }

        /// What the store says about a file it cannot read.
        static func reason(_ verdict: KnownHostsStore.Verdict) throws -> String {
            guard case .storeUnreadable(let reason) = verdict else {
                throw UnexpectedVerdict(verdict: verdict)
            }
            return reason
        }

        struct UnexpectedVerdict: Error {
            var verdict: KnownHostsStore.Verdict
        }

        @Test func aFileThatCannotBeOpenedVouchesForNobody() throws {
            let directory = try TemporaryDirectory()
            let (store, file) = try Self.unreadableStore(in: directory) { file in
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            }

            // The server is on record with another key. With the record out
            // of reach that must not turn into a first encounter, which is
            // what would let the changed key through.
            let changed = store.check(host: "mac.example", port: 22, key: Self.otherEd25519)
            let reason = try Self.reason(changed)
            #expect(reason.hasPrefix("The list of trusted SSH servers could not be read. "))
            #expect(reason.contains("permission"))
            // Nor is the key that is on record vouched for, or a stranger.
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519) == changed)
            #expect(store.check(host: "other.example", port: 22, key: Self.ecdsa) == changed)

            // Listing and changing say the same thing instead of acting on
            // a list they cannot see.
            #expect(throws: KnownHostsStore.Unreadable(reason: reason)) { try store.all() }
            #expect(throws: KnownHostsStore.Unreadable(reason: reason)) {
                try store.trust(host: "mac.example", port: 22, key: Self.otherEd25519)
            }
            #expect(throws: KnownHostsStore.Unreadable(reason: reason)) {
                try store.remove(host: "mac.example", port: 22)
            }
            #expect(try store.trust(
                host: "mac.example", port: 22, key: Self.otherEd25519,
                decidedOn: .unknown(fingerprint: "SHA256:second")) == changed)

            // Once it can be read again, everything on record still counts.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519)
                == .mismatch(expected: "SHA256:first", presented: "SHA256:second"))
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519) == .trusted)
        }

        @Test(arguments: [
            ("this is not JSON", "is damaged"),
            (#"{"schemaVersion":1}"#, "is damaged"),
            ("", "is damaged"),
            // What a later version of the app might write.
            (#"{"schemaVersion":2,"servers":[]}"#, "newer version of OpenScreens"),
            (#"{"schemaVersion":2,"hosts":[],"groups":[]}"#, "newer version of OpenScreens"),
        ])
        func lookingAtAFileThatDoesNotMakeSenseLeavesItAsItIs(contents: String, explanation: String) throws {
            let directory = try TemporaryDirectory()
            let (store, file) = try Self.unreadableStore(in: directory) { file in
                try Data(contents.utf8).write(to: file)
            }

            let reason = try Self.reason(store.check(host: "mac.example", port: 22, key: Self.ed25519))
            #expect(reason.contains(explanation))
            #expect(throws: KnownHostsStore.Unreadable(reason: reason)) { try store.all() }
            #expect(throws: KnownHostsStore.Unreadable(reason: reason)) {
                try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
            }

            // Whatever is in the file may be all that is left of the records,
            // or records a newer version can read. It has not been moved,
            // rewritten or joined by anything.
            #expect(try Data(contentsOf: file) == Data(contents.utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["KnownHosts.json"])
        }

        @Test func startingAfreshSetsAFileThatCannotBeReadAside() throws {
            let directory = try TemporaryDirectory()
            let (store, file) = try Self.unreadableStore(in: directory) { file in
                try Data("this is not JSON".utf8).write(to: file)
            }

            try store.removeAll()
            // The store is empty and works again…
            #expect(try store.all().isEmpty)
            #expect(store.check(host: "mac.example", port: 22, key: Self.ed25519)
                == .unknown(fingerprint: "SHA256:first"))
            try store.trust(host: "mac.example", port: 22, key: Self.otherEd25519)
            #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519) == .trusted)

            // …and the file it could not read is still there under another
            // name, as it was.
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            let aside = try #require(names.first { $0.hasPrefix("KnownHosts.unreadable-") })
            #expect(Set(names) == [file.lastPathComponent, aside])
            #expect(try Data(contentsOf: directory.file(aside)) == Data("this is not JSON".utf8))
        }

        @Test func startingAfreshForgetsEveryServer() throws {
            let directory = try TemporaryDirectory()
            for store in [KnownHostsStore(fileURL: nil), KnownHostsStore(fileURL: directory.file("KnownHosts.json"))] {
                // With nothing on record there is nothing to forget.
                try store.removeAll()
                try store.trust(host: "mac.example", port: 22, key: Self.ed25519)
                try store.trust(host: "other.example", port: 2222, key: Self.ecdsa)

                try store.removeAll()
                #expect(try store.all().isEmpty)
                #expect(store.check(host: "mac.example", port: 22, key: Self.otherEd25519)
                    == .unknown(fingerprint: "SHA256:second"))
            }
            // A list that could be read leaves nothing behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
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
            #expect(try KnownHostsStore(fileURL: file).all().count == 40)
        }
    }
}

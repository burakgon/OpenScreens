#if os(macOS)

import Foundation
import Testing
@testable import OpenScreensCore

extension SSHTests {
    /// Runs the client against a real OpenSSH server.
    ///
    /// Every test starts its own private `sshd` (see ``PrivateSSHServer``) and
    /// is skipped, not failed, where one cannot be started.
    @Suite("SSH against a private sshd", .timeLimit(.minutes(2)))
    struct SSHIntegrationTests {

        // MARK: Signing in

        @Test func signsInWithAnAuthorisedKey() async throws {
            try await PrivateSSHServer.run { server in
                let knownHosts = KnownHostsStore(fileURL: nil)
                let client = try await server.connect(knownHosts: knownHosts)

                #expect(client.isConnected)
                #expect(client.host == "127.0.0.1")
                #expect(client.port == server.port)
                #expect(client.username == server.username)
                // The ready-made policy put the server's key on record, and it
                // is the key ssh-keygen says the server has.
                #expect(try knownHosts.all() == [
                    KnownHostsStore.Entry(host: "127.0.0.1", port: server.port, keys: [server.hostKey]),
                ])
                #expect(await server.waitForSessionCount(1))

                await client.close()
                #expect(!client.isConnected)
                #expect(await server.waitForSessionCount(0))
                // Closing twice is harmless.
                await client.close()
            }
        }

        @Test func signsInWithEveryKindOfKey() async throws {
            try await PrivateSSHServer.run { server in
                // The public key is written out by this module and the
                // signature made with the key it read from an OpenSSH file,
                // protected ones included: the server accepting it checks
                // both ends of that.
                for fixture in SSHKeyFixtures.all {
                    let key = try SSHPrivateKey(openSSH: fixture.privateKey, passphrase: fixture.passphrase)
                    // Until the server is told about the key, it is refused.
                    let refusal = SSHError.authenticationFailed(.credentialsRejected)
                    await #expect(throws: refusal, "\(fixture.name)") {
                        try await server.connect(credential: .key(key))
                    }
                    try server.authorize(key)
                    let client = try await server.connect(credential: .key(key))
                    #expect(client.isConnected, "\(fixture.name)")
                    await client.close()
                }
            }
        }

        @Test func aKeyTheServerDoesNotKnowIsRejected() async throws {
            try await PrivateSSHServer.run { server in
                await #expect(throws: SSHError.authenticationFailed(.credentialsRejected)) {
                    try await server.connect(credential: .key(.generateEd25519()))
                }
                // The failed attempt left nothing behind on the server.
                #expect(await server.waitForSessionCount(0))
            }
        }

        @Test func aPasswordIsNoUseOnAKeyOnlyServer() async throws {
            try await PrivateSSHServer.run { server in
                // The server only continues with public keys, so there is
                // nothing left to try: that is a different failure from a
                // wrong password, and the UI can say so.
                let expected = SSHError.authenticationFailed(.noMoreMethods(serverAccepts: ["publickey"]))
                await #expect(throws: expected) {
                    try await server.connect(credential: .password("hunter2"))
                }
            }
        }

        // MARK: Host keys

        @Test func theHostKeyPolicyIsToldWhatTheStoreKnows() async throws {
            try await PrivateSSHServer.run { server in
                let knownHosts = KnownHostsStore(fileURL: nil)
                let challenges = Recorder<SSHHostKeyChallenge>()
                let policy: SSHHostKeyPolicy = { challenge in
                    challenges.record(challenge)
                    return (try? challenge.trust()) == .trusted
                }

                // First encounter: the server is unknown.
                try await server.connect(knownHosts: knownHosts, hostKeyPolicy: policy).close()
                // Second encounter: the key the policy recorded is recognised.
                try await server.connect(knownHosts: knownHosts, hostKeyPolicy: policy).close()

                let seen = challenges.values
                try #require(seen.count == 2)
                for challenge in seen {
                    #expect(challenge.host == "127.0.0.1")
                    #expect(challenge.port == server.port)
                    #expect(challenge.key == server.hostKey)
                    #expect(challenge.keyType == "ssh-ed25519")
                    #expect(challenge.fingerprint == server.hostKey.fingerprint)
                }
                #expect(seen[0].verdict == .unknown(fingerprint: server.hostKey.fingerprint))
                #expect(seen[1].verdict == .trusted)
            }
        }

        @Test func anECDSAHostKeyIsDescribedAsSSHKeygenDescribesIt() async throws {
            try await PrivateSSHServer.run(hostKeyType: "ecdsa") { server in
                let challenges = Recorder<SSHHostKeyChallenge>()
                let client = try await server.connect { challenge in
                    challenges.record(challenge)
                    return true
                }
                #expect(challenges.values.map(\.key) == [server.hostKey])
                #expect(challenges.values.first?.keyType == "ecdsa-sha2-nistp256")
                await client.close()
            }
        }

        @Test func aServerWithOnlyAnRSAHostKeyIsExplained() async throws {
            try await PrivateSSHServer.run(hostKeyType: "rsa") { server in
                // swift-nio-ssh has no RSA, so the two sides cannot agree on
                // a host key algorithm. The error should say what is wrong
                // rather than report a bare protocol failure.
                let error = await #expect(throws: SSHError.self) { try await server.connect() }
                guard case .connectionFailed(let reason) = error else {
                    Issue.record("expected .connectionFailed, got \(String(describing: error))")
                    return
                }
                #expect(reason.contains("no SSH algorithms in common"))
            }
        }

        @Test func timeSpentDecidingAboutTheHostKeyIsNotCountedAgainstTheTimeout() async throws {
            try await PrivateSSHServer.run { server in
                // A person reading a fingerprint takes longer than a server
                // may take to answer. The first must not trip the second.
                let client = try await server.connect(
                    hostKeyPolicy: { _ in
                        try? await Task.sleep(for: .seconds(2))
                        return true
                    },
                    timeout: .seconds(1))
                #expect(client.isConnected)
                await client.close()
            }
        }

        @Test func aPolicyThatSaysNoEndsTheAttempt() async throws {
            try await PrivateSSHServer.run { server in
                let expected = SSHError.hostKeyRejected(fingerprint: server.hostKey.fingerprint)
                await #expect(throws: expected) {
                    try await server.connect(hostKeyPolicy: { _ in false })
                }

                // The ready-made policy refuses a first encounter unless it
                // was told to trust those, and records nothing when it refuses.
                let knownHosts = KnownHostsStore(fileURL: nil)
                await #expect(throws: expected) {
                    try await server.connect(
                        knownHosts: knownHosts,
                        hostKeyPolicy: SSHClient.knownHostsPolicy(trustUnknownHosts: false))
                }
                let recorded = try knownHosts.all()
                #expect(recorded.isEmpty)
            }
        }

        @Test func aChangedHostKeyIsRefusedByTheStandardPolicy() async throws {
            try await PrivateSSHServer.run { server in
                // The store remembers this address with some other key, as it
                // would after the server was replaced, or impersonated.
                let knownHosts = KnownHostsStore(fileURL: nil)
                let remembered = SSHHostKey(type: "ssh-ed25519", fingerprint: "SHA256:somethingElse")
                try knownHosts.trust(host: "127.0.0.1", port: server.port, key: remembered)

                let verdicts = Recorder<KnownHostsStore.Verdict>()
                let standard = SSHClient.knownHostsPolicy(trustUnknownHosts: true)
                await #expect(throws: SSHError.hostKeyRejected(fingerprint: server.hostKey.fingerprint)) {
                    try await server.connect(knownHosts: knownHosts) { challenge in
                        verdicts.record(challenge.verdict)
                        return await standard(challenge)
                    }
                }
                #expect(verdicts.values == [
                    .mismatch(expected: "SHA256:somethingElse", presented: server.hostKey.fingerprint),
                ])
                // Trusting unknown hosts does not extend to changed ones.
                #expect(try knownHosts.all().first?.keys == [remembered])
            }
        }

        @Test func aRecordThatCannotBeReadStopsTheConnectionAndSaysWhy() async throws {
            try await PrivateSSHServer.run { server in
                // The server is on record, with a key it no longer presents,
                // and then the record goes out of reach.
                let directory = try TemporaryDirectory()
                let file = directory.file("KnownHosts.json")
                let knownHosts = KnownHostsStore(fileURL: file)
                let remembered = SSHHostKey(type: "ssh-ed25519", fingerprint: "SHA256:somethingElse")
                try knownHosts.trust(host: "127.0.0.1", port: server.port, key: remembered)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

                // Trusting servers met for the first time does not help it:
                // nobody can say that this is one.
                let verdicts = Recorder<KnownHostsStore.Verdict>()
                let standard = SSHClient.knownHostsPolicy(trustUnknownHosts: true)
                let error = await #expect(throws: SSHError.self) {
                    try await server.connect(knownHosts: knownHosts) { challenge in
                        verdicts.record(challenge.verdict)
                        return await standard(challenge)
                    }
                }
                guard case .knownHostsUnreadable(let reason) = error else {
                    Issue.record("expected .knownHostsUnreadable, got \(String(describing: error))")
                    return
                }
                // The user is told what is wrong, and it is not the key.
                #expect(verdicts.values == [.storeUnreadable(reason: reason)])
                #expect(reason.hasPrefix("The list of trusted SSH servers could not be read. "))
                #expect(error?.errorDescription == "The SSH server's identity could not be checked. \(reason)")
                #expect(await server.waitForSessionCount(0))

                // With the record back, the changed key is the mismatch it
                // always was.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                await #expect(throws: SSHError.hostKeyRejected(fingerprint: server.hostKey.fingerprint)) {
                    try await server.connect(knownHosts: knownHosts)
                }
            }
        }

        // MARK: Connections that do not come about

        @Test func aRefusedConnectionFailsWithoutWaitingForTheTimeout() async throws {
            let port = try PrivateSSHServer.refusingLoopbackPort()
            let clock = ContinuousClock()
            let started = clock.now

            let error = await #expect(throws: SSHError.self) {
                try await SSHClient.connect(
                    host: "127.0.0.1", port: port, username: "nobody",
                    credential: .password("x"),
                    knownHosts: KnownHostsStore(fileURL: nil),
                    hostKeyPolicy: { _ in true },
                    timeout: .seconds(30))
            }
            guard case .connectionFailed = error else {
                Issue.record("expected .connectionFailed, got \(String(describing: error))")
                return
            }
            #expect(clock.now - started < .seconds(10))
        }

        @Test func aConnectionThatIsNeverAcceptedTimesOut() async throws {
            let unanswering = try UnansweringPort()
            let clock = ContinuousClock()
            let started = clock.now

            // The time runs out while the connection is still being made.
            // Giving up closes the socket, and that must not be what gets
            // reported: the cause is the timeout, the closing is fallout.
            await #expect(throws: SSHError.timeout) {
                try await SSHClient.connect(
                    host: "127.0.0.1", port: unanswering.port, username: "nobody",
                    credential: .password("x"),
                    knownHosts: KnownHostsStore(fileURL: nil),
                    hostKeyPolicy: { _ in true },
                    timeout: .seconds(1))
            }
            let elapsed = clock.now - started
            #expect(elapsed >= .milliseconds(900) && elapsed < .seconds(10))
            // The port had to stay held until the attempt was over.
            withExtendedLifetime(unanswering) {}
        }

        @Test func aServerThatNeverAnswersTimesOut() async throws {
            let silent = try await LoopbackServer.start(.silent)
            defer { silent.stop() }
            let clock = ContinuousClock()
            let started = clock.now

            await #expect(throws: SSHError.timeout) {
                try await SSHClient.connect(
                    host: "127.0.0.1", port: silent.port, username: "nobody",
                    credential: .password("x"),
                    knownHosts: KnownHostsStore(fileURL: nil),
                    hostKeyPolicy: { _ in true },
                    timeout: .seconds(1))
            }
            let elapsed = clock.now - started
            #expect(elapsed >= .milliseconds(900) && elapsed < .seconds(10))
        }

        @Test func cancellingTheTaskAbandonsTheAttempt() async throws {
            let silent = try await LoopbackServer.start(.silent)
            defer { silent.stop() }

            let attempt = Task {
                try await SSHClient.connect(
                    host: "127.0.0.1", port: silent.port, username: "nobody",
                    credential: .password("x"),
                    knownHosts: KnownHostsStore(fileURL: nil),
                    hostKeyPolicy: { _ in true },
                    timeout: .seconds(60))
            }
            try await Task.sleep(for: .milliseconds(200))
            let clock = ContinuousClock()
            let cancelled = clock.now
            attempt.cancel()

            await #expect(throws: CancellationError.self) { try await attempt.value }
            #expect(clock.now - cancelled < .seconds(5))
        }

        @Test func invalidAddressesAreRefusedUpFront() async {
            for (host, port) in [("", 22), ("127.0.0.1", 0), ("127.0.0.1", 70_000)] {
                let error = await #expect(throws: SSHError.self) {
                    try await SSHClient.connect(
                        host: host, port: port, username: "nobody",
                        credential: .password("x"),
                        knownHosts: KnownHostsStore(fileURL: nil),
                        hostKeyPolicy: { _ in true })
                }
                guard case .connectionFailed = error else {
                    Issue.record("expected .connectionFailed, got \(String(describing: error))")
                    continue
                }
            }
        }
    }
}

#endif

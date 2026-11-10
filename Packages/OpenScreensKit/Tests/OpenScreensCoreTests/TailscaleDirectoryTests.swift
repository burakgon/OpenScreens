import Foundation
import Testing
@testable import OpenScreensCore

// MARK: - Support

/// A source whose answers are scripted call by call. A call can be held back
/// until the test lets it go, to look at the directory mid-refresh.
private actor ScriptedTailscaleSource: TailscaleSource {
    struct Step: Sendable {
        var result: Result<[TailscaleDevice], any Error>
        var isHeld = false

        static func devices(_ devices: [TailscaleDevice], held: Bool = false) -> Step {
            Step(result: .success(devices), isHeld: held)
        }

        static func failure(_ error: any Error, held: Bool = false) -> Step {
            Step(result: .failure(error), isHeld: held)
        }
    }

    private let steps: [Step]
    private(set) var callCount = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// The last step repeats for every call after it.
    init(_ steps: Step...) {
        self.steps = steps
    }

    func devices() async throws -> [TailscaleDevice] {
        callCount += 1
        let step = steps[min(callCount, steps.count) - 1]

        let reached = callWaiters.filter { $0.count <= callCount }
        callWaiters.removeAll { $0.count <= callCount }
        reached.forEach { $0.continuation.resume() }

        if step.isHeld {
            await withCheckedContinuation { held.append($0) }
        }
        return try step.result.get()
    }

    /// Returns once `devices()` has been called at least `count` times.
    func waitForCall(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    /// Lets every held call go on.
    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class TailscaleTestBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Tests

@MainActor
@Suite struct TailscaleDirectoryTests {

    private func device(
        _ name: String,
        os: String = "macOS",
        online: Bool = true,
        isSelf: Bool = false,
        id: String? = nil
    ) -> TailscaleDevice {
        TailscaleDevice(
            id: id ?? "n-\(name)",
            name: name,
            dnsName: "\(name.lowercased()).tail-example.ts.net",
            addresses: ["100.64.0.1"],
            os: os,
            isOnline: online,
            isSelf: isSelf)
    }

    /// Waits, briefly, for something that happens a moment after a refresh.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Arranging

    @Test func devicesAreArrangedForTheList() {
        let arranged = TailscaleDirectory.arranged([
            device("phone", os: "iOS", online: true),
            device("zeta", online: false),
            device("tablet", os: "android", online: false),
            device("alpha", os: "linux", online: false),
            device("Mini 10"),
            device("this-mac", isSelf: true),
            device("beta", os: "windows"),
            device("mini 2"),
            device("tv", os: "tvOS", online: true),
        ])
        #expect(arranged.map(\.name) == [
            // Can be controlled and online, by name the way Finder sorts:
            // without regard to case, and 2 before 10.
            "beta", "mini 2", "Mini 10",
            // Can be controlled, offline.
            "alpha", "zeta",
            // Cannot be controlled: online, then offline.
            "phone", "tv", "tablet",
        ])
    }

    @Test func repeatedDevicesAreListedOnceAndSameNamesInASteadyOrder() {
        let arranged = TailscaleDirectory.arranged([
            device("twin", id: "n-2"),
            device("twin", id: "n-1"),
            device("twin", id: "n-2"),
        ])
        #expect(arranged.map(\.id) == ["n-1", "n-2"])
    }

    // MARK: Refreshing

    @Test func aDirectoryStartsNotConfigured() {
        let directory = TailscaleDirectory(source: { nil })
        #expect(directory.state == .notConfigured)
        #expect(directory.devices.isEmpty)
        #expect(!directory.isRefreshing)
    }

    @Test func refreshingPublishesTheDevices() async {
        let source = ScriptedTailscaleSource(.devices([
            device("zeta"), device("this-mac", isSelf: true), device("alpha"),
        ]))
        let directory = TailscaleDirectory(source: { source })
        let before = Date.now
        await directory.refresh()

        #expect(directory.devices.map(\.name) == ["alpha", "zeta"])
        #expect(!directory.isRefreshing)
        guard case .ready(let date) = directory.state else {
            Issue.record("expected ready, got \(directory.state)")
            return
        }
        #expect(date >= before && date <= Date.now)
    }

    @Test func withoutASourceTheDirectoryIsNotConfigured() async {
        let source = ScriptedTailscaleSource(.devices([device("alpha")]))
        let current = TailscaleTestBox<(any TailscaleSource)?>(source)
        let directory = TailscaleDirectory(source: { current.value })

        await directory.refresh()
        #expect(directory.devices.count == 1)

        current.value = nil
        await directory.refresh()
        #expect(directory.state == .notConfigured)
        #expect(directory.devices.isEmpty)
        #expect(!directory.isRefreshing)
        #expect(await source.callCount == 1)
    }

    @Test func aFailureThatSettlesTheMatterEmptiesTheList() async {
        let source = ScriptedTailscaleSource(
            .devices([device("alpha")]),
            .failure(TailscaleError.accessTokenRejected))
        let directory = TailscaleDirectory(source: { source })

        await directory.refresh()
        #expect(directory.devices.count == 1)

        await directory.refresh()
        #expect(directory.devices.isEmpty)
        #expect(
            directory.state == .failed(TailscaleError.accessTokenRejected.errorDescription ?? ""))
        #expect(!directory.isRefreshing)
    }

    @Test func aFailureToGetThroughKeepsTheList() async {
        let source = ScriptedTailscaleSource(
            .devices([device("alpha")]),
            .failure(URLError(.notConnectedToInternet)),
            .failure(TailscaleError.timedOut),
            .failure(TailscaleError.server(status: 503, message: nil)),
            .devices([device("alpha"), device("beta")]))
        let directory = TailscaleDirectory(source: { source })
        await directory.refresh()

        for _ in 0..<3 {
            await directory.refresh()
            #expect(directory.devices.map(\.name) == ["alpha"])
            guard case .failed(let message) = directory.state else {
                Issue.record("expected a failure, got \(directory.state)")
                return
            }
            #expect(!message.isEmpty)
        }

        await directory.refresh()
        #expect(directory.devices.map(\.name) == ["alpha", "beta"])
        guard case .ready = directory.state else {
            Issue.record("expected ready, got \(directory.state)")
            return
        }
    }

    @Test func aFirstFailureLeavesNothingToShow() async {
        let source = ScriptedTailscaleSource(.failure(TailscaleError.notRunning))
        let directory = TailscaleDirectory(source: { source })
        await directory.refresh()
        #expect(directory.devices.isEmpty)
        #expect(directory.state == .failed(TailscaleError.notRunning.errorDescription ?? ""))
    }

    @Test func loadingIsOnlyShownUntilThereIsAList() async {
        let source = ScriptedTailscaleSource(
            .devices([device("alpha")], held: true),
            .devices([device("alpha"), device("beta")], held: true),
            .failure(URLError(.timedOut)),
            .devices([device("alpha")], held: true))
        let directory = TailscaleDirectory(source: { source })

        let first = Task { await directory.refresh() }
        await source.waitForCall(1)
        #expect(directory.state == .loading)
        #expect(directory.isRefreshing)
        #expect(directory.devices.isEmpty)
        await source.release()
        await first.value
        guard case .ready(let firstDate) = directory.state else {
            Issue.record("expected ready, got \(directory.state)")
            return
        }
        #expect(!directory.isRefreshing)

        // A list that is on show stays on show while it is brought up to date.
        let second = Task { await directory.refresh() }
        await source.waitForCall(2)
        #expect(directory.state == .ready(firstDate))
        #expect(directory.isRefreshing)
        #expect(directory.devices.map(\.name) == ["alpha"])
        await source.release()
        await second.value
        #expect(directory.devices.map(\.name) == ["alpha", "beta"])
        #expect(!directory.isRefreshing)

        // After a failure the next attempt counts as loading again.
        await directory.refresh()
        guard case .failed = directory.state else {
            Issue.record("expected a failure, got \(directory.state)")
            return
        }
        let fourth = Task { await directory.refresh() }
        await source.waitForCall(4)
        #expect(directory.state == .loading)
        #expect(directory.devices.map(\.name) == ["alpha", "beta"])
        await source.release()
        await fourth.value
        #expect(directory.devices.map(\.name) == ["alpha"])
    }

    @Test func aNewerRefreshWins() async {
        let source = ScriptedTailscaleSource(
            .devices([device("stale")], held: true),
            .devices([device("fresh")]))
        let directory = TailscaleDirectory(source: { source })

        let first = Task { await directory.refresh() }
        await source.waitForCall(1)
        await directory.refresh()
        #expect(directory.devices.map(\.name) == ["fresh"])
        let settled = directory.state
        guard case .ready = settled else {
            Issue.record("expected ready, got \(settled)")
            return
        }
        #expect(!directory.isRefreshing)

        // The first listing comes back late and is ignored.
        await source.release()
        await first.value
        #expect(directory.devices.map(\.name) == ["fresh"])
        #expect(directory.state == settled)
        #expect(!directory.isRefreshing)
    }

    // MARK: Choosing a source

    @Test func aChangeOfSourceStartsOver() async {
        let local = ScriptedTailscaleSource(.devices([device("from-this-mac")]))
        let api = ScriptedTailscaleSource(.devices([device("from-the-api")], held: true))
        let credentials = TailscaleCredentials.accessToken("tskey-api-test")
        let selection = TailscaleTestBox(TailscaleDirectory.Selection(source: local, identity: .local))
        let directory = TailscaleDirectory(select: { selection.value })

        await directory.refresh()
        #expect(directory.devices.map(\.name) == ["from-this-mac"])

        // What one source listed is not shown while another is asked.
        selection.value = .init(source: api, identity: .api(tailnet: "-", credentials: credentials))
        let switched = Task { await directory.refresh() }
        await api.waitForCall(1)
        #expect(directory.devices.isEmpty)
        #expect(directory.state == .loading)
        await api.release()
        await switched.value
        #expect(directory.devices.map(\.name) == ["from-the-api"])
    }

    @Test func aChangeOfSourceDoesNotKeepTheOldListThroughAFailure() async {
        let local = ScriptedTailscaleSource(.devices([device("from-this-mac")]))
        let api = ScriptedTailscaleSource(.failure(URLError(.notConnectedToInternet)))
        let selection = TailscaleTestBox(TailscaleDirectory.Selection(source: local, identity: .local))
        let directory = TailscaleDirectory(select: { selection.value })
        await directory.refresh()

        selection.value = .init(
            source: api, identity: .api(tailnet: "-", credentials: .accessToken("tskey-api-test")))
        await directory.refresh()
        #expect(directory.devices.isEmpty)
        guard case .failed = directory.state else {
            Issue.record("expected a failure, got \(directory.state)")
            return
        }
    }

    @Test func turningTailscaleOffEmptiesTheDirectory() async {
        // Neither mode used here has a source to ask, so nothing leaves the test.
        let store = CredentialStore(storage: InMemorySecretStorage())
        let mode = TailscaleTestBox(TailscaleMode.off)
        let directory = TailscaleDirectory(credentials: store, mode: { mode.value })

        await directory.refresh()
        #expect(directory.state == .notConfigured)
        #expect(!directory.isRefreshing)

        // The API without saved credentials is not configured either.
        mode.value = .api(tailnet: "example.com")
        await directory.refresh()
        #expect(directory.state == .notConfigured)
        #expect(directory.devices.isEmpty)
    }

    @Test func modesComeDownToConfigurations() async throws {
        typealias Configuration = TailscaleDirectory.Configuration
        let empty = CredentialStore(storage: InMemorySecretStorage())
        let withToken = CredentialStore(storage: InMemorySecretStorage())
        try withToken.setSecret("tskey-api-test", named: TailscaleCredentials.SecretName.accessToken)
        let token = TailscaleCredentials.accessToken("tskey-api-test")

        #expect(await TailscaleDirectory.configuration(for: .off, credentials: withToken) == nil)
        #expect(
            await TailscaleDirectory.configuration(for: .api(tailnet: "example.com"), credentials: empty)
                == nil)
        #expect(
            await TailscaleDirectory.configuration(for: .api(tailnet: "example.com"), credentials: withToken)
                == Configuration.api(tailnet: "example.com", credentials: token))
        #expect(
            await TailscaleDirectory.configuration(for: .api(), credentials: withToken)
                == Configuration.api(tailnet: "-", credentials: token))
        // Saved credentials decide for the API even where Tailscale is installed.
        #expect(
            await TailscaleDirectory.configuration(for: .automatic(), credentials: withToken)
                == Configuration.api(tailnet: "-", credentials: token))

        #if os(macOS)
        #expect(
            await TailscaleDirectory.configuration(for: .local, credentials: withToken)
                == Configuration.local)
        // Without credentials it comes down to whether this Mac has Tailscale.
        let fallback: Configuration? = TailscaleLocalSource.isInstalled ? .local : nil
        #expect(
            await TailscaleDirectory.configuration(for: .automatic(), credentials: empty) == fallback)
        #else
        #expect(await TailscaleDirectory.configuration(for: .local, credentials: withToken) == nil)
        #expect(await TailscaleDirectory.configuration(for: .automatic(), credentials: empty) == nil)
        #endif
    }

    // MARK: Automatic refreshing

    @Test(.timeLimit(.minutes(1)))
    func automaticRefreshingKeepsListingUntilStopped() async throws {
        let source = ScriptedTailscaleSource(.devices([device("alpha")]))
        let directory = TailscaleDirectory(source: { source })

        // Shorter than the minimum, so the minimum applies.
        directory.startAutoRefresh(every: .milliseconds(1))
        await source.waitForCall(2)
        directory.stop()
        #expect(directory.devices.map(\.name) == ["alpha"])

        try await Task.sleep(for: TailscaleDirectory.minimumRefreshInterval + .milliseconds(500))
        #expect(await source.callCount == 2)
        guard case .ready = directory.state else {
            Issue.record("expected ready, got \(directory.state)")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func startingAgainReplacesTheSchedule() async throws {
        let source = ScriptedTailscaleSource(.devices([device("alpha")]))
        let directory = TailscaleDirectory(source: { source })

        directory.startAutoRefresh(every: TailscaleDirectory.minimumRefreshInterval)
        await source.waitForCall(1)
        // The new schedule refreshes at once and then not for an hour. Were
        // the first one still running, it would refresh again within moments.
        directory.startAutoRefresh(every: .seconds(3600))
        await source.waitForCall(2)
        try await Task.sleep(for: TailscaleDirectory.minimumRefreshInterval + .milliseconds(500))
        #expect(await source.callCount == 2)
        directory.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDirectoryThatRefreshesAutomaticallyCanStillBeReleased() async {
        let source = ScriptedTailscaleSource(.devices([device("alpha")]))
        var directory: TailscaleDirectory? = TailscaleDirectory(source: { source })
        weak let released = directory

        directory?.startAutoRefresh(every: .seconds(3600))
        await source.waitForCall(1)
        #expect(await eventually { directory?.isRefreshing == false })

        directory = nil
        #expect(released == nil)
    }

    // MARK: Errors

    @Test func failuresAreSortedIntoPassingAndLasting() {
        #expect(TailscaleDirectory.isTransient(URLError(.timedOut)))
        #expect(TailscaleDirectory.isTransient(URLError(.notConnectedToInternet)))
        #expect(TailscaleDirectory.isTransient(TailscaleError.timedOut))
        #expect(TailscaleDirectory.isTransient(TailscaleError.server(status: 502, message: nil)))
        #expect(!TailscaleDirectory.isTransient(TailscaleError.accessDenied))
        #expect(!TailscaleDirectory.isTransient(TailscaleError.loggedOut))
        #expect(!TailscaleDirectory.isTransient(CocoaError(.fileNoSuchFile)))
    }

    @Test func messagesAreTheErrorsOwn() {
        #expect(
            TailscaleDirectory.message(for: TailscaleError.loggedOut)
                == TailscaleError.loggedOut.errorDescription)
        let network = URLError(.notConnectedToInternet)
        #expect(TailscaleDirectory.message(for: network) == network.localizedDescription)
        #expect(!TailscaleDirectory.message(for: network).isEmpty)
    }
}

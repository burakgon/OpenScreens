import Foundation
import Observation

/// Where a ``TailscaleDirectory`` gets its list of devices from.
public enum TailscaleMode: Hashable, Sendable {
    /// Tailscale is not used; the directory stays empty.
    case off
    /// The HTTP API when credentials are saved in the keychain; otherwise, on
    /// a Mac with Tailscale installed, the Tailscale client; otherwise
    /// nothing. The mode to use unless the user has chosen one.
    case automatic(tailnet: String = "-")
    /// The Tailscale client installed on this Mac. Needs no setting up.
    /// Not available on iPhone and iPad.
    case local
    /// Tailscale's HTTP API, signed with the credentials saved in the
    /// keychain. `tailnet` is a tailnet ID, or `-` for the credentials' own.
    case api(tailnet: String = "-")
}

/// The devices in the user's tailnet, kept ready for the interface.
///
/// The directory is told where to look through a closure that is asked again
/// before every refresh, so changing a preference — turning Tailscale off,
/// switching between this Mac's client and the HTTP API, another tailnet —
/// takes effect with the next ``refresh()``.
@MainActor
@Observable
public final class TailscaleDirectory {

    public enum State: Equatable, Sendable {
        /// There is nowhere to list devices from: Tailscale is turned off, no
        /// credentials are saved, or no Tailscale client is installed.
        case notConfigured
        /// The first listing from a source is under way.
        case loading
        /// ``devices`` is the list as it was at this moment.
        case ready(Date)
        /// The last attempt failed; the text says why.
        case failed(String)
    }

    /// Devices to offer, this one excluded: those that can be controlled
    /// first, then those that are online, then by name.
    ///
    /// After a failed refresh the list from the last good one is kept if the
    /// failure was only a matter of not getting through (no network, a
    /// timeout, a server error). It is emptied when the failure says the list
    /// itself is no longer to be trusted — credentials rejected, Tailscale
    /// stopped or signed out — and whenever the source changes.
    public private(set) var devices: [TailscaleDevice] = []
    public private(set) var state: State = .notConfigured
    /// Whether a refresh is under way. Unlike ``state``, which stays `.ready`
    /// while an existing list is being brought up to date, this is true
    /// during every refresh.
    public private(set) var isRefreshing = false

    /// A source, and something that tells one configuration from another.
    struct Selection: Sendable {
        var source: any TailscaleSource
        var identity: Configuration?
    }

    /// What ``TailscaleMode`` comes down to once the keychain and the disk
    /// have been looked at.
    enum Configuration: Hashable, Sendable {
        case local
        case api(tailnet: String, credentials: TailscaleCredentials)
    }

    @ObservationIgnored private let select: @MainActor () async -> Selection?
    @ObservationIgnored private var currentIdentity: Configuration?
    @ObservationIgnored private var hasSelection = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fetch: Task<[TailscaleDevice], any Error>?
    @ObservationIgnored private var autoRefresh: Task<Void, Never>?

    /// The shortest pause between automatic refreshes.
    public static let minimumRefreshInterval: Duration = .seconds(1)

    /// Creates a directory that follows the app's preferences.
    ///
    /// - Parameters:
    ///   - credentials: The keychain to read the API credentials from, under
    ///     the names in ``TailscaleCredentials/SecretName``. They are read
    ///     afresh, off the main thread, before every refresh.
    ///   - mode: Asked before every refresh for where to look.
    public convenience init(
        credentials: CredentialStore = CredentialStore(),
        mode: @escaping @MainActor () -> TailscaleMode
    ) {
        let sources = SourceCache()
        self.init(select: {
            let configuration = await TailscaleDirectory.configuration(
                for: mode(), credentials: credentials)
            return configuration.map {
                Selection(source: sources.source(for: $0), identity: $0)
            }
        })
    }

    /// Creates a directory that lists from a source of the caller's making.
    ///
    /// - Parameter source: Asked before every refresh; `nil` means there is
    ///   nothing to list from.
    public convenience init(source: @escaping @MainActor () -> (any TailscaleSource)?) {
        self.init(select: {
            source().map { Selection(source: $0, identity: nil) }
        })
    }

    /// The one real initializer: `select` is asked before every refresh for
    /// the source to use and what configuration it stands for.
    init(select: @escaping @MainActor () async -> Selection?) {
        self.select = select
    }

    // MARK: - Refreshing

    /// Lists the devices again and updates ``devices`` and ``state``.
    ///
    /// Returns when the listing has been applied. If another refresh starts
    /// meanwhile, that one wins: this one's listing is abandoned and its
    /// result dropped. Cancelling the calling task does not abandon the
    /// listing — it runs to its end, bounded by the source's own timeout, so
    /// ``state`` always settles on what was actually found out.
    public func refresh() async {
        generation += 1
        let generation = generation
        fetch?.cancel()
        fetch = nil
        isRefreshing = true

        let selection = await select()
        guard generation == self.generation else { return }

        guard let selection else {
            hasSelection = false
            currentIdentity = nil
            setDevices([])
            state = .notConfigured
            isRefreshing = false
            return
        }

        if !hasSelection || selection.identity != currentIdentity {
            // Devices listed by one source say nothing about another.
            hasSelection = true
            currentIdentity = selection.identity
            setDevices([])
            state = .loading
        } else if case .ready = state {
            // A list that is on show stays on show while it is brought up to
            // date; only a first listing, or a new attempt after a failure,
            // counts as loading.
        } else {
            state = .loading
        }

        let source = selection.source
        let fetch = Task { try await Self.arrangedDevices(from: source) }
        self.fetch = fetch
        let result = await fetch.result
        guard generation == self.generation else { return }
        self.fetch = nil
        isRefreshing = false

        switch result {
        case .success(let listed):
            setDevices(listed)
            state = .ready(.now)
        case .failure(let error):
            if !Self.isTransient(error) {
                setDevices([])
            }
            state = .failed(Self.message(for: error))
        }
    }

    /// Refreshes now and then again every `interval` until ``stop()``.
    /// Calling it again replaces the schedule.
    public func startAutoRefresh(every interval: Duration = .seconds(60)) {
        autoRefresh?.cancel()
        let interval = max(interval, Self.minimumRefreshInterval)
        autoRefresh = Task { [weak self] in
            while !Task.isCancelled {
                // The directory is only held for the length of a refresh, so
                // this loop does not keep it alive between them.
                do {
                    guard let self else { return }
                    await self.refresh()
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Ends automatic refreshing. ``devices`` and ``state`` stay as they are,
    /// and a refresh that is under way is left to finish.
    public func stop() {
        autoRefresh?.cancel()
        autoRefresh = nil
    }

    private func setDevices(_ newValue: [TailscaleDevice]) {
        // Assigning an equal list would still wake every observer.
        if devices != newValue {
            devices = newValue
        }
    }

    // MARK: - Arranging

    /// Asks a source for its devices and puts them in publishing order. A
    /// large tailnet has thousands of devices, so the sorting is done here,
    /// off the main actor, and only the finished list is handed over.
    @concurrent
    private static func arrangedDevices(
        from source: any TailscaleSource
    ) async throws -> [TailscaleDevice] {
        arranged(try await source.devices())
    }

    /// The order and selection ``devices`` is published in: without this
    /// device and without repeats; controllable before not, online before
    /// offline, then by name the way Finder sorts names.
    nonisolated static func arranged(_ devices: [TailscaleDevice]) -> [TailscaleDevice] {
        var seen = Set<String>()
        return devices
            .filter { !$0.isSelf && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.canBeControlled != rhs.canBeControlled {
                    return lhs.canBeControlled
                }
                if lhs.isOnline != rhs.isOnline {
                    return lhs.isOnline
                }
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.id < rhs.id
                }
            }
    }

    /// Whether a failure leaves the last good list standing. See ``devices``.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? TailscaleError {
            return error.isTransient
        }
        return error is URLError
    }

    nonisolated static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Choosing a source

    /// Works out what a mode means right now. This reads the keychain and
    /// looks for the Tailscale client on disk, so it runs off the main actor.
    @concurrent
    static func configuration(
        for mode: TailscaleMode,
        credentials: CredentialStore
    ) async -> Configuration? {
        switch mode {
        case .off:
            return nil

        case .local:
            #if os(macOS)
            return .local
            #else
            return nil
            #endif

        case .api(let tailnet):
            return TailscaleCredentials.saved(in: credentials).map {
                .api(tailnet: tailnet, credentials: $0)
            }

        case .automatic(let tailnet):
            if let saved = TailscaleCredentials.saved(in: credentials) {
                return .api(tailnet: tailnet, credentials: saved)
            }
            #if os(macOS)
            return TailscaleLocalSource.isInstalled ? .local : nil
            #else
            return nil
            #endif
        }
    }

    /// Keeps the source for the current configuration, so that a source's
    /// own state — an OAuth access token above all — survives from one
    /// refresh to the next, and is dropped the moment anything changes.
    @MainActor
    private final class SourceCache {
        private var cached: (configuration: Configuration, source: any TailscaleSource)?

        func source(for configuration: Configuration) -> any TailscaleSource {
            if let cached, cached.configuration == configuration {
                return cached.source
            }
            let source = Self.makeSource(for: configuration)
            cached = (configuration, source)
            return source
        }

        private static func makeSource(for configuration: Configuration) -> any TailscaleSource {
            switch configuration {
            case .api(let tailnet, let credentials):
                return TailscaleAPISource(tailnet: tailnet, credentials: credentials)
            case .local:
                #if os(macOS)
                return TailscaleLocalSource()
                #else
                // `configuration(for:credentials:)` never produces `.local`
                // where there is no Tailscale client to ask.
                return UnavailableSource()
                #endif
            }
        }
    }

    #if !os(macOS)
    /// Stands in for the local source on platforms that have none.
    private struct UnavailableSource: TailscaleSource {
        func devices() async throws -> [TailscaleDevice] {
            throw TailscaleError.notInstalled
        }
    }
    #endif
}

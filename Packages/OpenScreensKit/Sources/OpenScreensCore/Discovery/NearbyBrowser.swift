import Foundation
import Observation

/// Finds computers on the local network that offer screen sharing.
///
/// Views read ``computers`` and ``state``; the app calls ``start()`` while the
/// list is on screen and ``stop()`` when it is not. All Bonjour work happens
/// off the main thread, and bursts of discoveries are gathered so observers
/// are told about a changed list a few times a second at most.
///
/// Call ``start()`` again whenever the app becomes active. It does nothing
/// while browsing is healthy, and it makes a fresh attempt after access to
/// the local network was denied — which is how a permission the user has
/// just granted in Settings gets noticed.
@MainActor
@Observable
public final class NearbyBrowser {

    public enum State: Equatable, Sendable {
        /// Not browsing.
        case idle
        /// Browsing; ``computers`` is kept up to date.
        case searching
        /// The user has not allowed this app to use the local network.
        case denied
        /// Browsing failed. It is retried automatically; the text says why.
        case failed(String)
    }

    /// Computers currently advertising screen sharing, except this device,
    /// in name order.
    public private(set) var computers: [NearbyComputer] = []
    public private(set) var state: State = .idle

    /// The Bonjour service types the browser looks for. On iOS every one of
    /// them has to be listed under `NSBonjourServices` in the app's
    /// Info.plist, next to an `NSLocalNetworkUsageDescription`; a type that
    /// is missing there cannot be searched for.
    public nonisolated static let bonjourServiceTypes: [String] =
        BonjourServiceType.allCases.map(\.rawValue)

    @ObservationIgnored private let makeSearch: @MainActor () -> any NearbySearch
    @ObservationIgnored private let firstRetryDelay: Duration
    @ObservationIgnored private let longestRetryDelay: Duration

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var sessionBegan: ContinuousClock.Instant?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// How long the next retry waits. Grows while failures keep coming.
    @ObservationIgnored private(set) var retryDelay: Duration

    public convenience init() {
        self.init(makeSearch: { NearbyEngine() })
    }

    /// The initializer tests use: the browsing itself and the pace of
    /// retries are supplied from outside.
    init(
        makeSearch: @escaping @MainActor () -> any NearbySearch,
        firstRetryDelay: Duration = .seconds(1),
        longestRetryDelay: Duration = .seconds(30)
    ) {
        self.makeSearch = makeSearch
        self.firstRetryDelay = firstRetryDelay
        self.longestRetryDelay = longestRetryDelay
        retryDelay = firstRetryDelay
    }

    /// Starts looking for nearby computers. Does nothing when already
    /// searching; after a denial or a failure it tries again from scratch.
    public func start() {
        if state == .searching, session != nil {
            return
        }
        retryDelay = firstRetryDelay
        beginSession()
    }

    /// Stops looking and empties ``computers``.
    public func stop() {
        retry?.cancel()
        retry = nil
        session = nil
        sessionBegan = nil
        retryDelay = firstRetryDelay
        setComputers([])
        setState(.idle)
    }

    // MARK: - Sessions

    /// One run of browsing: a search and the task that listens to it.
    /// Letting go of a session is what stops it, so nothing keeps running
    /// when the browser itself is released without ``NearbyBrowser/stop()``.
    private final class Session: Sendable {
        let search: any NearbySearch
        let listener: Task<Void, Never>

        init(search: any NearbySearch, listener: Task<Void, Never>) {
            self.search = search
            self.listener = listener
        }

        deinit {
            listener.cancel()
            search.shutdown()
        }
    }

    private func beginSession() {
        retry?.cancel()
        retry = nil
        session = nil

        let search = makeSearch()
        let listener = Task { [weak self] in
            for await event in search.events {
                guard let self else { return }
                self.handle(event, from: search)
            }
        }
        session = Session(search: search, listener: listener)
        sessionBegan = .now
        setComputers([])
        setState(.searching)
        search.start()
    }

    private func handle(_ event: NearbyEngine.Event, from search: any NearbySearch) {
        // An event can still turn up from a search whose session has just
        // been let go — it was already on its way here. It is not wanted.
        guard session?.search === search else { return }
        switch event {
        case .computers(let computers):
            setComputers(computers)

        case .status(.searching):
            setState(.searching)

        case .status(.denied):
            // The search stays up: the system lets a waiting browser carry on
            // once access is granted, and that arrives as `.searching`.
            setComputers([])
            setState(.denied)

        case .status(.failed(let message)):
            // The search has shut itself down. Show why, then try again.
            session = nil
            setComputers([])
            setState(.failed(message))
            scheduleRetry()
        }
    }

    /// Browsing mostly fails for reasons that pass — the system's Bonjour
    /// service restarting, or the app coming back from the background with
    /// its connection to that service gone — so a failure is retried.
    ///
    /// A run that worked for a while before failing is retried quickly. One
    /// that fails as soon as it starts is up against something that is not
    /// going away by itself, and waits longer each time.
    private func scheduleRetry() {
        if let sessionBegan, ContinuousClock.now - sessionBegan > longestRetryDelay {
            retryDelay = firstRetryDelay
        }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, longestRetryDelay)

        retry?.cancel()
        retry = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            // Stopping or starting calls a pending retry off by cancelling
            // it, which can also happen just after the wait has ended.
            guard let self, !Task.isCancelled else { return }
            self.beginSession()
        }
    }

    // Assigning an equal value would still wake every observer, so both
    // properties are only written when they really change.

    private func setComputers(_ newValue: [NearbyComputer]) {
        if computers != newValue {
            computers = newValue
        }
    }

    private func setState(_ newValue: State) {
        if state != newValue {
            state = newValue
        }
    }
}

/// The part of browsing that ``NearbyBrowser`` hands off: something that is
/// started once, reports through `events`, and is finished after `shutdown()`
/// or a failure. ``NearbyEngine`` is the real one; tests script their own.
protocol NearbySearch: AnyObject, Sendable {
    var events: AsyncStream<NearbyEngine.Event> { get }
    func start()
    func shutdown()
}

extension NearbyEngine: NearbySearch {}

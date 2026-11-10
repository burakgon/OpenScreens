import Dispatch
import Foundation
import Network
import dnssd
import os

/// Does the Bonjour work for ``NearbyBrowser``, off the main thread.
///
/// One engine lives for one run of browsing: it is started once, reports
/// through ``events`` and is thrown away after ``shutdown()`` or a failure.
///
/// The engine is an actor that runs on its own serial dispatch queue.
/// Network.framework and DNS-SD are told to call back on that same queue, so
/// a callback is already running "inside" the actor and reaches its state
/// synchronously through `assumeIsolated` — no hop, no reordering, and the
/// compiler still checks that nothing else touches the state.
actor NearbyEngine {

    enum Status: Equatable, Sendable {
        /// Browsing is under way.
        case searching
        /// The user has not allowed access to the local network.
        case denied
        /// Browsing stopped working; the engine has shut itself down.
        case failed(String)
    }

    enum Event: Sendable {
        /// The complete, ordered list of nearby computers.
        case computers([NearbyComputer])
        case status(Status)
    }

    /// Everything the engine has to say, in order. Ends when the engine stops.
    nonisolated let events: AsyncStream<Event>

    /// How long changes are gathered before they are published. Bonjour
    /// answers arrive in bursts — a browse result, then its resolve, then its
    /// device-info, times every computer — and observers should hear about a
    /// burst once, not dozens of times a second.
    static let coalescingInterval: DispatchTimeInterval = .milliseconds(250)

    private static let log = Logger(subsystem: "com.burakgon.openscreens", category: "Nearby")

    private nonisolated let queue: DispatchSerialQueue
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    private var isRunning = false
    private var hasStarted = false
    private var browsers: [BonjourServiceType: NWBrowser] = [:]
    private var connection: DNSServiceConnection?
    /// Running resolves and device-info lookups, by service identifier.
    private var resolves: [String: DNSServiceConnection.Lookup] = [:]
    private var deviceInfoLookups: [String: DNSServiceConnection.Lookup] = [:]

    private var records = NearbyRecords()
    private var local = NearbyLocalIdentity()
    private var publishIsScheduled = false
    private var told = NearbyReports()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init() {
        queue = DispatchSerialQueue(label: "com.burakgon.openscreens.nearby", qos: .utility)
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    // MARK: - Lifecycle

    /// Starts browsing. Returns immediately; the work happens on the engine's
    /// queue.
    nonisolated func start() {
        queue.async { self.assumeIsolated { $0.begin() } }

        // ProcessInfo's host name can take seconds to produce when DNS is
        // slow, so it is fetched on the side and added when it arrives. The
        // names that matter most are already known by then.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let name = ProcessInfo.processInfo.hostName
            guard let self else { return }
            self.queue.async { self.assumeIsolated { $0.addLocalHostName(name) } }
        }
    }

    /// Stops browsing and releases every system resource. Returns
    /// immediately; ``events`` ends once the engine has wound down.
    nonisolated func shutdown() {
        queue.async { self.assumeIsolated { $0.end() } }
    }

    private func begin() {
        guard !hasStarted else { return }
        hasStarted = true
        isRunning = true
        local = NearbyLocalIdentity.current()

        guard let connection = DNSServiceConnection(queue: queue) else {
            fail(.failed(Status.message(
                forDNSServiceError: DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))))
            return
        }
        self.connection = connection
        for service in BonjourServiceType.allCases {
            browse(for: service)
        }
    }

    private func end() {
        guard isRunning else {
            continuation.finish()
            return
        }
        tearDown()
        continuation.finish()
    }

    /// Reports why browsing cannot go on, then winds the engine down.
    private func fail(_ status: Status) {
        guard isRunning else { return }
        tearDown()
        report(status)
        continuation.finish()
    }

    private func tearDown() {
        isRunning = false
        for browser in browsers.values {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browsers.removeAll()
        // Ends every resolve and device-info lookup along with the connection.
        connection?.invalidate()
        connection = nil
        resolves.removeAll()
        deviceInfoLookups.removeAll()
        records = NearbyRecords()
    }

    private func addLocalHostName(_ name: String) {
        guard isRunning else { return }
        let before = local
        local.addHostName(name)
        if local != before {
            setNeedsPublish()
        }
    }

    // MARK: - Browsing

    private func browse(for service: BonjourServiceType) {
        // Device-info is the one type whose TXT record is the point.
        let descriptor: NWBrowser.Descriptor = service == .deviceInfo
            ? .bonjourWithTXTRecord(type: service.rawValue, domain: NearbyComputer.localDomain)
            : .bonjour(type: service.rawValue, domain: NearbyComputer.localDomain)
        let parameters = NWParameters()
        // Computers reachable only over a peer-to-peer link are not ones a
        // lasting screen sharing connection can be made to.
        parameters.includePeerToPeer = false

        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.browser(for: service, changedTo: state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.assumeIsolated { $0.browser(for: service, found: results) }
        }
        browsers[service] = browser
        browser.start(queue: queue)
    }

    private func browser(for service: BonjourServiceType, changedTo state: NWBrowser.State) {
        guard isRunning else { return }
        switch state {
        case .ready:
            if service == .screenSharing {
                report(.searching)
            }

        case .waiting(let error):
            // Waiting means the browser carries on by itself once whatever is
            // in the way clears. Only a refusal is worth telling anyone about;
            // it applies to the whole app, so any browser may be the one to
            // report it.
            if Status.problem(error) == .denied {
                report(.denied)
            }

        case .failed(let error):
            let problem = Status.problem(error)
            if problem == .denied || service == .screenSharing {
                fail(problem)
            } else {
                // Only enrichment is lost. Typically the type is missing from
                // NSBonjourServices; say so where a developer will see it.
                let type = service.rawValue
                let reason = String(describing: error)
                Self.log.error(
                    "Browsing for \(type, privacy: .public) failed: \(reason, privacy: .public)")
                browsers.removeValue(forKey: service)?.cancel()
            }

        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func browser(for service: BonjourServiceType, found results: Set<NWBrowser.Result>) {
        guard isRunning else { return }
        switch service {
        case .screenSharing:
            screenSharingChanged(results)
        case .ssh:
            records.sshNames = Self.names(in: results)
        case .sftp:
            records.sftpNames = Self.names(in: results)
        case .deviceInfo:
            records.advertisedDeviceInfo = Self.deviceInfo(in: results)
        }
        setNeedsPublish()
    }

    private static func names(in results: Set<NWBrowser.Result>) -> Set<String> {
        var names = Set<String>()
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                names.insert(NearbyRecords.nameKey(name))
            }
        }
        return names
    }

    private static func deviceInfo(
        in results: Set<NWBrowser.Result>
    ) -> [String: BonjourDeviceInfo] {
        var found: [String: BonjourDeviceInfo] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let record) = result.metadata else { continue }
            found[NearbyRecords.nameKey(name)] = BonjourDeviceInfo(txt: record.dictionary)
        }
        return found
    }

    /// Brings the records in line with the screen sharing services now on the
    /// network: forgets the ones that left, looks up the ones that arrived.
    private func screenSharingChanged(_ results: Set<NWBrowser.Result>) {
        var present: [String: NearbyRecords.ScreenSharingService] = [:]
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                continue
            }
            let service = NearbyRecords.ScreenSharingService(name: name, type: type, domain: domain)
            present[service.id] = service
        }

        for id in records.screenSharing.keys where present[id] == nil {
            cancelLookups(for: id)
            records.screenSharing[id] = nil
        }
        for (id, service) in present where records.screenSharing[id] == nil {
            records.screenSharing[id] = service
            lookUp(service)
        }
    }

    // MARK: - Lookups

    /// Starts resolving a service to its host name and port, and asks for the
    /// device-info record of the same name — the only way to learn a Mac's
    /// model, since Macs do not advertise device-info as a browsable service.
    private func lookUp(_ service: NearbyRecords.ScreenSharingService) {
        guard let connection else { return }
        let id = service.id
        do {
            resolves[id] = try connection.resolve(
                name: service.name, type: service.type, domain: service.domain
            ) { [weak self] event in
                self?.assumeIsolated { $0.resolve(of: id, reported: event) }
            }

            if let fullName = DNSServiceConnection.fullName(
                service: service.name,
                type: BonjourServiceType.deviceInfo.rawValue,
                domain: service.domain) {
                deviceInfoLookups[id] = try connection.queryTXT(fullName: fullName) {
                    [weak self] event in
                    self?.assumeIsolated { $0.deviceInfoLookup(of: id, reported: event) }
                }
            }
        } catch {
            lookupFailed(error.code)
        }
    }

    private func cancelLookups(for id: String) {
        if let lookup = resolves.removeValue(forKey: id) {
            connection?.cancel(lookup)
        }
        if let lookup = deviceInfoLookups.removeValue(forKey: id) {
            connection?.cancel(lookup)
        }
    }

    private func resolve(of id: String, reported event: DNSServiceConnection.Event) {
        guard isRunning, records.screenSharing[id] != nil else { return }
        switch event {
        case .resolved(let host, let port):
            // One answer is all that is needed, and a resolve left running
            // keeps querying the network.
            if let lookup = resolves.removeValue(forKey: id) {
                connection?.cancel(lookup)
            }
            records.screenSharing[id]?.host = NearbyComputer.normalizedHost(host)
            // Port 0 is how a service says it is not really offered.
            records.screenSharing[id]?.port = port > 0 ? port : nil
            setNeedsPublish()

        case .failed(let code):
            if let lookup = resolves.removeValue(forKey: id) {
                connection?.cancel(lookup)
            }
            lookupFailed(code)

        case .record:
            break
        }
    }

    private func deviceInfoLookup(of id: String, reported event: DNSServiceConnection.Event) {
        guard isRunning, records.screenSharing[id] != nil else { return }
        switch event {
        case .record(let data, let isAdded):
            // A model does not change, so the first answer ends the lookup.
            // For a computer without the record the lookup simply stays open
            // until the computer leaves; the system backs its queries off.
            guard isAdded else { return }
            if let lookup = deviceInfoLookups.removeValue(forKey: id) {
                connection?.cancel(lookup)
            }
            records.screenSharing[id]?.deviceInfo = BonjourDeviceInfo(
                txt: BonjourTXT.entries(in: data))
            setNeedsPublish()

        case .failed(let code):
            if let lookup = deviceInfoLookups.removeValue(forKey: id) {
                connection?.cancel(lookup)
            }
            lookupFailed(code)

        case .resolved:
            break
        }
    }

    /// A lookup failing on its own costs one computer its details. The
    /// daemon going away takes everything with it and ends the engine.
    private func lookupFailed(_ code: DNSServiceErrorType) {
        guard Status.isConnectionLoss(code) else {
            Self.log.debug("A Bonjour lookup failed with DNS-SD error \(code, privacy: .public)")
            return
        }
        // The connection has let go of the daemon by itself. Winding down
        // the rest is left for the next turn, clear of whichever handler
        // brought the news.
        queue.async { [weak self] in
            self?.assumeIsolated { $0.fail(.failed(Status.message(forDNSServiceError: code))) }
        }
    }

    // MARK: - Publishing

    private func report(_ status: Status) {
        guard let consequence = told.note(status) else { return }
        continuation.yield(.status(status))
        if consequence == .listIsDueAgain {
            setNeedsPublish()
        }
    }

    /// Schedules one publication for everything that changes in the next
    /// ``coalescingInterval``.
    private func setNeedsPublish() {
        guard isRunning, !publishIsScheduled else { return }
        publishIsScheduled = true
        queue.asyncAfter(deadline: .now() + Self.coalescingInterval) { [weak self] in
            self?.assumeIsolated { $0.publish() }
        }
    }

    private func publish() {
        publishIsScheduled = false
        guard isRunning else { return }
        let computers = records.computers(excluding: local)
        guard told.note(computers) else { return }
        continuation.yield(.computers(computers))
    }
}

// MARK: - What has been reported

/// What the engine has told its listener so far, so that it says a thing
/// once — and says it again when the listener can no longer be assumed to
/// know it.
struct NearbyReports {
    enum Consequence: Equatable {
        /// What the listener has of the list still stands.
        case listStands
        /// The list has to be published again even if it has not changed.
        case listIsDueAgain
    }

    private var status: NearbyEngine.Status?
    private var computers: [NearbyComputer] = []

    /// Notes a status about to be reported.
    ///
    /// - Returns: `nil` when it is the status the listener already has;
    ///   otherwise what reporting it entails.
    mutating func note(_ status: NearbyEngine.Status) -> Consequence? {
        guard status != self.status else { return nil }
        let wasDenied = self.status == .denied
        self.status = status
        if status == .denied {
            // Told that access is denied, the listener empties its list.
            // What was published before then is no longer what it has.
            computers = []
            return .listStands
        }
        // Browsing can pick up after a denial with exactly the computers it
        // had before. The list is unchanged then, and has to be sent anyway.
        return wasDenied ? .listIsDueAgain : .listStands
    }

    /// Notes the list as it is now.
    ///
    /// - Returns: Whether it differs from what the listener has, and so has
    ///   to be published.
    mutating func note(_ computers: [NearbyComputer]) -> Bool {
        guard computers != self.computers else { return false }
        self.computers = computers
        return true
    }
}

// MARK: - Reading errors

extension NearbyEngine.Status {
    /// What a Network.framework error means for browsing: a refusal by the
    /// user, or a failure with a message that can be shown.
    static func problem(_ error: NWError) -> NearbyEngine.Status {
        switch error {
        case .dns(let code):
            if code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                return .denied
            }
            return .failed(message(forDNSServiceError: code))
        default:
            return .failed("Looking for nearby computers failed: \(error.localizedDescription)")
        }
    }

    /// Whether a DNS-SD error means the connection to the daemon is gone, as
    /// opposed to one lookup having failed.
    static func isConnectionLoss(_ code: DNSServiceErrorType) -> Bool {
        DNSServiceConnection.isConnectionLoss(code)
    }

    static func message(forDNSServiceError code: DNSServiceErrorType) -> String {
        switch Int(code) {
        case kDNSServiceErr_NoAuth:
            // What iOS answers when a service type is not declared.
            "This app is not set up to look for nearby computers. Its Bonjour service types must be listed under NSBonjourServices in Info.plist."
        case kDNSServiceErr_ServiceNotRunning:
            "The system's Bonjour service is not running."
        case kDNSServiceErr_DefunctConnection:
            "The connection to the system's Bonjour service was closed."
        default:
            "Looking for nearby computers failed (DNS-SD error \(code))."
        }
    }
}

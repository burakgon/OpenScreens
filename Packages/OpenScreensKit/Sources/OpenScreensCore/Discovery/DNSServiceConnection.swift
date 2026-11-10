import Dispatch
import Foundation
import dnssd

/// A connection to the system's DNS-SD daemon that carries any number of
/// lookups at once.
///
/// `NWBrowser` finds services but only ever hands out resolved *addresses*.
/// A saved computer needs the host *name* (`Studio.local`) so it keeps working
/// when the address changes, and that is only available from the DNS-SD C
/// API. All lookups share this one connection, so a network with hundreds of
/// screen-sharing Macs costs one socket rather than hundreds.
///
/// Threading: the DNS-SD client library does no locking of its own. Every
/// method must be called on the queue given to ``init(queue:)``, which is
/// also the queue handlers are called on. Because of that, once
/// ``cancel(_:)`` or ``invalidate()`` returns, no further handler runs.
///
/// Losing the daemon: when the daemon goes away — it was restarted, or the
/// system took the socket back from a suspended app — the library closes the
/// connection's socket by itself, and from then on its references name a
/// descriptor that is no longer its own. The number is free for the next
/// file or socket the app opens, and every call that would send the daemon
/// a message — starting a lookup, stopping one — would write that message
/// into it. So a connection that has lost its daemon is let go of at once
/// and as a whole: the shared reference is released, which frees every
/// lookup with it without a word to anyone, and nothing started on it is
/// touched again. Lookups are never released one by one unless the daemon is
/// known to be there.
final class DNSServiceConnection {

    /// What a lookup reports.
    enum Event: Sendable {
        /// A service resolved to a host target (`Studio.local.`) and port.
        case resolved(host: String, port: Int)
        /// A record's data appeared (`isAdded`) or went away.
        case record(Data, isAdded: Bool)
        case failed(DNSServiceErrorType)
    }

    /// A lookup could not be started.
    struct Failure: Error {
        let code: DNSServiceErrorType
    }

    /// One running lookup. Keep it to ``DNSServiceConnection/cancel(_:)`` it.
    final class Lookup {
        fileprivate var ref: DNSServiceRef?
        fileprivate let handler: @Sendable (Event) -> Void
        fileprivate weak var connection: DNSServiceConnection?

        fileprivate init(
            connection: DNSServiceConnection,
            handler: @escaping @Sendable (Event) -> Void
        ) {
            self.connection = connection
            self.handler = handler
        }

        /// Passes on an error the library reported for this lookup.
        fileprivate func failed(_ code: DNSServiceErrorType) {
            if DNSServiceConnection.isConnectionLoss(code) {
                // The library has stopped listening and is about to close
                // the socket. Releasing the shared reference from inside its
                // callback is something it provides for: it ends its round
                // of the lookups there and then.
                connection?.release()
            }
            handler(.failed(code))
        }
    }

    private let queue: DispatchQueue
    private var connection: DNSServiceRef?
    /// A second descriptor for the connection's socket. The library's own
    /// can be closed under this object and its number given to something
    /// else; this one stays what it is, and says whether the daemon is still
    /// at the other end.
    private var watch: Int32 = -1
    /// Owns every running lookup. The C callbacks reach a lookup through an
    /// unretained pointer, which stays valid for exactly as long as the lookup
    /// is in this table.
    private var lookups: [ObjectIdentifier: Lookup] = [:]

    /// Opens the connection. Fails when the daemon cannot be reached.
    init?(queue: DispatchQueue) {
        self.queue = queue
        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError,
              let connection else { return nil }
        let descriptor = DNSServiceRefSockFD(connection)
        guard DNSServiceSetDispatchQueue(connection, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return nil
        }
        self.connection = connection
        if descriptor >= 0 {
            watch = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        }
    }

    deinit {
        // Normally invalidate() has already run on the queue. If it has not,
        // the connection still has to be released there, and the lookups
        // kept alive until then, because a callback may be in flight.
        guard connection != nil || watch >= 0 || !lookups.isEmpty else { return }
        let leftovers = Leftovers(
            connection: connection, lookups: Array(lookups.values), watch: watch)
        queue.async { leftovers.release() }
    }

    /// Whether a DNS-SD error means the connection to the daemon is gone, as
    /// opposed to one lookup having failed.
    static func isConnectionLoss(_ code: DNSServiceErrorType) -> Bool {
        code == DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)
            || code == DNSServiceErrorType(kDNSServiceErr_DefunctConnection)
    }

    /// The descriptor the library talks to the daemon through and this
    /// object's own second descriptor for the same socket; `nil` once the
    /// connection has been let go of. For tests, which stand in for a daemon
    /// that goes away by shutting the socket down.
    var descriptors: (library: Int32, watch: Int32)? {
        connection.map { (DNSServiceRefSockFD($0), watch) }
    }

    /// Resolves a service to its host name and port.
    ///
    /// The handler is called for every answer until the lookup is cancelled.
    /// Cancel it once an answer has arrived: a resolve left running keeps
    /// querying the network.
    func resolve(
        name: String,
        type: String,
        domain: String,
        handler: @escaping @Sendable (Event) -> Void
    ) throws(Failure) -> Lookup {
        try start(handler) { ref, context in
            DNSServiceResolve(
                &ref,
                DNSServiceFlags(kDNSServiceFlagsShareConnection),
                0,  // any interface
                name, type, domain,
                resolveReply, context)
        }
    }

    /// Asks for the TXT record with the given full name, such as
    /// `Studio._device-info._tcp.local.`.
    func queryTXT(
        fullName: String,
        handler: @escaping @Sendable (Event) -> Void
    ) throws(Failure) -> Lookup {
        try start(handler) { ref, context in
            DNSServiceQueryRecord(
                &ref,
                DNSServiceFlags(kDNSServiceFlagsShareConnection),
                0,  // any interface
                fullName,
                UInt16(kDNSServiceType_TXT),
                UInt16(kDNSServiceClass_IN),
                queryRecordReply, context)
        }
    }

    /// Stops a lookup. Safe to call from the lookup's own handler, and more
    /// than once.
    func cancel(_ lookup: Lookup) {
        guard lookups.removeValue(forKey: ObjectIdentifier(lookup)) != nil,
              let ref = lookup.ref else { return }
        lookup.ref = nil
        // Stopping one lookup sends the daemon a message. With no daemon
        // there, the lookup goes the way of the whole connection instead.
        guard daemonIsThere else {
            release()
            return
        }
        DNSServiceRefDeallocate(ref)
    }

    /// Stops every lookup and closes the connection.
    func invalidate() {
        release()
    }

    /// Lets go of the connection and everything started on it.
    ///
    /// Only the shared reference is released. The library frees the lookups
    /// with it and says nothing to the daemon about them, which matters when
    /// the daemon is gone: released one by one, each would have a farewell
    /// written to a socket that may be somebody else's by now.
    private func release() {
        for lookup in lookups.values {
            lookup.ref = nil
        }
        lookups.removeAll()
        if let connection {
            DNSServiceRefDeallocate(connection)
            self.connection = nil
        }
        if watch >= 0 {
            close(watch)
            watch = -1
        }
    }

    /// Whether the daemon is still at the other end of the socket.
    ///
    /// The library closes its descriptor when it reads the end of the
    /// connection, on this object's queue. Seen from that queue, then, a
    /// socket that has not ended is one the library still holds, and can be
    /// written to; one that has ended may already be closed and must not be.
    private var daemonIsThere: Bool {
        guard watch >= 0 else { return true }
        var byte: UInt8 = 0
        while true {
            // A look, not a read: what is waiting is left for the library.
            let count = recv(watch, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count > 0 { return true }
            if count == 0 { return false }
            if errno == EINTR { continue }
            return errno == EAGAIN || errno == EWOULDBLOCK
        }
    }

    /// Joins a service name, type and domain into a full DNS name, escaping
    /// the dots and spaces a service name may contain.
    static func fullName(service: String, type: String, domain: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        guard DNSServiceConstructFullName(&buffer, service, type, domain) == kDNSServiceErr_NoError
        else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func start(
        _ handler: @escaping @Sendable (Event) -> Void,
        _ begin: (inout DNSServiceRef?, UnsafeMutableRawPointer) -> DNSServiceErrorType
    ) throws(Failure) -> Lookup {
        // Starting a lookup sends the daemon a message as well.
        guard let connection, daemonIsThere else {
            release()
            throw Failure(code: DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))
        }
        let lookup = Lookup(connection: self, handler: handler)
        // An operation on a shared connection starts from a copy of the
        // connection's reference and gets its own reference back.
        var ref: DNSServiceRef? = connection
        let error = begin(&ref, Unmanaged.passUnretained(lookup).toOpaque())
        guard error == kDNSServiceErr_NoError, let ref else {
            if Self.isConnectionLoss(error) {
                release()
            }
            throw Failure(code: error)
        }
        lookup.ref = ref
        lookups[ObjectIdentifier(lookup)] = lookup
        return lookup
    }

    /// What outlived its connection object. See `deinit`.
    private struct Leftovers: @unchecked Sendable {
        let connection: DNSServiceRef?
        /// Only kept alive: releasing the connection releases what they hold.
        let lookups: [Lookup]
        let watch: Int32

        func release() {
            if let connection {
                DNSServiceRefDeallocate(connection)
            }
            if watch >= 0 {
                close(watch)
            }
        }
    }
}

// MARK: - C callbacks

/// Recovers the lookup a callback is for. The pointer is unretained: the
/// connection's table keeps the lookup alive while callbacks can arrive, and
/// the reference taken here keeps it alive for the rest of the callback even
/// if the handler cancels it.
private func lookup(from context: UnsafeMutableRawPointer?) -> DNSServiceConnection.Lookup? {
    guard let context else { return nil }
    return Unmanaged<DNSServiceConnection.Lookup>.fromOpaque(context).takeUnretainedValue()
}

private let resolveReply: DNSServiceResolveReply = {
    _, _, _, errorCode, _, hostTarget, port, _, _, context in
    guard let lookup = lookup(from: context) else { return }
    guard errorCode == kDNSServiceErr_NoError else {
        lookup.failed(errorCode)
        return
    }
    guard let hostTarget else { return }
    // The port arrives in network byte order.
    lookup.handler(.resolved(
        host: String(cString: hostTarget),
        port: Int(UInt16(bigEndian: port))))
}

private let queryRecordReply: DNSServiceQueryRecordReply = {
    _, flags, _, errorCode, _, _, _, length, data, _, context in
    guard let lookup = lookup(from: context) else { return }
    guard errorCode == kDNSServiceErr_NoError else {
        lookup.failed(errorCode)
        return
    }
    let record = data.map { Data(bytes: $0, count: Int(length)) } ?? Data()
    let isAdded = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
    lookup.handler(.record(record, isAdded: isAdded))
}

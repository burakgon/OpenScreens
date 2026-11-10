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

        fileprivate init(handler: @escaping @Sendable (Event) -> Void) {
            self.handler = handler
        }
    }

    private let queue: DispatchQueue
    private var connection: DNSServiceRef?
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
        guard DNSServiceSetDispatchQueue(connection, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return nil
        }
        self.connection = connection
    }

    deinit {
        // Normally invalidate() has already run on the queue. If it has not,
        // the references still have to be released there, and the lookups
        // kept alive until then, because a callback may be in flight.
        guard connection != nil || !lookups.isEmpty else { return }
        let leftovers = Leftovers(connection: connection, lookups: Array(lookups.values))
        queue.async { leftovers.release() }
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
        guard lookups.removeValue(forKey: ObjectIdentifier(lookup)) != nil else { return }
        if let ref = lookup.ref {
            DNSServiceRefDeallocate(ref)
            lookup.ref = nil
        }
    }

    /// Stops every lookup and closes the connection.
    func invalidate() {
        for lookup in lookups.values {
            if let ref = lookup.ref {
                DNSServiceRefDeallocate(ref)
                lookup.ref = nil
            }
        }
        lookups.removeAll()
        if let connection {
            DNSServiceRefDeallocate(connection)
            self.connection = nil
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
        guard let connection else {
            throw Failure(code: DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))
        }
        let lookup = Lookup(handler: handler)
        // An operation on a shared connection starts from a copy of the
        // connection's reference and gets its own reference back.
        var ref: DNSServiceRef? = connection
        let error = begin(&ref, Unmanaged.passUnretained(lookup).toOpaque())
        guard error == kDNSServiceErr_NoError, let ref else {
            throw Failure(code: error)
        }
        lookup.ref = ref
        lookups[ObjectIdentifier(lookup)] = lookup
        return lookup
    }

    /// References that outlived their connection object. See `deinit`.
    private struct Leftovers: @unchecked Sendable {
        let connection: DNSServiceRef?
        let lookups: [Lookup]

        func release() {
            for lookup in lookups {
                if let ref = lookup.ref {
                    DNSServiceRefDeallocate(ref)
                }
            }
            if let connection {
                DNSServiceRefDeallocate(connection)
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
        lookup.handler(.failed(errorCode))
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
        lookup.handler(.failed(errorCode))
        return
    }
    let record = data.map { Data(bytes: $0, count: Int(length)) } ?? Data()
    let isAdded = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
    lookup.handler(.record(record, isAdded: isAdded))
}

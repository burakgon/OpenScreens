import Dispatch
import Foundation
import Testing
import dnssd
@testable import OpenScreensCore

// These tests talk to the system's Bonjour daemon over its local socket. A
// stand-in would not do: what is tested is what the DNS-SD library itself
// does with that socket once the daemon has gone away.
//
// Nothing is put on the network. The only lookups that run ask for a record
// of `localhost`, which the daemon answers by itself, and the daemon going
// away is played by shutting down this process's own end of the connection.

private enum BonjourDaemon {
    /// Whether there is a daemon to talk to at all. Where there is none the
    /// suite is skipped.
    static let isReachable: Bool = {
        var ref: DNSServiceRef?
        guard DNSServiceCreateConnection(&ref) == kDNSServiceErr_NoError, let ref else {
            return false
        }
        DNSServiceRefDeallocate(ref)
        return true
    }()

}

/// Which socket a descriptor stands for.
///
/// A descriptor is only a number, and a number that has been closed is
/// handed to the next thing this process opens — tests run side by side, so
/// that can be at any moment. Whether a number is in use therefore says
/// nothing about a particular socket; what the number stands for does.
private struct SocketIdentity: Equatable {
    private let device: dev_t
    private let node: ino_t

    /// `nil` when the number is not in use or is not a socket.
    init?(of descriptor: Int32) {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFSOCK else { return nil }
        device = information.st_dev
        node = information.st_ino
    }
}

/// Lets a connection, which belongs to its queue, be handed to that queue.
private struct OnItsQueue<Value>: @unchecked Sendable {
    var value: Value
}

/// Something a callback on another thread can add to.
private final class Collected<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.withLock { elements.append(element) }
    }

    var all: [Element] {
        lock.withLock { elements }
    }
}

/// A connection with its queue, and the means to take its daemon away.
private final class Session: @unchecked Sendable {
    let queue = DispatchSerialQueue(label: "com.burakgon.openscreens.tests.dnssd")
    private let connection: OnItsQueue<DNSServiceConnection>
    /// The library's descriptor and the connection's own, as they were when
    /// the connection was opened.
    let descriptors: (library: Int32, watch: Int32)
    /// The socket both of them stand for.
    private let socket: SocketIdentity

    init() throws {
        let queue = queue
        let opened = queue.sync { OnItsQueue(value: DNSServiceConnection(queue: queue)) }
        connection = OnItsQueue(value: try #require(opened.value))
        let connection = connection
        descriptors = try #require(queue.sync { connection.value.descriptors })
        socket = try #require(SocketIdentity(of: descriptors.watch))
        #expect(SocketIdentity(of: descriptors.library) == socket)
    }

    /// Whether the connection's own descriptor still holds the socket open.
    var holdsItsOwnDescriptor: Bool {
        SocketIdentity(of: descriptors.watch) == socket
    }

    /// Runs `body` on the connection's queue, where it has to be used.
    func onQueue<Result: Sendable>(_ body: @Sendable (DNSServiceConnection) -> Result) -> Result {
        let connection = connection
        return queue.sync { body(connection.value) }
    }

    /// What the app sees when the daemon is restarted, or when the system
    /// takes the socket back: the connection ends.
    func loseTheDaemon() {
        shutdown(descriptors.watch, SHUT_RDWR)
    }

    /// Whether the library has read everything the daemon has sent so far.
    /// To be asked on the connection's queue, where the reading is done.
    var nothingIsWaiting: Bool {
        var byte: UInt8 = 0
        return recv(descriptors.watch, &byte, 1, MSG_PEEK | MSG_DONTWAIT) < 0
            && (errno == EAGAIN || errno == EWOULDBLOCK)
    }

    /// Waits for the library to notice and close its descriptor.
    func libraryClosedItsDescriptor(within timeout: Duration = .seconds(5)) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while SocketIdentity(of: descriptors.library) == socket {
            guard ContinuousClock.now < deadline else { return false }
            usleep(100)
        }
        return true
    }
}

/// A connection of the app's own that has nothing to do with Bonjour: a TCP
/// connection on loopback, standing in for a remote desktop session.
private final class Bystander {
    private let near: Int32
    private let far: Int32
    private var placed: Int32 = -1

    init?() {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(listener, generic, length) == 0 && getsockname(listener, generic, &length) == 0
            }
        } && listen(listener, 1) == 0
        guard listening else { return nil }

        let near = socket(AF_INET, SOCK_STREAM, 0)
        let connected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(near, $0, length) == 0 }
        }
        guard connected else {
            close(near)
            return nil
        }
        let far = accept(listener, nil, nil)
        guard far >= 0 else {
            close(near)
            return nil
        }
        var on: Int32 = 1
        setsockopt(near, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(far, F_SETFL, O_NONBLOCK)
        self.near = near
        self.far = far
    }

    deinit {
        if placed >= 0 { close(placed) }
        close(near)
        close(far)
    }

    /// Gives the connection a descriptor number that has just become free,
    /// as the system does for the next file or socket the app opens.
    ///
    /// - Returns: `false` when something else in this process got the number
    ///   first. Nothing is ever taken from anyone: the number is used only if
    ///   it is free.
    func takeOver(_ number: Int32) -> Bool {
        let descriptor = fcntl(near, F_DUPFD, number)
        guard descriptor == number else {
            if descriptor >= 0 { close(descriptor) }
            return false
        }
        placed = descriptor
        return true
    }

    /// Everything that has been written into the connection so far.
    func received() -> [UInt8] {
        var all: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Loopback delivers at once, but not before `send` has returned.
        for _ in 0..<20 {
            let count = recv(far, &buffer, buffer.count, 0)
            if count > 0 {
                all.append(contentsOf: buffer[..<count])
            } else {
                usleep(1000)
            }
        }
        return all
    }
}

@Suite(.serialized, .enabled(if: BonjourDaemon.isReachable))
struct DNSServiceConnectionTests {

    private func eventually(
        within timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private let notRunning = DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)

    // MARK: While the daemon is there

    @Test func aLookupCanBeStoppedAndLettingGoClosesBothDescriptors() async throws {
        let session = try Session()
        let events = Collected<DNSServiceConnection.Event>()

        // `localhost` has no TXT record, and the daemon says so by itself.
        let started = session.onQueue { connection in
            OnItsQueue(value: try? connection.queryTXT(fullName: "localhost.") { events.append($0) })
        }
        let lookup = OnItsQueue(value: try #require(started.value))
        _ = await eventually(within: .seconds(2)) { !events.all.isEmpty }
        // One lookup failing is not the connection failing.
        for event in events.all {
            if case .failed(let code) = event {
                #expect(!DNSServiceConnection.isConnectionLoss(code))
            }
        }
        #expect(session.onQueue { $0.descriptors != nil })

        // Stopping is safe more than once, and another lookup still starts.
        let again = session.onQueue { connection in
            connection.cancel(lookup.value)
            connection.cancel(lookup.value)
            return (try? connection.queryTXT(fullName: "localhost.") { _ in }) != nil
        }
        #expect(again)

        #expect(session.holdsItsOwnDescriptor)
        session.onQueue { $0.invalidate() }
        #expect(session.onQueue { $0.descriptors == nil })
        // Its own descriptor is closed with it, and the library closes the
        // other a moment later.
        #expect(!session.holdsItsOwnDescriptor)
        #expect(session.libraryClosedItsDescriptor())
    }

    @Test func aConnectionReleasedWithoutBeingInvalidatedClosesItsDescriptor() throws {
        var session: Session? = try Session()
        let descriptors = try #require(session?.descriptors)
        let queue = try #require(session?.queue)
        let socket = try #require(SocketIdentity(of: descriptors.watch))
        _ = session?.onQueue { connection in
            (try? connection.queryTXT(fullName: "localhost.") { _ in }) != nil
        }

        // Released from this thread, not from the connection's queue, which
        // is where the letting go then has to happen.
        session = nil
        queue.sync {}

        #expect(SocketIdentity(of: descriptors.watch) != socket)
    }

    // MARK: Once the daemon has gone

    /// The daemon goes away while nothing is being looked up, so there is
    /// nobody for the library to tell. It closes its socket all the same,
    /// and the number is given to something else.
    @Test func aLookupStartedAfterTheDaemonWentAwayIsRefusedAndWritesNowhere() async throws {
        let session = try Session()
        let bystander = try #require(Bystander())

        session.loseTheDaemon()
        let observing = session.libraryClosedItsDescriptor()
            && bystander.takeOver(session.descriptors.library)

        // A computer turns up on the network and is looked up.
        let refusal = session.onQueue { connection -> DNSServiceErrorType? in
            do {
                let lookup = try connection.resolve(
                    name: "OpenScreens Test", type: "_rfb._tcp", domain: "local.") { _ in }
                connection.cancel(lookup)
                return nil
            } catch let failure as DNSServiceConnection.Failure {
                return failure.code
            } catch {
                return DNSServiceErrorType(kDNSServiceErr_Unknown)
            }
        }

        #expect(refusal == notRunning)
        // Not a byte of the request reached the other connection.
        if observing {
            #expect(bystander.received().isEmpty)
        }
        // The connection has let go of everything, and stays that way.
        #expect(session.onQueue { $0.descriptors == nil })
        let second = session.onQueue { connection -> DNSServiceErrorType? in
            do {
                _ = try connection.queryTXT(fullName: "localhost.") { _ in }
                return nil
            } catch let failure as DNSServiceConnection.Failure {
                return failure.code
            } catch {
                return DNSServiceErrorType(kDNSServiceErr_Unknown)
            }
        }
        #expect(second == notRunning)
        session.onQueue { $0.invalidate() }
    }

    /// The daemon goes away while lookups are running. The library tells
    /// the first of them; what the owner then does — stop its lookups, close
    /// the connection — must not be written into a socket that is no longer
    /// the library's.
    @Test func lettingGoAfterTheDaemonWentAwayWritesNowhere() async throws {
        let session = try Session()
        let bystander = try #require(Bystander())
        let told = Collected<Int>()

        let started = session.onQueue { connection in
            OnItsQueue(value: (0..<3).compactMap { index in
                try? connection.queryTXT(fullName: "localhost.") { event in
                    if case .failed(let code) = event, DNSServiceConnection.isConnectionLoss(code) {
                        told.append(index)
                    }
                }
            })
        }
        #expect(started.value.count == 3)

        session.loseTheDaemon()
        #expect(await eventually { !told.all.isEmpty })
        let observing = session.libraryClosedItsDescriptor()
            && bystander.takeOver(session.descriptors.library)

        // By the time the owner hears of it the connection is already let
        // go of, as a whole; stopping the lookups one by one changes nothing.
        session.onQueue { connection in
            for lookup in started.value {
                connection.cancel(lookup)
            }
            connection.invalidate()
        }

        if observing {
            #expect(bystander.received().isEmpty)
        }
        // One lookup was told. The others went with the connection.
        #expect(told.all.count == 1)
        #expect(session.onQueue { $0.descriptors == nil })
    }

    /// The same, with the owner stopping a lookup before it has heard
    /// anything: the library has not got round to telling it yet.
    @Test func stoppingALookupFindsOutThatTheDaemonHasGone() async throws {
        let session = try Session()
        let bystander = try #require(Bystander())
        let answered = Collected<DNSServiceErrorType>()
        let told = Collected<DNSServiceErrorType>()

        let started = session.onQueue { connection in
            OnItsQueue(value: (0..<2).compactMap { _ in
                try? connection.queryTXT(fullName: "localhost.") { event in
                    guard case .failed(let code) = event else { return }
                    if DNSServiceConnection.isConnectionLoss(code) {
                        told.append(code)
                    } else {
                        answered.append(code)
                    }
                }
            })
        }
        #expect(started.value.count == 2)
        // Let the daemon's answers be read first, so that nothing is waiting
        // on the socket.
        _ = await eventually(within: .seconds(2)) { answered.all.count == 2 }

        // Lost and found out in one turn of the queue, before the library's
        // own handler has had a chance to run.
        let found = session.onQueue { connection -> (nothingWasWaiting: Bool, stillOpen: Bool) in
            let nothingWasWaiting = session.nothingIsWaiting
            session.loseTheDaemon()
            connection.cancel(started.value[0])
            return (nothingWasWaiting, connection.descriptors != nil)
        }
        let observing = session.libraryClosedItsDescriptor()
            && bystander.takeOver(session.descriptors.library)
        session.onQueue { connection in
            connection.cancel(started.value[1])
            connection.invalidate()
        }
        // Whatever the daemon was in the middle of, nothing goes astray.
        if observing {
            #expect(bystander.received().isEmpty)
        }
        // An answer that was still waiting to be read is another matter:
        // until the library has read it and come to the end, the socket is
        // the library's own, and stopping a lookup is rightly a message into
        // it. The loss is there to be found out only with nothing waiting —
        // which is how it is unless the daemon was very slow to answer.
        if found.nothingWasWaiting {
            #expect(!found.stillOpen)
            // Nobody is told afterwards: the lookups went with the connection.
            #expect(told.all.isEmpty)
        }
    }

    @Test func onlyLosingTheDaemonCountsAsLosingTheConnection() {
        #expect(DNSServiceConnection.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)))
        #expect(DNSServiceConnection.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_DefunctConnection)))
        #expect(!DNSServiceConnection.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)))
        #expect(!DNSServiceConnection.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
        #expect(!DNSServiceConnection.isConnectionLoss(DNSServiceErrorType(kDNSServiceErr_NoError)))
    }
}

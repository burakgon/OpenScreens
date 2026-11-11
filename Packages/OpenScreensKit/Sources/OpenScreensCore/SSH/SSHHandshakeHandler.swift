import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices
import Synchronization

/// The part of a connection attempt that must be reachable from outside the
/// event loop.
///
/// It holds the channel, so that cancelling the calling task can close it,
/// and the reason the attempt failed, which is more telling than the error
/// NIO reports for a channel that was closed underneath it.
final class SSHConnectionAttempt: Sendable {
    private struct State {
        var channel: (any Channel)?
        var isCancelled = false
        var failure: SSHError?
        var transientError: String?
    }

    private let state = Mutex(State())

    /// Takes charge of the channel as soon as it exists, before it connects.
    func adopt(_ channel: any Channel) throws {
        try state.withLock { state in
            guard !state.isCancelled else { throw CancellationError() }
            state.channel = channel
        }
    }

    /// The calling task was cancelled: abandon the attempt wherever it is.
    func cancel() {
        let channel = state.withLock { state in
            state.isCancelled = true
            return state.channel
        }
        channel?.close(promise: nil)
    }

    /// Closes the channel of an attempt that did not work out.
    func abandon() {
        state.withLock { $0.channel }?.close(promise: nil)
    }

    /// Records why the attempt failed. The first reason is the real one;
    /// whatever follows is fallout from closing the channel. For the same
    /// reason a bare "closed" is never recorded: it says what happened to
    /// the channel, not why.
    func fail(_ error: SSHError) {
        guard error != .closed else { return }
        state.withLock { $0.failure = $0.failure ?? error }
    }

    /// Records the most recent reason Network.framework gave for not being
    /// able to connect yet.
    func noteTransientError(_ description: String) {
        state.withLock { $0.transientError = description }
    }

    /// Chooses the error to report for an attempt that ended with `error`.
    func outcome(for error: any Error) -> any Error {
        let snapshot = state.withLock { $0 }
        if snapshot.isCancelled {
            return CancellationError()
        }
        if let failure = snapshot.failure {
            return failure
        }
        let translated = SSHError.translatingConnectFailure(error)
        // Giving up while Network.framework was still reporting a problem is
        // better described by the problem than by "timed out" or "closed".
        if let translated = translated as? SSHError, translated == .timeout || translated == .closed,
           let transientError = snapshot.transientError {
            return SSHError.connectionFailed(transientError)
        }
        return translated
    }
}

/// Takes an SSH connection from the moment its socket connects to the end of
/// user authentication, and afterwards notes why the connection ended.
///
/// It sits behind `NIOSSHHandler` in the pipeline and also serves as that
/// handler's two delegates: the one that judges the server's host key and the
/// one that supplies the user's credential. Everything here runs on the
/// channel's event loop.
final class SSHHandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    struct Configuration: Sendable {
        var host: String
        var port: Int
        var username: String
        var credential: SSHCredential
        var knownHosts: KnownHostsStore
        var hostKeyPolicy: SSHHostKeyPolicy
        /// Time allowed for the handshake, not counting time the host key
        /// policy spends deciding.
        var timeout: TimeAmount
    }

    private enum Phase {
        case connecting
        case handshaking
        case established
        case failed
    }

    private let configuration: Configuration
    private let attempt: SSHConnectionAttempt
    private let log: SSHConnectionLog
    private let authenticated: EventLoopPromise<Void>

    private var phase = Phase.connecting
    private var context: ChannelHandlerContext?
    private var hasOfferedCredential = false
    private var hostKeyDecision: Task<Void, Never>?
    /// The host key the policy accepted while the connection was being made.
    private var acceptedHostKey: NIOSSHPublicKey?

    private var timer: Scheduled<Void>?
    private var timerStartedAt: NIODeadline?
    private var remainingTime: TimeAmount

    init(
        configuration: Configuration,
        attempt: SSHConnectionAttempt,
        log: SSHConnectionLog,
        eventLoop: any EventLoop
    ) {
        self.configuration = configuration
        self.attempt = attempt
        self.log = log
        self.authenticated = eventLoop.makePromise(of: Void.self)
        self.remainingTime = configuration.timeout
    }

    /// Succeeds when the user is signed in; fails with the reason otherwise.
    var authentication: EventLoopFuture<Void> {
        authenticated.futureResult
    }

    // MARK: Channel events

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // The pipeline is being taken apart, so the channel is closing. If
        // nothing has settled the attempt by now, this does: the promise must
        // not be left unanswered whichever way the channel went down.
        fail(SSHError.closed)
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        if phase == .connecting {
            phase = .handshaking
            startTimer()
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is UserAuthSuccessEvent:
            guard phase == .handshaking else { break }
            phase = .established
            stopTimer()
            authenticated.succeed(())
        case let event as NIOTSNetworkEvents.WaitingForConnectivity:
            connectionIsWaiting(because: event.transientError)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if phase == .established {
            // Nothing recovers an SSH transport after an error. Channels on
            // this connection learn of its end from swift-nio-ssh; the log
            // lets them say what caused it.
            log.record(SSHError.describe(error))
            context.close(promise: nil)
        } else {
            fail(SSHError.translatingConnectFailure(error))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Only a connection that was up can be closed by the server. One that
        // never connected fails through the connect itself, with the reason.
        if phase == .handshaking {
            fail(SSHError.connectionFailed(
                "The server closed the connection before sign-in finished."))
        }
        context.fireChannelInactive()
    }

    /// Network.framework could not connect and is waiting for conditions to
    /// change. That is worth waiting out when the network is still coming up,
    /// for example an on-demand VPN, but not when the server itself answered
    /// with a refusal.
    private func connectionIsWaiting(because error: NWError) {
        switch error {
        case .posix(.ECONNREFUSED):
            fail(SSHError.connectionFailed(
                "The server refused the connection on port \(configuration.port). "
                    + "Check that SSH (Remote Login) is turned on."))
        case .posix(.ETIMEDOUT):
            // Not a reason, just the timeout arriving by another route.
            break
        default:
            attempt.noteTransientError(SSHError.describe(error))
        }
    }

    /// Ends an attempt that has not reached authentication. Does nothing once
    /// the connection is established or has already failed.
    private func fail(_ error: any Error) {
        guard phase == .connecting || phase == .handshaking else { return }
        phase = .failed
        stopTimer()
        hostKeyDecision?.cancel()
        hostKeyDecision = nil
        if let error = error as? SSHError {
            attempt.fail(error)
        }
        authenticated.fail(error)
        context?.close(promise: nil)
    }

    // MARK: Handshake timer

    private func startTimer() {
        guard let context, timer == nil, phase == .handshaking else { return }
        timerStartedAt = .now()
        timer = context.eventLoop.assumeIsolated().scheduleTask(in: remainingTime) {
            self.timer = nil
            self.fail(SSHError.timeout)
        }
    }

    /// Stops the clock, keeping what is left of the allowance.
    private func stopTimer() {
        guard let timer, let timerStartedAt else { return }
        timer.cancel()
        self.timer = nil
        remainingTime = max(.zero, remainingTime - (NIODeadline.now() - timerStartedAt))
    }
}

// MARK: - Host key

extension SSHHandshakeHandler: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // swift-nio-ssh keeps the key's contents to itself; its text form is
        // the public way to the type and the bytes the fingerprint is made of.
        guard let key = SSHHostKey(openSSHPublicKey: String(openSSHPublicKey: hostKey)) else {
            validationCompletePromise.fail(
                SSHError.connectionFailed("The server's host key could not be read."))
            return
        }

        switch phase {
        case .handshaking:
            break
        case .established:
            // The server is replacing the session's encryption keys, which
            // it does after so much data or time (`RekeyLimit` in OpenSSH),
            // and proves its identity again as part of that. The answer is
            // already known: the key accepted for this connection, and no
            // other. A person was asked once; a different key now is not a
            // new question for them but a connection that changed hands.
            // Nothing is looked up and nobody is asked, so the answer is
            // given on the spot, and no clock runs: the connection's
            // channels are waiting for this exchange to be over.
            if hostKey == acceptedHostKey {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyRejected(fingerprint: key.fingerprint))
            }
            return
        case .connecting, .failed:
            validationCompletePromise.fail(SSHError.closed)
            return
        }

        // The policy may put the question to a person. Their thinking time is
        // not the server being slow, so the handshake clock stops meanwhile.
        stopTimer()
        let configuration = self.configuration
        // The policy's answer: `nil` to go on, or why the attempt ends here.
        let decision = validationCompletePromise.futureResult.eventLoop.makePromise(of: SSHError?.self)
        hostKeyDecision = Task {
            let challenge = SSHHostKeyChallenge(
                host: configuration.host,
                port: configuration.port,
                key: key,
                verdict: configuration.knownHosts.check(
                    host: configuration.host, port: configuration.port, key: key),
                knownHosts: configuration.knownHosts)
            if await configuration.hostKeyPolicy(challenge) {
                decision.succeed(nil)
            } else if case .storeUnreadable(let reason) = challenge.verdict {
                // Nothing was wrong with the key that anyone could tell. The
                // user needs to hear about the record instead.
                decision.succeed(.knownHostsUnreadable(reason))
            } else {
                decision.succeed(.hostKeyRejected(fingerprint: key.fingerprint))
            }
        }
        decision.futureResult.assumeIsolated().whenSuccess { refusal in
            self.hostKeyDecision = nil
            guard self.phase == .handshaking else {
                // The attempt ended while the question was open.
                validationCompletePromise.fail(SSHError.closed)
                return
            }
            self.startTimer()
            if let refusal {
                validationCompletePromise.fail(refusal)
            } else {
                self.acceptedHostKey = hostKey
                validationCompletePromise.succeed(())
            }
        }
    }
}

// MARK: - User authentication

extension SSHHandshakeHandler: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let method: NIOSSHAvailableUserAuthenticationMethods
        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch configuration.credential {
        case .password(let password):
            method = .password
            offer = .password(.init(password: password))
        case .key(let key):
            method = .publicKey
            offer = .privateKey(.init(privateKey: key.nioSSHPrivateKey))
        }

        guard hasOfferedCredential else {
            // The first call does not reflect the server yet: swift-nio-ssh
            // passes every method it knows and learns the real list from the
            // server's answer.
            hasOfferedCredential = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: configuration.username, serviceName: "", offer: offer))
            return
        }

        // Called again, so the server turned the credential down, and
        // `availableMethods` is now its list of methods that may still
        // succeed. There is nothing else to offer. The promise has to fail
        // rather than complete with `nil`: swift-nio-ssh takes `nil` to mean
        // "nothing yet" and would leave the connection waiting forever.
        let failure: SSHError.AuthenticationFailure = availableMethods.contains(method)
            ? .credentialsRejected
            : .noMoreMethods(serverAccepts: Self.names(of: availableMethods))
        nextChallengePromise.fail(SSHError.authenticationFailed(failure))
    }

    private static func names(of methods: NIOSSHAvailableUserAuthenticationMethods) -> [String] {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names
    }
}

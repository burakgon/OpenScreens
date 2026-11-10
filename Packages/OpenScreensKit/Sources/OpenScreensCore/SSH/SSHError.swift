import Foundation
import Network
import NIOCore
import NIOSSH

/// Why an SSH connection could not be made, or stopped working.
public enum SSHError: Error, Equatable, Sendable {
    /// The network connection or the SSH handshake failed. The text names the
    /// underlying cause.
    case connectionFailed(String)

    /// The server did not answer in time.
    case timeout

    /// The host key policy declined the key the server presented.
    case hostKeyRejected(fingerprint: String)

    /// The server did not let this user in.
    case authenticationFailed(AuthenticationFailure)

    /// The server refused to open a channel. For a tunnel this usually means
    /// nothing is listening on the target port, or that the server does not
    /// allow forwarding.
    case channelOpenRefused(String)

    /// The server does not offer the named subsystem (for example `sftp`).
    case subsystemUnavailable(String)

    /// The connection is closed.
    case closed

    /// The two ways signing in can fail.
    public enum AuthenticationFailure: Equatable, Sendable {
        /// The server accepts this kind of credential but rejected this one:
        /// a wrong password, or a key that is not authorised for the account.
        case credentialsRejected

        /// There is nothing left to try. The server does not accept the kind
        /// of credential that was offered; `serverAccepts` lists the methods
        /// it would have continued with (`publickey`, `password`, …), limited
        /// to the ones swift-nio-ssh understands.
        case noMoreMethods(serverAccepts: [String])
    }
}

extension SSHError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            "Could not connect over SSH: \(reason)"
        case .timeout:
            "The SSH server did not respond in time."
        case .hostKeyRejected(let fingerprint):
            "The SSH server's identity was not accepted (\(fingerprint))."
        case .authenticationFailed(.credentialsRejected):
            "The SSH server rejected the password or key."
        case .authenticationFailed(.noMoreMethods(let serverAccepts)):
            if serverAccepts.isEmpty {
                "The SSH server does not accept this sign-in method."
            } else {
                "The SSH server does not accept this sign-in method. "
                    + "It accepts: \(serverAccepts.joined(separator: ", "))."
            }
        case .channelOpenRefused(let reason):
            "The SSH server could not open the connection: \(reason)"
        case .subsystemUnavailable(let name):
            "The SSH server does not provide \(name)."
        case .closed:
            "The SSH connection is closed."
        }
    }
}

// MARK: - Translating lower-level errors

extension SSHError {
    /// Describes an arbitrary error for an error message or a log line.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SSHError:
            return error.errorDescription ?? String(describing: error)
        case let error as NWError:
            return describe(error)
        default:
            // The structural form is kept next to the localized text because
            // the two carry different information, and for an error nobody
            // anticipated either may be the one that explains it.
            let structural = String(describing: error)
            let localized = error.localizedDescription
            return structural == localized ? structural : "\(structural) (\(localized))"
        }
    }

    /// Says what a Network.framework error means for a connection, in words,
    /// and keeps the code beside them. The code is what tells an unexplained
    /// drop apart afterwards: `ETIMEDOUT` is TCP keepalive giving up on a
    /// silent peer, `ECONNRESET` is the peer hanging up.
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            "\(String(cString: strerror(code.rawValue))) (errno \(code.rawValue))"
        case .dns:
            "The server's name could not be found (DNS error \(error.debugDescription))"
        default:
            error.debugDescription
        }
    }

    /// Maps whatever NIO, Network.framework or swift-nio-ssh reported while
    /// connecting and signing in onto this module's vocabulary.
    ///
    /// Cancellation is passed through untouched so callers can tell a
    /// cancelled task from a failed connection.
    static func translatingConnectFailure(_ error: any Error) -> any Error {
        switch error {
        case is SSHError, is CancellationError:
            return error
        case ChannelError.connectTimeout:
            return SSHError.timeout
        case let error as NWError:
            if case .posix(.ETIMEDOUT) = error { return SSHError.timeout }
            return SSHError.connectionFailed(describe(error))
        case let error as NIOSSHError where error.type == .keyExchangeNegotiationFailure:
            // swift-nio-ssh speaks a deliberately small, modern set: Curve25519
            // and NIST ECDH, Ed25519 and ECDSA host keys, AES-GCM.
            return SSHError.connectionFailed(
                "The server and OpenScreens have no SSH algorithms in common. "
                    + "The server may only offer RSA host keys or legacy ciphers.")
        default:
            return isClosure(error) ? SSHError.closed : SSHError.connectionFailed(describe(error))
        }
    }

    /// Maps a failure to open a channel on an established connection.
    static func translatingChannelFailure(_ error: any Error) -> any Error {
        switch error {
        case is SSHError, is CancellationError:
            return error
        case let error as NIOSSHError where error.type == .channelSetupRejected:
            return SSHError.channelOpenRefused(channelRejectionReason(error))
        default:
            return isClosure(error) ? SSHError.closed : SSHError.connectionFailed(describe(error))
        }
    }

    /// Whether `error` only says that the channel or connection is gone.
    static func isClosure(_ error: any Error) -> Bool {
        switch error {
        case ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed, ChannelError.eof,
             ChannelError.outputClosed, ChannelError.inputClosed:
            true
        case ChannelPipelineError.notFound:
            // The pipeline is emptied when its channel closes, so a missing
            // handler means the connection went away first.
            true
        case let error as NIOSSHError:
            error.type == .tcpShutdown || error.type == .creatingChannelAfterClosure
        default:
            false
        }
    }

    /// Explains a rejected channel open.
    ///
    /// The server gives a reason code (RFC 4254 §5.1) and a text. The code is
    /// the dependable half: for a forwarding it is not allowed to make,
    /// OpenSSH's text is just "open failed". swift-nio-ssh keeps both private
    /// and only shows them in its description, as `…: Reason: <code> <text>`.
    private static func channelRejectionReason(_ error: NIOSSHError) -> String {
        let description = String(describing: error)
        guard let marker = description.range(of: "Reason: ") else { return description }
        let reason = description[marker.upperBound...]
        let parts = reason.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first.flatMap({ UInt32($0) }) else { return String(reason) }
        let text = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        let meaning: String
        switch code {
        case 1:
            meaning = "Not permitted by the server's configuration"
        case 2:
            // The server tried and failed; its text is the reason it got,
            // such as "Connection refused".
            return text.isEmpty ? "The server could not reach the destination" : text
        case 3:
            meaning = "Not supported by the server"
        case 4:
            meaning = "The server is out of resources"
        default:
            meaning = "Reason code \(code)"
        }
        return text.isEmpty ? meaning : "\(meaning) (\(text))"
    }
}

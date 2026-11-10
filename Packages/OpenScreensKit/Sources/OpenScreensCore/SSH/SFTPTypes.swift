import Foundation

/// The result code an SFTP server answers a request with
/// (draft-ietf-secsh-filexfer-02 §7).
///
/// A struct rather than an enum because servers are free to send codes this
/// version of the protocol does not define, and those must survive intact.
public struct SFTPStatusCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ok = SFTPStatusCode(rawValue: 0)
    /// A read reached the end of a file, or a listing the end of a directory.
    public static let endOfFile = SFTPStatusCode(rawValue: 1)
    public static let noSuchFile = SFTPStatusCode(rawValue: 2)
    public static let permissionDenied = SFTPStatusCode(rawValue: 3)
    /// The catch-all: the operation failed for a reason version 3 has no
    /// code for, such as a directory that is not empty or a name that is
    /// already taken.
    public static let failure = SFTPStatusCode(rawValue: 4)
    public static let badMessage = SFTPStatusCode(rawValue: 5)
    public static let noConnection = SFTPStatusCode(rawValue: 6)
    public static let connectionLost = SFTPStatusCode(rawValue: 7)
    public static let operationUnsupported = SFTPStatusCode(rawValue: 8)
}

/// Why a file transfer operation failed.
public enum SFTPError: Error, Equatable, Sendable {
    /// The server refused the request. `message` is the server's own
    /// explanation and may be empty.
    case status(code: SFTPStatusCode, message: String)

    /// The server speaks a version of SFTP other than 3.
    case unsupportedVersion(UInt32)

    /// The server sent something the protocol does not allow.
    case invalidResponse(String)

    /// The session was closed, by either side.
    case connectionClosed

    /// The session's channel or the SSH connection under it failed.
    case connectionFailed(String)

    /// A file on this device could not be read or written.
    case localFile(path: String, reason: String)

    /// The code of a request the server refused; `nil` for other failures.
    public var statusCode: SFTPStatusCode? {
        if case .status(let code, _) = self { code } else { nil }
    }
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(.noSuchFile, _):
            "The file or folder does not exist on the server."
        case .status(.permissionDenied, _):
            "The server did not permit the operation."
        case .status(.operationUnsupported, _):
            "The server does not support this operation."
        case .status(let code, let message):
            message.isEmpty
                ? "The server could not complete the operation (code \(code.rawValue))."
                : "The server could not complete the operation: \(message)"
        case .unsupportedVersion(let version):
            "The server uses SFTP version \(version), which is not supported."
        case .invalidResponse(let detail):
            "The server sent an invalid response: \(detail)"
        case .connectionClosed:
            "The file transfer connection is closed."
        case .connectionFailed(let reason):
            "The file transfer connection failed: \(reason)"
        case .localFile(let path, let reason):
            "“\(path)”: \(reason)"
        }
    }
}

/// What an SFTP server reports about a file, and what a client may ask it to
/// set. Every field is optional on the wire; a server sends what it knows.
public struct SFTPAttributes: Hashable, Sendable {
    /// Size in bytes.
    public var size: UInt64?
    public var userID: UInt32?
    public var groupID: UInt32?
    /// The POSIX mode word: the kind of file in the top bits and the
    /// permission bits below, as in `stat(2)`.
    public var mode: UInt32?
    public var accessDate: Date?
    public var modificationDate: Date?

    public init(
        size: UInt64? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        mode: UInt32? = nil,
        accessDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.size = size
        self.userID = userID
        self.groupID = groupID
        self.mode = mode
        self.accessDate = accessDate
        self.modificationDate = modificationDate
    }

    // The file type field of a POSIX mode word. Spelled out because the
    // values are fixed by the SFTP specification, whatever the local
    // platform's headers say.
    private static let fileTypeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let regularFileType: UInt32 = 0o100000
    private static let symbolicLinkType: UInt32 = 0o120000

    public var isDirectory: Bool {
        mode.map { $0 & Self.fileTypeMask == Self.directoryType } ?? false
    }

    public var isRegularFile: Bool {
        mode.map { $0 & Self.fileTypeMask == Self.regularFileType } ?? false
    }

    public var isSymbolicLink: Bool {
        mode.map { $0 & Self.fileTypeMask == Self.symbolicLinkType } ?? false
    }

    /// The permission bits alone (`rwxrwxrwx` plus set-user-ID, set-group-ID
    /// and sticky), without the kind of file.
    public var permissions: UInt16? {
        mode.map { UInt16($0 & 0o7777) }
    }
}

/// One entry of a remote directory.
public struct SFTPItem: Identifiable, Hashable, Sendable {
    public let name: String
    /// The directory the entry was listed from, joined with its name.
    public let path: String
    /// Whether the entry itself is a directory. A symbolic link is never one,
    /// whatever it points to; ask ``SFTPClient/attributes(of:followSymlinks:)``
    /// about its target.
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// Size in bytes; zero when the server did not say.
    public let size: Int64
    public let modified: Date?
    /// The POSIX permission bits, such as `0o644`.
    public let permissions: UInt16?

    public var id: String { path }

    init(name: String, directory: String, attributes: SFTPAttributes) {
        self.name = name
        self.path = SFTPPath.join(directory, name)
        self.isDirectory = attributes.isDirectory
        self.isSymlink = attributes.isSymbolicLink
        self.size = Int64(clamping: attributes.size ?? 0)
        self.modified = attributes.modificationDate
        self.permissions = attributes.permissions
    }
}

/// Reports how far a transfer has come: the bytes moved so far, and the total
/// when it is known. Called from the task doing the transfer.
public typealias SFTPProgressHandler = @Sendable (_ completed: Int64, _ total: Int64?) -> Void

/// Remote paths are plain strings with `/` separators, whatever the device
/// this code runs on uses.
enum SFTPPath {
    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

}

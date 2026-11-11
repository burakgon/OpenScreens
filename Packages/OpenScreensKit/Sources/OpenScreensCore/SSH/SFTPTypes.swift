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

    /// A folder, or a folder with everything in it, holds more entries than
    /// are taken from a server at once. `limit` is how many are.
    case tooManyEntries(limit: Int)

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
        case .tooManyEntries(let limit):
            "The folder holds more than \(limit.formatted()) items, which is more than can be handled at once."
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

    /// What kind of thing the attributes describe, or `nil` when they do not
    /// say: the kind is part of the mode, and a server may leave the mode
    /// out.
    var kind: SFTPFileKind? {
        guard let mode else { return nil }
        switch mode & Self.fileTypeMask {
        case Self.directoryType: return .directory
        case Self.regularFileType: return .file
        case Self.symbolicLinkType: return .symbolicLink
        default: return .other
        }
    }

    /// The permission bits alone (`rwxrwxrwx` plus set-user-ID, set-group-ID
    /// and sticky), without the kind of file.
    public var permissions: UInt16? {
        mode.map { UInt16($0 & 0o7777) }
    }

    /// The permissions a copy of the file is given: who may read, write and
    /// run it. Running as the owner or the group, and the sticky bit, mean
    /// something on the computer they were set on and are not handed to
    /// another one.
    var copiedPermissions: UInt16? {
        permissions.map { $0 & 0o777 }
    }

    /// The permissions a copy of the folder is given: ``copiedPermissions``,
    /// except that whoever makes the copy can always list, change and enter
    /// it, because it has to be filled.
    var copiedFolderPermissions: UInt16? {
        copiedPermissions.map { $0 | 0o700 }
    }
}

/// What kind of thing an entry of a directory is.
enum SFTPFileKind: Sendable {
    case directory
    case file
    case symbolicLink
    /// A device, a socket, a pipe: nothing with contents to copy.
    case other
}

/// One entry of a remote directory that can be used here: its name is one,
/// and what it is has been settled, by asking the server where the listing
/// did not say.
struct SFTPDirectoryEntry: Sendable {
    var name: String
    var attributes: SFTPAttributes
    var kind: SFTPFileKind
}

/// What a server's listing of one directory came to.
struct SFTPDirectoryContents: Sendable {
    var entries: [SFTPDirectoryEntry]
    /// How many entries were left out because of their names; see
    /// ``SFTPListing/unusableNameCount``.
    var unusableNameCount: Int
}

/// The contents of a remote directory, and how much of it had to be left
/// out.
public struct SFTPListing: Sendable {
    /// The entries, sorted by name the way Finder sorts.
    public let items: [SFTPItem]

    /// How many entries are missing from ``items`` because their names
    /// cannot be used: the bytes of the name are not UTF-8, so there is no
    /// text to show or to ask the server for, or the name is not the name of
    /// one entry, as with a slash in it. `.` and `..` are not counted; they
    /// are not contents.
    public let unusableNameCount: Int
}

/// What a folder download left out.
public struct SFTPDownloadSummary: Equatable, Sendable {
    /// How many files and folders were not copied because their names cannot
    /// be used; see ``SFTPListing/unusableNameCount``. A folder counts once,
    /// whatever it holds. Symbolic links and special files, which are never
    /// copied, are not counted.
    public var unusableNameCount = 0
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
        self.init(
            SFTPDirectoryEntry(name: name, attributes: attributes, kind: attributes.kind ?? .other),
            directory: directory)
    }

    /// - Parameter entry: An entry of `directory`. What it is goes by its
    ///   `kind`, which may have been found out some other way than from its
    ///   attributes.
    init(_ entry: SFTPDirectoryEntry, directory: String) {
        self.name = entry.name
        self.path = SFTPPath.join(directory, entry.name)
        self.isDirectory = entry.kind == .directory
        self.isSymlink = entry.kind == .symbolicLink
        self.size = Int64(clamping: entry.attributes.size ?? 0)
        self.modified = entry.attributes.modificationDate
        self.permissions = entry.attributes.permissions
    }
}

/// Reports how far a transfer has come: the bytes moved so far, and the total
/// when it is known. Called from the task doing the transfer.
public typealias SFTPProgressHandler = @Sendable (_ completed: Int64, _ total: Int64?) -> Void

/// Remote paths are plain strings with `/` separators, whatever the device
/// this code runs on uses.
public enum SFTPPath {
    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// A name for a file that is not meant to stay: one being written until
    /// it is complete (`partial`), or one moved out of the way of its
    /// replacement (`previous`). It is hidden, says whose it is, and is
    /// random enough that nothing else has it. Its length does not depend
    /// on the name of the file it stands in for, which may already be as
    /// long as a name can be.
    static func temporaryName(kind: String) -> String {
        let number = UInt64.random(in: .min ... .max)
        let digits = String(number, radix: 16)
        return ".openscreens-" + String(repeating: "0", count: 16 - digits.count) + digits + "." + kind
    }

    /// The path of an entry called `name` in the same folder as the entry at
    /// the remote `path`.
    static func sibling(of path: String, named name: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return name }
        return String(path[...slash]) + name
    }

    /// Whether `name` can stand for one entry of a folder, on the server or
    /// in the local folder a remote entry is copied to.
    ///
    /// It has to be something other than `.` and `..`, and may hold neither a
    /// slash nor a NUL. The name is looked at byte by byte, which is how a
    /// file system reads it. Looking at characters is not enough: a slash
    /// followed by a combining mark or an invisible joiner is one character
    /// that is not "/", and the slash in it still separates folders. Taken at
    /// face value, a name like that lets a server put a download outside the
    /// folder it was aimed at.
    public static func isUsableName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard !bytes.isEmpty, !bytes.elementsEqual(".".utf8), !bytes.elementsEqual("..".utf8) else {
            return false
        }
        return !bytes.contains { $0 == UInt8(ascii: "/") || $0 == 0 }
    }

    /// Where the entry called `name` goes in the local folder `directory`.
    ///
    /// Two things have to hold, and each is checked without relying on the
    /// other. The name is usable (``isUsableName(_:)``). And the place the
    /// name leads to, once every `.` and `..` is worked out, is the entry of
    /// that name directly inside `directory`: not above it, not deeper, and
    /// not under a name the system made out of the one given.
    ///
    /// - Returns: `nil` when either does not hold.
    public static func localURL(for name: String, in directory: URL) -> URL? {
        LocalFolder(directory).url(for: name)
    }

    /// Where the entry at `path` inside a tree goes when the tree is copied
    /// to the local folder `root`. The path is names joined by slashes, and
    /// each of them is put through ``localURL(for:in:)`` on the way down. The
    /// empty path is the tree itself.
    static func localURL(forPath path: String, in root: URL) -> URL? {
        var url = root
        guard !path.isEmpty else { return url }
        for name in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let next = localURL(for: String(name), in: url) else { return nil }
            url = next
        }
        return url
    }

    /// A local folder that entries named by a server are about to go into.
    ///
    /// Working out where the folder itself is makes up half the work of
    /// checking a name against it, and is the same for every name in a
    /// listing. It is done once, here.
    struct LocalFolder {
        let url: URL
        private let components: [String]

        init(_ url: URL) {
            self.url = url
            components = Self.resolvedComponents(of: url)
        }

        /// Where the entry called `name` goes; see ``SFTPPath/localURL(for:in:)``.
        func url(for name: String) -> URL? {
            guard SFTPPath.isUsableName(name) else { return nil }
            let entry = url.appending(path: name)
            return holds(entry, as: name) ? entry : nil
        }

        /// Whether `entry` is the entry called `name` directly inside this
        /// folder.
        func holds(_ entry: URL, as name: String) -> Bool {
            let resolved = Self.resolvedComponents(of: entry)
            return resolved.count == components.count + 1
                && resolved.last == name
                && resolved.starts(with: components)
        }

        /// The components of a local path with `.` and `..` worked out.
        ///
        /// This is done on the text alone. Foundation's own standardizing
        /// asks the file system on the way, and gives a folder that exists
        /// and a file in it that does not exist yet two different spellings.
        private static func resolvedComponents(of url: URL) -> [String] {
            var resolved: [String] = []
            for component in url.pathComponents {
                switch component {
                case ".":
                    continue
                case "..":
                    // The first component is the root, with nothing above it.
                    if resolved.count > 1 {
                        resolved.removeLast()
                    }
                default:
                    resolved.append(component)
                }
            }
            return resolved
        }
    }
}

extension Int64 {
    /// The sum of this and `other`, or the value nearest to it when the true
    /// sum does not fit.
    ///
    /// Sizes are added this way. A size comes from the other end of a
    /// connection, or from a file that may be mostly holes, and two of them
    /// can each be in range without their sum being.
    func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflowed) = addingReportingOverflow(other)
        guard overflowed else { return sum }
        return other < 0 ? .min : .max
    }
}

import Foundation
import OpenScreensCore

/// A section of the library, as chosen in the sidebar.
public enum LibraryFilter: Hashable, Sendable {
    case all
    case favorites
    case recents
    case group(UUID)
    case tag(String)

    func title(in library: LibraryStore) -> String {
        switch self {
        case .all: "All Computers"
        case .favorites: "Favorites"
        case .recents: "Recents"
        case .group(let id): library.group(id)?.name ?? "Group"
        case .tag(let tag): "#\(tag)"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .recents: "clock"
        case .group: "folder"
        case .tag: "number"
        }
    }

    /// Computers in this section, before search and sorting.
    func computers(in library: LibraryStore) -> [Computer] {
        switch self {
        case .all: library.computers
        case .favorites: library.favorites
        case .recents: library.recents
        case .group(let id): library.computers(in: id)
        case .tag(let tag): library.computers.filter { $0.tags.contains(tag) }
        }
    }

    /// Recents have a natural order of their own; everything else follows
    /// the user's chosen sort.
    var hasIntrinsicOrder: Bool {
        self == .recents
    }
}

extension Computer {
    /// Whether the computer matches a search string.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle)
            || host.localizedCaseInsensitiveContains(needle)
            || (username?.localizedCaseInsensitiveContains(needle) ?? false)
            || notes.localizedCaseInsensitiveContains(needle)
            || tags.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

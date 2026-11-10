import AppIntents
import OpenScreensCore
import OpenScreensUI
#if os(macOS)
import AppKit
#endif

/// Hands a link to the app's interface.
///
/// On iPhone and iPad the library is always there to pick it up. On the Mac
/// the library window may be closed, so the request goes through the URL
/// handler, which opens a window when it needs one.
@MainActor
private func deliver(_ link: AppLink) {
    #if os(macOS)
    switch link {
    case .computer(let id):
        NSWorkspace.shared.open(AppLink.url(forComputer: id))
    case .target:
        AppModel.shared.pendingLink = link
        NSApp.activate()
    }
    #else
    AppModel.shared.pendingLink = link
    #endif
}

/// A saved computer, as Shortcuts, Siri and Spotlight see it.
struct ComputerEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Computer")
    static let defaultQuery = ComputerQuery()

    let id: UUID
    let name: String
    let address: String
    let symbolName: String

    init(_ computer: Computer) {
        id = computer.id
        name = computer.displayName
        address = computer.displayAddress
        symbolName = computer.kind.symbolName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(address)",
            image: .init(systemName: symbolName))
    }
}

struct ComputerQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ComputerEntity] {
        let library = AppModel.shared.library
        return identifiers.compactMap { library.computer($0).map(ComputerEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ComputerEntity] {
        AppModel.shared.library.computers
            .filter {
                $0.displayName.localizedCaseInsensitiveContains(string)
                    || $0.host.localizedCaseInsensitiveContains(string)
            }
            .map(ComputerEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ComputerEntity] {
        let library = AppModel.shared.library
        // Favourites first, then the most recently used, then the rest.
        var seen = Set<UUID>()
        return (library.favorites + library.recents + library.computers)
            .filter { seen.insert($0.id).inserted }
            .map(ComputerEntity.init)
    }
}

/// Opens a session to a saved computer.
struct ConnectToComputerIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Computer"
    static let description = IntentDescription(
        "Opens a remote session to one of your saved computers.",
        categoryName: "Connections")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Computer")
    var computer: ComputerEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$computer)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        deliver(.computer(computer.id))
        return .result()
    }
}

/// Opens a session to an address that is not in the library.
struct QuickConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Connect"
    static let description = IntentDescription(
        "Connects to a host name, IP address or vnc:// link.",
        categoryName: "Connections")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Address", description: "A host name, IP address or vnc:// link.")
    var address: String

    static var parameterSummary: some ParameterSummary {
        Summary("Quick connect to \(\.$address)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let target = ConnectionTarget(text: address) else {
            throw QuickConnectError.invalidAddress
        }
        deliver(.target(target))
        return .result()
    }
}

enum QuickConnectError: Error, CustomLocalizedStringResourceConvertible {
    case invalidAddress

    var localizedStringResource: LocalizedStringResource {
        "That doesn't look like an address OpenScreens can connect to."
    }
}

struct OpenScreensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToComputerIntent(),
            phrases: [
                "Connect to \(\.$computer) with \(.applicationName)",
                "Open \(\.$computer) in \(.applicationName)",
                "Control \(\.$computer) with \(.applicationName)",
            ],
            shortTitle: "Connect",
            systemImageName: "macbook.and.iphone")
    }
}

import Foundation
import OpenScreensCore

/// A computer that was found — on the local network or in the tailnet —
/// rather than saved by the user.
struct DiscoveredComputer: Identifiable, Hashable {
    var id: String
    var name: String
    /// Where to connect. `nil` while a nearby computer is still being
    /// resolved to an address.
    var host: String?
    var port: Int
    var kind: ComputerKind
    /// The hardware or system, when the computer says.
    var detail: String?
    /// The symbol for that hardware, when it is more telling than the kind's.
    var symbolName: String
    /// Whether the computer can be reached right now. Nearby computers are
    /// by definition; tailnet devices may be offline.
    var isOnline: Bool
    var supportsSSH: Bool
    var origin: ComputerOrigin

    init(_ nearby: NearbyComputer) {
        id = "nearby:\(nearby.id)"
        name = nearby.name
        host = nearby.host
        port = nearby.port
        kind = nearby.kind
        detail = nearby.model.flatMap(MacModel.family)
        symbolName = nearby.model.flatMap(MacModel.symbolName) ?? nearby.kind.symbolName
        isOnline = true
        supportsSSH = nearby.supportsSSH
        origin = .bonjour(serviceName: nearby.name)
    }

    init(_ device: TailscaleDevice) {
        id = "tailscale:\(device.id)"
        name = device.name
        host = device.preferredHost.isEmpty ? nil : device.preferredHost
        port = Computer.defaultPort
        kind = device.kind
        detail = nil
        symbolName = device.kind.symbolName
        isOnline = device.isOnline
        supportsSSH = false
        origin = .tailscale(nodeID: device.id)
    }

    var target: ConnectionTarget? {
        host.map { ConnectionTarget(host: $0, port: port, name: name, kind: kind, origin: origin) }
    }

    /// What to show under the name.
    var subtitle: String {
        guard let host else { return "Finding address…" }
        return port == Computer.defaultPort ? host : "\(host):\(port)"
    }

    /// A library entry to start from when the user decides to keep it.
    func template(defaults: ConnectionSettings) -> Computer {
        Computer(
            name: name,
            host: host ?? "",
            port: port,
            kind: kind,
            settings: kind.isApple ? defaults : ConnectionSettings.defaults(for: kind),
            origin: origin)
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle)
            || (host?.localizedCaseInsensitiveContains(needle) ?? false)
    }
}

/// What can be said about a Mac from its model identifier.
enum MacModel {
    /// The product family, for identifiers that name one. Macs since 2022
    /// are all `MacN,N`, which says only that it is a Mac.
    static func family(_ identifier: String) -> String? {
        let families: [(prefix: String, name: String)] = [
            ("MacBookPro", "MacBook Pro"),
            ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"),
            ("iMacPro", "iMac Pro"),
            ("iMac", "iMac"),
            ("Macmini", "Mac mini"),
            ("MacPro", "Mac Pro"),
            ("VirtualMac", "Virtual Mac"),
        ]
        return families.first { identifier.hasPrefix($0.prefix) }?.name
    }

    /// The symbol that looks like the Mac, for the same identifiers.
    static func symbolName(_ identifier: String) -> String? {
        switch family(identifier) {
        case "MacBook Pro", "MacBook Air", "MacBook": "laptopcomputer"
        case "iMac", "iMac Pro": "desktopcomputer"
        case "Mac mini": "macmini"
        case "Mac Pro": "macpro.gen3"
        default: nil
        }
    }
}

extension AppModel {
    /// Computers on the local network, by name.
    var nearbyComputers: [DiscoveredComputer] {
        (sampleDiscovery?.nearby ?? nearby.computers)
            .map(DiscoveredComputer.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Tailnet devices that could be connected to: not this device, not
    /// phones and the like, and not offline ones if the user hides those.
    var tailnetComputers: [DiscoveredComputer] {
        (sampleDiscovery?.tailscale ?? tailscale.devices)
            .filter { $0.canBeControlled && !$0.isSelf }
            .filter { $0.isOnline || !settings.hidesOfflineTailscaleDevices }
            .map(DiscoveredComputer.init)
            .sorted {
                if $0.isOnline != $1.isOnline { return $0.isOnline }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Whether there is anything to say about Tailscale: it is switched on
    /// and either set up or showing sample devices.
    var showsTailscale: Bool {
        guard settings.tailscaleEnabled else { return false }
        return sampleDiscovery != nil || tailscale.state != .notConfigured
    }

    /// The library's own entry for a discovered computer, if it has one.
    func savedComputer(for discovered: DiscoveredComputer) -> Computer? {
        if let byOrigin = library.computers.first(where: { $0.origin == discovered.origin }) {
            return byOrigin
        }
        guard let host = discovered.host else { return nil }
        return library.existingComputer(host: host, port: discovered.port)
    }
}

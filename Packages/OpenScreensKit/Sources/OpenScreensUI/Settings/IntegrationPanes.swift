import OpenScreensCore
import SwiftUI

struct TailscaleSettingsPane: View {
    var body: some View {
        ContentUnavailableView("Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
    }
}

struct SSHKeysSettingsPane: View {
    var body: some View {
        ContentUnavailableView("SSH Keys", systemImage: "key")
    }
}

/// What the interface needs to know about a stored SSH key.
struct SSHKeySummary: Identifiable, Hashable {
    let id: UUID
    let name: String
}

extension AppModel {
    var sshKeyList: [SSHKeySummary] { [] }
}

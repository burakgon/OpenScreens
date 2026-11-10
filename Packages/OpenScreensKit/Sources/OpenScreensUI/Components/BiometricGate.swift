import LocalAuthentication
import SwiftUI

/// Device-owner authentication for the optional app lock.
enum BiometricGate {
    /// What the device unlocks with, for labels: "Face ID", "Touch ID", …
    static var methodName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            #if os(macOS)
            return "Your Password"
            #else
            return "Your Passcode"
            #endif
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    /// Whether the device has any way to authenticate its owner.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Asks the device owner to authenticate, falling back to the passcode or
    /// account password when biometrics are unavailable or fail.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            // No passcode is set: there is nothing to check against, and
            // locking the user out of their own data would help nobody.
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Covers its content until the device owner has authenticated.
struct AppLockModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked = false
    @State private var isAuthenticating = false

    private var isLocked: Bool {
        model.settings.requiresAuthentication && !isUnlocked
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isLocked {
                    lockScreen
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: isLocked)
            .task { await unlockIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    // Lock again once the app has really gone away, not for
                    // every momentary loss of focus.
                    if model.settings.requiresAuthentication, model.sessions.sessions.isEmpty {
                        isUnlocked = false
                    }
                case .active:
                    Task { await unlockIfNeeded() }
                default:
                    break
                }
            }
    }

    private var lockScreen: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("OpenScreens Is Locked")
                    .font(.title2.weight(.semibold))
                Button("Unlock with \(BiometricGate.methodName)") {
                    Task { await unlockIfNeeded() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
            .padding(32)
        }
    }

    private func unlockIfNeeded() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await BiometricGate.authenticate(reason: "Unlock your computers") {
            isUnlocked = true
        }
    }
}

extension View {
    /// Requires device-owner authentication before showing this view, when
    /// the user has turned the app lock on.
    public func appLock() -> some View {
        modifier(AppLockModifier())
    }
}

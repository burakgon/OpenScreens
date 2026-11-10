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

/// Whether the app's content is behind its lock. One instance is shared by
/// every window, so unlocking one unlocks them all.
@Observable
public final class AppLock {
    public private(set) var isUnlocked: Bool
    public private(set) var isAuthenticating = false

    /// - Parameter startsUnlocked: Pass `true` when the lock is not in use
    ///   at launch, so that turning it on later does not lock the app under
    ///   the person who just turned it on.
    public init(startsUnlocked: Bool) {
        isUnlocked = startsUnlocked
    }

    public func lock() {
        isUnlocked = false
    }

    /// Asks the device owner to authenticate, unless that is already under
    /// way or done.
    public func unlock() async {
        guard !isUnlocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await BiometricGate.authenticate(reason: "Unlock your computers") {
            isUnlocked = true
        }
    }
}

extension AppModel {
    /// Whether the user has to authenticate before seeing anything.
    public var isLocked: Bool {
        settings.requiresAuthentication && !lock.isUnlocked
    }
}

/// Covers its content until the device owner has authenticated.
struct AppLockModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.isLocked {
                    lockScreen
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.isLocked)
            .task { await unlockIfNeeded() }
            #if os(iOS)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    // Lock again once the app has really gone away, not for
                    // every momentary loss of focus.
                    if model.settings.requiresAuthentication, model.sessions.sessions.isEmpty {
                        model.lock.lock()
                    }
                case .active:
                    Task { await unlockIfNeeded() }
                default:
                    break
                }
            }
            #endif
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
                .disabled(model.lock.isAuthenticating)
            }
            .padding(32)
        }
    }

    private func unlockIfNeeded() async {
        guard model.isLocked else { return }
        await model.lock.unlock()
    }
}

extension View {
    /// Requires device-owner authentication before showing this view, when
    /// the user has turned the app lock on.
    public func appLock() -> some View {
        modifier(AppLockModifier())
    }
}

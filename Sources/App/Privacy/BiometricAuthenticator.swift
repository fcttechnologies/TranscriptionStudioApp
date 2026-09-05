import Foundation
import LocalAuthentication
import OSLog

/// The biometric unlock seam for the per-session privacy lock. A protocol so `AppModel`'s gate
/// is testable with a fake — the pure gate decision (`PrivacyGate`) decides *whether* to prompt;
/// this performs the prompt.
protocol BiometricAuthenticating: Sendable {
    /// Prompt for the device owner's biometric (or passcode fallback). Returns whether the
    /// unlock succeeded; never throws — a cancel, failure, or unavailable biometry is just `false`.
    func authenticate(reason: String) async -> Bool
}

/// LocalAuthentication-backed unlock. Uses `.deviceOwnerAuthentication`: Face ID / Touch ID is
/// the primary path, with the device passcode as the fallback — so a legitimately-owned device
/// can always open its own private session (biometrics-only would risk a permanent lockout if
/// Face ID is unavailable or fails), while a thief without the biometric or passcode cannot.
struct BiometricAuthenticator: BiometricAuthenticating {
    init() {}

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        let policy: LAPolicy = .deviceOwnerAuthentication
        var evaluationError: NSError?
        // Safety: LocalAuthentication's NSError** is written during this call and read right after.
        guard unsafe context.canEvaluatePolicy(policy, error: &evaluationError) else {
            // No biometry AND no passcode set — the device has no lock at all, so there's
            // nothing to gate against. Fail closed: an un-unlockable session stays shut.
            Logger.persistence.error("Biometric unlock unavailable: \(evaluationError?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            // User cancel, biometry lockout, etc. — treated as "not unlocked".
            return false
        }
    }
}

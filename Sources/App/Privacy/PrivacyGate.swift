import Foundation

/// The pure decision layer for the per-session privacy lock — no LocalAuthentication, no
/// SwiftData, so it's directly unit-tested. `BiometricAuthenticator` performs the actual
/// prompt; `AppModel` and `TranscriptSessionStore` apply these verdicts.
enum PrivacyGate {
    /// Whether opening a session must prompt for a biometric unlock right now. A non-private
    /// session never prompts; a private one prompts unless it was already unlocked in this
    /// context.
    static func requiresAuthentication(isPrivate: Bool, alreadyUnlocked: Bool = false) -> Bool {
        isPrivate && !alreadyUnlocked
    }

    /// Whether a session may surface to the assistant layer — Spotlight indexing, relevant-entity
    /// donation, and Siri / App-Intent library queries. A private session is withheld from all of
    /// it, so a biometric-locked transcript can't leak through search or be read aloud unlocked.
    static func isEligibleForAssistant(isPrivate: Bool) -> Bool {
        !isPrivate
    }
}

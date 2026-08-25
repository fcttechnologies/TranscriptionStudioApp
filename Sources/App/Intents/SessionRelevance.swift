import AppIntents
import Foundation
import OSLog

/// Donates the active/last-opened transcript to the system as a *relevant* entity, so Siri and
/// Apple Intelligence can resolve "summarize this" / "ask about this" to it without a
/// disambiguation turn. This is **contextual relevance** — a hint about which content matters
/// *right now* — and is deliberately distinct from Spotlight indexing (`TranscriptSpotlightIndex`,
/// which makes every session *searchable*): the relevant donation is a single, replaceable
/// "currently-active" pointer, not the whole library.
///
/// SDK-27's `RelevantEntities` scopes donations to an `AppEntityContext`. For a transcription app
/// whose sessions are audio recordings, the applicable built-in context is `.audio(.nowPlaying)`:
/// the open transcript is the now-playing candidate (it can be played back from the detail view),
/// so the system surfaces it at the right audio/now-playing moments. The complementary
/// "summarize *this exact on-screen thing*" lever is the on-screen `EntityIdentifier` annotation
/// on the detail view, which is a separate surface.
@MainActor
enum SessionRelevance {
    /// The single audio context TS donates the active session under.
    private static let context: AppEntityContext = .audio(.nowPlaying)

    /// Donate the just-opened session as the relevant now-playing transcript, replacing any
    /// previous donation. Best-effort: a donation failure never affects opening the session, and
    /// donation is skipped under tests (the system store isn't available there). Resolving the
    /// entity is a cheap main-actor store read; if the id doesn't resolve (e.g. mid-delete), the
    /// donation is simply skipped rather than clearing a still-valid one.
    static func donateActiveSession(id: UUID) {
        guard !AppModelContainer.isRunningTests else { return }
        guard let entity = TranscriptSessionStore.entities(withIDs: [id]).first else { return }
        Task {
            do {
                try await RelevantEntities.shared.updateEntities([entity], for: context)
            } catch {
                Logger.persistence.error("Relevant-entity donation failed: \(error, privacy: .public)")
            }
        }
    }
}

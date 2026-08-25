import AppIntents
import Foundation

/// The `NSUserActivity` the detail view advertises while a transcript is on screen — the
/// activity-level half of on-screen entity annotation. The view-level half is the
/// `appEntityIdentifier(_:)` annotation applied alongside it (`OnscreenTranscript` in
/// `SessionDetailView`); this activity carries the same `EntityIdentifier` on
/// `NSUserActivity.appEntityIdentifier`, so "summarize this" / "ask about this" said while a
/// transcript is open resolves to the visible session with zero parameters through both cues.
///
/// The activity is a contextual cue for Siri / Apple Intelligence only: Handoff is explicitly
/// opted out (continuation isn't implemented — advertising it would show a Handoff icon that
/// opens the app without restoring), and searchability stays with the named Spotlight index
/// (`TranscriptSpotlightIndex`), never a second index via activity eligibility.
enum SessionActivity {
    /// The advertised activity type for a transcript open in the detail view.
    static let viewingType = "com.fcttechnologies.TranscriptionStudio.viewingTranscript"

    /// Configure the advertised activity for the on-screen session. Pure field mapping —
    /// callers pass the session's identity rather than the model so it's directly testable.
    static func configureViewing(_ activity: NSUserActivity, sessionID: UUID, title: String) {
        activity.title = title
        activity.targetContentIdentifier = sessionID.uuidString
        activity.appEntityIdentifier = EntityIdentifier(for: TranscriptSessionEntity.self,
                                                        identifier: sessionID.uuidString)
        // A context cue, not a continuation point: Handoff defaults to eligible, so opt out.
        activity.isEligibleForHandoff = false
    }
}

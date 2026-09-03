import FCTMetrics

/// Dated deltas, coalesced by day on-device before they ride.
///
/// One per feature, because what a counter answers is how many installs reach a feature at all —
/// which no crash trail can say, and which is the difference between a capability that earns its
/// maintenance and one nobody has ever found. A `String`-backed enum for the reason every name on
/// this wire is one: `Diag` takes no free text, so nothing a person recorded, said or typed can
/// reach a field report through it.
nonisolated enum TranscriptionCounter: String, DiagCounter, CaseIterable {
    /// A live recording saved as a session — the app's own microphone path.
    case sessionsRecorded = "sessions_recorded"
    /// An audio or video file transcribed.
    case filesTranscribed = "files_transcribed"
    /// A link transcribed, which is the only path that spends the network before the model.
    case linksTranscribed = "links_transcribed"
    /// The extraction substrate landing on a session: decisions, action items and events.
    case highlightsExtracted = "highlights_extracted"
    /// A question asked of the library assistant.
    case assistantQuestions = "assistant_questions"
    /// A transcript rendered out of the app, in any format.
    case transcriptsExported = "transcripts_exported"
    /// A speaker slot bound to a real person.
    case speakersNamed = "speakers_named"
    /// A dictation whose text reached the app.
    case dictationsCompleted = "dictations_completed"
}

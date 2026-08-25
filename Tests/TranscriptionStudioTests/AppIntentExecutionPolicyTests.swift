import AppIntents
import Testing
@testable import TranscriptionStudio

/// Pins the intents that mutate app-owned state (live recording, transcription jobs, the
/// SwiftData store, the archived audio) to the main app process — never a future extension.
struct AppIntentExecutionPolicyTests {
    @Test @available(iOS 27.0, *)
    func stateWritingIntentsRunOnlyInTheMainApp() {
        let targets: [IntentExecutionTargets] = [
            StartRecordingIntent.allowedExecutionTargets,
            StopRecordingIntent.allowedExecutionTargets,
            TranscribeFileIntent.allowedExecutionTargets,
            DeleteTranscriptIntent.allowedExecutionTargets,
            OpenSettingsIntent.allowedExecutionTargets,
            OpenInspectorIntent.allowedExecutionTargets,
            TranscribeLinkIntent.allowedExecutionTargets,
            RenameTranscriptIntent.allowedExecutionTargets,
            PlayTranscriptIntent.allowedExecutionTargets,
            PausePlaybackIntent.allowedExecutionTargets,
            SpeakTranscriptIntent.allowedExecutionTargets,
            StopSpeakingIntent.allowedExecutionTargets,
        ]

        #expect(targets.allSatisfy { $0 == .main })
    }
}

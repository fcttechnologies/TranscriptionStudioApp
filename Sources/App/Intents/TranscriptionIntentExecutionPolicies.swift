import AppIntents

// These intents mutate app-owned state — the live recording, a transcription job, the
// SwiftData store, or the archived audio — and depend on the main app's live `AppModel` /
// `RecordingController`. Pin them to the main app process so a future App Intents/widget
// extension sharing this package never tries to run them without that live state.

@available(iOS 27.0, *)
extension StartRecordingIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension StopRecordingIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension TranscribeFileIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension DeleteTranscriptIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension OpenSettingsIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension OpenInspectorIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension TranscribeLinkIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension RenameTranscriptIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension PlayTranscriptIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension PausePlaybackIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension SpeakTranscriptIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension StopSpeakingIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

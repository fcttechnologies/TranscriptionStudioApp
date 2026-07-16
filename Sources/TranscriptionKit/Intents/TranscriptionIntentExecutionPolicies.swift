import AppIntents

// These intents mutate app-owned state — the live recording, a transcription job, the
// SwiftData store, or the archived audio — and depend on the main app's live `AppModel` /
// `RecordingController`. Pin them to the main app process so a future App Intents/widget
// extension sharing this package never tries to run them without that live state.

@available(iOS 27.0, *)
extension StartRecordingIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension StopRecordingIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension TranscribeFileIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension DeleteTranscriptIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension OpenSettingsIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension OpenInspectorIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension TranscribeLinkIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension RenameTranscriptIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension PlayTranscriptIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(iOS 27.0, *)
extension PausePlaybackIntent {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

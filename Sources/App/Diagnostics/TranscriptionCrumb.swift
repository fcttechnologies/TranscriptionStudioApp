import FCTMetrics

/// The names this app's own work travels under on the crash trail.
///
/// A `String`-backed enum, which is what makes every name a compile-time constant: `Diag` takes no
/// free text anywhere, so nothing a person said or typed can reach a field report through it.
///
/// Every case here is an intent, spelled `intent.…` so an intent's run stays separable from a
/// screen's appearance. An intent is the code most likely to crash with nobody watching — no UI,
/// often no running app, fired from Siri, a Live Activity button, a control or the Lock Screen
/// against a store opened through the App Group rather than the app's own — so without a name of
/// its own a crash there arrives with a trail whose last entry is whatever the person last did by
/// hand.
nonisolated enum TranscriptionCrumb: String, DiagBreadcrumb, CaseIterable {
    /// Dictation: the verb, and the control that opens the surface for it.
    case dictateIntent = "intent.dictate"
    case openDictationIntent = "intent.open_dictation"
    /// Recording, from anywhere — including the Live Activity, which runs in its own process.
    case startRecordingIntent = "intent.start_recording"
    case stopRecordingIntent = "intent.stop_recording"
    case getRecordingStatusIntent = "intent.get_recording_status"
    case stopRecordingActivityIntent = "intent.activity_stop_recording"
    case toggleRecordingPauseActivityIntent = "intent.activity_toggle_recording_pause"
    case togglePlaybackActivityIntent = "intent.activity_toggle_playback"
    /// The two long-running transcription doors.
    case transcribeFileIntent = "intent.transcribe_file"
    case transcribeLinkIntent = "intent.transcribe_link"
    /// What the library is asked, and what the model is asked of one transcript.
    case searchTranscriptsIntent = "intent.search_transcripts"
    case getLatestTranscriptIntent = "intent.get_latest_transcript"
    case askTranscriptIntent = "intent.ask_transcript"
    case summarizeTranscriptIntent = "intent.summarize_transcript"
    /// Acting on a transcript.
    case renameTranscriptIntent = "intent.rename_transcript"
    case deleteTranscriptIntent = "intent.delete_transcript"
    case assignSpeakersIntent = "intent.assign_speakers"
    case exportTranscriptIntent = "intent.export_transcript"
    /// Playback and speech.
    case playTranscriptIntent = "intent.play_transcript"
    case speakTranscriptIntent = "intent.speak_transcript"
    case stopSpeakingIntent = "intent.stop_speaking"
    case pausePlaybackIntent = "intent.pause_playback"
    /// Out into the rest of the system.
    case addEventToCalendarIntent = "intent.add_event_to_calendar"
    case addActionItemReminderIntent = "intent.add_action_item_reminder"
    /// Navigation, including the one every other intent hands back to open the app.
    case openAppIntent = "intent.open_app"
    case openTranscriptIntent = "intent.open_transcript"
    case openLibraryIntent = "intent.open_library"
    case openInspectorIntent = "intent.open_inspector"
    case openSettingsIntent = "intent.open_settings"
}

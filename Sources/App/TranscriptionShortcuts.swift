import AppIntents

/// Zero-setup Siri phrases. `\(.applicationName)` binds each phrase to the app.
///
/// This lives in the **app target**, not in `TranscriptionKit` beside the intents it names:
/// `autoShortcuts` metadata does not merge from a dependency package, so a provider declared in
/// the Kit builds, links, and registers nothing — silently, at every layer. The built bundle's
/// `autoShortcutProviderMangledName` is the only honest reading, and `scripts/gate.sh` takes it
/// from both platforms' artifacts.
///
/// Apple caps a provider at 10 promoted shortcuts (`AppShortcutContract.systemLimit`) and drops
/// the rest with no error. `DeleteTranscriptIntent`, `ExportTranscriptIntent`, `OpenLibraryIntent`
/// and `GetRecordingStatusIntent` therefore stay reachable through the Shortcuts app and Spotlight
/// without a canned phrase, which frees room for `OpenInspectorIntent` and `TranscribeLinkIntent`.
/// The promoted set is exactly 10 on both platforms; the gate pins the count from the artifacts.
///
/// `TranscribeLinkIntent` is promoted on iOS too even though URL ingest is Mac-only: the intent
/// already answers there with a spoken `unavailableOnThisDevice` by design, and it was reachable
/// from Shortcuts on iOS regardless. Gating only the PHRASE left the shared `AppShortcuts`
/// catalog carrying a key the iOS artifact could never register, which is a real warning about a
/// stray key and must stay one.
struct TranscriptionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Start a new recording in \(.applicationName)",
                "New recording in \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic")

        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Stop my \(.applicationName) recording"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle")

        AppShortcut(
            intent: TranscribeFileIntent(),
            phrases: [
                "Transcribe a file with \(.applicationName)",
                "Transcribe a file in \(.applicationName)"
            ],
            shortTitle: "Transcribe File",
            systemImageName: "waveform")

        AppShortcut(
            intent: SearchTranscriptsIntent(),
            phrases: [
                "Search my transcripts in \(.applicationName)",
                "Search \(.applicationName) transcripts"
            ],
            shortTitle: "Search Transcripts",
            systemImageName: "magnifyingglass")

        AppShortcut(
            intent: GetLatestTranscriptIntent(),
            phrases: [
                "Read my last transcript in \(.applicationName)",
                "What's my latest \(.applicationName) transcript"
            ],
            shortTitle: "Latest Transcript",
            systemImageName: "text.quote")

        AppShortcut(
            intent: AskTranscriptIntent(),
            phrases: [
                "Ask my last recording in \(.applicationName)",
                "Ask \(.applicationName) about my transcript"
            ],
            shortTitle: "Ask a Transcript",
            systemImageName: "questionmark.bubble")

        AppShortcut(
            intent: OpenTranscriptIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Open Transcript",
            systemImageName: "doc.text")

        AppShortcut(
            intent: SummarizeTranscriptIntent(),
            phrases: [
                "Summarize my last recording in \(.applicationName)",
                "Summarize my \(.applicationName) transcript"
            ],
            shortTitle: "Summarize Transcript",
            systemImageName: "text.redaction")

        AppShortcut(
            intent: OpenInspectorIntent(),
            phrases: [
                "Open the inspector in \(.applicationName)",
                "Show my \(.applicationName) inspector"
            ],
            shortTitle: "Open Inspector",
            systemImageName: "gauge.with.dots.needle.bottom.50percent")

        AppShortcut(
            intent: TranscribeLinkIntent(),
            phrases: [
                "Transcribe a link with \(.applicationName)",
                "Transcribe a link in \(.applicationName)"
            ],
            shortTitle: "Transcribe Link",
            systemImageName: "link")
    }
}

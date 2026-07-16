import AppIntents
import Foundation

/// Donation wrappers for the key Transcription Studio intents. Called from the UI flow
/// (Views/) at the moment the user performs the matching action there, so Siri learns real
/// usage — never from inside an intent's own `perform()`, since Siri/Shortcuts already saw
/// that invocation.
enum TranscriptionIntentDonations {
    #if DEBUG
    private static let donationsEnabled = false
    #else
    private static let donationsEnabled = true
    #endif

    static func donateStartRecording(mode: RecordingController.Mode) async {
        guard donationsEnabled else { return }
        let intent = StartRecordingIntent()
        #if os(macOS)
        intent.mode = mode == .meeting ? .meeting : .room
        #else
        intent.mode = .room
        #endif
        _ = try? await intent.donate()
    }

    static func donateStopRecording() async {
        guard donationsEnabled else { return }
        _ = try? await StopRecordingIntent().donate()
    }

    static func donateTranscribeFile(fileURL: URL) async {
        guard donationsEnabled else { return }
        let intent = TranscribeFileIntent()
        intent.file = IntentFile(fileURL: fileURL, filename: fileURL.lastPathComponent, type: .audio)
        _ = try? await intent.donate()
    }

    static func donateOpenTranscript(_ session: TranscriptSessionEntity) async {
        guard donationsEnabled else { return }
        let intent = OpenTranscriptIntent()
        intent.target = session
        _ = try? await intent.donate()
    }

    static func donateDeleteTranscript(_ session: TranscriptSessionEntity) async {
        guard donationsEnabled else { return }
        let intent = DeleteTranscriptIntent()
        intent.target = session
        _ = try? await intent.donate()
    }

    static func donateSearchTranscripts(query: String) async {
        guard donationsEnabled, !query.isEmpty else { return }
        let intent = SearchTranscriptsIntent()
        intent.query = query
        _ = try? await intent.donate()
    }

    static func donateSummarizeTranscript(_ session: TranscriptSessionEntity) async {
        guard donationsEnabled else { return }
        let intent = SummarizeTranscriptIntent()
        intent.session = session
        _ = try? await intent.donate()
    }

    static func donateExportTranscript(_ session: TranscriptSessionEntity, format: TranscriptExport.Format) async {
        guard donationsEnabled else { return }
        let intent = ExportTranscriptIntent()
        intent.session = session
        intent.format = format
        _ = try? await intent.donate()
    }

    static func donateOpenLibrary() async {
        guard donationsEnabled else { return }
        _ = try? await OpenLibraryIntent().donate()
    }

    static func donateTranscribeLink(urlString: String) async {
        guard donationsEnabled, !urlString.isEmpty else { return }
        let intent = TranscribeLinkIntent()
        intent.url = urlString
        _ = try? await intent.donate()
    }

    static func donateRenameTranscript(_ session: TranscriptSessionEntity, newTitle: String) async {
        guard donationsEnabled else { return }
        let intent = RenameTranscriptIntent()
        intent.target = session
        intent.newTitle = newTitle
        _ = try? await intent.donate()
    }

    static func donatePlayTranscript(_ session: TranscriptSessionEntity) async {
        guard donationsEnabled else { return }
        let intent = PlayTranscriptIntent()
        intent.target = session
        _ = try? await intent.donate()
    }

    static func donatePausePlayback() async {
        guard donationsEnabled else { return }
        _ = try? await PausePlaybackIntent().donate()
    }
}

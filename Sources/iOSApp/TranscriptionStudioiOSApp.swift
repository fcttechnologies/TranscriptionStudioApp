import SwiftUI
import SwiftData
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSRootView()
        }
        .modelContainer(AppModelContainer.shared)
    }
}

/// The iOS shell: Transcribe (files) / Record (mic) / Library. URL ingest is Mac-only —
/// the surface doesn't exist here rather than existing disabled.
struct IOSRootView: View {
    var body: some View {
        TabView {
            Tab("Transcribe", systemImage: "text.quote") {
                LanePlaceholderView(title: "Transcribe",
                                    systemImage: "text.quote",
                                    laneNote: "File transcription lands with Lane A (ingest + ASR).")
            }
            Tab("Record", systemImage: "waveform.badge.microphone") {
                LanePlaceholderView(title: "Record",
                                    systemImage: "waveform.badge.microphone",
                                    laneNote: "Live recording + diarization lands with Lane B.")
            }
            Tab("Library", systemImage: "books.vertical") {
                LanePlaceholderView(title: "Library",
                                    systemImage: "books.vertical",
                                    laneNote: "Saved sessions land with Lane C (app UI).")
            }
        }
    }
}

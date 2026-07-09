import SwiftUI
import TranscriptionKit

/// The Mac shell: sidebar (Transcribe / Record / Library) + detail. The UI lane replaces
/// the placeholder details with the real surfaces.
public struct MacRootView: View {
    public enum Surface: String, CaseIterable, Identifiable {
        case transcribe, record, library
        public var id: String { rawValue }

        var title: String {
            switch self {
            case .transcribe: "Transcribe"
            case .record: "Record"
            case .library: "Library"
            }
        }

        var systemImage: String {
            switch self {
            case .transcribe: "text.quote"
            case .record: "waveform.badge.microphone"
            case .library: "books.vertical"
            }
        }
    }

    @State private var selection: Surface? = .transcribe

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(Surface.allCases, selection: $selection) { surface in
                Label(surface.title, systemImage: surface.systemImage)
                    .tag(surface)
            }
            .navigationTitle("Transcription Studio")
        } detail: {
            switch selection ?? .transcribe {
            case .transcribe:
                LanePlaceholderView(title: "Transcribe",
                                    systemImage: "text.quote",
                                    laneNote: "URL + file transcription lands with Lane A (ingest + ASR).")
            case .record:
                LanePlaceholderView(title: "Record",
                                    systemImage: "waveform.badge.microphone",
                                    laneNote: "Live recording + diarization lands with Lane B (capture + diarization).")
            case .library:
                LanePlaceholderView(title: "Library",
                                    systemImage: "books.vertical",
                                    laneNote: "Saved sessions land with Lane C (app UI).")
            }
        }
    }
}

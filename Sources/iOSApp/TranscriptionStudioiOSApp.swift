import SwiftUI
import SwiftData
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    @State private var app: AppModel

    init() {
        let model = AppModel.live(captureFactory: { mode, sessionID, recorder in
            // iOS records from the microphone in every mode (meeting capture is Mac-only and
            // the surface doesn't exist here).
            _ = mode
            return [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
                          tracks: [.mixed])]
        })
        // Register the live model so App Intents (Siri/Shortcuts) resolve it via @Dependency.
        TranscriptionAppIntents.registerDependencies(appModel: model)
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            // The single-view home, iPhone-native: no URL ingest and no meeting mode (both
            // are Mac-only capabilities).
            StudioHomeView()
                .environment(app)
                .task {
                    TranscriptSpotlightIndex.reindexAll()
                    // Warm the speech model up front so the first job isn't blocked by the
                    // one-time model compile (see AppModel.prewarmDefaultEngine).
                    app.prewarmDefaultEngine()
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

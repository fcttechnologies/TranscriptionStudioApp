import SwiftUI
import SwiftData
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

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
                // A shared media file arrives via the Share extension's URL-scheme ping; drain
                // the App Group drop-box and enqueue it as a job.
                .onOpenURL { url in app.handleIngestURL(url) }
                // Safety net: iOS Share extensions can't reliably open their host, so also drain
                // on every foreground — the extension's staged item is picked up here.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.ingestPendingShares() }
                }
                .task {
                    TranscriptSpotlightIndex.reindexAll()
                    // Drain anything the Share extension staged while the app wasn't running.
                    app.ingestPendingShares()
                    // Warm the speech model up front so the first job isn't blocked by the
                    // one-time model compile (see AppModel.prewarmDefaultEngine).
                    app.prewarmDefaultEngine()
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

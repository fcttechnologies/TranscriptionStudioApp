import SwiftUI
import SwiftData
import TranscriptionKit
import TranscriptionMacKit

@main
struct TranscriptionStudioApp: App {
    @State private var app: AppModel

    init() {
        let model = AppModel.live(captureFactory: { mode, sessionID, recorder in
            switch mode {
            case .room:
                [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
                       tracks: [.mixed])]
            case .meeting:
                // One ScreenCaptureKit stream carries both tracks on a shared clock.
                [.init(source: MeetingCaptureSource(sessionID: sessionID, recorder: recorder),
                       tracks: [.microphone, .system])]
            }
        }, urlDownloader: URLIngestService())
        // Register the live model so App Intents (Siri/Shortcuts) resolve it via @Dependency.
        TranscriptionAppIntents.registerDependencies(appModel: model)
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(app)
                .task {
                    // Wipe any per-job temp dirs left by a previous run (web-app parity).
                    URLIngestService.sweepStartupTemp()
                    TranscriptSpotlightIndex.reindexAll()
                    // Warm the speech model up front so the first job isn't blocked by the
                    // one-time model compile (see AppModel.prewarmDefaultEngine).
                    app.prewarmDefaultEngine()
                }
        }
        .modelContainer(AppModelContainer.shared)
        .defaultSize(width: 1140, height: 740)
        .commands { AppCommands(app: app) }
    }
}

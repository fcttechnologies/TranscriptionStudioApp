import SwiftUI
import SwiftData
import FCTCloudKit
import TranscriptionKit
import TranscriptionMacKit

@main
struct TranscriptionStudioApp: App {
    @State private var app: AppModel
    @State private var cloudKitSync = CloudKitSyncMonitor()
    @State private var bootstrap: LibraryBootstrap
    /// Keeps this device's Spotlight index fresh with sessions changed on the other device while
    /// the app runs (launch's `reindexAll` only covers the gap at startup). Retained for the
    /// app's lifetime; created in the launch task so it never spins up under tests.
    @State private var spotlightObserver: SpotlightIndexObserver?
    /// MetricKit production diagnostics — daily metric reports + crash/hang/hitch/launch/memory
    /// events, tagged with the pipeline stage they occurred in. Held for the app's lifetime.
    @State private var metricsReporter = MetricsReporter()
    @Environment(\.scenePhase) private var scenePhase

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
        let context = model.modelContext
        _bootstrap = State(initialValue: LibraryBootstrap(sessionCount: {
            (try? context.fetchCount(FetchDescriptor<TranscriptSession>())) ?? 0
        }))
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(app)
                .environment(cloudKitSync)
                .environment(bootstrap)
                // A shared link arrives via the Share extension's URL-scheme ping; drain the
                // App Group drop-box and enqueue it as a job.
                .onOpenURL { url in app.handleIngestURL(url) }
                // Safety net: also drain on every foreground, in case the extension staged an
                // item without the open landing.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.ingestPendingShares() }
                }
                .task {
                    // Wipe any per-job temp dirs left by a previous run (web-app parity).
                    URLIngestService.sweepStartupTemp()
                    AppModelContainer.stampMainContextAuthor()
                    // Start consuming MetricKit reports for the rest of the session (idempotent).
                    metricsReporter.start()
                    TranscriptSpotlightIndex.reindexAll()
                    // Keep the index fresh with cross-device changes for the rest of the session.
                    if spotlightObserver == nil {
                        spotlightObserver = SpotlightIndexObserver(container: AppModelContainer.shared)
                    }
                    // Drain anything the Share extension staged while the app wasn't running.
                    app.ingestPendingShares()
                    // The Mac is the companion processor: watch for links queued on iOS and
                    // publish a presence heartbeat the phone reads.
                    app.startMacCompanionServices()
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

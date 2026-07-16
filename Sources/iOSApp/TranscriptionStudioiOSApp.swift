import SwiftUI
import SwiftData
import FCTCloudKit
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    @State private var app: AppModel
    @State private var cloudKitSync = CloudKitSyncMonitor()
    @State private var bootstrap: LibraryBootstrap
    /// Keeps this device's Spotlight index fresh with sessions changed on the other device while
    /// the app runs (launch's `reindexAll` only covers the gap at startup). Retained for the
    /// app's lifetime; created in the launch task so it never spins up under tests.
    @State private var spotlightObserver: SpotlightIndexObserver?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Simulator / agent E2E: `-TSMockRecording` composes the deterministic mock engine stack
        // (no ML model, no mic) so a live recording streams seeded segments — used to verify the
        // live-transcript and caption surfaces on the simulator.
        let useMockRecording = ProcessInfo.processInfo.arguments.contains("-TSMockRecording")
        let model = useMockRecording ? AppModel.mock() : AppModel.live(captureFactory: Self.micCaptureFactory)
        #else
        let model = AppModel.live(captureFactory: Self.micCaptureFactory)
        #endif
        // Register the live model so App Intents (Siri/Shortcuts) resolve it via @Dependency.
        TranscriptionAppIntents.registerDependencies(appModel: model)
        _app = State(initialValue: model)
        let context = model.modelContext
        _bootstrap = State(initialValue: LibraryBootstrap(sessionCount: {
            (try? context.fetchCount(FetchDescriptor<TranscriptSession>())) ?? 0
        }))
    }

    /// iOS records from the microphone in every mode (meeting capture is Mac-only and the
    /// surface doesn't exist here).
    private static let micCaptureFactory: RecordingController.CaptureFactory = { _, sessionID, recorder in
        [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
               tracks: [.mixed])]
    }

    var body: some Scene {
        WindowGroup {
            // The single-view home, iPhone-native: meeting mode is Mac-only, but a link can now be
            // queued here for the Mac to transcribe (see AppModel.submitLink).
            StudioHomeView()
                .environment(app)
                .environment(cloudKitSync)
                .environment(bootstrap)
                // A shared media file arrives via the Share extension's URL-scheme ping; drain
                // the App Group drop-box and enqueue it as a job.
                .onOpenURL { url in app.handleIngestURL(url) }
                // Safety net: iOS Share extensions can't reliably open their host, so also drain
                // on every foreground — the extension's staged item is picked up here.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.ingestPendingShares() }
                }
                .task {
                    #if DEBUG
                    // Simulator screenshots / agent E2E: `-TSSeedDemoLibrary` fills an empty
                    // library with two playable demo sessions.
                    DemoLibrarySeeder.seedIfRequested(context: app.modelContext)
                    // `-TSMockRecording` auto-starts a room recording off the mock engines so the
                    // live sheet opens streaming seeded captions with no model/mic (see init).
                    if ProcessInfo.processInfo.arguments.contains("-TSMockRecording"),
                       !app.recording.isActive {
                        app.requestRecording(mode: .room)
                    }
                    #endif
                    // Relocate any speech model the Background Assets downloader extension
                    // pre-fetched (before first launch) from the App Group into WhisperKit's
                    // download base, so the warmup below finds it on disk and skips the network.
                    BackgroundAssetsModelInstaller.installStagedModel()
                    AppModelContainer.stampMainContextAuthor()
                    TranscriptSpotlightIndex.reindexAll()
                    // Keep the index fresh with cross-device changes for the rest of the session.
                    if spotlightObserver == nil {
                        spotlightObserver = SpotlightIndexObserver(container: AppModelContainer.shared)
                    }
                    // Drain anything the Share extension staged while the app wasn't running.
                    app.ingestPendingShares()
                    // Warm the speech model up front so the first job isn't blocked by the
                    // one-time model compile (see AppModel.prewarmDefaultEngine). If the model
                    // isn't present (extension never ran — e.g. a sideloaded build), WhisperKit's
                    // own background-session download is the guaranteed fallback.
                    app.prewarmDefaultEngine()
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

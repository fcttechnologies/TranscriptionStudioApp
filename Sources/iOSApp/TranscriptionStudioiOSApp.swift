import FCTAccount
import SwiftData
import SwiftUI
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    @State private var app: AppModel
    /// The shared FCT session — one keychain item for the whole portfolio. Resolves before the
    /// engine does: `resume()` is what turns a stored session into the event the engine's
    /// lifecycle is built from.
    @State private var account = AccountController()
    /// The record engine + blob layer, alive exactly as long as an account is.
    @State private var sync: TranscriptionSync
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
        let sync = TranscriptionSync()
        _sync = State(initialValue: sync)
        _bootstrap = State(initialValue: LibraryBootstrap(
            sessionCount: { (try? context.fetchCount(FetchDescriptor<TranscriptSession>())) ?? 0 },
            isRestoring: { sync.status == .syncing }
        ))
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
                .environment(account)
                .environment(sync)
                .environment(bootstrap)
                // A shared media file arrives via the Share extension's URL-scheme ping; drain
                // the App Group drop-box and enqueue it as a job.
                .onOpenURL { url in app.handleIngestURL(url) }
                // Safety net: iOS Share extensions can't reliably open their host, so also drain
                // on every foreground — the extension's staged item is picked up here.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    app.ingestPendingShares()
                    // Re-read the shared session, re-check the Apple credential, run a cycle —
                    // launch, foregrounding, post-push is the rung correctness rides on.
                    Task {
                        await account.resume()
                        await account.refreshAppleCredentialState()
                        sync.foregrounded()
                    }
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
                    sync.start(controller: account, container: AppModelContainer.shared)
                    // The recording is fetch-on-demand, so playback reads the blob layer through
                    // these two seams: the cache first, one digest-verified download otherwise.
                    app.sync = sync
                    app.playback.cachedRecordingBytes = { sync.cachedRecordingData(for: $0) }
                    app.playback.recordingBytes = { try await sync.recordingData(for: $0) }
                    await account.resume()
                    // Start consuming MetricKit reports for the rest of the session (idempotent).
                    metricsReporter.start()
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

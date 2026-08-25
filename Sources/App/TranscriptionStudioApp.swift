import FCTAccount
import SwiftData
import SwiftUI

/// The app shell — one target for iPhone, iPad and Mac, a thin window over the shared
/// `TranscriptionKit`. The Mac-only capabilities (ScreenCaptureKit meeting capture, yt-dlp/ffmpeg
/// URL ingest) come from `TranscriptionMacKit`, which this target links on macOS only: that
/// package uses APIs with no iOS availability, so the dependency edge on it is filtered to macOS
/// in `project.yml` and the module is never built for the iOS destination.
@main
struct TranscriptionStudioApp: App {
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
        #if os(macOS)
        let model = AppModel.live(captureFactory: Self.captureFactory,
                                  urlDownloader: URLIngestService())
        #elseif DEBUG
        // Simulator / agent E2E: `-TSMockRecording` composes the deterministic mock engine stack
        // (no ML model, no mic) so a live recording streams seeded segments — used to verify the
        // live-transcript and caption surfaces on the simulator.
        let useMockRecording = ProcessInfo.processInfo.arguments.contains("-TSMockRecording")
        let model = useMockRecording ? AppModel.mock() : AppModel.live(captureFactory: Self.captureFactory)
        #else
        let model = AppModel.live(captureFactory: Self.captureFactory)
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

    #if os(macOS)
    /// Meeting mode is one ScreenCaptureKit stream carrying system audio and the microphone on a
    /// shared clock; room mode is the microphone alone.
    private static let captureFactory: RecordingController.CaptureFactory = { mode, sessionID, recorder in
        switch mode {
        case .room:
            [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
                   tracks: [.mixed])]
        case .meeting:
            [.init(source: MeetingCaptureSource(sessionID: sessionID, recorder: recorder),
                   tracks: [.microphone, .system])]
        }
    }
    #else
    /// iOS records from the microphone in every mode (meeting capture is Mac-only and the
    /// surface doesn't exist here).
    private static let captureFactory: RecordingController.CaptureFactory = { _, sessionID, recorder in
        [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
               tracks: [.mixed])]
    }
    #endif

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(app)
                .environment(account)
                .environment(sync)
                .environment(bootstrap)
                // A shared item arrives via the Share extension's URL-scheme ping; drain the
                // App Group drop-box and enqueue it as a job.
                .onOpenURL { url in app.handleIngestURL(url) }
                // Also drain on every foreground, in case the extension staged an item without
                // the open landing — on iOS a Share extension can't reliably open its host, so
                // there this drain is the real path rather than a backstop.
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
                .task { await launch() }
        }
        .modelContainer(AppModelContainer.shared)
        #if os(macOS)
        .defaultSize(width: 1140, height: 740)
        .commands { AppCommands(app: app) }
        #endif
    }

    /// The single home surface, with the Mac-only capabilities switched on where they exist.
    @ViewBuilder
    private var rootView: some View {
        #if os(macOS)
        MacRootView()
        #else
        StudioHomeView()
        #endif
    }

    /// Everything the app does once, at launch, in the order the rest of the session depends on.
    @MainActor
    private func launch() async {
        #if os(macOS)
        // Wipe any per-job temp dirs left by a previous run (web-app parity).
        URLIngestService.sweepStartupTemp()
        #else
        #if DEBUG
        // Simulator screenshots / agent E2E: `-TSSeedDemoLibrary` fills an empty library with two
        // playable demo sessions.
        DemoLibrarySeeder.seedIfRequested(context: app.modelContext)
        // `-TSMockRecording` auto-starts a room recording off the mock engines so the live sheet
        // opens streaming seeded captions with no model/mic (see init).
        if ProcessInfo.processInfo.arguments.contains("-TSMockRecording"), !app.recording.isActive {
            app.requestRecording(mode: .room)
        }
        #endif
        // Relocate any speech model the Background Assets downloader extension pre-fetched
        // (before first launch) from the App Group into WhisperKit's download base, so the warmup
        // below finds it on disk and skips the network.
        BackgroundAssetsModelInstaller.installStagedModel()
        #endif
        AppModelContainer.stampMainContextAuthor()
        sync.start(controller: account, container: AppModelContainer.shared)
        // The recording is fetch-on-demand, so playback reads the blob layer through these two
        // seams: the cache first, one digest-verified download otherwise.
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
        #if os(macOS)
        // The Mac is the companion processor: watch for links queued on iOS and publish a
        // presence heartbeat the phone reads.
        app.startMacCompanionServices()
        #endif
        // Warm the speech model up front so the first job isn't blocked by the one-time model
        // compile (see AppModel.prewarmDefaultEngine). On iOS, if the model isn't present
        // (the extension never ran — e.g. a sideloaded build), WhisperKit's own background-session
        // download is the guaranteed fallback.
        app.prewarmDefaultEngine()
    }
}

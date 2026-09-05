import FCTAccount
#if DEBUG
import FCTScreenshotStudio
#endif
import SwiftData
import SwiftUI

/// The app shell — one target for iPhone, iPad and Mac. The Mac-only capabilities
/// (ScreenCaptureKit meeting capture, yt-dlp/ffmpeg URL ingest) are compiled in on macOS alone;
/// the source guards and the macOS-filtered dependency edges in `project.yml` are what keep them
/// out of the iOS product.
///
/// The window holds `RootView` and nothing else: the front door owns what the user sees until
/// there is a session and the account's library has landed. What runs *here* is only the work that
/// belongs to the process rather than to the account — diagnostics, temp sweeps, staged-model
/// relocation — all of which is true whether anyone is signed in or not.
@main
struct TranscriptionStudioApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var app: AppModel
    /// The shared FCT session — one keychain item for the whole portfolio. The account gate owns
    /// the launch `resume()`, because the gate is what a wrong answer would show.
    @State private var account = AccountController()
    /// The record engine + blob layer, alive exactly as long as an account is. Started from behind
    /// the gate.
    @State private var sync = TranscriptionSync()
    #if DEBUG
    /// The debug surface's own store. Every session the debug tools seed or delete is a synced
    /// row, so they act on a second, local-only store file instead. The app's own root keeps its
    /// own container: nothing the debug tools write can reach the account's library, and each
    /// studio scene carries the demo store itself (`ScreenshotStudioCatalog`).
    private let debugStore = TranscriptionDebugStore.demo
    #endif
    /// MetricKit production diagnostics — daily metric reports + crash/hang/hitch/launch/memory
    /// events, tagged with the pipeline stage they occurred in. Held for the app's lifetime.

    init() {
        TranscriptionDiagnostics.start()
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
            RootView(account: account)
                .environment(app)
                .environment(account)
                .environment(sync)
                // Two consumers on the app's one scheme, told apart by the URL's host. A
                // dictation hand-off carries a finished result's id, which is read out of the App
                // Group container and shown. Anything else is the Share extension's ping: drain
                // the drop-box and enqueue what it staged. Harmless while the gate is up — the
                // drop-box keeps, and the app drains it again on every foreground.
                .onOpenURL { url in
                    guard !app.handleDictationURL(url) else { return }
                    app.handleIngestURL(url)
                }
                .task { await launch() }
                #if DEBUG
                .environment(\.debugDemoStore, debugStore)
                #endif
        }
        .modelContainer(AppModelContainer.shared)
        #if os(macOS)
        .defaultSize(width: 1140, height: 740)
        .commands { AppCommands(app: app) }
        #endif

        // The Mac screenshot studio gets its OWN window. A Mac App Store shot IS a window, and
        // hanging the studio off the Settings sheet confines every scene to the sheet's bounds, so
        // the feed captures at sheet width and the capture is useless. iOS does not have this
        // problem because `fullScreenCover` escapes its sheet; nothing escapes a sheet on macOS.
        // Sized to the Mac App Store's own 1440x900 minimum so a capture needs no rescaling.
        // `Text(verbatim:)` rather than a bare literal, which would bind the `LocalizedStringKey`
        // overload: this window exists only in DEBUG, so its title is developer-facing and reaches
        // no user in any language — extracted as a key it would sit in the shipping catalog
        // demanding ten translations for a string no shipping build even compiles.
        #if DEBUG && os(macOS)
        Window(Text(verbatim: "Screenshot Studio"), id: ScreenshotStudioWindow.id) {
            ScreenshotStudioWindowContent()
                .frame(minWidth: 1440, minHeight: 900)
        }
        .defaultSize(width: 1440, height: 900)
        #endif
    }

    /// Process-level launch work: true with or without an account, so it runs beside the gate
    /// rather than behind it. Everything that belongs to the *account* — the sync engine, the
    /// first pull, Spotlight, the companion services, the speech-model warmup — is
    /// `SignedInRootView.openTheDoor()`. The speech models' background download is not: it
    /// starts here, before any account, so a first launch spends its onboarding minutes fetching.
    @MainActor
    private func launch() async {
        #if os(macOS)
        // Wipe any per-job temp dirs left by a previous run.
        URLIngestService.sweepStartupTemp()
        #else
        // Relocate any speech model the Background Assets downloader extension pre-fetched
        // (before first launch) from the App Group into the models root, so the warmup behind
        // the gate finds it on disk and skips the network.
        SpeechModelStore.installStagedModels()
        #endif
        // Whatever is still missing starts coming down now, in the background, before the door
        // opens: the system keeps transferring while the app is away and resumes after a
        // relaunch. The front door shows the progress; nothing asks.
        SpeechModelDownloader.shared.start()
        AppModelContainer.stampMainContextAuthor()
        // MetricKit consumption is the shared layer's (`TranscriptionDiagnostics.service`), which
        // both uploads and mirrors to OSLog. This app used to run a SECOND MetricManager beside it
        // purely for the OSLog half; that mirroring now lives in `MetricsService` so all thirteen
        // apps get it, and the local subscriber is gone.
    }
}

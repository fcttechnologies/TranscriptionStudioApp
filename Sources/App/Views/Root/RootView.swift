import FCTAccount
import FCTAccountProfile
import FCTOnboarding
import SwiftData
import SwiftUI

/// The root on every destination: **the front door, then the app.**
///
/// Stages 1 and 2 — the intro carousel and the required three-provider sign-in — are
/// `FCTOnboarding`'s `AccountGate`, and this app supplies only its pages. The gate's content
/// closure is not called until a session exists, so nothing below it is constructed, queries the
/// store, or starts a task while the gate is up, and a sign-out puts it straight back.
///
/// Sign-in is **required**. Transcription Studio's library — the sessions, every word of every
/// transcript, the highlights, the speaker bindings and the recordings themselves — lives in the
/// user's own FCT account, and there is no signed-out-but-using-the-app state to design for.
struct RootView: View {
    let account: AccountController

    var body: some View {
        AccountGate(
            tint: .accentColor,
            items: TranscriptionOnboardingCarousel.items,
            controller: account,
            appearance: TranscriptionAccountAppearance.standard,
            continueButtonIdentifier: A11yID.onboardingContinue
        ) {
            SignedInRootView()
        }
        // Top-trailing on BOTH platforms, because the bottom is where the gate's own Continue
        // button lives on both: the iOS gate fills the screen and puts the CTA at the bottom edge,
        // and the macOS panel is centred with its CTA a few points above the window's. A bar
        // pinned to the bottom lands on top of the CTA either way — which is what driving each
        // platform showed, one after the other.
        .overlay(alignment: .topTrailing) { debugTestAccountBar }
    }

    /// The one-tap sign-in an agent driving a Debug build uses. It rides over the gate rather than
    /// inside it — the gate's surfaces belong to the module, not to this app — and goes away the
    /// moment a session exists. Empty in a release build, and empty in a Debug build that was
    /// never handed the credential.
    @ViewBuilder
    private var debugTestAccountBar: some View {
        #if DEBUG
        if !account.state.isSignedIn {
            DebugTestAccountSignInBar(controller: account)
        }
        #endif
    }
}

/// Everything behind the gate: the account's first pull, then the app.
///
/// It is only ever constructed with a session in hand, which is what lets it start the sync
/// bootstrap and install the playback seams without guarding any of them — and what makes the
/// restore stage below the *only* place an empty library can be reasoned about.
struct SignedInRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountController.self) private var account
    @Environment(TranscriptionSync.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    @State private var frontDoor = TranscriptionFrontDoor()
    /// Keeps this device's Spotlight index fresh with sessions changed on the other device while
    /// the app runs (launch's `reindexAll` only covers the gap at startup). Retained for as long
    /// as the session is.
    @State private var spotlightObserver: SpotlightIndexObserver?

    var body: some View {
        stageView
            .task { await openTheDoor() }
            .onChange(of: scenePhase) { _, phase in
                guard frontDoor.stage == .ready else { return }
                // The Realtime rung is foreground-only, and `.background` is the transition that
                // ends one. `.inactive` is a notification shade or an app switcher, and dropping
                // the socket there would buy a re-join seconds later for nothing.
                guard phase != .background else { return sync.backgrounded() }
                guard phase == .active else { return }
                app.ingestPendingShares()
                // Re-read the shared session, re-check the Apple credential, run a cycle and
                // re-join the nudge channel — launch, foregrounding and post-push is the rung
                // correctness rides on.
                Task {
                    await account.resume()
                    await account.refreshAppleCredentialState()
                    sync.foregrounded()
                }
            }
    }

    @ViewBuilder
    private var stageView: some View {
        switch frontDoor.stage {
        case .launching:
            FrontDoorLaunchingView()
        case .restoring:
            FrontDoorRestoringView()
        case .restoreFailed(let message):
            FrontDoorRestoreFailedView(message: message) { Task { await frontDoor.retry() } }
        case .offerSpeechModel, .ready:
            accountOnboardingGate
        }
    }

    /// The one FCT onboarding, nested after this app's own restore stage — the account row is
    /// already on disk by the time this renders, so the gate's wait is instant — and *ahead* of
    /// the speech-model offer, because an app's own setup question comes after the account's.
    ///
    /// One gate across both stages rather than one per stage, so answering the speech-model offer
    /// does not rebuild the coordinator underneath it.
    @ViewBuilder
    private var accountOnboardingGate: some View {
        if let credentials = account.credentials, let stateFile = sync.stateFile {
            AccountOnboardingGate(
                tint: .accentColor,
                completedIn: TranscriptionSyncSchema.postgresSchema,
                appleFullName: sync.appleFullName,
                stateFile: stateFile,
                sync: { _ = await sync.restoreAccountData() },
                trusted: AccountTrusted(account: credentials)
            ) {
                if case .offerSpeechModel = frontDoor.stage {
                    FrontDoorSpeechModelView { frontDoor.speechModelOfferAnswered() }
                } else {
                    #if os(macOS)
                    MacRootView()
                    #else
                    StudioHomeView()
                    #endif
                }
            }
        } else {
            // The session ended under a signed-in stage; `AccountGate` takes the window back on
            // its own one update later.
            FrontDoorLaunchingView()
        }
    }

    /// Everything the session needs wired before any of it renders, then the routing itself.
    private func openTheDoor() async {
        #if os(iOS) && DEBUG
        // Simulator screenshots / agent E2E: `-TSSeedDemoLibrary` fills an empty library with two
        // playable demo sessions. Behind the gate, so the seeded rows land in a store that has an
        // account to belong to.
        DemoLibrarySeeder.seedIfRequested(context: app.modelContext)
        #endif
        sync.start(controller: account, container: AppModelContainer.shared)
        // The recording is fetch-on-demand, so playback reads the blob layer through these two
        // seams: the permanent local cache first, one digest-verified download otherwise.
        app.sync = sync
        app.playback.cachedRecordingBytes = { sync.cachedRecordingData(for: $0) }
        app.playback.recordingBytes = { try await sync.recordingData(for: $0) }
        // A sign-out, switch or deletion wipes this device's copy. The account gate takes the
        // window back on its own; this only forgets that this device ever restored, so the next
        // sign-in pulls the library down rather than opening onto an empty store.
        sync.onLocalDataCleared = { frontDoor.localDataCleared() }

        frontDoor.attachAccount(account)
        frontDoor.restoreAccountData = { await sync.restoreAccountData() }
        frontDoor.isSpeechModelInstalled = {
            ModelStorageScanner.isWhisperModelInstalled(app.settings.whisperModel)
        }

        await frontDoor.start()

        guard frontDoor.stage == .ready else { return }
        TranscriptSpotlightIndex.reindexAll()
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
        // Warm the speech model so the first job isn't blocked by the one-time model compile. It
        // waits for the session on purpose: the model is a gigabyte-scale download, and pulling it
        // down for someone who has not signed in spends their bandwidth on an app they may not
        // keep. On iOS, if the model isn't present (the Background Assets extension never ran —
        // e.g. a sideloaded build), WhisperKit's own background-session download is the fallback.
        app.prewarmDefaultEngine()
        #if os(iOS) && DEBUG
        // `-TSMockRecording` auto-starts a room recording off the mock engines so the live sheet
        // opens streaming seeded captions with no model or mic (see `TranscriptionStudioApp.init`).
        if ProcessInfo.processInfo.arguments.contains("-TSMockRecording"), !app.recording.isActive {
            app.requestRecording(mode: .room)
        }
        #endif
    }
}

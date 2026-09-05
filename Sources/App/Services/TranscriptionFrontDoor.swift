import FCTAccount
import Foundation
import Observation

/// Whether this device has already been offered the speech model, so the offer is made once and
/// never becomes a thing to dismiss on every launch.
///
/// Per install rather than per account: the model is a file on this disk, and which account is
/// signed in has nothing to do with whether it is already there. Answering "later" is a real
/// answer and is remembered — the model still arrives on its own, silently, exactly as it did
/// before the offer existed.
nonisolated enum SpeechModelOfferState {
    static let key = "com.fcttechnologies.TranscriptionStudio.speechModelOffered"

    static func wasOffered(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func markOffered(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// Where a launch routes once the account gate has let it through. A value rather than a step in a
/// sequence, so the routing table is something a test enumerates instead of drives.
nonisolated enum FrontDoorEntry: Equatable {
    /// This device has never pulled this account's library: restore before anything renders.
    case restore
    /// Already restored: straight to the app.
    case resume

    static func forLaunch(hasRestored: Bool) -> Self {
        hasRestored ? .resume : .restore
    }
}

/// What the window holds between the account gate and the app.
nonisolated enum FrontDoorStage: Equatable {
    case launching
    /// The account's library coming down. Nothing of the app is built here.
    case restoring
    case restoreFailed(String)
    /// The speech models are not all on this device yet: the stage shows the background download
    /// that started at launch (or the offer, when nothing is coming). Shown once, skippable, and
    /// never on the path of a device that already has them.
    case offerSpeechModel
    case ready
}

/// Stages 3 and 4 of the front door: the account's first pull, and only then the app.
///
/// Stages 1 and 2 — the intro carousel and the required sign-in — are `FCTOnboarding`'s
/// `AccountGate`, which is also what makes this type simple: it is constructed only behind a
/// session, so it never reasons about not having one.
///
/// **The restore comes before any surface**, which is what makes "you have nothing" structurally
/// unsayable here rather than guarded surface by surface: the feed is not built until the pull has
/// landed, and a pull that cannot complete shows its own refusal instead of an empty library. A
/// `false` from the restore is an unanswered question, never "new account".
///
/// Transcription Studio asks the user nothing of its own between the two — it needs no fact about
/// them to start working — so this machine has no setup stage. If it ever gains one it belongs
/// here, after the restore, for the reason the restore exists: asking for something the account
/// already holds is indistinguishable from data loss to the person being asked.
@MainActor
@Observable
final class TranscriptionFrontDoor {
    private(set) var stage: FrontDoorStage = .launching

    /// The two facts about the session this type routes on, read at the moment it routes. A
    /// closure rather than the controller itself: what the front door needs is a *reading*, and a
    /// reading is what a test can supply without touching the live keychain.
    @ObservationIgnored var session: () -> (hasSession: Bool, accountID: UUID?) = { (false, nil) }

    /// The first pull, as a seam — so the routing is testable without a live engine, and the app
    /// runs the real one.
    @ObservationIgnored var restoreAccountData: () async -> Bool = { true }

    /// Whether this device has ever finished reading this account — the engine's own durable,
    /// per-account marker, read through the sync bootstrap. A seam for the same reason the pull
    /// is one: the routing is a table, and a table is testable without a live engine.
    @ObservationIgnored var hasCompletedFirstPull: (UUID) -> Bool = { _ in false }

    /// Whether the speech model is already on this disk, as a seam. The live answer reads the
    /// bundled manifest against the install directory, which a routing test has no business
    /// needing on hand — and defaulting it to `true` means a harness that never wires it takes
    /// the model-present path rather than being surprised by an offer.
    @ObservationIgnored var isSpeechModelInstalled: () -> Bool = { true }

    @ObservationIgnored private let defaults: UserDefaults

    /// Guards a route that started before a sign-out re-entered from the top: an in-flight restore
    /// that lands late must not push the window back into the app the user has just left.
    private var attempt = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attachAccount(_ controller: AccountController) {
        session = { [weak controller] in
            (controller?.state.isSignedIn == true, controller?.credentials?.accountID)
        }
    }

    var entry: FrontDoorEntry {
        FrontDoorEntry.forLaunch(
            hasRestored: session().accountID.map { hasCompletedFirstPull($0) } ?? false
        )
    }

    /// Route from the top. Called at launch and after a sign-in.
    func start() async {
        let attemptID = UUID()
        attempt = attemptID

        switch entry {
        case .restore:
            await restore(attemptID: attemptID)
        case .resume:
            stage = stageAfterLibrary()
        }
    }

    /// The user answered the speech-model offer, either way. Recording the answer *here* rather
    /// than in the view is what keeps the offer from reappearing behind a view that got rebuilt.
    func speechModelOfferAnswered() {
        SpeechModelOfferState.markOffered(in: defaults)
        stage = .ready
    }

    /// This device's copy was wiped (sign-out, switch, deletion). The account gate takes the
    /// window back on its own; this puts the door back at the top, so the next sign-in routes
    /// from scratch. Nothing here forgets the restore: the marker is the engine's own and the
    /// clear that wiped the rows dropped it with them.
    func localDataCleared() {
        attempt = UUID()
        stage = .launching
    }

    func retry() async {
        await start()
    }

    private func restore(attemptID: UUID) async {
        stage = .restoring
        let restored = await restoreAccountData()
        guard attempt == attemptID else { return }
        // An empty library and an unreachable account look identical from here and mean opposite
        // things, so the refusal is surfaced rather than resolved into a feed that says "no
        // sessions yet" about a library nobody managed to read.
        guard restored else {
            stage = .restoreFailed(String(
                localized: "Couldn’t reach your account to restore your library. Check your connection and try again.",
                comment: "Front door: the account's first pull could not complete"
            ))
            return
        }
        stage = stageAfterLibrary()
    }

    /// The library is in hand; the only thing left is the ~1.2 GB of speech models, coming down
    /// since launch. Shown only when they are genuinely absent and the stage has never been
    /// passed, so the common launch — models present, or already passed — reaches the app in the
    /// same step it always did.
    private func stageAfterLibrary() -> FrontDoorStage {
        guard !SpeechModelOfferState.wasOffered(in: defaults), !isSpeechModelInstalled() else {
            return .ready
        }
        return .offerSpeechModel
    }
}

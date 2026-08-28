import FCTAccount
import Foundation
import Observation

/// Whether this device has ever pulled this account's library down — the fact that separates
/// "this account is new" from "this account's library has not arrived yet".
///
/// Kept per account id rather than per install: an install-wide flag reads `true` for the *second*
/// account to sign in on this device, which is exactly the case that opens onto an empty store.
/// It syncs nowhere on purpose — it is a statement about this device — and a sign-out, switch or
/// deletion clears it, so the next sign-in restores again.
nonisolated enum LibraryRestoreState {
    static let key = "com.fcttechnologies.TranscriptionStudio.restoredAccountID"

    static func hasRestored(accountID: UUID, in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) == accountID.uuidString
    }

    static func markRestored(accountID: UUID, in defaults: UserDefaults = .standard) {
        defaults.set(accountID.uuidString, forKey: key)
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
            hasRestored: session().accountID
                .map { LibraryRestoreState.hasRestored(accountID: $0, in: defaults) } ?? false
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
            stage = .ready
        }
    }

    /// This device's copy was wiped (sign-out, switch, deletion). The account gate takes the window
    /// back on its own; what this does is forget that this device ever restored, so the next
    /// sign-in pulls the library down again instead of opening onto an empty store.
    func localDataCleared() {
        LibraryRestoreState.clear(in: defaults)
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
        if let accountID = session().accountID {
            LibraryRestoreState.markRestored(accountID: accountID, in: defaults)
        }
        stage = .ready
    }
}

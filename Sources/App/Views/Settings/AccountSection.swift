import FCTAccount
import FCTServerSync
import SwiftUI

/// Transcription Studio's palette and copy, carried into the account module's surfaces without the
/// module knowing what this app is. Used by the front-door gate, which is the only place this app
/// ever asks anyone to sign in.
@MainActor
enum TranscriptionAccountAppearance {
    static let standard = AccountAppearance(
        title: String(localized: "Your library, on every device"),
        footnote: String(
            localized: """
            Transcription and speaker identification run on this device. Your library — the \
            transcripts, the highlights, the speakers and the recordings themselves — is stored \
            in your private FCT account, so it reaches your Mac and your iPhone and survives a \
            new one. Signing out removes it from this device once everything has synced; it comes \
            right back when you sign in again.
            """
        )
    )
}

/// The account + sync block Settings drops in: the shipped `AccountSettingsSection` with this
/// app's sync status inside it, and its sign-out pre-flight.
///
/// There is no sign-in row here. Settings does not exist until a session does — `AccountGate` at
/// the root is what makes that structural rather than a rule — so the only account states this
/// surface can be in are signed-in and signing out.
struct AccountSection: View {
    let account: AccountController
    let sync: TranscriptionSync

    /// Held while the sign-out pre-flight waits for the user's answer. `beforeSignOut` is an
    /// `async` hook and a confirmation dialog is a view, so the continuation is what joins them.
    @State private var pendingSignOut: CheckedContinuation<Bool, Never>?
    @State private var outstandingAtSignOut = 0

    var body: some View {
        AccountSettingsSection(
            controller: account,
            appData: AppDataDeletion(
                schema: TranscriptionSyncSchema.postgresSchema,
                appName: "Transcription Studio",
                barrier: deletionBarrier
            ) { [sync] in await sync.eraseLocalData() },
            syncStatus: {
                SyncStatusRow(
                    status: sync.status,
                    counted: sync.counted,
                    blobCounted: sync.blobCounted,
                    lastSyncedAt: sync.lastSyncedAt,
                    lastError: sync.lastError,
                    retryRefused: { await sync.retryRefused() },
                    rebuild: { await sync.fullResync() }
                )
                keptLibraryNote
            },
            beforeSignOut: { await preflightSignOut() }
        )
        .confirmationDialog(
            String(localized: "Some changes haven't uploaded yet"),
            isPresented: Binding(
                get: { pendingSignOut != nil },
                set: { if !$0 { answerSignOut(false) } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Sign Out and Keep This Library")) { answerSignOut(true) }
                .accessibilityIdentifier(A11yID.signOutKeepLibrary)
            Button(String(localized: "Cancel"), role: .cancel) { answerSignOut(false) }
                .accessibilityIdentifier(A11yID.signOutCancel)
        } message: {
            Text("""
            \(outstandingAtSignOut) change(s) haven't reached the server. Signing out normally \
            removes this library from this device, because your account can give it back — but \
            these can't come back yet, so this device will keep everything instead. Stay signed \
            in until sync finishes, or sign out and keep the library here.
            """)
        }

        // The repair for a person who ended up with two accounts. It shows only while signed in,
        // and its screen is pushed, so it rides the `NavigationStack` the settings sheet is
        // already inside. Its barrier refuses rather than offering a discard: nothing is being
        // destroyed, so work the server has never seen simply has nowhere to go until the device
        // is signed in as the other account.
        AccountMergeSection(
            controller: account,
            barrier: deletionBarrier,
            reHome: { [sync] target in sync.reHome(into: target) }
        )
    }

    /// What a sign-out left behind. Not the shared row's to say: it is a fact about a sign-out this
    /// device already ran, rather than about the state of the queue now.
    @ViewBuilder
    private var keptLibraryNote: some View {
        if sync.keptOnSignOut > 0 {
            Label {
                Text("\(sync.keptOnSignOut) change(s) hadn't reached the server, so this device kept its library at sign-out.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark")
            }
        }
    }

    /// The unpushed-work barrier both destructive doors run: push everything that still can go,
    /// then answer what the server has never seen. One value rather than two, because the deletion
    /// doors and the merge ask the same question of the same outbox — they differ only in what
    /// they offer next, and that is the module's decision rather than this app's.
    private var deletionBarrier: DeletionBarrier {
        DeletionBarrier { [sync] in
            await sync.syncNow(.full)
            guard let census = await sync.unsyncedWork else { throw AccountSectionError.uncountable }
            return .counted(retrying: census.retrying, stuck: census.stuck)
        }
    }

    /// Sign-out is the one act with no way back: after `.signedOut` there is no token left to
    /// push with. So this runs a cycle first — most "unsynced" is simply a cycle that has not
    /// happened yet — and only asks when something genuinely could not be uploaded.
    private func preflightSignOut() async -> Bool {
        await sync.syncNow(.full)
        // A count that could not be taken lets the sign-out through: the clear it runs into is
        // itself barrier-gated and keeps the library on anything unpushed, so the refusal is
        // enforced there rather than duplicated here.
        guard let outstanding = sync.unsyncedWork, !outstanding.isDrained else { return true }
        outstandingAtSignOut = outstanding.total
        return await withCheckedContinuation { continuation in
            pendingSignOut = continuation
        }
    }

    private func answerSignOut(_ proceed: Bool) {
        guard let continuation = pendingSignOut else { return }
        pendingSignOut = nil
        outstandingAtSignOut = 0
        continuation.resume(returning: proceed)
    }
}

private enum AccountSectionError: Error {
    /// "I could not tell" must never be spelled as zero at the moment a merge is decided.
    case uncountable
}


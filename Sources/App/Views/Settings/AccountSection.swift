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
            syncStatus: { SyncStatusRow(sync: sync) },
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

/// The sync state, said out loud.
///
/// R3: an empty library and an unreachable server look identical and mean opposite things, so
/// this never infers — every line below is a state the engine reported.
struct SyncStatusRow: View {
    let sync: TranscriptionSync

    @State private var isResyncing = false
    @State private var isRetrying = false

    var body: some View {
        Group {
            LabeledContent {
                Text(headline)
                    .foregroundStyle(needsAttention ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            } label: {
                Text("Sync")
            }
            .accessibilityIdentifier(A11yID.settingsSyncStatus)

            if sync.counted.retrying > 0 {
                LabeledContent("Waiting to upload", value: "\(sync.counted.retrying)")
            }

            // The blob queue's own waiting half. "Syncing" rather than "uploading" because the
            // queue holds object deletes beside uploads, and a recording the user deleted is not
            // a recording going up.
            if sync.blobCounted.retrying > 0 {
                LabeledContent("Syncing recordings", value: "\(sync.blobCounted.retrying)")
            }

            // Both queues' refused half, which waiting never clears — the same condition and the
            // same advice whether the server judged a record or the object store refused a
            // recording. Said separately from the queued counts because a judged entry leaves the
            // pending set, so a queued-only count reads zero for work stranded here forever.
            if needsAttentionCount > 0 {
                LabeledContent("Needs attention") {
                    Text("\(needsAttentionCount)")
                        .foregroundStyle(.tint)
                }
                retryRefusedButton
            }

            if sync.keptOnSignOut > 0 {
                Label {
                    Text("\(sync.keptOnSignOut) change(s) hadn't reached the server, so this device kept its library at sign-out.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                }
            }

            if let lastSyncedAt = sync.lastSyncedAt {
                LabeledContent {
                    Text(lastSyncedAt, format: .relative(presentation: .named))
                } label: {
                    Text("Last synced")
                }
            }

            if sync.status == .resyncRequired {
                Button {
                    isResyncing = true
                    Task {
                        await sync.fullResync()
                        isResyncing = false
                    }
                } label: {
                    if isResyncing {
                        ProgressView()
                    } else {
                        Text("Rebuild from the server")
                    }
                }
                .disabled(isResyncing)
            }

            if let error = sync.lastError, sync.status != .off {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The way back from a refusal, beside the count that reports it. A row reading "3 changes the
    /// server refused" with nothing next to it is a dead end, and the refusal blocks its own
    /// recovery: the drained-outbox barrier counts stuck entries, so a poisoned outbox refuses both
    /// the full resync and the sign-out, leaving deleting the app as the only route back.
    ///
    /// One button for both wires, because that is how the count above reads them — a judged record
    /// and a refused recording pose the same question. Here that matters more than in any other app
    /// in the fleet: the recordings ride the blob layer, so the bytes a refusal strands are the
    /// audio itself.
    @ViewBuilder
    private var retryRefusedButton: some View {
        Button {
            isRetrying = true
            Task {
                await sync.retryRefused()
                isRetrying = false
            }
        } label: {
            if isRetrying {
                ProgressView()
            } else {
                Text("Try these again")
            }
        }
        .disabled(isRetrying)
        .accessibilityIdentifier(A11yID.settingsRetryRefused)
    }

    private var headline: String {
        switch sync.status {
        case .off: String(localized: "Off — this device only")
        case .idle: String(localized: "Up to date")
        case .syncing: String(localized: "Syncing…")
        case .offline(let retryingIn):
            String(localized: "Offline — retrying in \(Int(retryingIn.rounded()))s")
        case .failed(let count): String(localized: "\(count) change(s) the server refused")
        case .needsReauthentication: String(localized: "Sign in again to resume")
        case .resyncRequired: String(localized: "This device needs to rebuild")
        case .merged: String(localized: "Your account moved — sign in again")
        }
    }

    private var needsAttentionCount: Int { sync.counted.stuck + sync.blobCounted.stuck }

    private var needsAttention: Bool {
        switch sync.status {
        case .off, .idle, .syncing: false
        case .offline, .needsReauthentication, .resyncRequired, .failed, .merged: true
        }
    }
}

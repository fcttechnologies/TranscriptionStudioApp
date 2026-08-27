import FCTAccount
import FCTServerSync
import SwiftUI

/// Transcription Studio's palette and copy, carried into the account module's sheet without the
/// module knowing what this app is.
@MainActor
enum TranscriptionAccountAppearance {
    static let standard = AccountAppearance(
        title: String(localized: "Keep your transcripts on every device"),
        footnote: String(
            localized: """
            Transcription Studio works without an account, and transcription always runs on this \
            device. Signing in keeps your library — transcripts, highlights, and the recordings \
            themselves — in step across your Mac and iPhone. Signing out removes them from this \
            device once everything has synced; they come right back when you sign in again.
            """
        )
    )
}

/// The account + sync block Settings drops in: the shipped `AccountSettingsSection` with this
/// app's sync status inside it, its sign-out pre-flight, and — with no account — the
/// non-blocking sign-in row. The app is whole without an account; this is settings-first, never
/// a wall.
struct AccountSection: View {
    let account: AccountController
    let sync: TranscriptionSync

    @Binding var signInPresented: Bool

    /// Held while the sign-out pre-flight waits for the user's answer. `beforeSignOut` is an
    /// `async` hook and a confirmation dialog is a view, so the continuation is what joins them.
    @State private var pendingSignOut: CheckedContinuation<Bool, Never>?
    @State private var outstandingAtSignOut = 0

    var body: some View {
        AccountSettingsSection(controller: account) {
            SyncStatusRow(sync: sync)
        } beforeSignOut: {
            await preflightSignOut()
        }
        .confirmationDialog(
            String(localized: "Some changes haven't uploaded yet"),
            isPresented: Binding(
                get: { pendingSignOut != nil },
                set: { if !$0 { answerSignOut(false) } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Sign Out and Keep This Library")) { answerSignOut(true) }
            Button(String(localized: "Cancel"), role: .cancel) { answerSignOut(false) }
        } message: {
            Text("""
            \(outstandingAtSignOut) change(s) haven't reached the server. Signing out normally \
            removes this library from this device, because your account can give it back — but \
            these can't come back yet, so this device will keep everything instead. Stay signed \
            in until sync finishes, or sign out and keep the library here.
            """)
        }

        if account.state.account == nil {
            Section {
                Button {
                    signInPresented = true
                } label: {
                    Label("Sign in to sync", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("settings.signIn")
            } footer: {
                Text("Transcription Studio works without an account. Signing in keeps your transcripts and recordings in step across your devices.")
            }
        }
    }

    /// Sign-out is the one act with no way back: after `.signedOut` there is no token left to
    /// push with. So this runs a cycle first — most "unsynced" is simply a cycle that has not
    /// happened yet — and only asks when something genuinely could not be uploaded.
    private func preflightSignOut() async -> Bool {
        await sync.syncNow()
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

extension View {
    /// The sign-in sheet, presented by the same surface that shows ``AccountSection``.
    func transcriptionSignInSheet(isPresented: Binding<Bool>, account: AccountController) -> some View {
        sheet(isPresented: isPresented) {
            AccountSignInView(controller: account, appearance: TranscriptionAccountAppearance.standard)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
    }
}

/// The sync state, said out loud.
///
/// R3: an empty library and an unreachable server look identical and mean opposite things, so
/// this never infers — every line below is a state the engine reported.
struct SyncStatusRow: View {
    let sync: TranscriptionSync

    @State private var isResyncing = false

    var body: some View {
        Group {
            LabeledContent {
                Text(headline)
                    .foregroundStyle(needsAttention ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            } label: {
                Text("Sync")
            }
            .accessibilityIdentifier("settings.syncStatus")

            if sync.counted.retrying > 0 {
                LabeledContent("Waiting to upload", value: "\(sync.counted.retrying)")
            }

            // The refused half, which waiting never clears. Said separately because it is the one
            // the row used to omit: a judged entry leaves the pending set, so a queued-only count
            // reads zero for a record stranded on this device forever.
            if sync.counted.stuck > 0 {
                LabeledContent("Needs attention") {
                    Text("\(sync.counted.stuck)")
                        .foregroundStyle(.tint)
                }
            }

            if sync.blobPendingCount > 0 {
                LabeledContent("Recordings uploading", value: "\(sync.blobPendingCount)")
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
        }
    }

    private var needsAttention: Bool {
        switch sync.status {
        case .off, .idle, .syncing: false
        case .offline, .needsReauthentication, .resyncRequired, .failed: true
        }
    }
}

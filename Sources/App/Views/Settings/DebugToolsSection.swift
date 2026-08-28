#if DEBUG
import SwiftData
import SwiftUI

/// The two affordances an agent driving a Debug build needs and a launch argument cannot give it:
/// seed the library with presentable content, and put it back to empty — both from inside a
/// running app, without a relaunch.
///
/// `-TSSeedDemoLibrary` still exists and still seeds at launch; it just cannot re-seed an app that
/// is already open, which is exactly the state a walkthrough is in when it needs content.
///
/// **Both act on the signed-in account, not on a sandbox.** Seeded sessions push like any other
/// and the reset's deletes push too — which is what makes them useful (they exercise the real sync
/// path) and why they exist only in a Debug build signed into the shared test account.
///
/// Deliberately not localized: a Debug-only surface in the shipped catalog is ten translations of
/// a control no user ever sees.
struct DebugToolsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    @State private var confirmingReset = false
    @State private var lastAction: String?

    var body: some View {
        Section {
            Button {
                DemoLibrarySeeder.seed(context: modelContext)
                lastAction = "Seeded the demo library."
            } label: {
                Label { Text(verbatim: "Seed demo library") } icon: { Image(systemName: "wand.and.sparkles") }
            }
            .accessibilityIdentifier(A11yID.debugSeedLibrary)

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label { Text(verbatim: "Delete every session") } icon: { Image(systemName: "trash") }
            }
            .accessibilityIdentifier(A11yID.debugResetLibrary)

            if let lastAction {
                Text(verbatim: lastAction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.debugToolsStatus)
            }
        } header: {
            Text(verbatim: "Debug tools")
        } footer: {
            Text(verbatim: "Debug builds only. Both act on the signed-in account: seeded sessions "
                 + "upload, and deleting removes them everywhere.")
        }
        .confirmationDialog(Text(verbatim: "Delete every session on this account?"),
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(role: .destructive) { reset() } label: { Text(verbatim: "Delete Everything") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: "This deletes every transcript and recording, here and on every other "
                 + "device signed into this account.")
        }
    }

    /// Every session, through the same transaction a swipe-to-delete runs — so the recordings are
    /// released from the blob layer and Spotlight is cleaned up, rather than the store being
    /// emptied underneath them.
    private func reset() {
        let sessions = (try? modelContext.fetch(FetchDescriptor<TranscriptSession>())) ?? []
        for session in sessions {
            SessionDeletion.delete(session, in: modelContext, app: app)
        }
        lastAction = "Deleted \(sessions.count) session(s)."
    }
}
#endif

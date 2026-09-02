#if DEBUG
import FCTAccount
import FCTScreenshotStudio
import SwiftData
import SwiftUI

/// The two affordances an agent driving a Debug build needs and a launch argument cannot give it:
/// seed the library with presentable content, and put it back to empty — both from inside a
/// running app, without a relaunch.
///
/// `-TSSeedDemoLibrary` still exists and still seeds at launch; it just cannot re-seed an app that
/// is already open, which is exactly the state a walkthrough is in when it needs content.
///
/// **Both act on the detached debug store, never the account's library.** Every `TranscriptSession`
/// is a synced row: a seed pointed at the app's own store uploads each one, and a delete-everything
/// sends a tombstone per session to every device on the account. So the seed writes into a second,
/// local-only store file, the reset can only erase that file, and the toggle below is what puts
/// that store on screen.
///
/// Deliberately not localized: a Debug-only surface in the shipped catalog is ten translations of
/// a control no user ever sees.
struct DebugToolsSection: View {
    @Environment(AccountController.self) private var account
    @Environment(\.debugStoreSwitch) private var debugStore

    @State private var confirmingReset = false
    @State private var lastAction: String?
    @State private var resetRefusal: DebugResetRefusal?

    var body: some View {
        Section {
            Toggle(isOn: renderDebugStore) {
                Label { Text(verbatim: "Render debug store") } icon: { Image(systemName: "shippingbox") }
            }
            .disabled(debugStore == nil)
            .accessibilityIdentifier(A11yID.debugRenderStore)

            Button {
                seed()
            } label: {
                Label { Text(verbatim: "Seed demo library") } icon: { Image(systemName: "wand.and.sparkles") }
            }
            .accessibilityIdentifier(A11yID.debugSeedLibrary)

            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label { Text(verbatim: "Erase debug store") } icon: { Image(systemName: "trash") }
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
            Text(verbatim: "Debug builds only. Both act on a detached demo store beside the app's "
                 + "own — the account's library is a different file and is never written to. Turn "
                 + "the toggle on to see the demo library in the app.")
        }
        .confirmationDialog(Text(verbatim: "Erase the debug store?"),
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(role: .destructive) { reset() } label: { Text(verbatim: "Erase Everything") }
                .accessibilityIdentifier(A11yID.debugResetConfirm)
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: "This erases the demo store and this device's sync caches. Your "
                 + "account's own sessions are a different store and are not touched.")
        }
        .alert(
            resetRefusal?.title ?? "",
            isPresented: Binding(get: { resetRefusal != nil }, set: { if !$0 { resetRefusal = nil } }),
            presenting: resetRefusal
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { refusal in
            Text(refusal.message)
        }
    }

    /// Whether the app is rendering the detached demo store rather than the account's library.
    private var renderDebugStore: Binding<Bool> {
        Binding(
            get: { debugStore?.isEngaged ?? false },
            set: { shouldEngage in
                guard let debugStore else {
                    lastAction = DebugStoreSwitch.missingSwitchMessage
                    return
                }
                guard shouldEngage else {
                    debugStore.disengage()
                    lastAction = "Rendering the account's own library."
                    return
                }
                do {
                    try debugStore.engage()
                    lastAction = "Rendering the detached debug store."
                } catch {
                    lastAction = "Debug store unavailable: \(error.localizedDescription)"
                }
            }
        )
    }

    private func seed() {
        guard let debugStore else {
            lastAction = DebugStoreSwitch.missingSwitchMessage
            return
        }
        do {
            DemoLibrarySeeder.seed(context: try debugStore.detachedContainer().mainContext)
            lastAction = "Seeded the demo library into the detached store."
        } catch {
            lastAction = "Debug store unavailable: \(error.localizedDescription)"
        }
    }

    /// Erases the demo store and the caches named with it, and refuses while an account is signed
    /// in — a reset underneath a live engine and a live session is a state nothing downstream is
    /// built to survive.
    private func reset() {
        guard let debugStore else {
            lastAction = DebugStoreSwitch.missingSwitchMessage
            return
        }
        let caches = [
            try? AppModelContainer.syncStateFileURL(),
            try? AppModelContainer.blobStateFileURL(),
            try? AppModelContainer.blobCacheDirectory(),
        ].compactMap { $0 }
        do {
            try DebugReset.perform(debugStore, isSignedIn: account.state.isSignedIn, localCaches: caches)
            lastAction = "Erased the debug store."
        } catch let refusal as DebugResetRefusal {
            resetRefusal = refusal
        } catch {
            lastAction = "Erase failed: \(error.localizedDescription)"
        }
    }
}
#endif

import SwiftUI

/// The Mac shell: the shared single-view home with the Mac-only capabilities switched on
/// (URL ingest, ScreenCaptureKit meeting capture). Keyboard shortcuts live in `AppCommands`
/// on the scene.
struct MacRootView: View {
    init() {}

    var body: some View {
        StudioHomeView(capabilities: .init(meetingCapture: true))
    }
}

/// Scene commands: ⌘N new recording, ⌘L back to the feed, ⌘I inspector, ⌘, settings.
struct AppCommands: Commands {
    let app: AppModel

    init(app: AppModel) { self.app = app }

    var body: some Commands {
        // Replace the default "New Window" (⌘N) so ⌘N starts a recording, per the app's shell.
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                app.requestRecording(mode: .room)
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier(A11yID.commandNewRecording)
        }
        // Settings is a sheet over the home view (not a Settings scene), so ⌘, is wired here.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.activeSheet = .settings }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityIdentifier(A11yID.commandSettings)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Sessions") { app.returnHome() }
                .keyboardShortcut("l", modifiers: .command)
                .accessibilityIdentifier(A11yID.commandShowSessions)
            Button(app.activeSheet == .inspector ? "Hide Inspector" : "Show Inspector") {
                app.activeSheet = app.activeSheet == .inspector ? nil : .inspector
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .accessibilityIdentifier(A11yID.commandToggleInspector)
            Divider()
        }
    }
}

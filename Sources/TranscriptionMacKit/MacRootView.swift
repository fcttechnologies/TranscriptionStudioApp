import SwiftUI
import TranscriptionKit

/// The Mac shell: the shared single-view home with the Mac-only capabilities switched on
/// (URL ingest, ScreenCaptureKit meeting capture). Keyboard shortcuts live in `AppCommands`
/// on the scene.
public struct MacRootView: View {
    public init() {}

    public var body: some View {
        StudioHomeView(capabilities: .init(urlIngest: true, meetingCapture: true))
    }
}

/// Scene commands: ⌘N new recording, ⌘L back to the feed, ⌘I inspector, ⌘, settings.
public struct AppCommands: Commands {
    let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var body: some Commands {
        // Replace the default "New Window" (⌘N) so ⌘N starts a recording, per the app's shell.
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                app.requestRecording(mode: .room)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        // Settings is a sheet over the home view (not a Settings scene), so ⌘, is wired here.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.activeSheet = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Sessions") { app.returnHome() }
                .keyboardShortcut("l", modifiers: .command)
            Button(app.activeSheet == .inspector ? "Hide Inspector" : "Show Inspector") {
                app.activeSheet = app.activeSheet == .inspector ? nil : .inspector
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}

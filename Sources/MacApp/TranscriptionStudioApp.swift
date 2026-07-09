import SwiftUI
import SwiftData
import TranscriptionKit
import TranscriptionMacKit

@main
struct TranscriptionStudioApp: App {
    @State private var app = AppModel.live()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(app)
                .task { app.seedSampleSessionIfNeeded() }
        }
        .modelContainer(AppModelContainer.shared)
        .defaultSize(width: 1140, height: 740)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

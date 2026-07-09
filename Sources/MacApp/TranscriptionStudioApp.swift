import SwiftUI
import SwiftData
import TranscriptionKit
import TranscriptionMacKit

@main
struct TranscriptionStudioApp: App {
    @State private var app = AppModel.live(captureFactory: { mode, sessionID, recorder in
        switch mode {
        case .room:
            [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
                   tracks: [.mixed])]
        case .meeting:
            // One ScreenCaptureKit stream carries both tracks on a shared clock.
            [.init(source: MeetingCaptureSource(sessionID: sessionID, recorder: recorder),
                   tracks: [.microphone, .system])]
        }
    })

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

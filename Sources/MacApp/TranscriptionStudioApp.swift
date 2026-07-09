import SwiftUI
import SwiftData
import TranscriptionKit
import TranscriptionMacKit

@main
struct TranscriptionStudioApp: App {
    var body: some Scene {
        WindowGroup {
            MacRootView()
        }
        .modelContainer(AppModelContainer.shared)
    }
}

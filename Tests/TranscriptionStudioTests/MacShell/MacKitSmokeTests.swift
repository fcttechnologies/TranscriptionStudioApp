import Testing
@testable import TranscriptionStudio

@Suite("MacKit smoke")
@MainActor
struct MacKitSmokeTests {
    // The target links and its root view type exists.
    @Test func rootViewExists() {
        _ = MacRootView()
    }
}

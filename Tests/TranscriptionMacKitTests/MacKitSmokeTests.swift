import Testing
@testable import TranscriptionMacKit

@Suite("MacKit smoke")
struct MacKitSmokeTests {
    // The target links and its root view type exists (real tests land with Lanes A/B).
    @Test func rootViewExists() {
        _ = MacRootView()
    }
}

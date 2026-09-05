// The Mac studio's window content. A separate view because a `Scene` body cannot inject an
// environment, and this window sits outside the app's own root: its scenes are the app's real
// views, so they need the demo store on both seams — the container they render from and the
// `AppModel` they write through — which is the only store the studio may touch.
#if DEBUG && os(macOS)
import FCTScreenshotStudio
import SwiftUI

/// The studio window's id, shared by the `Window` scene and the Settings row that opens it. It
/// lives beside the window rather than on the app struct because the `transcribe-cli` target
/// compiles these sources without the `@main` file, and a Settings row naming a constant declared
/// there fails to compile in that target alone.
enum ScreenshotStudioWindow {
    static let id = "transcriptionStudio.screenshotStudio"
}

struct ScreenshotStudioWindowContent: View {
    var body: some View {
        ScreenshotStudioMacView(scenes: ScreenshotStudioCatalog.scenes) { context in
            DemoLibrarySeeder.seed(context: context)
        }
        .environment(\.debugDemoStore, TranscriptionDebugStore.demo)
        .modelContainer(TranscriptionDebugStore.container)
        .environment(TranscriptionDebugStore.appModel)
    }
}
#endif

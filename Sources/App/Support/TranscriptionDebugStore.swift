#if DEBUG
import FCTScreenshotStudio
import Foundation
import SwiftData

/// Transcription Studio's detached debug store: the second, local-only file every debug seed and
/// reset acts on, so nothing under `#if DEBUG` can reach the signed-in account's library.
///
/// Two things point at it, not one. Reads come out of the `ModelContainer` a studio scene carries,
/// which is what `DebugDemoStore` holds; writes go through ``AppModel``, which carries a
/// `ModelContext` of its own that no container in the environment reaches. A scene rendering the
/// demo store with `AppModel` still on the app's own would show demo rows over real writes — so
/// the pairing lives here, and `studioStore()` applies both together.
@MainActor
enum TranscriptionDebugStore {
    /// The detached store the debug tools seed into and the debug reset erases.
    static let demo = DebugDemoStore(store: AppModelContainer.configuration)

    /// The `AppModel` a studio scene writes through, over the same container the scene renders —
    /// `renderContainer`, so an unopenable demo store falls to an empty stand-in rather than to
    /// the account's library.
    ///
    /// Its engines are the mock stack rather than the routed recognizer: a scene photographs saved
    /// transcripts, and building the real engine here would load a speech model to render a screen
    /// that never asks one a question.
    static let appModel = AppModel(modelContext: ModelContext(demo.renderContainer))
}
#endif

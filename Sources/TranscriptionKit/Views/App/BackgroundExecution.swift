import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Runs `work` in a Task, holding a `UIApplication` background-task assertion for its duration on
/// iOS so it keeps running briefly after the app is backgrounded. iOS *bounds* that window (a few
/// minutes — enough to finish short/medium transcriptions); a very long job still needs the app
/// open, because iOS grants no unbounded background compute outside the audio/download modes. The
/// expiration handler ends the assertion cleanly so the app is never terminated for overrunning.
/// A plain passthrough on macOS (no such limit there).
enum BackgroundExecution {
    static func running(_ name: String, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task {
            #if canImport(UIKit)
            let token = BackgroundTaskToken()
            await token.begin(name)
            await work()
            await token.end()
            #else
            await work()
            #endif
        }
    }
}

#if canImport(UIKit)
@MainActor
private final class BackgroundTaskToken {
    private var id: UIBackgroundTaskIdentifier = .invalid
    func begin(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif

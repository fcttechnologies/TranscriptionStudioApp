#if os(iOS)
import UIKit

/// The one UIKit seam the app needs: when the speech models' background `URLSession` finishes
/// its transfers while the app is not running, iOS relaunches the app and hands it this
/// completion handler, which the session calls back once it has delivered every event. Nothing
/// else lives here.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == SpeechModelDownloader.sessionIdentifier else { completionHandler(); return }
        let handler = UncheckedSendableBox(completionHandler)
        Task { @MainActor in
            SpeechModelDownloader.shared.handleEvents { handler.value() }
        }
    }
}

/// A non-Sendable closure carried across an actor hop it is only ever invoked from, once.
private struct UncheckedSendableBox: @unchecked Sendable {
    let value: () -> Void
    init(_ value: @escaping () -> Void) { self.value = value }
}
#endif

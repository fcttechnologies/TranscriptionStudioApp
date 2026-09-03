import AppIntents
import SwiftUI
import WidgetKit

/// "Dictate" in Control Center, on the Lock Screen, and on the Action button — the surface a
/// dictation is actually used from, because it is reachable without finding the app first.
///
/// The button rides `OpenDictationIntent`, whose `.foreground` mode sends it to the app process:
/// the extension never opens a microphone, which is what keeps `perform()` short enough to return
/// before the system re-queries the control.
struct DictateControl: ControlWidget {
    static let kind = "com.fcttechnologies.TranscriptionStudio.Dictate"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenDictationIntent()) {
                Label("Dictate", systemImage: "mic")
            }
        }
        .displayName("Dictate")
        .description("Speak a note and get clean text back.")
    }
}

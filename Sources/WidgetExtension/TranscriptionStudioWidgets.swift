import SwiftUI
import WidgetKit

/// The widget extension's entry point — the two Live Activities (recording + playback).
/// Home-screen widgets, when they come, join this bundle.
@main
struct TranscriptionStudioWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        PlaybackLiveActivity()
    }
}

/// mm:ss (h:mm:ss past an hour) for a static timestamp — the paused clock and duration labels.
/// (The running clocks are self-advancing timer texts; this mirrors the app's `TimeFormat`,
/// which lives in the heavy kit this extension can't link.)
func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// A running elapsed clock pinned to a max width per magnitude tier, so the growing digits
/// never shift the layout around them (the VillainArc width-capping idiom).
struct ElapsedTimerText: View {
    let anchor: Date
    var font: Font = .title2
    /// (under 10 min, 10 min–1 hr, 1 hr+)
    var widths: (base: CGFloat, tenMinute: CGFloat, hour: CGFloat) = (60, 72, 92)

    var body: some View {
        let elapsed = Date.now.timeIntervalSince(anchor)
        let maxWidth = elapsed >= 3_600 ? widths.hour : (elapsed >= 600 ? widths.tenMinute : widths.base)
        Text(anchor, style: .timer)
            .font(font.weight(.semibold))
            .fontDesign(.rounded)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: maxWidth, alignment: .trailing)
    }
}

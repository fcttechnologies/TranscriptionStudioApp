import Foundation
import SwiftUI

/// The design-token sheet. The convention: **no magic numbers in views** — every spacing,
/// size, corner radius, duration, and tuning value lives here so the look is adjustable in
/// one place. Group constants by surface; add groups as surfaces land.
public enum DesignMetrics {
    // MARK: Global rhythm
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 16
    public static let spacingXL: CGFloat = 24
    public static let spacingXXL: CGFloat = 40

    public static let cornerS: CGFloat = 8
    public static let cornerM: CGFloat = 12
    public static let cornerL: CGFloat = 16
    public static let cornerXL: CGFloat = 22

    /// Minimum hit target (HIG).
    public static let hitTarget: CGFloat = 44

    // MARK: Motion (see motion-craft: UI under 300ms, springs critically damped by default)
    public static let pressFeedbackDuration: Double = 0.16
    /// General UI transitions — graceful, no bounce.
    public static let standardSpring = Animation.spring(duration: 0.35, bounce: 0)
    /// Snappier settle for menus, toggles, small state changes.
    public static let snappySpring = Animation.spring(duration: 0.22, bounce: 0)
    /// A little momentum — only for gesture-released / arrival motion.
    public static let arrivalSpring = Animation.spring(duration: 0.4, bounce: 0.18)
    /// Live-value follow (level meter, auto-scroll): quick but smooth, interruptible.
    public static let liveFollowSpring = Animation.spring(duration: 0.28, bounce: 0)
    /// Group-entrance stagger step (motion-craft: 30–80ms).
    public static let staggerStep: Double = 0.045

    // MARK: Surfaces
    /// Inset ring width on the dark-mode card seam (VillainArc idiom).
    public static let surfaceRingWidth: CGFloat = 0.5
    public static let cardShadowRadius: CGFloat = 10
    public static let cardShadowY: CGFloat = 4
    public static let cardShadowOpacity: Double = 0.10

    // MARK: Transcript
    /// Per-speaker accent colors (speaker 0–3). Semantic system colors elsewhere.
    public static let speakerPalette: [Color] = [.blue, .orange, .purple, .teal]
    public static let meColor: Color = .green
    public static let unknownColor: Color = .gray

    public static let turnSpacing: CGFloat = 14
    public static let turnAccentWidth: CGFloat = 3
    public static let turnCorner: CGFloat = 10
    public static let speakerChipVPadding: CGFloat = 3
    public static let speakerChipHPadding: CGFloat = 8
    /// Provisional (still-revisable) transcript opacity floor.
    public static let provisionalOpacity: Double = 0.55
    /// Karaoke playback: how far non-playing lines recede while a line is lit.
    public static let karaokeRecededOpacity: Double = 0.45
    /// The detail playback bar's central play/pause control.
    public static let playControlSize: CGFloat = 52
    /// How long after a manual scroll the karaoke auto-follow stays out of the way.
    public static let karaokeFollowResumeDelay: TimeInterval = 4
    public static let shimmerDuration: Double = 1.3
    public static let shimmerHighlightOpacity: Double = 0.85
    public static let shimmerMinBandWidth: CGFloat = 40

    /// Confidence → visual affordance. Low confidence reads as a lighter, dotted underline.
    public static let confidenceUnderlineOpacityHigh: Double = 0.0
    /// Below this attribution confidence, a segment gets a "check this" affordance.
    public static let lowConfidenceThreshold: Float = 0.55

    // MARK: Suggestion chips (the detail view's "Suggested" row)
    public static let suggestionChipVPadding: CGFloat = 7
    public static let suggestionChipHPadding: CGFloat = 12
    /// The chip's item text truncates past this, so one long title can't swallow the row.
    public static let suggestionDetailMaxWidth: CGFloat = 190
    /// The per-chip dismiss glyph's tap frame (small by design — a secondary affordance).
    public static let suggestionDismissTarget: CGFloat = 24

    // MARK: Level meter
    public static let levelMeterBarCount = 5
    public static let levelMeterBarWidth: CGFloat = 4
    public static let levelMeterBarSpacing: CGFloat = 3
    public static let levelMeterHeight: CGFloat = 34
    public static let levelMeterCorner: CGFloat = 2
    /// Meter ballistics: fast attack, slow release (peak-hold feel).
    public static let levelAttack: Float = 0.55
    public static let levelRelease: Float = 0.14
    public static let levelMeterFloorDB: Float = -50

    // MARK: Waveform (live scrolling capture trace)
    public static let waveformHeight: CGFloat = 56
    public static let waveformBarWidth: CGFloat = 2.5
    public static let waveformBarSpacing: CGFloat = 1.5
    public static let waveformSampleCount = 90
    public static let waveformMinBarFraction: CGFloat = 0.06

    // MARK: Record surface
    public static let recordControlSize: CGFloat = 64
    public static let recordGlyphSize: CGFloat = 24
    public static let elapsedFont: CGFloat = 34
    public static let modeCardCorner: CGFloat = 14

    // MARK: Job cards
    public static let jobCardCorner: CGFloat = 14
    public static let jobStepDotSize: CGFloat = 7
    public static let jobStepConnectorWidth: CGFloat = 2
    public static let jobProgressHeight: CGFloat = 6

    // MARK: Home feed (the single view)
    /// The feed column's readable max width (both platforms).
    public static let feedMaxWidth: CGFloat = 640
    public static let feedRowSpacing: CGFloat = 8
    public static let feedSectionSpacing: CGFloat = 20

    // MARK: Mini-player
    public static let miniPlayerHeight: CGFloat = 56
    public static let miniPlayerWaveWidth: CGFloat = 88
    public static let miniPlayerWaveHeight: CGFloat = 26
    public static let miniPlayerTileSize: CGFloat = 36

    // MARK: Sheets
    /// Fixed macOS sheet sizes (iOS sheets are full-height by default).
    public static let macSheetSize = CGSize(width: 520, height: 620)
    public static let macDetailSheetSize = CGSize(width: 760, height: 680)

    // MARK: Toasts
    public static let toastCorner: CGFloat = 16
    public static let toastMaxWidth: CGFloat = 460

    // MARK: Inspector
    public static let inspectorWidth: CGFloat = 340
    public static let inspectorMinWidth: CGFloat = 280
    public static let inspectorMaxWidth: CGFloat = 460
    public static let heatmapRowHeight: CGFloat = 22
    public static let heatmapSpeakerCount = 4
    public static let sparklineHeight: CGFloat = 28
    public static let loadChartHeight: CGFloat = 90
    public static let eventRowVPadding: CGFloat = 5
    public static let eventDotSize: CGFloat = 6
    public static let abTimelineHeight: CGFloat = 30

    /// Pipeline-event level → accent color.
    public static func color(for level: PipelineEventLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    /// Thermal state → color (green→red pressure ramp).
    public static func color(for thermal: ProcessInfo.ThermalState) -> Color {
        switch thermal {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }

    public static func thermalLabel(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// Accent color for a resolved speaker.
    public static func color(for speaker: SpeakerID) -> Color {
        switch speaker {
        case .me: meColor
        case .speaker(let index): speakerPalette[index % speakerPalette.count]
        case .unknown: unknownColor
        }
    }

    /// Accent color for a raw diarizer slot (0–3).
    public static func speakerColor(slot: Int) -> Color {
        speakerPalette[max(0, slot) % speakerPalette.count]
    }
}

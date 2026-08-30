import Foundation
import SwiftUI

/// The design-token sheet. The convention: **no magic numbers in views** — every spacing,
/// size, corner radius, duration, and tuning value lives here so the look is adjustable in
/// one place. Group constants by surface; add groups as surfaces land.
enum DesignMetrics {
    // MARK: Global rhythm
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let spacingXXL: CGFloat = 40

    static let cornerS: CGFloat = 8
    static let cornerM: CGFloat = 12
    static let cornerL: CGFloat = 16
    static let cornerXL: CGFloat = 22

    /// Minimum hit target (HIG).
    static let hitTarget: CGFloat = 44

    // MARK: Motion (see motion-craft: UI under 300ms, springs critically damped by default)
    static let pressFeedbackDuration: Double = 0.16
    /// General UI transitions — graceful, no bounce.
    static let standardSpring = Animation.spring(duration: 0.35, bounce: 0)
    /// Snappier settle for menus, toggles, small state changes.
    static let snappySpring = Animation.spring(duration: 0.22, bounce: 0)
    /// A little momentum — only for gesture-released / arrival motion.
    static let arrivalSpring = Animation.spring(duration: 0.4, bounce: 0.18)
    /// Live-value follow (level meter, auto-scroll): quick but smooth, interruptible.
    static let liveFollowSpring = Animation.spring(duration: 0.28, bounce: 0)
    /// Group-entrance stagger step (motion-craft: 30–80ms).
    static let staggerStep: Double = 0.045

    // MARK: Surfaces
    /// Hairline width of the card's seam (VillainArc idiom).
    static let surfaceRingWidth: CGFloat = 0.5
    /// The card seam's hairline opacity — laid over the fill as white in dark mode and black in
    /// light, so a card carries its own edge on any background. Matches the system separator.
    static let surfaceSeamOpacity: Double = 0.10
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowY: CGFloat = 4
    static let cardShadowOpacity: Double = 0.10

    // MARK: Transcript
    /// Per-speaker accent colors (speaker 0–3). Semantic system colors elsewhere.
    static let speakerPalette: [Color] = [.blue, .orange, .purple, .teal]
    static let meColor: Color = .green
    static let unknownColor: Color = .gray

    static let turnSpacing: CGFloat = 14
    static let turnAccentWidth: CGFloat = 3
    static let turnCorner: CGFloat = 10
    static let speakerChipVPadding: CGFloat = 3
    static let speakerChipHPadding: CGFloat = 8
    /// Provisional (still-revisable) transcript opacity floor.
    static let provisionalOpacity: Double = 0.55
    /// Karaoke playback: how far non-playing lines recede while a line is lit.
    static let karaokeRecededOpacity: Double = 0.45
    /// The detail playback bar's central play/pause control.
    static let playControlSize: CGFloat = 52
    /// How long after a manual scroll the karaoke auto-follow stays out of the way.
    static let karaokeFollowResumeDelay: TimeInterval = 4
    static let shimmerDuration: Double = 1.3
    static let shimmerHighlightOpacity: Double = 0.85
    static let shimmerMinBandWidth: CGFloat = 40

    /// Confidence → visual affordance. Low confidence reads as a lighter, dotted underline.
    static let confidenceUnderlineOpacityHigh: Double = 0.0
    /// Below this attribution confidence, a segment gets a "check this" affordance.
    static let lowConfidenceThreshold: Float = 0.55

    // MARK: Suggestion chips (the detail view's "Suggested" row)
    static let suggestionChipVPadding: CGFloat = 7
    static let suggestionChipHPadding: CGFloat = 12
    /// The chip's item text truncates past this, so one long title can't swallow the row.
    static let suggestionDetailMaxWidth: CGFloat = 190
    /// The per-chip dismiss glyph's tap frame (small by design — a secondary affordance).
    static let suggestionDismissTarget: CGFloat = 24

    // MARK: Level meter
    static let levelMeterBarCount = 5
    static let levelMeterBarWidth: CGFloat = 4
    static let levelMeterBarSpacing: CGFloat = 3
    static let levelMeterHeight: CGFloat = 34
    static let levelMeterCorner: CGFloat = 2
    /// Meter ballistics: fast attack, slow release (peak-hold feel).
    static let levelAttack: Float = 0.55
    static let levelRelease: Float = 0.14
    static let levelMeterFloorDB: Float = -50

    // MARK: Waveform (live scrolling capture trace)
    static let waveformHeight: CGFloat = 56
    static let waveformBarWidth: CGFloat = 2.5
    static let waveformBarSpacing: CGFloat = 1.5
    static let waveformSampleCount = 90
    static let waveformMinBarFraction: CGFloat = 0.06

    // MARK: Record surface
    static let recordControlSize: CGFloat = 64
    static let recordGlyphSize: CGFloat = 24
    static let elapsedFont: CGFloat = 34
    static let modeCardCorner: CGFloat = 14

    // MARK: Job cards
    static let jobCardCorner: CGFloat = 14
    static let jobStepDotSize: CGFloat = 7
    static let jobStepConnectorWidth: CGFloat = 2
    static let jobProgressHeight: CGFloat = 6

    // MARK: Home feed (the single view)
    /// The feed column's readable width. A fixed cap strands the column on a wide Mac window —
    /// at 1760pt it reads as a phone layout centred in a desert — so the column grows with its
    /// container between two bounds: `feedMinWidth` is what a session card needs to hold its
    /// title and metadata comfortably, `feedMaxWidth` is where a list of cards stops reading as
    /// a column and starts reading as a table.
    static let feedMinWidth: CGFloat = 640
    static let feedMaxWidth: CGFloat = 900
    static let feedWidthFraction: CGFloat = 0.62
    static let feedRowSpacing: CGFloat = 8
    static let feedSectionSpacing: CGFloat = 20

    /// The feed column's width inside a container of `width`. Never wider than the container
    /// itself, so a narrow window fills rather than clips.
    static func feedWidth(forContainer width: CGFloat) -> CGFloat {
        min(width, min(max(width * feedWidthFraction, feedMinWidth), feedMaxWidth))
    }

    /// The transcript's prose column inside the detail sheet — a reading measure, unrelated to
    /// the feed's card column.
    static let transcriptMaxWidth: CGFloat = 760
    /// The playback control bar's width. Deliberately narrower than the transcript it floats
    /// over: a control cluster reads as one by not spanning the text.
    static let playbackBarMaxWidth: CGFloat = 640
    /// How far a scrolling surface's content dissolves at an edge instead of being cut.
    static let scrollFadeLength: CGFloat = 28

    // MARK: Mini-player
    static let miniPlayerHeight: CGFloat = 56
    static let miniPlayerWaveWidth: CGFloat = 88
    static let miniPlayerWaveHeight: CGFloat = 26
    static let miniPlayerTileSize: CGFloat = 36

    // MARK: Sheets
    /// Fixed macOS sheet sizes (iOS sheets are full-height by default). Settings is sized to the
    /// tallest of its panes rather than to the sum of every section, which is what the one-column
    /// Form used to demand.
    static let macSheetSize = CGSize(width: 620, height: 640)
    static let macDetailSheetSize = CGSize(width: 760, height: 680)

    // MARK: Inspector
    static let inspectorWidth: CGFloat = 340
    static let inspectorMinWidth: CGFloat = 280
    static let inspectorMaxWidth: CGFloat = 460
    static let heatmapRowHeight: CGFloat = 22
    static let heatmapSpeakerCount = 4
    static let sparklineHeight: CGFloat = 28
    static let loadChartHeight: CGFloat = 90
    static let eventRowVPadding: CGFloat = 5
    static let eventDotSize: CGFloat = 6
    static let abTimelineHeight: CGFloat = 30

    /// Pipeline-event level → accent color.
    static func color(for level: PipelineEventLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    /// Thermal state → color (green→red pressure ramp).
    static func color(for thermal: ProcessInfo.ThermalState) -> Color {
        switch thermal {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }

    static func thermalLabel(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// Accent color for a resolved speaker.
    static func color(for speaker: SpeakerID) -> Color {
        switch speaker {
        case .me: meColor
        case .speaker(let index): speakerPalette[index % speakerPalette.count]
        case .unknown: unknownColor
        }
    }

    /// Accent color for a raw diarizer slot (0–3).
    static func speakerColor(slot: Int) -> Color {
        speakerPalette[max(0, slot) % speakerPalette.count]
    }
}

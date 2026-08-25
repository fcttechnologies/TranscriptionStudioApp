import SwiftUI

/// The speaker attribution pill shown above a transcript turn — a colored dot plus the
/// speaker's display name, tinted by the speaker's palette color. Compact and legible.
struct SpeakerChip: View {
    let speaker: SpeakerID
    var confidence: Float?

    init(speaker: SpeakerID, confidence: Float? = nil) {
        self.speaker = speaker
        self.confidence = confidence
    }

    private var color: Color { DesignMetrics.color(for: speaker) }

    var body: some View {
        HStack(spacing: DesignMetrics.spacingXS) {
            Circle()
                .fill(color)
                .frame(width: DesignMetrics.eventDotSize, height: DesignMetrics.eventDotSize)
            Text(speaker.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            if let confidence, confidence < DesignMetrics.lowConfidenceThreshold, speaker != .unknown {
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Low confidence attribution")
            }
        }
        .padding(.vertical, DesignMetrics.speakerChipVPadding)
        .padding(.horizontal, DesignMetrics.speakerChipHPadding)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(speaker.displayName))
    }
}

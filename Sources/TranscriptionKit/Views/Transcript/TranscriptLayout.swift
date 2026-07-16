import Foundation

/// How the detail view lays a stored transcript out — the Voice Memos rule: speaker structure
/// appears only when there's more than one voice to distinguish.
public enum TranscriptLayoutMode: Equatable, Sendable {
    /// One voice (or none identified): flat paragraphs, no speaker labels or accent bars.
    case flat
    /// Multiple voices: grouped speaker blocks with the colored label + leading accent bar.
    case grouped

    /// Grouped iff the turns carry more than one distinct speaker. `.unknown` counts as a
    /// speaker only alongside others — a transcript that is *entirely* unattributed reads as
    /// one voice, but a mix of attributed and unattributed blocks needs the labels to stay
    /// honest about which is which.
    public static func decide(turns: [TranscriptTurn]) -> TranscriptLayoutMode {
        Set(turns.map(\.speaker)).count > 1 ? .grouped : .flat
    }
}

/// Maps the live playhead to the currently-playing line — the pure core `PlayheadTracker`
/// drives on every tick.
public enum PlayheadMapper {
    /// Lines are treated as playing a hair before their stamped start, so a tap-to-seek that
    /// lands exactly on a boundary lights the tapped line, not its predecessor.
    public static let tolerance: TimeInterval = 0.05

    /// The id of the last line whose start is at or before `time` (within tolerance) —
    /// nil before the first line.
    public static func lineID(at time: TimeInterval,
                              lineStarts: [(id: String, start: TimeInterval)]) -> String? {
        lineStarts.last(where: { $0.start <= time + tolerance })?.id
    }
}

import Foundation

/// The bridge between a raw `StoredSegment.speakerSlot` (Int) and the `SpeakerID` display vocabulary,
/// plus which slots in a session can be named. Pure — testable without SwiftData beyond a session.
public enum SpeakerLabels {
    /// The `SpeakerID` for a raw slot: -1 = me, 0…n = a diarized speaker, anything else = unknown.
    public static func speaker(forSlot slot: Int) -> SpeakerID {
        switch slot {
        case -1: .me
        case 0...: .speaker(slot)
        default: .unknown
        }
    }

    /// The display name for a raw slot ("Me", "Speaker 2").
    public static func name(forSlot slot: Int) -> String {
        speaker(forSlot: slot).displayName
    }

    /// The distinct, namable speaker slots present in a session's segments — me + diarized speakers,
    /// unknown excluded — ordered me-first then ascending.
    @MainActor
    public static func assignableSlots(in session: TranscriptSession) -> [Int] {
        let slots = Set((session.segments ?? []).map(\.speakerSlot)).filter { $0 >= -1 }
        return slots.sorted()
    }
}

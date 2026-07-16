#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only: seed a small, realistic library when launched with `-TSSeedDemoLibrary`
/// (simulator screenshots, agent-driven E2E, design review). Two sessions cover the detail
/// view's two layouts — a multi-speaker meeting (grouped blocks) and a single-voice memo
/// (flat paragraphs) — each with synthesized, genuinely playable audio so the transport,
/// karaoke highlight and Live Activity paths all run for real. Idempotent: only an empty
/// library is seeded.
public enum DemoLibrarySeeder {
    public static let launchArgument = "-TSSeedDemoLibrary"

    @MainActor
    public static func seedIfRequested(context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        guard ((try? context.fetchCount(FetchDescriptor<TranscriptSession>())) ?? 0) == 0 else { return }

        context.insert(meetingSession())
        context.insert(memoSession())
        try? context.save()
    }

    // MARK: The two sessions

    private static func meetingSession() -> TranscriptSession {
        let session = TranscriptSession(title: "Kickoff — Rivera Dental rebuild", kind: .meetingRecording)
        let lines: [(SpeakerID, TimeInterval, String)] = [
            (.me, 0.4, "Alright, we're on. The goal today is scope — what actually ships in the first release."),
            (.me, 6.1, "I want the booking flow live before we touch the gallery."),
            (.speaker(0), 11.8, "Agreed on booking first. The current form drops about a third of submissions on mobile."),
            (.speaker(0), 18.9, "If we fix nothing else this quarter, that alone pays for the project."),
            (.speaker(1), 24.6, "Design-wise I'd keep the palette from the sign refresh — the teal reads well on the door and it should carry to the site."),
            (.me, 31.2, "Fine by me. Can we get the photography scheduled before the twenty-third?"),
            (.speaker(1), 35.9, "The photographer has Thursday morning open. I'll confirm by end of day."),
            (.speaker(0), 40.7, "Then let's lock it: booking flow, new home page, photography Thursday. Gallery slips to phase two."),
            (.me, 46.5, "Locked. I'll send the recap and the revised timeline tonight."),
        ]
        fill(session, lines: lines, duration: 52)
        // Highlights as the FM pass would leave them, so the Suggested row and the confirm
        // sheets show real content in the demo library.
        session.events = [TranscriptEvent(title: "Photography session",
                                          dateText: "Thursday morning",
                                          date: upcoming(weekday: 5, hour: 9))]
        session.actionItems = [
            TranscriptActionItem(task: "Send the recap and the revised timeline",
                                 owner: "Me", dueDateText: "tonight",
                                 dueDate: upcoming(hour: 20)),
        ]
        session.highlightsStatus = .ready
        return session
    }

    private static func memoSession() -> TranscriptSession {
        let session = TranscriptSession(title: "Route notes — Tuesday walk-ins", kind: .roomRecording)
        let lines: [(SpeakerID, TimeInterval, String)] = [
            (.speaker(0), 0.5, "Three stops worth writing down before I forget."),
            (.speaker(0), 4.8, "The bakery on Fifth wants the menu board quote in writing — owner's name is Marisol, she's in Tuesdays and Thursdays."),
            (.speaker(0), 13.2, "The auto shop said call back after the fifteenth when their season slows down. Don't push before that."),
            (.speaker(0), 20.9, "And the print shop already has a site but their hours are wrong everywhere — that's the opener next visit."),
            (.speaker(0), 28.4, "Follow-ups go out tomorrow morning, bakery first."),
        ]
        fill(session, lines: lines, duration: 34)
        session.actionItems = [
            TranscriptActionItem(task: "Send the bakery the menu board quote in writing",
                                 owner: "Me", dueDateText: "tomorrow morning",
                                 dueDate: upcoming(hour: 9, dayOffset: 1)),
        ]
        session.people = [TranscriptPerson(name: "Marisol")]
        session.highlightsStatus = .ready
        return session
    }

    /// The next occurrence of `hour` (optionally on `weekday`, optionally starting `dayOffset`
    /// days out) — keeps the demo's suggested dates believably in the future on any run day.
    private static func upcoming(weekday: Int? = nil, hour: Int, dayOffset: Int = 0) -> Date? {
        let from = Calendar.current.date(byAdding: .day, value: dayOffset, to: .now) ?? .now
        var components = DateComponents(hour: hour)
        components.weekday = weekday
        return Calendar.current.nextDate(after: from, matching: components,
                                         matchingPolicy: .nextTime)
    }

    private static func fill(_ session: TranscriptSession,
                             lines: [(speaker: SpeakerID, start: TimeInterval, text: String)],
                             duration: TimeInterval) {
        session.status = .complete
        session.duration = duration
        session.fullText = lines.map(\.text).joined(separator: " ")
        session.audioData = wavData(duration: duration)
        var segments: [StoredSegment] = []
        for (index, line) in lines.enumerated() {
            let end = index + 1 < lines.count ? lines[index + 1].start - 0.2 : duration
            let segment = StoredSegment(start: line.start, end: end, text: line.text)
            segment.speaker = line.speaker
            segment.speakerConfidence = 0.92
            // Confident, clean speech — so the demo doesn't wear the low-confidence
            // underline on every line.
            segment.avgLogprob = -0.05
            segment.noSpeechProb = 0.01
            segment.compressionRatio = 1.4
            segments.append(segment)
        }
        session.segments = segments
    }

    // MARK: Playable audio (a quiet, speech-paced tone bed — WAV, so AVAudioPlayer takes it)

    private static func wavData(duration: TimeInterval,
                                sampleRate: Int = 16_000) -> Data {
        let frameCount = Int(duration * Double(sampleRate))
        var pcm = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            // A low tone, amplitude-modulated on a syllable-ish rhythm with pauses — enough
            // life for the level meters without being unpleasant to actually play.
            let cadence = max(0, sin(t * 2.6)) * (0.6 + 0.4 * sin(t * 13))
            let sample = sin(t * 2 * .pi * 180) * 0.18 * cadence
            let value = Int16(max(-1, min(1, sample)) * 32_760)
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return wavFile(pcm: pcm, sampleRate: sampleRate)
    }

    private static func wavFile(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
#endif

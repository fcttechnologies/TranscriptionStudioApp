#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only: seed a realistic library when launched with `-TSSeedDemoLibrary` (simulator
/// screenshots, agent-driven E2E, design review) or from the debug tools, which is also what the
/// Screenshot Studio's scenes render.
///
/// The two hero sessions cover the detail view's two layouts — a multi-speaker meeting (grouped
/// blocks) and a single-voice memo (flat paragraphs) — each with synthesized, genuinely playable
/// audio so the transport, karaoke highlight and Live Activity paths all run for real. The rest
/// are the library around them: spread across a week so the feed sections by day, in every kind
/// the app records, because a feed holding one row photographs as an empty product.
///
/// `seedIfRequested` is idempotent (only an empty library is seeded); the affordance is not.
enum DemoLibrarySeeder {
    static let launchArgument = "-TSSeedDemoLibrary"

    /// The multi-speaker session the transcript and calendar scenes point at, by title.
    static let heroMeetingTitle = "Kickoff — Rivera Dental rebuild"

    @MainActor
    static func seedIfRequested(context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        guard ((try? context.fetchCount(FetchDescriptor<TranscriptSession>())) ?? 0) == 0 else { return }
        seed(context: context)
    }

    /// Seed unconditionally — the Settings affordance, which a running app reaches and a launch
    /// argument cannot. Not idempotent on purpose: an agent asking for content a second time wants
    /// content, and the reset beside it is how the library gets emptied.
    @MainActor
    static func seed(context: ModelContext) {
        context.insert(meetingSession())
        context.insert(memoSession())
        for session in librarySessions() { context.insert(session) }
        try? context.save()
    }

    // MARK: The library around the two heroes

    /// Six more finished sessions, dated back across the week so the feed groups them under
    /// several day headers. No audio: the transport is the hero sessions' job, and a megabyte of
    /// synthesized WAV per row buys a screenshot nothing.
    private static func librarySessions() -> [TranscriptSession] {
        [
            filled(
                title: "Pricing call — Northside Auto",
                kind: .meetingRecording,
                daysAgo: 1, hour: 15,
                lines: [
                    (.me, 0.3, "Thanks for making time. I want to walk the two options and let you pick."),
                    (.speaker(0), 5.9, "Go ahead. The board wants a number before Friday."),
                    (.me, 10.4, "Option one is the retainer — four hours a month, everything included."),
                    (.speaker(0), 16.8, "And the second one is per project?"),
                    (.me, 20.1, "Per project, with a discount if you commit to three this year."),
                    (.speaker(0), 26.3, "Send both in writing and I'll take it to the board Thursday."),
                ],
                duration: 32
            ),
            filled(
                title: "Site walk — Maple Street storefront",
                kind: .roomRecording,
                daysAgo: 1, hour: 10,
                lines: [
                    (.speaker(0), 0.4, "Standing in the doorway. The signage is the first problem — nobody can read it from the crosswalk."),
                    (.speaker(0), 8.2, "Interior lighting is warm, which is good, but the back half is dark by three in the afternoon."),
                    (.speaker(0), 16.7, "Counter placement blocks the natural path to the register. Worth moving before we photograph."),
                    (.speaker(0), 24.9, "Measure the window bay next visit — the vinyl quote depends on it."),
                ],
                duration: 31,
                locationName: "Maple Street"
            ),
            filled(
                title: "Podcast draft — episode 12 intro",
                kind: .fileTranscription,
                daysAgo: 2, hour: 9,
                lines: [
                    (.speaker(0), 0.2, "This week we're talking about the part of a rebuild nobody quotes for — the waiting."),
                    (.speaker(0), 7.5, "Every project I've shipped had a stretch where the work was done and the client wasn't ready."),
                    (.speaker(0), 15.1, "So the question is whether you build that stretch into the schedule or pretend it away."),
                    (.speaker(0), 22.4, "My answer, after four years of pretending it away, is that you build it in."),
                ],
                duration: 29
            ),
            filled(
                title: "Standup — Thursday",
                kind: .meetingRecording,
                daysAgo: 3, hour: 8,
                lines: [
                    (.me, 0.3, "Quick round. What's blocked?"),
                    (.speaker(0), 3.1, "Nothing blocked. The booking form is in review, I'll merge it this morning."),
                    (.speaker(1), 8.6, "I'm waiting on the photo selects before I can finish the home page."),
                    (.me, 13.2, "Selects come back today. Anything else goes to the parking lot."),
                    (.speaker(1), 18.0, "Then I'm clear."),
                ],
                duration: 23
            ),
            filled(
                title: "Voice memo — follow-ups before the weekend",
                kind: .roomRecording,
                daysAgo: 4, hour: 17,
                lines: [
                    (.speaker(0), 0.3, "Four things before I lose them."),
                    (.speaker(0), 3.4, "Invoice the dental group for the deposit — they asked for it itemized."),
                    (.speaker(0), 9.8, "Renew the domain that expires next month, it's on the old card."),
                    (.speaker(0), 16.2, "And call the printer back about the menu boards."),
                ],
                duration: 22
            ),
            filled(
                title: "Client interview — Harper & Sons",
                kind: .fileTranscription,
                daysAgo: 5, hour: 13,
                lines: [
                    (.me, 0.4, "Tell me how a customer finds you today."),
                    (.speaker(0), 4.2, "Word of mouth, mostly. My father ran it that way for thirty years."),
                    (.me, 10.1, "And when someone does look you up?"),
                    (.speaker(0), 13.5, "They find the map listing with the wrong hours on it. That's the whole internet as far as we're concerned."),
                    (.me, 21.7, "That's the first thing we fix, then. It costs nothing and it's costing you every week."),
                    (.speaker(0), 28.9, "That's what my daughter has been telling me."),
                ],
                duration: 35
            ),
        ]
    }

    /// One finished session: the transcript, the metadata line the feed card reads, and the day
    /// the feed sections it under.
    private static func filled(title: String,
                               kind: SessionKind,
                               daysAgo: Int,
                               hour: Int,
                               lines: [(speaker: SpeakerID, start: TimeInterval, text: String)],
                               duration: TimeInterval,
                               locationName: String? = nil) -> TranscriptSession {
        let session = TranscriptSession(title: title, kind: kind, createdAt: past(daysAgo: daysAgo, hour: hour))
        fill(session, lines: lines, duration: duration, audio: false)
        session.locationName = locationName
        session.highlightsStatus = .ready
        return session
    }

    /// A stamp `daysAgo` days back at `hour`, so the feed's day sections are stable whenever the
    /// seed is run.
    private static func past(daysAgo: Int, hour: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: hour, minute: 20, second: 0, of: day) ?? day
    }

    // MARK: The two sessions

    private static func meetingSession() -> TranscriptSession {
        let session = TranscriptSession(title: heroMeetingTitle, kind: .meetingRecording)
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
                             duration: TimeInterval,
                             audio: Bool = true) {
        session.status = .complete
        session.duration = duration
        session.fullText = lines.map(\.text).joined(separator: " ")
        if audio { session.audioData = wavData(duration: duration) }
        var segments: [StoredSegment] = []
        for (index, line) in lines.enumerated() {
            let end = index + 1 < lines.count ? lines[index + 1].start - 0.2 : duration
            let segment = StoredSegment(start: line.start, end: end, text: line.text)
            segment.speaker = line.speaker
            segment.speakerConfidence = 0.92
            // Confident, clean speech — so the demo doesn't wear the low-confidence
            // underline on every line.
            segment.avgLogprob = -0.05
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
            pcm.appendLittleEndian(value)
        }
        return wavFile(pcm: pcm, sampleRate: sampleRate)
    }

    private static func wavFile(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { data.appendLittleEndian(value) }
        func append16(_ value: UInt16) { data.appendLittleEndian(value) }
        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
#endif

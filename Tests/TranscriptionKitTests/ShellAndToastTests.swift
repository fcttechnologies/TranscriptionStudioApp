import Foundation
import Testing
@testable import TranscriptionKit

// The single-view shell's pure logic: toast queueing/dedup/sticky updates, the engine-
// prewarm → toast mapping, feed filtering + day bucketing, link validation, and the
// playback keep-alive rules the mini-player depends on.

@Suite("ToastCenter")
@MainActor
struct ToastCenterTests {

    // One toast shows at a time; a burst queues in order and advances on dismiss.
    @Test func showsOneAndQueuesTheRest() async throws {
        let center = ToastCenter()
        center.show(Toast(title: "First", systemImage: "checkmark"))
        center.show(Toast(title: "Second", systemImage: "checkmark"))
        #expect(center.current?.title == "First")
        center.dismiss()
        // The queue advances after a short gap (an unstructured ~220ms task) so out/in
        // transitions read as distinct. Poll with a deadline rather than racing that task
        // against one fixed sleep — on a loaded machine the single sleep loses.
        let deadline = ContinuousClock.now + .seconds(3)
        while center.current == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(center.current?.title == "Second")
    }

    // A dedup-keyed re-raise is dropped while its twin is showing or queued.
    @Test func dedupKeyCollapsesRepeats() {
        let center = ToastCenter()
        center.show(Toast(title: "Once", systemImage: "checkmark", dedupKey: "same"))
        center.show(Toast(title: "Again", systemImage: "checkmark", dedupKey: "same"))
        #expect(center.current?.title == "Once")
        center.dismiss()
        #expect(center.current == nil)
    }

    // showOrUpdate replaces the showing toast in place when the dedupKey matches — the
    // progress-notice update path.
    @Test func showOrUpdateReplacesInPlace() {
        let center = ToastCenter()
        center.showOrUpdate(Toast(title: "Downloading… 10%", systemImage: "waveform",
                                  duration: nil, dedupKey: "progress"))
        center.showOrUpdate(Toast(title: "Downloading… 60%", systemImage: "waveform",
                                  duration: nil, dedupKey: "progress"))
        #expect(center.current?.title == "Downloading… 60%")
    }

    // A sticky toast (nil duration) stays until resolved by its dedup key — including one
    // still sitting in the queue.
    @Test func dismissByDedupKeyResolvesShowingAndQueued() {
        let center = ToastCenter()
        center.show(Toast(title: "Busy", systemImage: "waveform", duration: nil, dedupKey: "work"))
        center.show(Toast(title: "Later", systemImage: "checkmark", dedupKey: "later"))
        center.dismiss(dedupKey: "later")   // removes the queued one
        center.dismiss(dedupKey: "work")    // resolves the showing one
        #expect(center.current == nil)
    }
}

@Suite("Engine prewarm → toasts")
@MainActor
struct EnginePrewarmToastTests {

    // Preparing raises a sticky progress notice and updates it in place.
    @Test func preparingShowsAndUpdatesProgress() {
        let center = ToastCenter()
        center.handlePrewarm(from: .idle, to: .preparing(phase: "Preparing speech model…", fraction: nil))
        #expect(center.current?.isProgress == true)
        #expect(center.current?.duration == nil)
        center.handlePrewarm(from: .preparing(phase: "Preparing speech model…", fraction: nil),
                             to: .preparing(phase: "Downloading model…", fraction: 0.4))
        #expect(center.current?.title == "Downloading model…")
        #expect(center.current?.message == "40%")
    }

    // Ready resolves the progress notice and announces — but only after a visible warmup.
    @Test func readyAfterPreparingAnnounces() {
        let center = ToastCenter()
        center.handlePrewarm(from: .idle, to: .preparing(phase: "Preparing…", fraction: nil))
        center.handlePrewarm(from: .preparing(phase: "Preparing…", fraction: nil), to: .ready)
        #expect(center.current?.style == .success)
    }

    // An instantly-ready engine (mocks, previews) never toasts.
    @Test func readyWithoutPreparingStaysQuiet() {
        let center = ToastCenter()
        center.handlePrewarm(from: .idle, to: .ready)
        #expect(center.current == nil)
    }

    // A failure resolves the progress notice and surfaces the error.
    @Test func failureSurfacesError() {
        let center = ToastCenter()
        center.handlePrewarm(from: .idle, to: .preparing(phase: "Preparing…", fraction: nil))
        center.handlePrewarm(from: .preparing(phase: "Preparing…", fraction: nil),
                             to: .failed("no network"))
        #expect(center.current?.style == .error)
        #expect(center.current?.message == "no network")
    }
}

@Suite("Session feed shaping")
@MainActor
struct SessionFeedShapingTests {

    private func makeSession(_ title: String, fullText: String = "",
                             daysAgo: Int = 0) -> TranscriptSession {
        let session = TranscriptSession(title: title, kind: .roomRecording)
        session.fullText = fullText
        session.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return session
    }

    // Filtering matches title and spoken content, case-insensitively; empty passes through.
    @Test func filterMatchesTitleAndFullText() {
        let sessions = [makeSession("Standup", fullText: "we shipped the beta"),
                        makeSession("Interview", fullText: "background and experience")]
        #expect(SessionFilter.filter(sessions, query: "").count == 2)
        #expect(SessionFilter.filter(sessions, query: "STANDUP").map(\.title) == ["Standup"])
        #expect(SessionFilter.filter(sessions, query: "beta").map(\.title) == ["Standup"])
        #expect(SessionFilter.filter(sessions, query: "  experience ").map(\.title) == ["Interview"])
        #expect(SessionFilter.filter(sessions, query: "nothing").isEmpty)
    }

    // Day bucketing groups by calendar day, newest day first.
    @Test func daySectionsGroupNewestFirst() {
        let today = makeSession("Today A")
        let yesterday = makeSession("Yesterday", daysAgo: 1)
        let older = makeSession("Older", daysAgo: 3)
        let sections = SessionFilter.daySections([today, yesterday, older])
        #expect(sections.count == 3)
        #expect(sections[0].sessions.map(\.title) == ["Today A"])
        #expect(sections[1].sessions.map(\.title) == ["Yesterday"])
        #expect(sections[2].sessions.map(\.title) == ["Older"])
        #expect(sections[0].day > sections[1].day)
    }
}

@Suite("URL validation")
struct URLValidationTests {

    @Test func acceptsHTTPURLsWithHosts() {
        #expect(URLValidation.isTranscribableURL("https://youtube.com/watch?v=abc"))
        #expect(URLValidation.isTranscribableURL("  http://tiktok.com/@x/video/1  "))
        #expect(!URLValidation.isTranscribableURL("youtube.com/watch"))     // no scheme
        #expect(!URLValidation.isTranscribableURL("file:///tmp/a.mp3"))     // not http(s)
        #expect(!URLValidation.isTranscribableURL("https://"))              // no host
        #expect(!URLValidation.isTranscribableURL(""))
    }

    @Test func suggestsHostTitles() {
        #expect(URLValidation.suggestedTitle(for: "https://youtube.com/watch?v=abc") == "Link · youtube.com")
        #expect(URLValidation.suggestedTitle(for: "not a url") == "not a url")
    }
}

@Suite("Playback keep-alive")
@MainActor
struct PlaybackKeepAliveTests {

    // A session without archived audio prepares to "no audio" and never sets now-playing.
    @Test func prepareWithoutAudioClearsNowPlaying() {
        let playback = PlaybackController()
        let session = TranscriptSession(title: "Silent", kind: .fileTranscription)
        #expect(playback.prepare(session: session) == false)
        #expect(playback.nowPlaying == nil)
        #expect(playback.hasLoadedAudio == false)
    }

    // releaseIfIdle drops audio that was never engaged; unload always drops it.
    @Test func releaseIfIdleUnloadsUntouchedAudio() {
        let playback = PlaybackController()
        playback.releaseIfIdle()   // nothing loaded — must not trap
        #expect(playback.nowPlaying == nil)
        playback.unload()
        #expect(playback.hasLoadedAudio == false)
    }
}

@Suite("Shell sheet routing")
@MainActor
struct ShellRoutingTests {

    // openSession presents the session sheet; returnHome clears any presentation.
    @Test func openSessionAndReturnHome() {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        let id = UUID()
        app.openSession(id: id)
        #expect(app.activeSheet == .session(id))
        app.returnHome()
        #expect(app.activeSheet == nil)
    }

    // Requesting a recording while one is active just re-expands the live sheet.
    @Test func requestRecordingWhileActiveExpandsSheet() {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.recording.start(mode: .room)
        app.activeSheet = nil
        app.requestRecording(mode: .room)
        #expect(app.activeSheet == .liveRecording)
    }
}

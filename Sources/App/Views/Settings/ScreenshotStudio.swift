// Both platforms. The scenes are the same — they are Transcription Studio's own views — and each
// platform's presenter differs only in how it puts one on screen: iOS covers, macOS fills the
// window, because a Mac App Store shot is a window. The app is ONE multiplatform target, so the
// catalog compiles once and each shell reaches for its own presenter.
#if DEBUG
import FCTScreenshotStudio
import SwiftData
import SwiftUI

// MARK: - The demo store, carried by every scene

extension View {
    /// Everything a studio scene reads and writes, on the detached demo store. The container is
    /// what every `@Query` and `@Environment(\.modelContext)` inside the scene resolves to; the
    /// `AppModel` is the write seam that carries a `ModelContext` of its own, which no container
    /// in the environment would redirect. Both together, or the screens render demo rows while
    /// the writes behind them land in the account's library.
    func studioStore() -> some View {
        modelContainer(TranscriptionDebugStore.demo.renderContainer)
            .environment(TranscriptionDebugStore.appModel)
    }
}

// MARK: - Catalog

/// Transcription Studio's App-Store-screenshot scenes. The harness that presents them — the
/// gallery, the seed affordance, the entitlement override, the driving identifiers — is
/// `FCTScreenshotStudio`; what lives here is the part only this app can say: which screens sell
/// it, and in what order.
///
/// Every scene returns one of the app's **real** views against the seeded demo store. None of them
/// rebuilds a screen for marketing: a rebuilt screen drifts from the shipping one silently, and
/// the screenshot then advertises a product that does not exist.
///
/// **The live-recording surface has no scene, and cannot.** Its transcript comes from the engine
/// as audio arrives, so the only version a seeded process can render is the mock engine's
/// placeholder sentences — a screenshot of "The quick brown fox" over the app's best screen. That
/// shot is captured from a real run on a device, not from here.
@MainActor
enum ScreenshotStudioCatalog {
    /// Ranked by selling power, and **the order is itself the argument**:
    ///
    /// 1. **The library** is what the app *is* — a week of recordings grouped by day, each row
    ///    saying what kind it was and how many voices were in it. Everything below is one row of
    ///    this screen opened up, so nothing else can go first.
    /// 2. **A transcript with its speakers** is the product delivered: turns attributed to
    ///    people, the playback bar that highlights the line being spoken, and the suggestions the
    ///    on-device pass pulled out of it. With 1 it carries almost all of the conversion.
    /// 3. **A spoken date becoming a calendar event** is the differentiator. Every transcription
    ///    app hands back text; this one hands back the thing the text was *for*, as an editable
    ///    draft that writes nothing until it is confirmed — which is also the privacy claim made
    ///    visible.
    /// 4. **Ask your library** is the flagship: a question answered across every transcript, on
    ///    device. It ranks below 3 because it is a promise the shopper has to take on faith,
    ///    where 3 is a mechanism they can see working.
    /// 5. **One session's intelligence** is the same claim scoped to a single recording — the
    ///    summary and the grounded Q&A. Last because it corroborates 4 rather than adding a claim.
    ///
    /// Scenes 4 and 5 render Apple Intelligence output, so they photograph their unavailable state
    /// on a device where the model is off — capture them where it is on, as scene 3's calendar
    /// permission sheet is captured where Calendar access can be granted.
    static let scenes: [ScreenshotStudioScene] = [
        ScreenshotStudioScene(
            id: "library",
            title: "The Library",
            detail: "Poster · a week of recordings, grouped by day",
            symbol: "square.stack.3d.up"
        ) {
            AnyView(StudioHomeView(capabilities: homeCapabilities).studioStore())
        },
        ScreenshotStudioScene(
            id: "transcript",
            title: "A Transcript With Its Speakers",
            detail: "Payoff · attributed turns, karaoke playback, suggestions",
            symbol: "text.alignleft"
        ) {
            AnyView(StudioSessionDetailScene().studioStore())
        },
        ScreenshotStudioScene(
            id: "calendar",
            title: "Spoken Date → Calendar",
            detail: "Differentiator · draft-then-confirm, nothing written until Add",
            symbol: "calendar.badge.plus"
        ) {
            AnyView(StudioCalendarDraftScene().studioStore())
        },
        ScreenshotStudioScene(
            id: "ask",
            title: "Ask Your Library",
            detail: "Flagship · one question across every transcript, on device",
            symbol: "sparkles.rectangle.stack"
        ) {
            AnyView(AskLibraryView().studioStore())
        },
        ScreenshotStudioScene(
            id: "intelligence",
            title: "One Session's Intelligence",
            detail: "Corroboration · summary and grounded Q&A for one recording",
            symbol: "sparkles"
        ) {
            AnyView(StudioIntelligenceScene().studioStore())
        },
    ]

    /// What the studio's host can do. The Mac shell turns meeting capture on, so the Mac shot
    /// shows the entry point a Mac buyer is being sold.
    private static var homeCapabilities: StudioHomeView.Capabilities {
        #if os(macOS)
        .init(meetingCapture: true)
        #else
        .init()
        #endif
    }

    // MARK: Seeded lookups

    /// The seeded multi-speaker session every one-session scene points at, resolved by title and
    /// preferring the row that actually carries turns — a scene resolving to an empty twin renders
    /// the unseeded placeholder instead of the screen being sold.
    static func heroSession(in context: ModelContext) -> TranscriptSession? {
        let title = DemoLibrarySeeder.heroMeetingTitle
        let descriptor = FetchDescriptor<TranscriptSession>(predicate: #Predicate { $0.title == title })
        let matches = (try? context.fetch(descriptor)) ?? []
        return matches.max { ($0.segments?.count ?? 0) < ($1.segments?.count ?? 0) }
    }

    /// The extracted event the calendar scene drafts: the hero session's, which is the one the
    /// seed gives a date worth adding.
    static func heroEventID(in context: ModelContext) -> UUID? {
        heroSession(in: context)?.events?.first?.id
    }
}

// MARK: - Fetch-backed scenes

/// Resolves the seeded hero session and hands it to the real detail screen.
private struct StudioSessionDetailScene: View {
    @Environment(\.modelContext) private var context
    @State private var session: TranscriptSession?

    var body: some View {
        Group {
            if let session {
                SessionDetailView(session: session)
            } else {
                ScreenshotStudioUnseededView()
            }
        }
        .task { session = ScreenshotStudioCatalog.heroSession(in: context) }
    }
}

/// The suggestion chip's destination, on the seeded session's extracted event.
private struct StudioCalendarDraftScene: View {
    @Environment(\.modelContext) private var context
    @State private var eventID: UUID?

    var body: some View {
        Group {
            if let eventID {
                CalendarDraftConfirmView(eventID: eventID)
            } else {
                ScreenshotStudioUnseededView()
            }
        }
        .task { eventID = ScreenshotStudioCatalog.heroEventID(in: context) }
    }
}

/// The intelligence sheet over the seeded hero session.
private struct StudioIntelligenceScene: View {
    @Environment(\.modelContext) private var context
    @State private var session: TranscriptSession?

    var body: some View {
        Group {
            if let session {
                SessionIntelligenceSheet(session: session)
            } else {
                ScreenshotStudioUnseededView()
            }
        }
        .task { session = ScreenshotStudioCatalog.heroSession(in: context) }
    }
}
#endif

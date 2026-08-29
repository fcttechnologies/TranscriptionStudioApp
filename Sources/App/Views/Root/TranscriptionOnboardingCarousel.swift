import FCTComponentsUI
import FCTOnboarding
import SwiftUI

/// Transcription Studio's four intro pages, as the carousel's own `OnboardingItem`s.
///
/// **The carousel, its pager, its dots, its device frame and the sign-in that ends it are all
/// `FCTOnboarding`'s.** What this app supplies is exactly this: a title, a subtitle, and a picture
/// of itself per appearance. Authoring a second carousel here is how one front door becomes
/// thirteen slightly different ones.
///
/// The pictures are rendered from live SwiftUI mocks rather than captured PNGs, because every page
/// describes the app *doing* something — a recording streaming words, a transcript split by
/// speaker — and a capture of a first-run app with an empty library shows none of it. They are
/// rendered without a bezel: the module draws the hardware the app is actually running on, and a
/// frame drawn here would sit inside that one.
///
/// The mocks are rendered at the running platform's own proportions — a portrait phone screen on
/// iOS, a landscape display on macOS — because the module fits the image into an iPhone bezel or a
/// MacBook lid accordingly, and a portrait capture inside a laptop lid is the tell of a port.
enum TranscriptionOnboardingCarousel {
    /// Rendered once per process: eight images (four pages, two appearances), made on the way into
    /// a screen shown once per install.
    @MainActor private static var cache: [OnboardingItem]?

    @MainActor static var items: [OnboardingItem] {
        if let cache { return cache }
        let pages: [(String, String, OnboardingMockScreen.Kind)] = [
            (
                String(localized: "Words as you speak them", comment: "Onboarding page 1 title"),
                String(
                    localized: "Watch the transcript arrive as you speak — on this device.",
                    comment: "Onboarding page 1 subtitle"
                ),
                .record
            ),
            (
                String(localized: "Who said what", comment: "Onboarding page 2 title"),
                String(
                    localized: "Split by speaker. Name someone once and it sticks.",
                    comment: "Onboarding page 2 subtitle"
                ),
                .speakers
            ),
            (
                String(localized: "Anything with audio in it", comment: "Onboarding page 3 title"),
                String(
                    localized: "A file, a link, a share sheet, or a meeting off your Mac.",
                    comment: "Onboarding page 3 subtitle"
                ),
                .ingest
            ),
            (
                String(localized: "Ask your library", comment: "Onboarding page 4 title"),
                String(
                    localized: "Ask Siri, or search every word you’ve ever recorded.",
                    comment: "Onboarding page 4 subtitle"
                ),
                .ask
            ),
        ]
        let items = pages.enumerated().map { index, page in
            OnboardingItem(
                id: index,
                title: page.0,
                subtitle: page.1,
                screenshot: render(page.2, scheme: .light),
                screenshotDark: render(page.2, scheme: .dark)
            )
        }
        cache = items
        return items
    }

    /// One page's picture, in the appearance it will be shown in. A failed render yields nil, which
    /// the carousel draws as a plain screen — a dull page rather than a crash on the first surface
    /// anyone sees.
    @MainActor private static func render(_ kind: OnboardingMockScreen.Kind, scheme: ColorScheme) -> PlatformImage? {
        // The Mac mock is rendered at a fraction of a real window's point size, not at 1:1. The
        // carousel fits the image into a ~570pt-wide MacBook lid, so a true 1440-wide capture
        // arrives at 40% scale and its body text is an illegible smudge — which is what a real
        // screenshot of a Mac app in a lid actually looks like. Rendering the same 1.6 aspect
        // smaller makes every glyph 1.44x larger on the page for free.
        #if os(macOS)
        let size = CGSize(width: 1000, height: 625)
        #else
        let size = CGSize(width: 402, height: 874)
        #endif
        let renderer = ImageRenderer(
            content: OnboardingMockScreen(kind: kind)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        #if os(macOS)
        return renderer.nsImage
        #else
        return renderer.uiImage
        #endif
    }
}

/// A stylized render of one Transcription Studio screen: real, recognizable content in the app's
/// own visual language (`DesignMetrics`' speaker palette, its waveform, its feed cards), never
/// lorem.
///
/// It draws the SCREEN only — no bezel, no shadow, no device corner. On macOS it lays the same
/// content out as the Mac app does, side by side, because the page is framed in a laptop lid.
struct OnboardingMockScreen: View {
    enum Kind { case record, speakers, ingest, ask }

    let kind: Kind

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
    }

    private var canvas: Color {
        scheme == .dark ? Color(white: 0.07) : Color(white: 0.96)
    }

    private var ink: Color { scheme == .dark ? .white : .black }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            MockFeedColumn(kind: kind)
                .frame(width: 300)
            Divider()
            MockDetailColumn(kind: kind)
                .frame(maxWidth: .infinity)
        }
        .padding(22)
        #else
        MockDetailColumn(kind: kind)
            .padding(20)
        #endif
    }
}

// MARK: - The Mac shell's left column

/// The session feed, as the Mac app shows it beside the open transcript. Present on macOS only —
/// on a phone the transcript is the whole screen.
private struct MockFeedColumn: View {
    let kind: OnboardingMockScreen.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            Text(verbatim: "Sessions")
                .font(.system(.largeTitle, weight: .bold))
            MockSearchField(text: kind == .ask ? "March budget" : "Search transcripts")
            ForEach(Array(MockLibrary.sessions.enumerated()), id: \.offset) { index, session in
                MockSessionCard(session: session, selected: index == 0)
            }
            Spacer()
        }
        .padding(.trailing, DesignMetrics.spacingXL)
    }
}

private struct MockSearchField: View {
    let text: String

    var body: some View {
        HStack(spacing: DesignMetrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, DesignMetrics.spacingM)
        .padding(.vertical, DesignMetrics.spacingS)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

private struct MockSessionCard: View {
    let session: MockLibrary.Session
    let selected: Bool

    var body: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous)
                .fill(.tint.opacity(selected ? 0.9 : 0.18))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: session.glyph)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: session.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignMetrics.spacingM)
        .background(
            selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.background.secondary),
            in: RoundedRectangle(cornerRadius: DesignMetrics.cornerL, style: .continuous)
        )
    }
}

// MARK: - The page itself

private struct MockDetailColumn: View {
    let kind: OnboardingMockScreen.Kind

    var body: some View {
        switch kind {
        case .record: MockRecordScreen()
        case .speakers: MockSpeakersScreen()
        case .ingest: MockIngestScreen()
        case .ask: MockAskScreen()
        }
    }
}

/// Page 1 — a live recording, its waveform, and the transcript arriving under it.
private struct MockRecordScreen: View {
    var body: some View {
        VStack(spacing: DesignMetrics.spacingXL) {
            MockTitleBar(title: "Recording", trailing: "0:47")
            MockWaveform()
            VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
                MockTranscriptTurn(speaker: 0, name: "Speaker 1",
                                   line: "So the March budget — we agreed to hold the media spend flat.")
                MockTranscriptTurn(speaker: 1, name: "Speaker 2",
                                   line: "Flat through Q2, and then we revisit once the pilot numbers land.")
                MockTranscriptTurn(speaker: 0, name: "Speaker 1",
                                   line: "Right. I’ll write that up tonight and send it round.",
                                   provisional: true)
            }
            Spacer(minLength: 0)
            MockRecordControl()
        }
    }
}

/// Page 2 — the same transcript with the speakers named.
private struct MockSpeakersScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingL) {
            MockTitleBar(title: "Quarterly planning", trailing: "18:32")
            HStack(spacing: DesignMetrics.spacingS) {
                MockSpeakerChip(speaker: 0, name: "Dana")
                MockSpeakerChip(speaker: 1, name: "Marcus")
                MockSpeakerChip(speaker: 2, name: "Priya")
            }
            VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
                MockTranscriptTurn(speaker: 0, name: "Dana",
                                   line: "Let’s lock the March budget before anyone books media.")
                MockTranscriptTurn(speaker: 1, name: "Marcus",
                                   line: "Flat through Q2. I’ll take the write-up.")
                MockTranscriptTurn(speaker: 2, name: "Priya",
                                   line: "Send it to me first — I want the pilot numbers in the same doc.")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Page 3 — everything that can become a transcript.
private struct MockIngestScreen: View {
    private static let rows: [(String, String, String)] = [
        ("link", "Paste a link", "A talk, a podcast, an interview"),
        ("folder", "Choose a file", "Audio or video, any length"),
        ("square.and.arrow.up", "Share from any app", "Straight into your library"),
        ("person.2.wave.2", "Capture a meeting", "System audio and your mic, together"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingL) {
            MockTitleBar(title: "Add", trailing: nil)
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: DesignMetrics.spacingM) {
                    Image(systemName: row.0)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.1).font(.headline)
                        Text(verbatim: row.2).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(DesignMetrics.spacingM)
                .background(.background.secondary,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.cornerL, style: .continuous))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Page 4 — a question answered out of the library.
private struct MockAskScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingL) {
            MockTitleBar(title: "Ask your library", trailing: nil)
            HStack {
                Spacer(minLength: 60)
                Text(verbatim: "What did we decide about the March budget?")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(DesignMetrics.spacingM)
                    .background(.tint, in: RoundedRectangle(cornerRadius: DesignMetrics.cornerXL, style: .continuous))
            }
            HStack {
                VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
                    Text(verbatim: "You agreed to hold media spend flat through Q2 and revisit after the pilot numbers land.")
                        .font(.callout)
                    Label {
                        Text(verbatim: "Quarterly planning · 4:12")
                    } icon: {
                        Image(systemName: "waveform")
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(DesignMetrics.spacingM)
                // A stronger fill than the cards use: this bubble runs nearly the column's width,
                // and at the scale the carousel draws it a card-weight tint disappears into the
                // canvas and the answer reads as bare text on the page.
                .background(.quaternary.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: DesignMetrics.cornerXL, style: .continuous))
                Spacer(minLength: 40)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Spacer()
            }
        }
    }
}

// MARK: - Mock building blocks

private struct MockTitleBar: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.system(.title, weight: .bold))
            Spacer()
            if let trailing {
                Text(verbatim: trailing)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The live capture trace, at the app's own bar geometry.
private struct MockWaveform: View {
    /// A fixed, plausible envelope — deterministic so a render is reproducible and never a
    /// different picture per build.
    private static let levels: [CGFloat] = (0..<DesignMetrics.waveformSampleCount).map { index in
        let phase = Double(index)
        let envelope = 0.45 + 0.35 * sin(phase / 7) * cos(phase / 17)
        return max(DesignMetrics.waveformMinBarFraction, CGFloat(abs(envelope)))
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignMetrics.waveformBarSpacing) {
            ForEach(Array(Self.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.tint)
                    .frame(width: DesignMetrics.waveformBarWidth,
                           height: max(3, DesignMetrics.waveformHeight * level))
            }
        }
        .frame(height: DesignMetrics.waveformHeight)
        .frame(maxWidth: .infinity)
    }
}

private struct MockTranscriptTurn: View {
    let speaker: Int
    let name: String
    let line: String
    var provisional = false

    var body: some View {
        // The speaker rule is drawn as a leading overlay on the text, not as a sibling in an
        // HStack: a bare `RoundedRectangle` is flexible on both axes, so as a sibling it grows to
        // whatever height the row is offered and drags the turns apart with it.
        VStack(alignment: .leading, spacing: DesignMetrics.spacingXS) {
            Text(verbatim: name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DesignMetrics.speakerColor(slot: speaker))
            Text(verbatim: line)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, DesignMetrics.spacingM)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(DesignMetrics.speakerColor(slot: speaker))
                .frame(width: DesignMetrics.turnAccentWidth)
        }
        .opacity(provisional ? DesignMetrics.provisionalOpacity : 1)
    }
}

private struct MockSpeakerChip: View {
    let speaker: Int
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, DesignMetrics.speakerChipHPadding)
            .padding(.vertical, DesignMetrics.speakerChipVPadding)
            .background(DesignMetrics.speakerColor(slot: speaker).opacity(0.18), in: Capsule())
            .foregroundStyle(DesignMetrics.speakerColor(slot: speaker))
    }
}

private struct MockRecordControl: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: DesignMetrics.recordControlSize, height: DesignMetrics.recordControlSize)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white)
                    .frame(width: DesignMetrics.recordGlyphSize, height: DesignMetrics.recordGlyphSize)
            }
    }
}

/// The library the Mac column shows — the same three sessions on every page, so the pages read as
/// one app rather than four unrelated pictures.
private enum MockLibrary {
    struct Session {
        let title: String
        let detail: String
        let glyph: String
    }

    static let sessions: [Session] = [
        Session(title: "Quarterly planning", detail: "Today · 18:32 · 3 speakers", glyph: "person.2.wave.2"),
        Session(title: "Customer call — Alvarez", detail: "Yesterday · 24:05", glyph: "phone"),
        Session(title: "Design review", detail: "Monday · 41:18 · 4 speakers", glyph: "waveform"),
    ]
}

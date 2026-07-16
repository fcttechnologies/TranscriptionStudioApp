# Detail View Redesign + Live Activities (spec)

An elegant, enterprise-grade redesign of the transcript detail/playback view, plus real system
media integration. References Fernando gave: **Apple Music** (karaoke lyric highlighting),
**Apple Voice Memos** (speaker grouping + the single-speaker flat layout). Bar: legit enterprise
elegance — run the taste anti-slop checklist against the result.

## Detail view (`SessionDetailView`)
- **Karaoke playhead.** The currently-playing line is highlighted (full opacity / weight); past
  and upcoming lines dimmed; auto-scroll keeps the current line centered (Apple Music lyrics
  feel). Tap any line → seek to its timestamp. (`PlayheadTracker` already maps playhead→line id —
  build on it.)
- **Speaker grouping is CONDITIONAL.** Group by speaker ONLY when the session has **more than one
  speaker**. Single speaker → flat paragraphs, no speaker labels/accent bar (the single-speaker
  Voice Memos layout). Multi-speaker → grouped blocks with a colored speaker label + leading
  accent bar (the "Speaker 1" Voice Memos layout).
- **Header:** title (with rename), date, duration, a source-kind chip (file / link / recording /
  meeting).
- **Playback bar:** play/pause, ±15s skip, a scrubber with elapsed / remaining, playback-speed
  control — elegant, glass, matching the shell's language.
- **Actions:** keep the sparkles (intelligence: ask/summarize) + the ellipsis menu (rename / copy
  / export); circular `xmark` close (no Done).

## Live Activities + media player (new — none exists today)
- **Playback Live Activity.** When a recording's audio plays, present a Live Activity (Dynamic
  Island + Lock Screen) AND register `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` handlers,
  so it shows up as a real system media player (Control Center / Lock Screen / AirPods:
  play·pause·skip·scrub, title + duration).
- **Recording Live Activity.** While recording, a Live Activity (Dynamic Island + Lock Screen)
  with elapsed time + a live level/waveform indicator and a Stop control.
- New **Widget/Live-Activity extension target** (project.yml + entitlements; App-Group already in
  place). ActivityKit for the activities; the media player via MediaPlayer framework.

## iOS 27 capabilities — no gaps
Audit the whole app against `~/Jarvis/database/research/wwdc26/ios-27-capabilities.md` and the
apple-skills `swiftui/whats-new-27` sub-skill, and adopt the current iOS-27 APIs wherever they
elevate the app (the redesign already uses several — `Button(role:.close)`, toolbar bottom-bar,
`safeAreaBar`, `confirmationDialog(item:)`). Gate with `#available` where the deploy target needs
it. This is a cross-cutting pass, not just the detail view.

## Build
Fable lane (long-horizon, elegant), grounded in `taste` + apple `design` + `swiftui/whats-new-27`
+ VillainArc (`~/Projects/VillainArc`) & Personal Context (`~/Projects/PersonalContext`).
Sequence AFTER the bgassets + companion lanes (they share project.yml / the extension graph).

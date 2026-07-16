# Adaptive / resizable layout audit (roadmap §13)

The size-class pass over the redesigned surfaces — home feed, session detail, mini-player,
live-recording sheet — on iPhone (compact width) and iPad Pro 13" (regular width), against
the iOS-27 resizability bar (iPhone mirroring, iPhone-on-iPad, split view): avoid rigid
geometry, let size classes and max-width clamps do the adapting.

## Verdict: structurally adaptive — no rigid-layout defects

- **Home feed** adapts correctly: cards clamp to `DesignMetrics.feedMaxWidth` (640) and
  center at regular width; the search control relocates from the iPhone bottom bar to the
  iPad top toolbar via `DefaultToolbarItem(kind: .search)`; the compose control stays
  reachable in both placements.
- **Session detail** presents full-screen on iPhone and as a centered form-sheet on iPad;
  transcript content clamps at 760pt; the suggestion-chip row truncates + scrolls
  horizontally exactly as designed (chips clamp, they don't stretch); the floating
  transport bar spans the sheet's safe-area width at both sizes.
- **Mini-player** clamps to `feedMaxWidth`, truncates its title, and keeps its controls
  hit-target-sized at both widths. Worst-case fixed content (dot + 88pt waveform + clock +
  pause) sums ~250pt — safe even at the 320pt narrowest compact width.
- **Live-recording sheet** is stack-based with no fixed geometry beyond type sizes; degrades
  cleanly (verified by inspection; mic capture can't run on the simulator).

## The one real defect: toast ↔ toolbar collision (both platforms)

`ToastHost` is a top-aligned overlay over the whole shell (`toastOverlay()` at the app
roots), padded only `spacingS` from the top — so any toast lands **on** the iOS-27 floating
toolbar row. A persistent progress toast ("Downloading speech model … %") sits over the
Ask-your-library / Settings controls for the entire download on iPhone *and* iPad.

This is a **design decision, not a mechanical fix** — deliberately not freehanded here.
Options, roughly in order of fit with the existing language:
1. Offset the toast host below the toolbar row (a `DesignMetrics` constant; fragile across
   platforms/dynamic type).
2. Present *persistent/progress* toasts from the **bottom** (above the mini-player/search
   bar), keeping transient notices at the top — matches how the mini-player already owns
   the bottom edge.
3. Shrink persistent progress into a compact pill that coexists with the toolbar.

## Owed to the device/Xcode loop (can't be driven headless)

- iPhone **landscape** (compact-height) pass — Simulator rotation isn't scriptable in this
  environment.
- Xcode 27 **resize-handle preview** sweep and iPad **Split View / Stage Manager** widths.
- Dynamic Type at accessibility sizes across the same surfaces.

# Per-session privacy lock

A per-session lock for the sensitive verticals (legal client interviews, therapy, medical,
personal journaling) — the explicit, marketable version of TS's on-device edge. Two halves:

1. **Biometric open** — a session marked private (`TranscriptSession.isPrivate`) requires a
   Face ID / Touch ID unlock before its transcript is revealed.
2. **Withheld from the assistant surface** — a private session is never Spotlight-indexed, never
   donated as a relevant/onscreen entity, and never returned by a Siri / App-Intent library
   query, so a locked transcript can't leak through search or be read aloud unlocked.

## Biometric open

- `BiometricAuthenticator` (LocalAuthentication) prompts with `.deviceOwnerAuthentication` —
  **biometrics first, device passcode as fallback**. Biometrics-only (`…WithBiometrics`) was
  rejected: if Face ID is unavailable or fails, the owner would be permanently locked out of
  their own session. Passcode fallback keeps the owner in and a thief (no biometric, no passcode)
  out. If the device has *no* lock at all, the gate fails **closed** (the session stays shut).
- The gate is centralized in `AppModel.openSession` (→ `presentSession`), the one entry point
  every open funnels through (row tap, finished recording, Spotlight, App Intents), so there's no
  unguarded path to a private transcript. `PrivacyGate.requiresAuthentication` is the pure
  decision; `BiometricAuthenticating` is a protocol so the gate is unit-tested with a fake.
- **No unlock caching this pass:** every open of a private session prompts. Simplest and most
  secure reading of "requires auth to open". A future enhancement could add a short in-memory
  grace window cleared on background — deliberately deferred, not needed for correctness.
- `NSFaceIDUsageDescription` is set on both app targets (project.yml). Missing it crashes the
  prompt.

## Sync exclusion — the honest limitation

The moat's ideal is "this session never leaves the device — not even to your own account." **That
half is documented, not shipped, and here's why — this is a real architectural constraint, not an
oversight.**

**Sync membership is per model *type*, not per row.** `TranscriptionSyncSchema` names the tables
the engine drains, and a `@Model` type is either in that schema or out of it; the outbox is
derived from persistent history over the whole store, so there is nowhere for "this row only" to
live. The recording is the same story one layer down: `BlobStore.stage` is what puts authored
bytes in the upload queue, and a session that skipped it would have a `nil` asset — visibly a
different kind of record, not a private one.

So true per-session exclusion would mean private sessions living in a **separate, local-only
`ModelContainer`** the engine never sees, routed there **at creation** (a post-hoc "make private"
toggle cannot honestly promise "never left the device" — by the time it is flipped, the row has
pushed). That is not clean in this architecture:

- The app is wired to a **single shared container** (`AppModelContainer.shared`) across the feed
  fetch, `SessionStoreObserver`, `AppModel.openSession`, the `TranscriptSessionEntity` read-path,
  Spotlight, playback, and every session-creation site. A second container means each of those
  must query and merge two stores.
- SwiftData object graphs **can't move between containers**, so the natural "toggle a session
  private" UX would require deep-copying the session + segments + highlights across stores.
- Privacy would have to become a **create-time-only** decision to be honest, changing the UX.

So the shipped guarantee is: **biometric lock + full withholding from the on-device assistant
surface (Spotlight / Siri / App Intents).** What a private session does *not* yet get is exclusion
from sync: with an account signed in, its rows and its recording reach the user's own private FCT
account like any other session. Transcription itself never leaves the device either way — no audio
is ever sent anywhere to be processed.

### The correct future design (when it's worth the surgery)

A dedicated local-only container for private sessions, chosen **at creation**:

- `AppModelContainer` gains a second container the sync engine is never handed.
- A thin `SessionStore` seam fronts both — the feed and by-id lookups query both and merge by
  `createdAt`; creation routes by the chosen privacy at record-start.
- Privacy becomes create-time (a "start private" affordance on the recorder), not a post-hoc
  toggle, so a private session is born local-only and never touches the synced store.

This is a real, bounded project — worth doing when the sensitive verticals are a committed
target, not a speculative one.

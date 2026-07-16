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

## CloudKit sync exclusion — the honest limitation

The moat's ideal is "this session never leaves the device — not even to your own iCloud." **That
half is documented, not shipped, and here's why — this is a real architectural constraint, not an
oversight.**

**SwiftData + CloudKit sync is configured per `ModelConfiguration` (per store), and a `@Model`
type belongs to exactly one configuration. There is no API to keep *some* rows of a type local
while others sync** — sync is all-or-nothing per model type. (Grounded against Apple's SwiftData
docs: `cloudKitDatabase` is a `ModelConfiguration` property; the container is a set of
configurations, each a separate store.)

So true per-session sync exclusion would require private sessions to live in a **separate,
local-only `ModelContainer`** (`cloudKitDatabase: .none`), routed there **at creation** (a
post-hoc "make private" toggle can't honestly promise "never left the device" — by the time you
flip it, CloudKit has already synced the row). That is not clean in TS's architecture:

- The app is wired to a **single shared container** (`AppModelContainer.shared`) across the feed
  fetch, `SessionStoreObserver`, `AppModel.openSession`, the `TranscriptSessionEntity` read-path,
  Spotlight, playback, and every session-creation site. A second container means each of those
  must query and merge two stores.
- SwiftData object graphs **can't move between containers**, so the natural "toggle a session
  private" UX would require deep-copying the session + segments + highlights across stores.
- Privacy would have to become a **create-time-only** decision to be honest, changing the UX.

Per the moat brief's explicit guidance ("if true CloudKit exclusion isn't cleanly achievable in
this architecture, implement the biometric lock + honestly document rather than fake it"), the
shipped guarantee is: **biometric lock + full withholding from the on-device assistant surface
(Spotlight / Siri / App Intents).** What a private session's data does *not* yet get is exclusion
from the user's own CloudKit private database (their own iCloud, end-to-end within their Apple
account — not a third-party server; TS is on-device and has no vendor cloud).

### The correct future design (when it's worth the surgery)

A dedicated local-only container for private sessions, chosen **at creation**:

- `AppModelContainer` gains a second container: `privateLocal` with `cloudKitDatabase: .none`.
- A thin `SessionStore` seam fronts both — the feed and by-id lookups query both and merge by
  `createdAt`; creation routes by the chosen privacy at record-start.
- Privacy becomes create-time (a "start private" affordance on the recorder), not a post-hoc
  toggle, so a private session is born local-only and never touches the synced store.

This is a real, bounded project — worth doing when the sensitive verticals are a committed
target, not a speculative one.

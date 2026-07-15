#!/usr/bin/env bash
# Build + install the Transcription Studio Mac app, signed with the local Apple Development
# cert so macOS TCC grants (Screen Recording for meeting capture, Microphone) PERSIST across
# rebuilds.
#
# WHY signing matters here (and not for a plain SwiftPM tool): an ad-hoc build (`codesign -s -`)
# gives the app a NEW code identity (cdhash) every rebuild, so macOS TCC drops the user's prior
# Screen Recording / Microphone grants → meeting capture falsely reports "blocked" until the user
# re-grants. Signing with a stable Apple Development cert keys the grants to a stable identity, so
# they survive every future rebuild.
#
# Usage: scripts/package-mac.sh [destDir]   (default dest: /Applications)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
DEST="${1:-/Applications}"

IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | sed -E 's/.*"(.*)".*/\1/')"
if [ -z "$IDENTITY" ]; then
  echo "✗ No 'Apple Development' signing identity in the keychain." >&2
  echo "  Open Xcode → Settings → Accounts, sign in with the Apple ID, and let it create the cert." >&2
  exit 1
fi
echo "› Signing identity: $IDENTITY"

xcodegen generate >/dev/null
DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT

echo "› Building Release (stably signed)…"
xcodebuild -project TranscriptionStudio.xcodeproj -scheme TranscriptionStudio -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES build

APP="$DERIVED/Build/Products/Release/TranscriptionStudio.app"
rm -rf "$DEST/TranscriptionStudio.app"
cp -R "$APP" "$DEST/"
echo "› Installed $DEST/TranscriptionStudio.app"
codesign -dvv "$DEST/TranscriptionStudio.app" 2>&1 | grep -E 'Authority=Apple Development|TeamIdentifier' | head -2

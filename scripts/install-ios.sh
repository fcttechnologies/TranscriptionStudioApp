#!/usr/bin/env bash
# Build Transcription Studio for iOS (Release) and install it on a paired physical iPhone.
# Run: scripts/install-ios.sh [device-udid]
#
# No Xcode GUI and no human step: the project signs automatically against
# DEVELOPMENT_TEAM X26SC78YDG, and -allowProvisioningUpdates lets the toolchain
# create/refresh the team provisioning profiles for the app + its extensions on
# its own. Xcode's build phases produce the real signed .app, so there is no
# hand-rolled bundle assembly here.
#
# The one part that stays human: LAUNCHING it. A running app keeps its old code
# until it next launches, and this installs over the app Fernando is using.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
cd "$HERE"

DERIVED="DerivedData/install-ios"
APP_NAME="TranscriptionStudio.app"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"

# Resolve the target device: an explicit UDID, else the sole paired physical iPhone.
# Refuse rather than guess when several are present — installing on the wrong phone is
# not something to recover from politely.
#
# Do NOT filter on the list's connection column. A device reachable over a localNetwork
# tunnel reads `available (paired)` there while `devicectl device info details` reports
# `Device State: connected` — so filtering on the word `connected` excludes exactly the
# wireless case this script exists to serve. What this step answers is which phone, never
# whether it can be reached; the build below is where an unreachable one is caught.
DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  # Match the UDID by SHAPE, never by column index: the Name and Model columns both contain
  # spaces ("iPhone 17 Pro Max (iPhone18,2)") and the Hostname column is often empty, so a
  # field offset silently resolves to a fragment of the model name. Two shapes: a PHYSICAL
  # device UDID is 8-16; a simulator's is the 8-4-4-4-12 UUID.
  FOUND=()
  while IFS= read -r _u; do [ -n "$_u" ] && FOUND+=("$_u"); done < <(
    xcrun devicectl list devices 2>/dev/null \
    | grep -E 'iPhone.*physical' \
    | grep -oE '[0-9A-F]{8}-([0-9A-F]{16}|[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})')
  case "${#FOUND[@]}" in
    0) echo "✗ No paired iPhone. Pair/unlock it, then: xcrun devicectl list devices" >&2; exit 1 ;;
    1) DEVICE="${FOUND[0]}" ;;
    *) echo "✗ ${#FOUND[@]} connected iPhones — name one: install-ios.sh <udid>" >&2
       printf '   %s\n' "${FOUND[@]}" >&2; exit 1 ;;
  esac
fi
echo "› Target device: $DEVICE"

echo "› Building Release for device…"
# Pinned to the phone rather than to `generic/platform=iOS`, which resolves to arm64 **and
# arm64e** — a slice the vendored xcframeworks and the SwiftPM dependencies do not build, so the
# app target's arm64e pass fails to find a module for any of them. A real device resolves to the
# one slice that ships.
#
# That pinning is also why the build's own failure has to be read rather than trusted: xcodebuild
# resolves the destination before it compiles a line, so a phone that is merely asleep fails here,
# and a bare `|| exit 3` would report a code defect for a locked screen. Exit 3 is a genuine build
# failure; an unreachable phone is exit 1 and says so.
BUILD_LOG="$(mktemp -t transcriptionstudio-install-ios)"
set +e
xcodebuild -project TranscriptionStudio.xcodeproj -scheme TranscriptionStudio \
  -configuration Release -destination "platform=iOS,id=$DEVICE" \
  -allowProvisioningUpdates -derivedDataPath "$DERIVED" \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym build 2>&1 | tee "$BUILD_LOG"
# `$?` is `tee`'s. The producer's status is what decides anything here.
BUILD_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  if grep -q "Unable to find a destination matching" "$BUILD_LOG"; then
    echo "✗ $DEVICE is paired but not reachable — wake and unlock the phone, then re-run." >&2
    exit 1
  fi
  exit 3
fi
rm -f "$BUILD_LOG"

BUILT="$PRODUCTS/$APP_NAME"
[[ -d "$BUILT" ]] || { echo "✗ Built app not found: $BUILT" >&2; exit 1; }

# Retain this build's symbols, keyed by the UUID a crash report names — the fleet's one hook,
# which prunes PER BINARY over the archive every app shares. It exits 0 when there is no dSYM to
# keep, so an install never fails over symbols.
#
# Every dSYM the build produced rather than the app's alone: this bundle ships three extensions
# (share, widget, background assets) beside the app, a crash frame names the UUID of whichever
# binary it happened in, and the hook's pruning is per binary precisely so each one can be kept
# without evicting the others.
for dsym in "$PRODUCTS"/*.dSYM; do
  [[ -d "$dsym" ]] || continue
  "$HOME/Jarvis/tools/diag/archive-dsym.sh" "$dsym"
done

echo "› Installing…"
xcrun devicectl device install app --device "$DEVICE" "$BUILT"

echo "✓ Installed $APP_NAME on $DEVICE — it runs the OLD code until it is next launched."

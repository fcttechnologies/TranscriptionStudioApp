#!/usr/bin/env bash
# Build transcribe-cli and install it to a STABLE, app-owned path — NOT .build/, which is a
# build-output dir that gets swept by build churn (worktrees, cleans, coverage runs). The 24/7
# serve LaunchAgent runs from this stable copy, so a restart/reboot can never find a missing
# binary. Re-run this after any change to the CLI to refresh the installed binary.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DEST_DIR="$HOME/Library/Application Support/TranscriptionStudio/bin"
mkdir -p "$DEST_DIR"

echo "› Building transcribe-cli (release)…"
BUILD_DIR="$(mktemp -d -t ts-cli-build)"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcodebuild -project TranscriptionStudio.xcodeproj -scheme transcribe-cli \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" build > "$BUILD_DIR/build.log" 2>&1 \
  || { tail -40 "$BUILD_DIR/build.log"; exit 1; }
PRODUCTS="$BUILD_DIR/Build/Products/Release"

# Install to a fresh file and rename over the old one, re-signing on the way. The binary is
# ad-hoc signed, and overwriting one IN PLACE leaves the kernel holding a signature that no
# longer matches the bytes — it then SIGKILLs the process the instant it launches, taking the
# 24/7 service down with no error in any log. A new inode plus a fresh signature avoids both.
STAGED="$DEST_DIR/.transcribe-cli.incoming"
cp "$PRODUCTS/transcribe-cli" "$STAGED"
codesign -f -s - "$STAGED"
mv -f "$STAGED" "$DEST_DIR/transcribe-cli"
echo "› Installed $DEST_DIR/transcribe-cli"

# The SPM resource bundles must travel with the binary: `Bundle.module` resolves them beside
# the executable, so a bundle left behind in .build/ is a runtime FATAL the moment its code
# path runs (FluidAudio's G2P lexicon dies this way on the first cloned /speak). Stage-and-
# rename per bundle for the same no-torn-state reason as the binary.
for bundle in "$PRODUCTS"/*.bundle; do
  name="$(basename "$bundle")"
  staged_bundle="$DEST_DIR/.$name.incoming"
  rm -rf "$staged_bundle"
  cp -R "$bundle" "$staged_bundle"
  rm -rf "$DEST_DIR/$name"
  mv "$staged_bundle" "$DEST_DIR/$name"
  echo "› Installed $DEST_DIR/$name"
done

# (Re)load the serve LaunchAgent onto the fresh binary.
launchctl kickstart -k "gui/$(id -u)/com.fcttechnologies.transcriptionstudio" 2>/dev/null \
  || echo "  (LaunchAgent not loaded yet — load setup/launch-agents/com.fcttechnologies.transcriptionstudio.plist)"
echo "› Serve reloaded."

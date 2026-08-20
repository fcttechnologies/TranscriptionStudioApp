#!/usr/bin/env bash
#
# Transcription Studio's full gate. Nothing is done until this is green.
#
# The app ships from ONE app target to iOS and macOS, so every check that reads a built artifact
# runs once per platform: metadata, entitlements and plist keys are produced per artifact, and a
# green iOS reading says nothing about the macOS one.
#
# This is the Debug loop. Before shipping, build Release on both platforms too and re-read the
# artifacts: a `#if DEBUG` path that release code still calls compiles clean here and breaks only
# in the archive. A Release *simulator* build additionally needs
# `ONLY_ACTIVE_ARCH=YES ARCHS=arm64` — Release defaults to building the x86_64 sim slice too, and
# the `_CoreSpotlight_FoundationModels` cross-import overlay is absent there.
#
# `swift test` here is the host suite. The real-model and bench suites are env-gated and off by
# default; run them by hand when touching those paths:
#   SORTFORMER_MODEL_OK=1 swift test --filter Sortformer
#   CONCURRENT_BENCH=1    swift test --filter ConcurrentLoadBench
#   LUXTTS_MODEL_OK=1     swift test --filter LuxTtsLive
# The real-engine integration tests read TestResources/*.wav (gitignored) — run
# scripts/make-verification-audio.sh once before the full suite.
#
# Usage:  scripts/gate.sh
# Env:    SIM_NAME  simulator device name (default "iPhone 17 Pro"). A concurrent lane points
#                   this at its own simulator; two lanes on one device collide on boot and install.

set -euo pipefail

cd "$(dirname "$0")/.."

SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
# The promoted set is 10 on macOS — exactly Apple's cap — and 9 on iOS, which has no URL ingest
# and so no TranscribeLinkIntent. Extras past the cap are dropped with no error, so the count is
# pinned rather than merely bounded.
SHORTCUT_COUNT_MAC=10
SHORTCUT_COUNT_IOS=9
VERIFY_SHORTCUTS="../FCTFoundation/scripts/verify-app-shortcuts.py"
DD="$(mktemp -d -t ts-gate)"
trap 'rm -rf "${DD}"' EXIT

fail() { echo "==> FAIL: $*"; exit 1; }

# Any Swift *source* warning is a defect. The appintentsmetadataprocessor "Metadata extraction
# skipped" notices are build-tool output, not compiler warnings, and are excluded.
check_warnings() {
  local log="$1" label="$2" found
  found="$(grep -E '\.swift:[0-9]+:[0-9]+: warning:' "${log}" || true)"
  [ -z "${found}" ] || { echo "${found}"; fail "${label} produced Swift source warnings (log: ${log})"; }
}

echo "==> Host suite: swift test"
swift test

# The committed .xcodeproj must be what project.yml currently generates — compared against the
# file on disk, not against git HEAD, so the check is about drift rather than about being mid-edit.
echo "==> Committed project matches project.yml"
cp TranscriptionStudio.xcodeproj/project.pbxproj "${DD}/project.pbxproj.before"
xcodegen generate >/dev/null
diff -q "${DD}/project.pbxproj.before" TranscriptionStudio.xcodeproj/project.pbxproj >/dev/null \
  || fail "TranscriptionStudio.xcodeproj was stale — project.yml regenerates it differently. It has
      now been regenerated; review and commit it."

build() {
  local label="$1" destination="$2" log="${DD}/${1}.log"
  echo "==> ${label}: build"
  if ! xcodebuild -project TranscriptionStudio.xcodeproj -scheme TranscriptionStudio \
        -destination "${destination}" -derivedDataPath "${DD}/${label}" \
        -allowProvisioningUpdates build >"${log}" 2>&1; then
    tail -40 "${log}"
    fail "${label} build failed (log: ${log})"
  fi
  check_warnings "${log}" "${label}"
}

build ios "platform=iOS Simulator,name=${SIM_NAME}"
build macos "platform=macOS,arch=arm64"

IOS_APP="${DD}/ios/Build/Products/Debug-iphonesimulator/TranscriptionStudio.app"
MAC_APP="${DD}/macos/Build/Products/Debug/TranscriptionStudio.app"

# The App Shortcuts provider must compile into the app target. A provider left in TranscriptionKit
# builds, links, and registers NOTHING — silently, at every other layer. Only the built app
# bundle's mangled provider name tells the truth, so both artifacts are read.
echo "==> App Shortcuts registered in both artifacts"
"${VERIFY_SHORTCUTS}" --expect "${SHORTCUT_COUNT_MAC}" --quiet "${MAC_APP}" \
  || fail "macOS App Shortcuts did not register — see the message above."
"${VERIFY_SHORTCUTS}" --expect "${SHORTCUT_COUNT_IOS}" --quiet "${IOS_APP}" \
  || fail "iOS App Shortcuts did not register — see the message above."

# The Mac slice is deliberately NOT sandboxed: it runs Hardened Runtime plus the hardened-process
# entitlements, because URL ingest shells out to yt-dlp/ffmpeg. The App Group carries the shared
# store the Share extension writes into, and the keychain group carries the FCT account session.
# The iOS artifact cannot be checked this way: a simulator build embeds no entitlements at all.
echo "==> macOS entitlements"
MAC_ENTITLEMENTS="$(codesign -d --entitlements - --xml "${MAC_APP}" 2>/dev/null)"
for key in com.apple.security.hardened-process com.apple.developer.applesignin \
           com.apple.security.application-groups keychain-access-groups; do
  echo "${MAC_ENTITLEMENTS}" | grep -q "${key}" || fail "macOS build is missing ${key}"
done
echo "${MAC_ENTITLEMENTS}" | grep -q com.apple.security.app-sandbox \
  && fail "macOS app picked up the sandbox — it ships hardened and unsandboxed"

# A macOS app extension must be sandboxed even when its host is not, and both then resolve the
# same App Group container. Nothing else reports a missing sandbox here.
echo "==> macOS Share extension is sandboxed into the App Group"
MAC_EXT_ENTITLEMENTS="$(codesign -d --entitlements - --xml \
  "${MAC_APP}/Contents/PlugIns/ShareExtension.appex" 2>/dev/null)"
for key in com.apple.security.app-sandbox com.apple.security.application-groups; do
  echo "${MAC_EXT_ENTITLEMENTS}" | grep -q "${key}" || fail "macOS Share extension is missing ${key}"
done

# Two bundle ids from one target via PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] — and on this app it is
# the *iOS* id that carries the suffix, the reverse of every other app here. That is exactly the
# kind of conditional a regeneration can drop without any build failing.
echo "==> Bundle ids per platform"
ios_id="$(plutil -extract CFBundleIdentifier raw -o - "${IOS_APP}/Info.plist")"
mac_id="$(plutil -extract CFBundleIdentifier raw -o - "${MAC_APP}/Contents/Info.plist")"
[ "${ios_id}" = "com.fcttechnologies.TranscriptionStudioiOS" ] || fail "iOS bundle id is ${ios_id}"
[ "${mac_id}" = "com.fcttechnologies.TranscriptionStudio" ] || fail "macOS bundle id is ${mac_id}"

ios_ext_id="$(plutil -extract CFBundleIdentifier raw -o - "${IOS_APP}/PlugIns/ShareExtension.appex/Info.plist")"
mac_ext_id="$(plutil -extract CFBundleIdentifier raw -o - "${MAC_APP}/Contents/PlugIns/ShareExtension.appex/Contents/Info.plist")"
[ "${ios_ext_id}" = "com.fcttechnologies.TranscriptionStudioiOS.ShareExtension" ] \
  || fail "iOS Share extension bundle id is ${ios_ext_id}"
[ "${mac_ext_id}" = "com.fcttechnologies.TranscriptionStudio.ShareExtension" ] \
  || fail "macOS Share extension bundle id is ${mac_ext_id}"

# The Share extension ships on both platforms; the widget and Background Assets extensions are
# iOS-only and must NOT ride along into the macOS product, where embedded iOS-only content is a
# hard failure. Nothing else reports this, in either direction.
echo "==> Embedded extensions per platform"
[ -d "${IOS_APP}/PlugIns/ShareExtension.appex" ] || fail "iOS build is missing the Share extension"
[ -d "${IOS_APP}/PlugIns/WidgetExtensioniOS.appex" ] || fail "iOS build is missing the widget extension"
[ -d "${IOS_APP}/Extensions/BackgroundAssetsExtension.appex" ] \
  || fail "iOS build is missing the Background Assets extension"
[ -d "${MAC_APP}/Contents/PlugIns/ShareExtension.appex" ] \
  || fail "macOS build is missing the Share extension"
[ ! -e "${MAC_APP}/Contents/PlugIns/WidgetExtensioniOS.appex" ] \
  || fail "macOS build embedded the iOS-only widget extension"
[ ! -e "${MAC_APP}/Contents/Extensions/BackgroundAssetsExtension.appex" ] \
  || fail "macOS build embedded the iOS-only Background Assets extension"

# TranscriptionMacKit uses APIs with no iOS availability, so the app's dependency edge on it is
# filtered to macOS. A dropped filter stops the iOS build compiling, but nothing reports the other
# direction — a filter that silently excluded macOS too would leave a Mac app with no meeting
# capture and no URL ingest, and it would still build. ScreenCaptureKit in the link list is the
# proof the kit is actually in the macOS product. Under ENABLE_DEBUG_DYLIB the code lives in a
# sibling dylib rather than the launcher, so both are scanned.
echo "==> Mac-only kit linked on macOS, absent from iOS"
mac_links() { otool -L "${MAC_APP}/Contents/MacOS/TranscriptionStudio"* ; }
mac_links | grep -q ScreenCaptureKit \
  || fail "macOS build did not link ScreenCaptureKit — TranscriptionMacKit is not in the product"
otool -L "${IOS_APP}/TranscriptionStudio"* | grep -q ScreenCaptureKit \
  && fail "iOS build linked ScreenCaptureKit — the macOS-only dependency edge lost its filter"

# One merged asset catalog serves both idioms. A catalog left carrying only the `ios` platform entry
# leaves the macOS build with no app icon, and actool says so in output the Swift-warning filter
# above does not catch. CFBundleIconName sits at a different depth per platform — top-level on
# macOS, nested under CFBundleIcons on iOS — so each is read at its own path.
echo "==> App icon per platform"
[ -f "${MAC_APP}/Contents/Resources/AppIcon.icns" ] \
  || fail "macOS build has no app icon (merged asset catalog is missing the mac idiom entry)"
plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "${IOS_APP}/Info.plist" >/dev/null \
  || fail "iOS build has no app icon"

echo "==> PASS: host suite green, both platforms build warning-free, shortcuts registered on both."

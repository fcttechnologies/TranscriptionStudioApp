#!/usr/bin/env bash
#
# Transcription Studio's full gate. Nothing is done until this is green.
#
# The app ships from ONE app target to iOS and macOS, so every check that reads a built artifact
# runs once per platform: metadata, entitlements and plist keys are produced per artifact, and a
# green iOS reading says nothing about the macOS one. The unit suite is APP-HOSTED and runs on the
# macOS destination (native on this Mac, no simulator); `transcribe-cli` carries its own logic
# suite beside it.
#
# This is the Debug loop. Before shipping, build Release on both platforms too and re-read the
# artifacts (scripts/package-mac.sh does the Mac one): a `#if DEBUG` path that release code still
# calls compiles clean here and breaks only in the archive. A Release *simulator* build
# additionally needs `ONLY_ACTIVE_ARCH=YES ARCHS=arm64` — Release defaults to building the x86_64
# sim slice too, and the `_CoreSpotlight_FoundationModels` cross-import overlay is absent there.
#
# The real-model and bench suites are env-gated and off by default; run them by hand when touching
# those paths. Through xcodebuild an env var must be prefixed TEST_RUNNER_ to reach the test host:
#   TEST_RUNNER_SORTFORMER_MODEL_OK=1 xcodebuild … test -only-testing:TranscriptionStudioTests/SortformerRealModelTests
#   TEST_RUNNER_CONCURRENT_BENCH=1    xcodebuild … test -only-testing:TranscriptionStudioTests/ConcurrentLoadBench
#   TEST_RUNNER_LUXTTS_MODEL_OK=1     xcodebuild … test -only-testing:TranscriptionStudioTests/LuxTtsLiveTests
# The real-engine integration tests read TestResources/*.wav (gitignored) — run
# scripts/make-verification-audio.sh once before the full suite.
#
# Usage:  scripts/gate.sh
# Env:    SIM_NAME  simulator device name for the iOS build leg (default "iPhone 17 Pro"). A
#         concurrent lane points this at its own simulator; two lanes on one device collide on
#         boot and install.

set -euo pipefail

cd "$(dirname "$0")/.."

source "../FCTFoundation/scripts/gate-lib.sh"
phase_init

SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
# The promoted set is 10 on macOS — exactly Apple's cap — and 9 on iOS, which has no URL ingest
# and so no TranscribeLinkIntent. Extras past the cap are dropped with no error, so the count is
# pinned rather than merely bounded.
SHORTCUT_COUNT_MAC=10
SHORTCUT_COUNT_IOS=9
MIN_APP_TESTS=564
# The fleet's localization floor. Every one of these must be declared in CFBundleLocalizations
# (the INFOPLIST_KEY_ variant is silently ignored) AND carry a real value for every key in both
# catalogs; the drift leg below proves the second half against the compiler's own extraction set.
SHIPPED_LANGUAGES="en,es,zh-Hans,fr,de,pt-BR,ja,ko,it,ru"
VERIFY_SHORTCUTS="../FCTFoundation/scripts/verify-app-shortcuts.py"
VERIFY_ICONS="../FCTFoundation/scripts/verify-app-icons.py"
DD="$(mktemp -d -t ts-gate)"
# The logs outlive the DerivedData they describe: a leg's log is read AFTER the run, and a failure
# that names a path inside ${DD} names a path the exit trap has already deleted.
LOGS="/tmp/ts-gate-logs"
rm -rf "${LOGS}" && mkdir -p "${LOGS}"
trap 'rm -rf "${DD}"' EXIT

fail() { echo "==> FAIL: $*"; exit 1; }

# The committed .xcodeproj must be what project.yml currently generates — compared against the
# file on disk, not against git HEAD, so the check is about drift rather than about being mid-edit.
echo "==> Committed project matches project.yml"
cp TranscriptionStudio.xcodeproj/project.pbxproj "${DD}/project.pbxproj.before"
xcodegen generate >/dev/null
diff -q "${DD}/project.pbxproj.before" TranscriptionStudio.xcodeproj/project.pbxproj >/dev/null \
  || fail "TranscriptionStudio.xcodeproj was stale — project.yml regenerates it differently. It has
      now been regenerated; review and commit it."
mark "xcodegen check"

# Every leg gets its own -derivedDataPath, which is what lets them run concurrently: two
# xcodebuilds against one DerivedData contend on the same build database.
start_build() {
  local label="$1" scheme="$2" action="$3" destination="$4"; shift 4
  echo "==> ${label}: ${action} — started"
  leg_start "${label}" "${LOGS}/${label}.log" \
    xcodebuild -project TranscriptionStudio.xcodeproj -scheme "${scheme}" \
      -destination "${destination}" -derivedDataPath "${DD}/${label}" \
      -allowProvisioningUpdates "$@" "${action}"
}

collect_build() {
  local label="$1" log="${LOGS}/${1}.log"
  leg_wait "${label}" || { tail -40 "${log}"; fail "${label} failed (log: ${log})"; }
  check_warnings "${log}" "${label}"
}

# WAVE 1 — the app on both platforms and the headless CLI, at once. They share no state and the
# box has cores to spare; serially this was the sum of three independent builds.
#
# The macOS and CLI legs are `build-for-testing`, not `build`: that produces the same artifacts AND
# compiles their test bundles, so each suite below is a test RUN rather than a second build of the
# graph it just built. The headless CLI builds from the same sources as a separate tool target; it
# must never rot.
start_build ios   TranscriptionStudio build             "platform=iOS Simulator,name=${SIM_NAME}"
start_build macos TranscriptionStudio build-for-testing "platform=macOS,arch=arm64"
start_build cli   transcribe-cli      build-for-testing "platform=macOS,arch=arm64"
collect_build macos
collect_build cli
collect_build ios
mark "Debug + CLI builds (concurrent)"

# The unit suite is app-hosted, so it runs on a destination rather than on the bare host. The
# macOS destination hosts it natively on this Mac — no simulator, no device — which keeps the
# everyday loop fast. It reuses the macOS build above, so this leg is the test run, not a rebuild.
#
# The count is asserted, not just the exit status: a target that stops compiling its test sources,
# or a scheme that stops listing them, reports `** TEST SUCCEEDED **` having executed nothing. Only
# a floor is pinned — adding tests must never fail the gate, losing them always must.
# WAVE 2 — both suites beside the Release build. The suites are app-hosted and their wall is
# mostly async settles rather than CPU, so overlapping them with the one remaining compile is
# close to free; serially the Release build was 42% of this gate on its own.
echo "==> Unit suite + CLI suite + Release builds"
TEST_LOG="${LOGS}/tests.log"
CLI_TEST_LOG="${LOGS}/clitests.log"
leg_start unit-suite "${TEST_LOG}" \
  xcodebuild -project TranscriptionStudio.xcodeproj -scheme TranscriptionStudio \
    -destination "platform=macOS,arch=arm64" -only-testing:TranscriptionStudioTests \
    -derivedDataPath "${DD}/macos" -allowProvisioningUpdates test-without-building
leg_start cli-suite "${CLI_TEST_LOG}" \
  xcodebuild -project TranscriptionStudio.xcodeproj -scheme transcribe-cli \
    -destination "platform=macOS,arch=arm64" -only-testing:TranscribeCLITests \
    -derivedDataPath "${DD}/cli" -allowProvisioningUpdates test-without-building
start_build macos-release TranscriptionStudio build "platform=macOS,arch=arm64" \
  -configuration Release
# The iOS Release leg is here for the one class of break Debug structurally cannot see: a
# `#if DEBUG` symbol that shipping code still calls compiles clean all day and fails only in the
# archive. `ONLY_ACTIVE_ARCH=YES ARCHS=arm64` is not an optimisation — Release defaults
# ONLY_ACTIVE_ARCH to NO, and the x86_64 simulator slice cannot resolve the
# `_CoreSpotlight_FoundationModels` cross-import overlay, so without the pin this leg does not
# merely take twice as long, it fails.
start_build ios-release TranscriptionStudio build "platform=iOS Simulator,name=${SIM_NAME}" \
  -configuration Release ONLY_ACTIVE_ARCH=YES ARCHS=arm64

leg_wait unit-suite || { grep -E '✘|error:|failed' "${TEST_LOG}" | head -40; fail "unit suite failed (log: ${TEST_LOG})"; }
check_warnings "${TEST_LOG}" "unit suite"
TEST_COUNT="$(sed -n 's/.*Test run with \([0-9]*\) tests.*/\1/p' "${TEST_LOG}" | tail -1)"
[ -n "${TEST_COUNT}" ] || fail "could not read a test count from ${TEST_LOG} — the suite may not have run"
[ "${TEST_COUNT}" -ge "${MIN_APP_TESTS}" ] \
  || fail "only ${TEST_COUNT} tests ran, expected at least ${MIN_APP_TESTS} — tests stopped being compiled or listed"
echo "    ${TEST_COUNT} tests passed"

# The CLI's own logic suite rides its scheme.
leg_wait cli-suite || { grep -E '✘|error:|failed' "${CLI_TEST_LOG}" | head -20; fail "CLI suite failed (log: ${CLI_TEST_LOG})"; }
check_warnings "${CLI_TEST_LOG}" "CLI suite"
CLI_TEST_COUNT="$(sed -n 's/.*Test run with \([0-9]*\) tests.*/\1/p' "${CLI_TEST_LOG}" | tail -1)"
[ -n "${CLI_TEST_COUNT}" ] || fail "could not read a test count from ${CLI_TEST_LOG}"
echo "    ${CLI_TEST_COUNT} tests passed"
collect_build macos-release
collect_build ios-release
mark "suites + Release builds (concurrent)"

IOS_APP="${DD}/ios/Build/Products/Debug-iphonesimulator/TranscriptionStudio.app"
MAC_APP="${DD}/macos/Build/Products/Debug/TranscriptionStudio.app"

# The App Shortcuts provider must compile into the app target. A provider left in another target
# builds, links, and registers NOTHING — silently, at every other layer. Only the built app
# bundle's mangled provider name tells the truth, so both artifacts are read.
echo "==> App Shortcuts registered in both artifacts"
"${VERIFY_SHORTCUTS}" --expect "${SHORTCUT_COUNT_MAC}" --quiet "${MAC_APP}" \
  || fail "macOS App Shortcuts did not register — see the message above."
"${VERIFY_SHORTCUTS}" --expect "${SHORTCUT_COUNT_IOS}" --quiet "${IOS_APP}" \
  || fail "iOS App Shortcuts did not register — see the message above."

# The Mac slice is deliberately NOT sandboxed: it runs Hardened Runtime plus the hardened-process
# entitlements on RELEASE (scripts/package-mac.sh builds that; see project.yml's configs), because
# URL ingest shells out to yt-dlp/ffmpeg. The Debug artifact carries the base capability set —
# Sign in with Apple, the App Group (the shared store the Share extension writes into), and the
# keychain group (the FCT account session); its hardening keys live in the Release entitlements
# file so the app-hosted test host stays unhardened. The iOS artifact cannot be checked this way:
# a simulator build embeds no entitlements at all.
echo "==> macOS entitlements"
MAC_ENTITLEMENTS="$(codesign -d --entitlements - --xml "${MAC_APP}" 2>/dev/null)"
for key in com.apple.developer.applesignin \
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

# Universal Purchase requires ONE bundle id across every destination: an iPhone subscriber is
# entitled on the Mac only when both artifacts carry the same id. A per-destination override
# reintroduced here would split the store record again, and no build would fail.
echo "==> Bundle id identical on both platforms"
ios_id="$(plutil -extract CFBundleIdentifier raw -o - "${IOS_APP}/Info.plist")"
mac_id="$(plutil -extract CFBundleIdentifier raw -o - "${MAC_APP}/Contents/Info.plist")"
[ "${ios_id}" = "com.fcttechnologies.TranscriptionStudio" ] || fail "iOS bundle id is ${ios_id}"
[ "${mac_id}" = "${ios_id}" ] || fail "macOS bundle id is ${mac_id}, expected ${ios_id}"

ios_ext_id="$(plutil -extract CFBundleIdentifier raw -o - "${IOS_APP}/PlugIns/ShareExtension.appex/Info.plist")"
mac_ext_id="$(plutil -extract CFBundleIdentifier raw -o - "${MAC_APP}/Contents/PlugIns/ShareExtension.appex/Contents/Info.plist")"
[ "${ios_ext_id}" = "com.fcttechnologies.TranscriptionStudio.ShareExtension" ] \
  || fail "iOS Share extension bundle id is ${ios_ext_id}"
[ "${mac_ext_id}" = "${ios_ext_id}" ] \
  || fail "macOS Share extension bundle id is ${mac_ext_id}, expected ${ios_ext_id}"

# The background-transcription wildcard is what BGTaskScheduler matches a submitted job against,
# and ContinuedTranscriptionTask builds the concrete id from Bundle.main at runtime. If this drifts
# from the app's own id every background job is rejected — at runtime, with nothing at build time
# reporting it.
bg_id="$(plutil -extract BGTaskSchedulerPermittedIdentifiers.0 raw -o - "${IOS_APP}/Info.plist")"
[ "${bg_id}" = "${ios_id}.transcription.*" ] \
  || fail "BGTaskSchedulerPermittedIdentifiers is ${bg_id}, expected ${ios_id}.transcription.*"

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

# A privacy manifest is a plain resource, and a bundle's declarations never inherit from the app
# that embeds it: every bundle Transcription Studio ships needs its own. A manifest authored into a
# directory that is not on the target's source paths appears in no artifact and no build reports
# it — it documents intent while satisfying nothing, so all six are read out of the built products.
# The file sits at the bundle root on iOS and under Contents/Resources on macOS.
echo "==> Privacy manifest in every shipped bundle"
for manifest in "${IOS_APP}/PrivacyInfo.xcprivacy" \
                "${IOS_APP}/PlugIns/ShareExtension.appex/PrivacyInfo.xcprivacy" \
                "${IOS_APP}/PlugIns/WidgetExtensioniOS.appex/PrivacyInfo.xcprivacy" \
                "${IOS_APP}/Extensions/BackgroundAssetsExtension.appex/PrivacyInfo.xcprivacy" \
                "${MAC_APP}/Contents/Resources/PrivacyInfo.xcprivacy" \
                "${MAC_APP}/Contents/PlugIns/ShareExtension.appex/Contents/Resources/PrivacyInfo.xcprivacy"; do
  [ -f "${manifest}" ] || { fail "missing ${manifest}"; continue; }
  plutil -lint "${manifest}" >/dev/null || fail "${manifest} is not a valid property list"
  [ "$(plutil -extract NSPrivacyTracking raw -o - "${manifest}" 2>/dev/null)" = "false" ] \
    || fail "${manifest} does not declare NSPrivacyTracking = false"
done

# ScreenCaptureKit has no meeting-capture API on iOS, so the Mac-only capture code compiles into
# the macOS product alone. A dropped guard stops the iOS build compiling, but nothing reports the
# other direction — a silent exclusion would leave a Mac app with no meeting capture and no URL
# ingest, and it would still build. ScreenCaptureKit in the link list is the proof the Mac-only
# code is actually in the product. Under ENABLE_DEBUG_DYLIB the code lives in a sibling dylib
# rather than the launcher, so both are scanned.
echo "==> Mac-only kit linked on macOS, absent from iOS"
# Only the Mach-O files, named exactly: a glob here also sweeps in the SwiftPM resource bundles,
# which otool cannot read and which would make the check emit errors it then ignores.
linked_frameworks() {
  local dir="$1" name="$2" f
  for f in "${dir}/${name}" "${dir}/${name}.debug.dylib"; do
    [ -f "${f}" ] && otool -L "${f}"
  done
}
linked_frameworks "${MAC_APP}/Contents/MacOS" TranscriptionStudio | grep -q ScreenCaptureKit \
  || fail "macOS build did not link ScreenCaptureKit — the Mac-only capture is not in the product"
linked_frameworks "${IOS_APP}" TranscriptionStudio | grep -q ScreenCaptureKit \
  && fail "iOS build linked ScreenCaptureKit — the macOS-only source guard lost its filter"

# One merged asset catalog serves both idioms. An AppIcon set declaring only one platform's idiom
# compiles clean and ships the other platform with no icon at all: actool reports it in output the
# Swift-warning filter above does not catch, and nothing else fails. Only the built bundles tell
# the truth, so both artifacts are read.
echo "==> App icon in both artifacts"
"${VERIFY_ICONS}" "${IOS_APP}" "${MAC_APP}" \
  || fail "App icon missing — see the message above."

# A `Text("…")` added in source reaches the String Catalog only when Xcode's IDE extracts it on
# build; a command-line xcodebuild never does. So the catalog silently stops covering the UI and
# every non-English locale ships the raw English key — a failure no build, no test and no artifact
# check anywhere else in this gate can see. The comparison is against the compiler's OWN extraction
# set (the .stringsdata swiftc already emitted into the macOS DerivedData), so it costs no build.
#
# SCOPE, so a green leg is not read as more than it is: this covers strings declared in THIS
# repo's sources. FCTFoundation's UI — the account gate, the onboarding carousel's own chrome —
# resolves through `Bundle.module` against the package's own complete catalogs, so those surfaces
# are the package's to translate and are not counted here.
#
# Both catalogs, table by table rather than as one merged pile: the App Shortcut phrases carry
# their own, and a phrase sitting in the app's Localizable table is exactly as undelivered as one
# sitting nowhere. `--require-languages` is what makes the leg about coverage rather than mere
# presence — a key with no Japanese value ships English to a Japanese phone, and the catalog
# holding the key is not the same as the catalog carrying the string.
echo "==> Localization drift (this repo's own sources)"
check_loc_drift "${DD}/macos" --require-languages "${SHIPPED_LANGUAGES}" \
  Sources/App/Localizable.xcstrings Sources/App/AppShortcuts.xcstrings
mark "artifact checks (Debug)"

# The Release Mac archive is the shippable artifact and the ONLY place Hardened Runtime rides:
# prove it still signs with the hardened-process entitlements (they live in a Release-only
# entitlements file — see project.yml's configs) and without a sandbox. The build itself already
# ran, beside the suites.
echo "==> Release macOS: hardened entitlements"
REL_APP="${DD}/macos-release/Build/Products/Release/TranscriptionStudio.app"
REL_ENTITLEMENTS="$(codesign -d --entitlements - --xml "${REL_APP}" 2>/dev/null)"
for key in com.apple.security.hardened-process com.apple.developer.applesignin \
           com.apple.security.application-groups keychain-access-groups; do
  echo "${REL_ENTITLEMENTS}" | grep -q "${key}" || fail "Release macOS app is missing ${key}"
done
echo "${REL_ENTITLEMENTS}" | grep -q com.apple.security.app-sandbox \
  && fail "Release macOS app picked up the sandbox"
mark "artifact checks (Release)"

phase_table
echo "==> PASS: ${TEST_COUNT} + ${CLI_TEST_COUNT} tests green, both platforms + CLI built" \
     "warning-free, shortcuts registered on both platforms, Release Mac hardened."

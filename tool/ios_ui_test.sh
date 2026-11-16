#!/usr/bin/env bash
# Runs the XCUITest suite (ios/RunnerUITests) on a connected iPhone/iPad or
# a simulator. See docs/device-testing.md.
#
#   DEVELOPMENT_TEAM=ABCDE12345 tool/ios_ui_test.sh DEVICE_ID [TEST]   (iPhone/iPad)
#   tool/ios_ui_test.sh DEVICE_ID [TEST]                               (simulator)
#
# DEVICE_ID is the UDID shown in the table of `xcrun devicectl list devices`
# (marked "(UDID)"; not the JSON output's `identifier`, which differs) or
# in `xcrun simctl list devices`. TEST narrows the run to target/class or
# target/class/method, e.g. RunnerUITests/RunnerUITests/testOpenLogScreen.
#
# Hardware needs your team, which is passed on the command line only, so it
# never lands in project.pbxproj; the committed project leaves
# DEVELOPMENT_TEAM unset. Simulators sign to run locally and need no team.
#
# A scripted scenario (see testScenario in RunnerUITests.swift):
#
#   SCENARIO="start,hold:60,status:Busy,hold:30,stop" \
#     tool/ios_ui_test.sh DEVICE_ID RunnerUITests/RunnerUITests/testScenario
#
# Results go to build/ios_ui_tests/<time>.xcresult.
set -euo pipefail

usage="usage: [DEVELOPMENT_TEAM=TEAMID] tool/ios_ui_test.sh DEVICE_ID [TEST]"
device=${1:?$usage}
only=${2:-}
root=$(cd "$(dirname "$0")/.." && pwd)

# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process.
if [[ -n "${SCENARIO:-}" ]]; then
  export TEST_RUNNER_SCENARIO="$SCENARIO"
fi

# Hardware runs Profile: a Flutter debug build won't start on a device
# without a debugger, and XCUITest launches it without one. Flutter has no
# profile mode for simulators, but debug builds run there unattached.
# (The list is captured first: grep -q stopping early would otherwise
# break simctl's pipe under pipefail.)
simulators=$(xcrun simctl list devices)
if grep -qF "$device" <<<"$simulators"; then
  simulator=true
  configuration=Debug
  flutter_mode=(--debug --simulator)
else
  simulator=false
  configuration=Profile
  flutter_mode=(--profile)
  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "ios_ui_test: $device is not a simulator; set DEVELOPMENT_TEAM to your Apple team id" >&2
    exit 64
  fi
fi

if [[ $simulator == true ]]; then
  # Boots it if needed and waits until it is ready; launching into a
  # simulator that is still booting can fail its preflight checks.
  xcrun simctl bootstatus "$device" -b >/dev/null
fi

# Writes ios/Flutter/Generated.xcconfig for that mode and runs pod install,
# without building the app twice.
(cd "$root" && flutter build ios "${flutter_mode[@]}" --config-only)

result="$root/build/ios_ui_tests/$(date +%Y%m%d-%H%M%S).xcresult"
mkdir -p "$(dirname "$result")"
args=(
  -workspace "$root/ios/Runner.xcworkspace"
  -scheme RunnerUITests
  -configuration "$configuration"
  -destination "id=$device"
  -resultBundlePath "$result"
)
if [[ -n "$only" ]]; then
  args+=(-only-testing:"$only")
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  args+=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

set +e
xcodebuild test "${args[@]}"
status=$?
set -e
echo "ios_ui_test: results in $result"
exit $status

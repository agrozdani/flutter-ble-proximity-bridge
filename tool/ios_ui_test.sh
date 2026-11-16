#!/usr/bin/env bash
# Runs the XCUITest suite (ios/RunnerUITests) on a connected iPhone/iPad or
# a simulator. See docs/device-testing.md.
#
#   DEVELOPMENT_TEAM=ABCDE12345 tool/ios_ui_test.sh DEVICE_ID [TEST]
#
# DEVICE_ID is a UDID from `xcrun devicectl list devices` (physical) or
# `xcrun simctl list devices` (simulator). TEST narrows the run, e.g.
# RunnerUITests/RunnerUITests/testOpenLogScreen.
#
# The team is passed on the command line only, so it never lands in
# project.pbxproj; the committed project keeps DEVELOPMENT_TEAM empty.
# Simulators need it too.
#
# A scripted scenario (see testScenario in RunnerUITests.swift):
#
#   SCENARIO="start,hold:60,status:Busy,hold:30,stop" \
#     DEVELOPMENT_TEAM=ABCDE12345 tool/ios_ui_test.sh DEVICE_ID RunnerUITests/RunnerUITests/testScenario
#
# Results, screenshots included, go to build/ios_ui_tests/<time>.xcresult.
set -euo pipefail

# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process.
[[ -n "${SCENARIO:-}" ]] && export TEST_RUNNER_SCENARIO="$SCENARIO"

device=${1:?usage: DEVELOPMENT_TEAM=TEAMID tool/ios_ui_test.sh DEVICE_ID [TEST]}
only=${2:-}
root=$(cd "$(dirname "$0")/.." && pwd)
result="$root/build/ios_ui_tests/$(date +%Y%m%d-%H%M%S).xcresult"
mkdir -p "$(dirname "$result")"

# Hardware runs Profile: a Flutter debug build won't start on a device
# without a debugger, and XCUITest launches it without one. Flutter has no
# profile mode for simulators, but debug builds run there unattached.
if xcrun simctl list devices | grep -q "$device"; then
  configuration=Debug
  flutter_mode=(--debug --simulator)
else
  configuration=Profile
  flutter_mode=(--profile)
fi

# Writes ios/Flutter/Generated.xcconfig for that mode and runs pod install,
# without building the app twice.
(cd "$root" && flutter build ios "${flutter_mode[@]}" --config-only)

args=(
  -workspace "$root/ios/Runner.xcworkspace"
  -scheme RunnerUITests
  -configuration "$configuration"
  -destination "id=$device"
  -resultBundlePath "$result"
)
[[ -n "$only" ]] && args+=(-only-testing:"$only")
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "ios_ui_test: set DEVELOPMENT_TEAM to your Apple team id" >&2
  exit 64
fi
args+=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")

set +e
xcodebuild test "${args[@]}"
status=$?
set -e
echo "ios_ui_test: results in $result"
exit $status

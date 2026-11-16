# Driving the app on real devices

Two scripts tap, swipe and screenshot the app on plugged-in devices, so a
change can be exercised on hardware while
[`tool/devlogs.dart`](../tool/devlogs.dart) collects the logs
([logging.md](logging.md)).

- Android: [`tool/android_ui.sh`](../tool/android_ui.sh), adb input driven
  by the labels on screen.
- iOS: [`tool/ios_ui_test.sh`](../tool/ios_ui_test.sh), which runs the
  XCUITest suite in [`ios/RunnerUITests/`](../ios/RunnerUITests/).

## Android

Needs USB debugging on and the computer authorized on the device. Install a
debug build first (debug, so `devlogs pull` can read the app's files):

```bash
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Then drive it by the text Flutter exposes to accessibility (button labels,
tooltips, list text):

```bash
tool/android_ui.sh launch
tool/android_ui.sh texts            # what's on screen right now
tool/android_ui.sh tap Start
tool/android_ui.sh wait running 10  # fails if it doesn't show up in time
tool/android_ui.sh screenshot /tmp/running.png
tool/android_ui.sh tap Stop
```

Set `ANDROID_SERIAL` when more than one device is attached. When adb can't
reach the device (e.g. a wrong `ANDROID_SERIAL`), the script stops with
adb's own error message. Labels match exactly. Line breaks (and tabs) in a label show as `\n` (`\t`) in
`texts`; pass such a label exactly as printed, in single quotes:

```bash
tool/android_ui.sh tap 'Mock peers\nSynthetic sightings — works on simulators, no Bluetooth or permissions needed'
```

A text field is found by its placeholder (`hint`), e.g.
`tap 'Filter (peer id, component, text)'`; then type with
`adb shell input text ...`.

## iOS (iPhone, iPad, simulator)

iOS has no adb-style input, so taps on iOS come from an XCUITest bundle,
`RunnerUITests`, with its own shared scheme of the same name. Each scenario
is a test method in
[`RunnerUITests.swift`](../ios/RunnerUITests/RunnerUITests.swift).

```bash
DEVELOPMENT_TEAM=<your team id> tool/ios_ui_test.sh <iPhone/iPad UDID>
tool/ios_ui_test.sh <simulator UDID> RunnerUITests/RunnerUITests/testOpenLogScreen
```

A test is named target/class/method; a name that matches nothing still
reports `TEST SUCCEEDED`, with zero tests run.

`testScenario` runs a script of steps from the `SCENARIO` variable, for
two-device Bluetooth tests where another device is driven alongside:

```bash
SCENARIO="start,hold:120,status:Busy,hold:60,stop,hold:60,start,hold:120,logs,shot:logs,back,stop" \
  DEVELOPMENT_TEAM=<team id> tool/ios_ui_test.sh <iPhone/iPad UDID> RunnerUITests/RunnerUITests/testScenario
```

`start` turns mock peers off and accepts iOS's Bluetooth prompt if it
shows. Each step prints `SCENARIO <time> <step>` in the xcodebuild output
as it begins, the time in the device's local time with milliseconds like
the app's log lines, so a script can wait for it and act on the other
device. The full step list is in the test's doc comment.

For an iPhone or iPad, use the UDID that the table printed by
`xcrun devicectl list devices` marks `(UDID)` (the `identifier` in its
JSON output is a different id). For a simulator, use the id from
`xcrun simctl list devices`; the script boots it if needed. Results land in
`build/ios_ui_tests/<time>.xcresult`, with a screenshot for each `shot:`
step and one at the end of each test. Open it in Xcode, or export the
screenshots with
`xcrun xcresulttool export attachments --path <bundle> --output-path <dir>`.

### Signing stays out of the repo

The committed project sets no team: `DEVELOPMENT_TEAM` is `""` on
`Runner` and absent on `RunnerTests` and `RunnerUITests`. For an iPhone or
iPad, the script passes your team as a build setting on the `xcodebuild`
command line with `-allowProvisioningUpdates`, which signs the app and the
UI-test runner without touching `project.pbxproj`. Simulators need no team
(Xcode signs to run locally). Before pushing, check that no team ID got in:

```bash
git diff origin/main -- ios/Runner.xcodeproj | grep DEVELOPMENT_TEAM
```

It should print nothing. A line starting with `+` means a team ID got in.

### One-time device setup

- iOS 17 or later: the UI-test bundle's minimum, because Xcode 27's XCTest
  is built for iOS 17. The app itself still supports iOS 15.5.
- Developer Mode on (Settings → Privacy & Security → Developer Mode).
- The device unlocked while the tests run.

If a run fails with `Timed out while enabling automation mode`, check that
the device is unlocked and look at **Settings → Developer → Enable UI
Automation**. On the iPad used here (iOS 27.2.1, Xcode 27.2) the tests ran
with that setting off and with it on; the one run that failed with this
message has no confirmed cause.

### Why Profile on hardware, Debug on simulators

On hardware the script tests the Profile configuration (the scheme's
default). A Flutter debug build won't start on a physical iOS device without
a debugger attached, and XCUITest launches the app without one. Flutter has
no profile mode for simulators, so for a simulator UDID the script switches
to Debug, which runs there unattached. Mock peers start on in Debug and off
in Profile (they default to `kDebugMode`), so a test that depends on them
sets the switch: `testStartAndStopWithMockPeers` and the scenario's
`start-mock` switch them on, the scenario's `start` switches them off.
Profile builds log at debug level like debug builds (see
[logging.md](logging.md)), so a UI-test run can be followed with `devlogs`
as usual.

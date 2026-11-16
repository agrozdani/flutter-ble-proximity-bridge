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

Set `ANDROID_SERIAL` when more than one device is attached. Labels match
exactly; multi-line labels show `\n` in `texts` output and can't be tapped
by label, so use `swipe` or `adb shell input tap X Y` for those.

## iOS (iPhone, iPad, simulator)

iOS has no adb-style input, so taps on iOS come from an XCUITest bundle,
`RunnerUITests`, with its own shared scheme of the same name. Each scenario
is a test method in
[`RunnerUITests.swift`](../ios/RunnerUITests/RunnerUITests.swift).

```bash
DEVELOPMENT_TEAM=<your team id> tool/ios_ui_test.sh <device UDID>
tool/ios_ui_test.sh <device UDID> RunnerUITests/RunnerUITests/testOpenLogScreen
```

A test is named target/class/method; a name that matches nothing still
reports `TEST SUCCEEDED`, with zero tests run.

`testScenario` runs a script of steps from the `SCENARIO` variable, for
two-device Bluetooth tests where another device is driven alongside:

```bash
SCENARIO="start,hold:120,status:Busy,hold:60,stop,hold:60,start,hold:120,logs,shot:logs,back,stop" \
  DEVELOPMENT_TEAM=<team id> tool/ios_ui_test.sh <device UDID> RunnerUITests/RunnerUITests/testScenario
```

`start` turns mock peers off and accepts iOS's Bluetooth prompt if it
shows. Each step prints `SCENARIO <time> <step>` in the xcodebuild output
as it begins, so a script can wait for it and act on the other device. The
full step list is in the test's doc comment.

UDIDs come from `xcrun devicectl list devices` (hardware) or
`xcrun simctl list devices` (simulators). Results, with a screenshot per
step, land in `build/ios_ui_tests/<time>.xcresult`. Open it in Xcode, or
export screenshots with
`xcrun xcresulttool export attachments --path <bundle> --output-path <dir>`.

### Signing stays out of the repo

The committed project leaves `DEVELOPMENT_TEAM` empty on every target,
`RunnerUITests` included. The script passes your team as a build setting
on the `xcodebuild` command line with `-allowProvisioningUpdates`, which
signs the app and the UI-test runner without touching `project.pbxproj`.
Simulators need the team too. Before pushing, check that no team ID got in:

```bash
git diff origin/main -- ios/Runner.xcodeproj | grep DEVELOPMENT_TEAM
```

It should print nothing. A line starting with `+` means a team ID got in.

### One-time device setup

- Developer Mode on (Settings → Privacy & Security → Developer Mode).
- **Settings → Developer → Enable UI Automation** on. Without it the run
  fails with `Timed out while enabling automation mode`.
- The device unlocked while the tests run.

### Why Profile on hardware, Debug on simulators

On hardware the script tests the Profile configuration (the scheme's
default). A Flutter debug build won't start on a physical iOS device without
a debugger attached, and XCUITest launches the app without one. Flutter has
no profile mode for simulators, so for a simulator UDID the script switches
to Debug, which runs there unattached. In Profile builds `kDebugMode` is false, so mock peers
start off and each test switches them on. Profile builds log at debug
level like debug builds (see [logging.md](logging.md)), so a UI-test run
can be followed with `devlogs` as usual.

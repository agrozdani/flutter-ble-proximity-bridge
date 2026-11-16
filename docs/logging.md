# Logging and debugging

Every layer of the bridge (Dart, Kotlin, Swift) writes the same kind of log
line, so a run on two phones can be read as one story: what Dart asked for,
what native did, what Herald delivered, what the pipeline decided and why,
and what reached the UI.

- Dart: [`lib/src/logging/`](../lib/src/logging/) (`Log`, `LoggingSetup`)
- Android: [`BridgeLog.kt`](../android/app/src/main/kotlin/com/example/ble_proximity_bridge/BridgeLog.kt)
- iOS: [`BridgeLog.swift`](../ios/Runner/BridgeLog.swift)
- Collecting and merging: [`tool/devlogs.dart`](../tool/devlogs.dart)
- In the app: the **Logs** button (receipt icon) in the app bar

## The line format

```text
2026-11-16 10:15:03.123 I native.pipeline [BLE.BLESensor.DelegateQueue] frame 1A2B3C4D ios st=1 col=2 rev=18 OFFLINE v3 via=5F2A0C11 → frame recorded; reported GONE [newest rev=17 online (read 4.1s ago)]
└──── local wall clock ─┘ │ └─ origin.component ┘ └─ thread / queue ──────────┘ └─ message
                          level: D(ebug) I(nfo) W(arn) E(rror)
```

- **Origin** is `dart` or `native`. Native lines name the thread (Android)
  or dispatch queue (iOS) they were logged on: `main`, `frame-sender`,
  Herald's queues.
- **Peer ids** are always upper-case hex, at least 8 digits, the same form
  the UI shows (`Peer 1A2B3C4D`). Grep for an id to follow one peer
  through both devices' logs.
- **`self=`** marks this device's own id (the Dart `identity` line, native
  `start` lines, every `payload` line). `tool/devlogs.dart merge` uses it to
  tag each id with the device it belongs to.
- **Payloads** are described the same way on both platforms:
  `1A2B3C4D android st=2 col=3 rev=17 online v3` (peer id, sender's
  platform, status code, color index, revision, offline flag, protocol
  version).
- Stack traces follow on indented lines.

The format is defined once in
[`log_line.dart`](../lib/src/logging/log_line.dart) and pinned by
[`test/log_test.dart`](../test/log_test.dart); the Kotlin and Swift
`describe` and `peerHex` helpers are pinned against each other by the
native unit tests.

## Where lines go

| | Dart lines | Native lines |
|---|---|---|
| Console | printed (`flutter run` shows them; logcat tag `flutter` on Android) | logcat tag `BPB` (Android) / os_log category `BPB` (iOS) |
| `flutter run` | yes | yes on Android and on iOS devices; on the iOS simulator Dart echoes them (below) |
| Log file on the device | yes (sent to native) | yes |
| In-app viewer | yes | yes (sent to Dart) |

**The log file** is the complete record of a run, written by native:

| Platform | Path | Pulled by |
|---|---|---|
| Android | `files/logs/bridge.log` in the app's data dir | `adb exec-out run-as com.example.ble_proximity_bridge cat files/logs/bridge.log` (debug builds) |
| iOS | `Documents/logs/bridge.log` in the app container | `xcrun devicectl device copy from ... --domain-type appDataContainer` |

Each launch starts a new file; the previous two are kept as `bridge.1.log`
and `bridge.2.log`, and a file is also rotated if it passes 4 MB. Writes are
synchronous, so the lines before a crash are on disk. Dart lines are sent to
native one at a time as they are logged, not batched, so in the file they
sit next to the native lines of the calls they describe.

**How native lines reach `flutter run`**, from the Flutter tool's source
(`flutter_tools` 3.47):

- Android: the tool shows every logcat line from the app's process, so
  `BPB` lines appear on their own. It learns the process id only once it
  connects to the Dart VM; the first few native lines of a launch (the log
  header) are in logcat and the file but not in `flutter run`.
- iOS device, Xcode 26 or later: the tool launches the app with
  `devicectl --console` and `OS_ACTIVITY_DT_MODE`, which mirrors os_log to
  the console. Native lines are logged at the default level because that
  mirror leaves out `.debug` messages (checked on macOS). **Not yet seen on
  a physical device**; if native lines are missing there, run with
  `--dart-define=LOG_ECHO_NATIVE=true`.
- iOS simulator: the tool only shows os_log messages from the app's main
  executable, and debug builds put the app's code in `Runner.debug.dylib`
  (checked: the lines are in the simulator's log, sent from that dylib). So
  the native logger tells Dart (in its `configure` answer) to print native
  lines there.

## Levels and switches

Debug and profile builds log at debug level; release builds at info. Build
switches (`flutter run --dart-define=NAME=value`):

| Switch | Values | Default |
|---|---|---|
| `LOG_LEVEL` | `debug` `info` `warn` `error` | `debug`; `info` in release |
| `HERALD_LOG` | `off` `fault` `info` `debug` | `fault`; `off` in release |
| `LOG_ECHO_NATIVE` | `true` | off (see above) |

Herald's own logging is separate from ours. It goes to logcat (tags like
`Sensor::BLE.ConcreteBLEReceiver`) / os_log (subsystem `Sensor`), and to
Herald's own `log.txt` (Android: `Android/media/<package>/Sensor/log.txt`; iOS:
`Documents/log.txt`), not to `bridge.log`. Its Android file stamps lines in
UTC, its iOS file in local time (seen side by side on a Pixel and an iPad:
both files start at their Herald host's start, 5 hours apart on the
Pixel). At `fault` it only logs what
Herald treats as an error or an unexpected state (around 60 places in its
iOS source); `debug` logs every scan, connection and read and is very
verbose. Some faults are expected with this bridge: it reuses one Herald
host across stop/start, so lines like `start, transmitter already enabled to
follow bluetooth state` or `stop denied, already stopped` are normal, and on
a simulator `scan failed, bluetooth is not powered on` is too.

## Components

| Component | What it tells you |
|---|---|
| `dart.app` | Launch header (build mode, OS, levels), lifecycle changes (`resumed`, `paused`, ...) |
| `dart.bridge` | `identity self=...`; every `start #n` / `stop #n` (n is the generation), each step of the handshake with timings, supersession, failures, phase changes |
| `dart.channel` | Every method call to native: `→ start ...`, `← start ok 12ms` / `← ... failed code: message` |
| `dart.events` | `ready`, `gone`, unknown event types, stream errors, undecodable events |
| `dart.peers` | `+` a peer appeared, `~` its status/color/device/distance bucket changed, `-` removed (goodbye; on Android also because its device has a new id; or evicted after 20 s of silence, 90 s on Android) |
| `dart.status` | This device's status/color changes and whether they were pushed |
| `dart.permissions` | Android permission results, per permission |
| `dart.stats` | Every 15 s while not idle: phase, events received (`+since last/total`), the peer list with age |
| `dart.flutter` / `dart.dart` | Uncaught framework / async errors with stack |
| `native.log` | Header: pid, app version, device, OS, file path; configuration |
| `native.method` | Every method call native received, and every rejection with its code |
| `native.service` / `native.controller` | Android service lifecycle (created, start command `#n`, superseded, destroyed); iOS controller start/stop |
| `native.activity` / `native.app` | Flutter engine attached; Android activity destroyed (the service may live on) |
| `native.host` | Herald host built / resumed / rebuilt, quiesced, stopped (or left running because a start raced in) |
| `native.frame` | Goodbye/hello frames sent, with the payload and (Android) how long the blocking send took |
| `native.payload` | Every change to what this device broadcasts, with its new revision |
| `native.pipeline` | Herald callbacks and what `FrameOverrides` decided (below) |
| `native.ble` | Bluetooth state from Herald, iOS authorization, Android permissions at start |
| `native.emit` | Every sighting sent to Dart with RSSI → median → smoothed → bucket and the cutoff set; `gone`, `ready`, errors |
| `native.sink` | Dart subscribing/cancelling, the Android parked-sink handoff, events dropped because nobody listened |
| `native.mock` | Mock source started |
| `native.stats` | Every 15 s while a source or host is up: mode, host, Bluetooth state, sink, our payload, Herald callback counts, events sent to Dart; then one line per known peer |
| `native.crash` | Uncaught exception (Android: any thread; iOS: Objective-C exceptions only) |

## The pipeline line

The one most bugs are found with. Each Herald callback that carries a
payload is logged with where it came from, what it said, what
`FrameOverrides` decided, what was reported, and what it was compared
with:

```text
<source> <payload> [rssi=..] via=<Herald target> → <verdict>; <outcome> [<what was remembered>]
```

- **source**: `read` (fresh GATT read), `frame` (goodbye/hello pushed by the
  peer), `cached` (Herald's stored copy, with an RSSI reading, or relayed).
- **via**: Herald's id for the remote device. On Android it is the
  Bluetooth address; Herald for iOS assigns its own random UUID (shown
  shortened), so it only matches Herald's own logs.
- **outcome**: `reported as a sighting`, `reported GONE`, `nothing
  reported`, or `stopped, so not reported` (the bridge is stopped but the
  decision is still recorded).

| Verdict | Meaning |
|---|---|
| `frame recorded` | A goodbye/hello frame now outvotes cached copies (30 s; 5 s for an iPhone's goodbye) |
| `dropped: older than the newest revision` | A frame or read older than one already seen (late goodbye, overtaken read, stale relay) |
| `accepted` | Taken as it is |
| `accepted; ends the frame's override` | A fresh read replaced the frame |
| `accepted: newer than the frame, which it ends` | Herald's copy is newer than the frame |
| `ignored: the peer's goodbye frame outvotes it` | A cached online copy of a peer that said goodbye |
| `replaced by the peer's hello frame` | A cached (often offline) copy of a peer that said hello |
| `replaced by the newest payload (it is older)` | A cached copy older than the newest online payload |
| `accepted: older, but the goodbye ran out ...` | Readings after a goodbye expired: likely a restart whose hello was lost |
| `ignored: older than a read that said offline` | A relayed copy older than a fresh offline read |

On Android, a read that returns a new id from a device last read under
another id gets its own line before the usual one: `read <payload> via=<address> →
replaces <old id>, read from that device 89.5s ago; <old id> reported GONE`.
The old id is removed in Dart with `removed: its device has a new id`
([android.md](android.md#a-new-id-from-the-same-device)).

To keep the volume down, the most common case, a cached payload accepted
as it is while running, is not logged by the pipeline; `native.emit` logs
that sighting with its distance. Frames, departures and every override
are logged at info; plain accepted reads, own payloads, relays and detects
at debug.

## The stats lines

```text
I native.stats [main] mode=BLE host=up bt=?/adapter on sink=on self=1A2B3C4D st=3 col=0 rev=4 online | herald: read=1 cached=14 detect=1 readAccepted=1 cachedAccepted=14 | to dart: peer=+14/120
I native.stats [main]   peer 0B5EAFE7 smooth=-71.4 n=12 → 1.5m last sample 1.0s ago | newest rev=9 online (read 6.2s ago)
I dart.stats phase=running mock=false gen=3 events peer=+15/121 gone=+0/0 ready=+0/1 error=+0/0 | peers=1: 0B5EAFE7 Near -71dBm busy/3 android seen 0.4s ago
```

- `herald:` counts the callbacks since the last line (`read`, `frame`,
  `cached`, `shared`, `detect`, `rssiOnly`, `malformed`, `own`) and each
  verdict; `whileStopped` counts callbacks after a stop, `replaced` (Android)
  old ids retired because their device now has a new one.
- `to dart: peer=+14/120` is events sent since the last line / in total;
  `nosink` counts events dropped because Dart was not listening. Compare
  with `dart.stats events`: native's sent count and Dart's received count
  should match (the two timers are not in step, so compare totals). After
  a stop native may be one or two ahead: an event native sent as Dart
  cancelled is dropped, so that it can't reach the next session
  (`ProximityEventChannel`).
- `bt=` is the last Bluetooth state Herald reported (`?` until it reports
  one: it does so when the state changes) and, on Android, what the
  adapter says right now. iOS has no second source: check the
  `native.ble authorization` line.
- A stopped host that hears nothing logs no stats line.

## Collecting logs

`tool/devlogs.dart` finds Android devices and emulators (adb), iPhones and
iPads (devicectl, Xcode 15+) and booted simulators:

```bash
dart run tool/devlogs.dart devices
```

**Live, while testing.** `flutter run` per device, each in its own terminal,
with a copy of the output:

```bash
flutter run -d <device-id> 2>&1 | tee logs/live/<label>.log
```

For Android, the whole logcat of the app's process (also Herald's lines and
anything Android's Bluetooth stack logs for the app; it re-attaches when the
app restarts):

```bash
dart run tool/devlogs.dart logcat -d <serial>
```

For an iPhone that is not under `flutter run` (a profile or release build,
or launched from the home screen), new lines of its log file every few
seconds:

```bash
dart run tool/devlogs.dart follow -d <udid>
```

**After a test.** Pull everything from every connected device, and merge:

```bash
dart run tool/devlogs.dart pull
```

This writes `logs/<date-time>/`: one `<label>.log` per device (its launches
in order), the raw files (including Herald's `log.txt`, Android's crash
buffer, and the app's iOS crash reports), and `merged.log`, one timeline of
all devices:

```text
10:15:03.120 Pixel-7      I native.frame [frame-sender] sending goodbye 0B5EAFE7 android st=3 col=0 rev=5 OFFLINE v3 to recent peers
10:15:03.180 Andis-iPhone I native.pipeline [BLE.BLESensor.DelegateQueue] frame 0B5EAFE7«Pixel-7» android ... → frame recorded; reported GONE [...]
10:15:03.182 Andis-iPhone I dart.peers - 0B5EAFE7«Pixel-7» removed: goodbye (listed for 42.0s)
```

Any files can be merged, pulled or captured, in any mix; a line that
appears in two of them (a pulled file and a `flutter run` capture of the
same device) is kept once:

```bash
dart run tool/devlogs.dart merge --level I phone=logs/x/Pixel-7.log phone=logs/live/pixel.log ipad=logs/x/iPad.log
```

The times are each device's wall clock. Phones normally set theirs from
the network, but nothing synchronizes them with each other, so ordering
across devices is only as good as their clocks agree.

Pulling needs: on Android a debug build (`run-as`); on iOS the device
unlocked and reachable by devicectl (cable, or the same network), and a
development-signed build.

**In the app.** The Logs screen shows the last 5000 lines from both sides,
filterable by level, origin and text, with a button to copy what is shown
(on iOS, Universal Clipboard pastes it on the Mac). Use it when the phones
are away from the computer, e.g. for distance tests.

## Debugging playbook

| Symptom | Look at |
|---|---|
| A peer never appears | Its sender: `native.payload` / `native.host started` (is it broadcasting?). The receiver: `native.ble` (`bluetooth state off`, iOS `authorization DENIED`, Android `permissions ... DENIED`), `native.stats herald:` (no `detect`/`read`/`cached` at all means Herald hears nothing), `native.pipeline ... own payload` (both devices using the same id) |
| A peer appears on one device only | Both devices' `native.stats herald:` counts; the silent side's `native.ble` and Herald's faults in logcat / `log.txt` |
| A peer flickers or vanishes | `dart.peers -` says why: `goodbye` or `evicted: silent for ...`. Before an eviction, `native.stats` shows how long ago its last sample was. On an Android receiver, `herald: none` for most of each minute with Herald `taskConnectDevice, connect timeout` warnings in between is Herald's scan cycle ([android.md](android.md#herald-listens-in-bursts)) |
| A stopped peer lingers (ghost) | The receiver's `native.pipeline` lines for that id after the sender's `native.frame sending goodbye`: was the frame received (`frame ... reported GONE`)? Are later cached copies `ignored: the peer's goodbye frame outvotes it`, or `accepted`? |
| A restarted peer stays hidden | Receiver: `ignored: the peer's goodbye frame outvotes it` until the frame runs out, then `accepted: older, but the goodbye ran out`; or a `read ... online` |
| A status change does not show | Sender: `native.payload broadcast now ... rev=N`. Receiver: a `read` with that revision within ~15 s, then `dart.peers ~ ... status` |
| The distance looks wrong | `native.emit`: raw `rssi`, `median`, `smooth`, which cutoff set (`iosCutoffs` / `androidCutoffs`, chosen by the sender's platform) and the bucket |
| Start hangs or fails | `dart.bridge start #n ...` with timings; `failed ... (no ready event)` means no `ready` within 10 s: look for `native.service start command #n ... superseded`, `start failed: ...`, `foreground promotion failed`, `native.emit error` |
| The UI does not update | `native.stats to dart` vs `dart.stats events`; `native.sink` (`Dart is not listening`, `sink=OFF`) |
| Android stops in the background | `native.service destroyed`, then `dart.events stream error` and on resume `dart.bridge app resumed after a failure: retrying start` |
| A crash | `native.crash` / `dart.flutter` / `dart.dart` lines at the end of the file; Android `logcat-crash.txt`, iOS `.ips` crash reports from `pull` |

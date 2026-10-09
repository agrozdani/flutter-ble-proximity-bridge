# Android implementation

Files: `android/app/src/main/kotlin/com/example/ble_proximity_bridge/`

| File | Role |
|---|---|
| `MainActivity.kt` | Channel registration, method dispatch, start validation |
| `ProximityService.kt` | Foreground service hosting Herald/mock, stream handler, sighting pipeline |
| `StatusPayloadSupplier.kt` | 16-byte payload encode/decode |
| `DistanceEstimator.kt` | Per-peer window → median → Kalman → bucket |
| `KalmanFilter1D.kt` | Small 1-D Kalman-style smoothing filter |
| `MockPeerSource.kt` | Synthetic sightings for emulators |

## Why a foreground service

Background BLE scanning on Android dies with the activity unless it runs in
a foreground service. The service is declared with the type Android
reserves for Bluetooth interactions:

```xml
<service
    android:name=".ProximityService"
    android:foregroundServiceType="connectedDevice"
    android:exported="false"
    android:stopWithTask="false" />
```

- Since Android 14 every foreground service must declare a type;
  `connectedDevice` is the one for Bluetooth. Promotion is refused at
  runtime unless one of the type's prerequisites holds — for this app, a
  granted Bluetooth runtime permission. `MainActivity` therefore refuses a
  real-BLE start without the permissions (`permission_denied`) before
  starting the service at all.
- A service started with `startForegroundService()` must call
  `startForeground()` before it stops, or Android crashes the app
  (*"Context.startForegroundService() did not then call
  Service.startForeground()"*). So the service promotes itself **first** and
  only then checks anything else; every failure path after that demotes,
  reports `start_failed` to Dart, and stops.
- `stopWithTask="false"` + `START_STICKY` keeps scanning alive when the
  user swipes the app away. The in-app Stop button (or Android reclaiming
  resources) ends it.
- After a `START_STICKY` restart the intent is null. The restarted process
  has no Flutter engine attached and the service does not re-promote itself,
  so it idles as a plain background service — which Android stops within
  about a minute under its background-execution limits. Nothing restarts
  scanning automatically; the bridge resumes when the user opens the app
  and starts it again.

**Mock mode runs in the same service but skips foreground promotion** — the
`connectedDevice` type requires Bluetooth permissions that the mock path
deliberately never requests. The activity therefore uses plain
`startService` for mock and `startForegroundService` for real BLE. The flip
side: a plain service is stopped by Android about a minute after the app
leaves the foreground. The service reports that to Dart as a
`service_stopped` stream error, and the Dart controller restarts the bridge
when the app returns to the foreground.

## The single long-lived Herald host

Like iOS, the service keeps its `SensorArray` and reuses it across logical
stop/start cycles — stop pushes a goodbye frame and calls `stop()` on the
persistent host once the frame is out; start calls `start()` on the same
instance and pushes a hello. The service instance itself also stays warm
across Dart-level stops (only `stopForeground` runs); real teardown happens
in `onDestroy`. Android can destroy the idle service on its own, after
which the next start builds a fresh host. See
[architecture.md](architecture.md#stopping-is-a-protocol-problem) for why
stop must be a protocol operation rather than a BLE-stack operation.

**Frames go out on a background thread.** Herald's Android
`immediateSendAll` connects to every Herald peer seen in the last minute,
one after another, and blocks the calling thread until each exchange
finishes — seconds per peer. Called on the main thread it would freeze the
UI on every Stop and Start. The service hands frames to a single-thread
executor (which also keeps goodbye and hello in order) and posts the host
`stop()` back to the main thread once the goodbye returns, skipping it if a
start raced in meanwhile.

Note that Herald 2.2.0 for Android *receives* immediate-send frames but
never delivers them to the delegate (the call is commented out in its GATT
server), so `didReceive` never fires here: goodbye/hello frames from this
device reach iOS peers only, and Android peers drop a stopped device by
staleness eviction.

## The pending-sink race

The platform channels are registered in `MainActivity.configureFlutterEngine`
— before any Dart code runs. The service, however, is only created when
Dart calls `start`. So when Dart subscribes to the EventChannel *before*
starting the bridge (which it does, to not miss the ready event), there is
no service to hand the sink to.

The fix is a static `AtomicReference` parking lot:

```kotlin
// MainActivity's stream handler:
val service = ProximityService.instance()
if (service != null) service.onListen(arguments, events)
else ProximityService.parkPendingSink(events)

// ProximityService.onCreate():
pendingSinkRef.getAndSet(null)?.let { onListen(null, it) }
```

This is not an edge case: the first start in every process takes this
path. Both `onListen` and `onCreate` run on the main thread, so they cannot
actually interleave; `getAndSet(null)` claims the sink atomically anyway, so
the handoff stays correct even if that ever changes.

## Stop versus a start in flight

`startForegroundService()` returns before the service's `onStartCommand`
runs, so a Dart `stop` can arrive while its `start` is still queued — and a
stop that finds no service instance has nothing to stop. Every start and
stop therefore takes a number from `ProximityService.nextCommand()`; the
start carries its number in the intent, and `onStartCommand` ignores a start
that is no longer the latest command (after promoting and demoting, as
above).

## Threading

Herald delivers `SensorDelegate` callbacks on its worker threads.
Flutter's `EventSink` must only be touched on the main thread, and can be
detached by `onCancel` at any moment. The service therefore:

1. does payload decoding and distance estimation on the callback thread
   (cheap, thread-confined work),
2. posts the finished event map via `Handler(Looper.getMainLooper())`,
3. on the main thread, uses the sink under `synchronized(sinkLock)` and
   clears it if `success()` throws — a thrown sink is a detached sink, and
   retrying into it is pointless.

`onCancel` only nulls the sink (under `sinkLock`); it deliberately leaves
queued main-thread callbacks in place, because the host `stop()` posted
after a goodbye still needs to run. A queued emit that fires after the sink
is cleared simply no-ops — `emit` re-checks the sink under the lock before
using it.

## Permissions

Modern, minimal-permission setup:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" tools:targetApi="s" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<!-- Android 11 and below -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
```

`neverForLocation` declares that scan results are not used to infer
location, which removes the location-permission requirement on Android 12+.
On Android 11 and below, BLE scanning is location-gated regardless, so the
Dart permission helper branches on SDK version: three Bluetooth runtime
permissions on 31+, location below.

Herald's own library manifest declares more — every Bluetooth and location
permission without `maxSdkVersion`, `WAKE_LOCK`, and a location-type
foreground service of its own. The merged manifest keeps this app's
`maxSdkVersion`/`neverForLocation` attributes where both declare the same
permission, but anything only Herald declares is added as-is. The app's
manifest therefore removes the two that would contradict the setup above
with `tools:node="remove"`: `ACCESS_COARSE_LOCATION` (Herald never checks
it) and Herald's unused `ForegroundService`. `WAKE_LOCK` stays — Herald
takes a wake lock and needs it.

## Herald configuration

```kotlin
BLESensorConfiguration.customServiceUUID = UUID.fromString(sessionId)
BLESensorConfiguration.customServiceDetectionEnabled = true
BLESensorConfiguration.customServiceAdvertisingEnabled = true
BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
BLESensorConfiguration.legacyHeraldServiceDetectionEnabled = false
```

The session UUID becomes the advertised GATT service UUID, so discovery is
scoped to devices sharing the session. Herald's standard service and its
pre-2.1 legacy service (whose detection is on by default) are disabled to
keep this app's traffic isolated from any other Herald-based deployment in
radio range.

Of Herald's nine `SensorDelegate` callbacks, four are wired to the pipeline:
`didRead` (payload without fresh RSSI), `didReceive` (immediate-send frames —
the goodbye/hello protocol; never called by Herald 2.2.0 for Android, see
above), `didShare` (payloads relayed by a peer — Herald's workaround for iOS
background advertising limits), and the workhorse
`didMeasure(..., withPayload)` which delivers RSSI and payload together.

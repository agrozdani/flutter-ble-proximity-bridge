# Android implementation

Files: `android/app/src/main/kotlin/com/example/ble_proximity_bridge/`

| File | Role |
|---|---|
| `MainActivity.kt` | Channel registration, method dispatch |
| `ProximityService.kt` | Foreground service hosting Herald/mock, stream handler, sighting pipeline |
| `StatusPayloadSupplier.kt` | 16-byte payload encode/decode |
| `DistanceEstimator.kt` | Per-peer window → median → Kalman → bucket |
| `KalmanFilter1D.kt` | Textbook 1-D Kalman filter |
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

- `connectedDevice` is mandatory on Android 14+ for BLE work, and promotion
  is rejected at runtime unless the Bluetooth permissions are actually
  granted — which is why the service re-checks them before
  `startForeground` and degrades by stopping itself instead of crashing.
- `stopWithTask="false"` + `START_STICKY` keeps scanning alive when the
  user swipes the app away. The in-app Stop button (or Android reclaiming
  resources) ends it.
- After a `START_STICKY` restart the intent is null; the service stays up
  but idle. The restarted process has no Flutter engine attached, so nothing
  restarts scanning automatically — the bridge resumes when the user opens
  the app and starts it again.

**Mock mode runs in the same service but skips foreground promotion** — the
`connectedDevice` type requires Bluetooth permissions that the mock path
deliberately never requests. The activity therefore uses plain
`startService` for mock and `startForegroundService` for real BLE.

## The single long-lived Herald host

Like iOS, the service creates its `SensorArray` at most once and reuses it
across logical stop/start cycles — stop pushes a goodbye frame and calls
`stop()` on the persistent host (after a 300 ms flush window), start calls
`start()` on the same instance and pushes a hello. The service instance
itself also stays warm across Dart-level stops (only `stopForeground` runs);
real teardown happens in `onDestroy`. See
[architecture.md](architecture.md#stopping-is-a-protocol-problem) for why
stop must be a protocol operation rather than a BLE-stack operation.

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

`getAndSet(null)` claims the sink atomically, so the handoff is correct
even if subscription and service creation race on different threads. This
is the kind of bug that never shows up in development (where you tap
buttons slowly) and always shows up in production cold starts.

## Threading

Herald delivers `SensorDelegate` callbacks on its BLE worker threads.
Flutter's `EventSink` must only be touched on the main thread, and can be
detached by `onCancel` at any moment. The service therefore:

1. does payload decoding and distance estimation on the callback thread
   (cheap, thread-confined work),
2. posts the finished event map via `Handler(Looper.getMainLooper())`,
3. on the main thread, reads the sink under `synchronized(sinkLock)` and
   clears it if `success()` throws — a thrown sink is a detached sink, and
   retrying into it is pointless.

`onCancel` only nulls the sink (under `sinkLock`); it deliberately leaves any
queued main-thread callbacks in place, because the goodbye/quiesce runnable
posted on stop still needs to run. A queued emit that fires after the sink is
cleared simply no-ops — `emit` re-checks the sink under the lock before using
it.

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
permissions on 31+, `ACCESS_FINE_LOCATION` below.

## Herald configuration

```kotlin
BLESensorConfiguration.customServiceUUID = UUID.fromString(sessionId)
BLESensorConfiguration.customServiceDetectionEnabled = true
BLESensorConfiguration.customServiceAdvertisingEnabled = true
BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
```

The session UUID becomes the advertised GATT service UUID, so discovery is
scoped to devices sharing the session. Herald's standard service is
disabled to keep this app's traffic isolated from any other Herald-based
deployment in radio range.

Of Herald's nine `SensorDelegate` callbacks, four feed the pipeline here:
`didRead` (payload without fresh RSSI), `didReceive` (immediate-send frames —
the goodbye/hello protocol), `didShare` (payloads relayed by a peer — Herald's
workaround for iOS background advertising limits), and the workhorse
`didMeasure(..., withPayload:)` which delivers RSSI and payload together.

# iOS implementation

Files: `ios/Runner/`

| File | Role |
|---|---|
| `AppDelegate.swift` | Channel registration, method dispatch, start validation |
| `ProximityController.swift` | Singleton hosting Herald/mock, stream handler, sighting pipeline |
| `StatusPayloadSupplier.swift` | 16-byte payload encode/decode |
| `DistanceEstimator.swift` | Per-peer window → median → Kalman → bucket |
| `KalmanFilter1D.swift` | Small 1-D Kalman-style smoothing filter |
| `MockPeerSource.swift` | Synthetic sightings for the simulator |

## Channel registration (scene-based template)

Flutter's iOS template uses the UIScene lifecycle (the default since
Flutter 3.41; the API below exists since 3.38): the engine is created
implicitly and `AppDelegate` receives it through
`FlutterImplicitEngineDelegate` instead of grabbing
`window.rootViewController` in `didFinishLaunchingWithOptions`:

```swift
func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
  GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  setupBridgeChannels(messenger: engineBridge.applicationRegistrar.messenger())
}
```

Unlike Android, iOS needs no pending-sink handoff: `ProximityController`
is a singleton created when the channels are registered, so it is the
EventChannel's stream handler before Dart can subscribe. The ready-replay
in `onListen` covers any subscribe/start ordering.

## Background modes and state restoration

`Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>      <!-- keep scanning in background -->
  <string>bluetooth-peripheral</string>   <!-- keep advertising in background -->
</array>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>…why the app uses Bluetooth…</string>
```

The background modes let the BLE stack keep working while the app is in
the background. iOS will still suspend or terminate the app eventually.
Herald creates its `CBCentralManager`/`CBPeripheralManager` with
state-restoration identifiers, which opts the app into CoreBluetooth state
restoration: iOS may relaunch a terminated app in the background to deliver
a Bluetooth event.

**This demo does not resume the bridge after such a relaunch.** The
`SensorArray` is only created when Dart calls `start`, which a background
relaunch never does. (There is no launch-options signal to react to either:
in a scene-based app, `application(_:didFinishLaunchingWithOptions:)`
receives `nil` launch options.) Supporting it would mean creating the Herald
stack at launch so its managers can pick up the restored state — Herald
handles the `willRestoreState` callbacks internally.

Related caveat Herald works around: a backgrounded iOS app stops
advertising its service UUID in the normal packet, making iOS↔iOS
background discovery unreliable — Herald's *payload sharing* (the
`didShare` callback) lets an Android device in range relay iPhones'
payloads to other iPhones that can't see them (with side effects; see
[Known limitations](architecture.md#known-limitations)).

The Bluetooth permission prompt is triggered by CoreBluetooth itself when
Herald creates its managers, i.e. on the first real-BLE start (keyed off
`NSBluetoothAlwaysUsageDescription`) — there is nothing to pre-request from
Dart, which is why the Dart permission helper is Android-only.

## Threading

Herald delivers `SensorDelegate` callbacks on its own dispatch queues.
The controller:

1. decodes and estimates on the callback queue,
2. hops to `DispatchQueue.main` — Flutter requires sink invocations on the
   platform thread,
3. on the main thread, reads the sink under `NSLock` right before calling
   it — `onCancel` can detach the sink while the hop is still queued, and a
   detached sink must not be invoked.

## The single long-lived Herald host

The `SensorArray` is created once and reused across logical stop/start
cycles (see [architecture.md](architecture.md#stopping-is-a-protocol-problem)
for the full reasoning). The iOS-specific forcing function: Herald creates
its CoreBluetooth managers with fixed state-restoration identifiers
(`"Sensor.BLE.ConcreteBLEReceiver"` / `"Sensor.BLE.ConcreteBLETransmitter"`),
so a rebuilt stack racing a still-unwinding one would have two managers
claiming the same identifier.

Logical stop flags the payload offline, pushes a goodbye over
`immediateSendAll` — which on iOS writes to the peers this device is
connected to as a central — then calls `stop()` on the persistent host after
a 300 ms flush window, since those writes are queued asynchronously
(cancelled if a start races in). Logical start calls `start()` on the same
instance and pushes a hello. The only path that rebuilds the host is a
session-id change, since the advertised service UUID must change with it.

## The Herald patches

The `Podfile`'s `post_install` hook patches two Herald 2.2.0 source files
in `Pods/`. Both patches are idempotent: if the original text is not found
(already patched, or a Herald release that changed the code), they do
nothing. CocoaPods marks installed pod sources read-only, so the hook makes
a file writable just long enough to write it.

**`patch_herald_immediate_send_all` — a crash fix.** Herald's
`immediateSendAll` force-unwraps each target's peripheral and signal
characteristic inside a block it queues for later. The characteristic is
`nil` until a new connection's services are discovered, and Herald resets
it to `nil` when a peer disconnects or re-publishes its services (which
every peer does on `start()`). A goodbye or hello sent in that window
crashes the app. The patch makes the block skip such peers instead.

**`patch_herald_for_swift6` — a build fix.** With Swift 6.3 (Xcode 26.4),
`SampleStatistics.swift`'s compound arithmetic exceeds the type-checker
budget, failing the build with *"the compiler is unable to type-check this
expression in reasonable time"*. The patch decomposes the four offending
assignment statements into sub-expressions — the same floating-point
operations in the same order, just kinder to the constraint solver. Swift
6.4 (Xcode 27) type-checks the original fine, so there the patch is
unnecessary but harmless. Remove it once Herald releases a Swift-6-compatible
version.

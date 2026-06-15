# iOS implementation

Files: `ios/Runner/`

| File | Role |
|---|---|
| `AppDelegate.swift` | Channel registration, method dispatch, BLE-relaunch detection |
| `ProximityController.swift` | Singleton hosting Herald/mock, stream handler, sighting pipeline |
| `StatusPayloadSupplier.swift` | 16-byte payload encode/decode |
| `DistanceEstimator.swift` | Per-peer window → median → Kalman → bucket |
| `KalmanFilter1D.swift` | Textbook 1-D Kalman filter |
| `MockPeerSource.swift` | Synthetic sightings for the simulator |

## Channel registration (scene-based template)

Recent Flutter templates use the UIScene lifecycle: the engine is created
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
is a singleton that exists from launch, so it is registered as the
EventChannel's stream handler immediately. The ready-replay in `onListen`
covers any subscribe/start ordering.

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

iOS will still suspend or kill the app eventually. CoreBluetooth's state
restoration can then *relaunch it headlessly* to deliver a Bluetooth event;
the only signal is a launch-options key, which `AppDelegate` checks:

```swift
if let centrals = launchOptions?[.bluetoothCentrals] as? [String], !centrals.isEmpty {
  // Relaunched by iOS for a BLE event, not by the user.
}
```

Herald creates its `CBCentralManager`/`CBPeripheralManager` with
restoration identifiers, which is what opts the app into this mechanism.
Related caveat Herald works around: a backgrounded iOS app stops
advertising its service UUID in the normal packet, making iOS↔iOS
background discovery unreliable — Herald's *payload sharing* (the
`didShare` callback) lets an Android device in range relay payloads
between iPhones that can't see each other.

The Bluetooth permission prompt is triggered by CoreBluetooth itself the
first time the stack starts (keyed off `NSBluetoothAlwaysUsageDescription`)
— there is nothing to pre-request from Dart, which is why the Dart
permission helper is Android-only.

## Threading

Herald delivers `SensorDelegate` callbacks on its own dispatch queues.
The controller:

1. decodes and estimates on the callback queue,
2. reads the sink under `NSLock` (it can be detached by `onCancel` at any
   moment),
3. hops to `DispatchQueue.main` for the actual `sink(event)` call — Flutter
   requires sink invocations on the platform thread.

## The single long-lived Herald host

The `SensorArray` is created at most once per process and reused across
logical stop/start cycles (see
[architecture.md](architecture.md#stopping-is-a-protocol-problem) for the
full reasoning). The iOS-specific forcing function: Herald creates its
CoreBluetooth managers with fixed state-restoration identifiers
(`"Sensor.BLE.ConcreteBLEReceiver"` / `"...Transmitter"`), and iOS forbids
two live managers sharing a restore identifier — so a rebuilt stack racing
a still-unwinding one is unreliable by construction.

Logical stop flags the payload offline, pushes a goodbye over
`immediateSendAll`, then calls `stop()` on the persistent host after a
300 ms flush window (cancelled if a start races in). Logical start calls
`start()` on the same instance and pushes a hello. The only path that
rebuilds the host is a session-id change, since the advertised service UUID
must change with it.

## The Herald build patch

Herald 2.2.0 has one source file (`SampleStatistics.swift`) whose compound
arithmetic expressions exceed the Swift 6.3+ (Xcode 26) type-checker
budget, failing the build with *"the compiler is unable to type-check this
expression in reasonable time"*.

The `Podfile` carries a `post_install` function
(`patch_herald_for_swift6`) that decomposes those two statements into
sub-expressions — mathematically identical, just kinder to the constraint
solver. The patch is idempotent and self-disabling: if Herald ships a fixed
release, the original text is no longer found and the patch becomes a
no-op. Remove it once Herald releases a Swift-6-compatible version.

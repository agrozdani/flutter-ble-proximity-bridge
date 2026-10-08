# Channel contract

The complete interface between Dart and native code. There is no
compile-time checking across the language boundary — this document, plus
one constants file per side, *is* the contract:

- Dart: [`lib/src/bridge/channel_names.dart`](../lib/src/bridge/channel_names.dart)
- Android: constants in [`MainActivity.kt`](../android/app/src/main/kotlin/com/example/ble_proximity_bridge/MainActivity.kt)
- iOS: constants in [`AppDelegate.swift`](../ios/Runner/AppDelegate.swift)

The Dart side of the contract is verified by
[`test/proximity_method_channel_test.dart`](../test/proximity_method_channel_test.dart).

## Channels

| Channel | Type | Direction |
|---|---|---|
| `ble_proximity_bridge/methods` | MethodChannel | Dart → native (commands) |
| `ble_proximity_bridge/events` | EventChannel | native → Dart (event stream) |

## Methods

### `start`

Starts proximity detection.

| Argument | Type | Meaning |
|---|---|---|
| `sessionId` | String | 128-bit UUID in the canonical `8-4-4-4-12` hex form, used as the BLE service UUID. Devices only discover peers started with the same session id. |
| `peerId` | int | This device's identifier in the broadcast payload. Non-negative. |
| `mock` | bool | Start the synthetic peer source instead of the BLE stack. |

Returns `true` when the request was accepted. **Acceptance is not
readiness** — initialization completes asynchronously and is signaled by
the `ready` event. Errors:

- `bad_args` (both platforms): a missing argument, a malformed `sessionId`,
  or a negative `peerId`.
- `permission_denied` (Android): a real-BLE start without the Bluetooth
  runtime permissions (Android 12+).
- `start_failed` (Android): the OS refused to start the service.

A failure after acceptance arrives as an error on the event stream (see
[Errors](#errors)). iOS has no such failure: Herald starts even with
Bluetooth off or unauthorized and starts scanning once Bluetooth is
available (it reports the state through its `didUpdateState` callback,
which this demo does not surface).

### `updateStatus`

Updates the payload this device broadcasts. Peers see the change the next
time they read our payload: on first contact, then roughly every 15 s
(`payloadDataUpdateTimeInterval` — strictly the *reader's* re-read
interval, but every install sets the same value).

| Argument | Type | Meaning |
|---|---|---|
| `status` | int | Status code (see `PeerStatus` in Dart). |
| `color` | int | Index into the shared color palette. |

Only valid while the bridge is running (`not_running` otherwise; `bad_args`
if an argument is missing). Dart pushes the current status right after the
ready handshake, so the native side never broadcasts stale state for long —
though a restart's hello frame still carries the previous session's status
(see [Known limitations](architecture.md#known-limitations)).

### `stop`

Stops the proximity source. The long-lived Herald host stays warm for the next
start; a logical stop winds down scanning/advertising rather than tearing the
stack down (see [architecture.md](architecture.md#stopping-is-a-protocol-problem)).
Always succeeds — Dart calls it defensively during teardown, so stopping an
already-stopped bridge is harmless (if a Herald host exists, it re-sends the
goodbye). On Android, a stop also cancels a `start` that Android has not
delivered to the service yet (see [android.md](android.md#stop-versus-a-start-in-flight)).

### `forgetPeer`

| Argument | Type | Meaning |
|---|---|---|
| `peerId` | int | Peer whose native distance model should be freed. |

Dart owns the "peer departed" heuristic (no sightings for 20 s) and drives
native cleanup with this call.

## Events

Every event is a map with a `type` discriminator, so new event kinds can be
added without breaking older Dart code (unknown types are ignored).

### Errors

Native reports failures that happen after `start` was accepted as stream
errors (`EventSink.error`). Dart fails a pending ready wait with it, or
moves the bridge to the error phase. Android sends:

| Code | When |
|---|---|
| `start_failed` | The service could not start the source (foreground promotion refused, missing permissions, Herald failed to start). |
| `service_stopped` | Android destroyed the service while a source was running. |

### `{type: "ready"}`

The native source (BLE or mock) finished initializing. Re-sent to late
subscribers — see the ready-replay pattern in
[architecture.md](architecture.md).

### `{type: "gone", id: int}`

A protocol-level goodbye: peer `id` announced that it stopped. Dart removes
the peer immediately instead of waiting out the staleness eviction.

This event exists because BLE itself has no goodbye. A stopped peripheral
cannot force-disconnect centrals that are already connected to it, and those
centrals keep measuring it over the live link and reporting it with the
payload they last read — so without an explicit signal, a stopped device
would appear alive indefinitely. The
native side emits `gone` whenever a peer's payload or immediate-send frame
carries the offline flag (see the wire payload below and
[architecture.md](architecture.md#stopping-is-a-protocol-problem)).
Immediate-send frames only ever reach iOS receivers; Herald 2.2.0 for
Android does not deliver them.

### `{type: "peer", ...}`

One sighting of a nearby peer.

| Key | Type | Always present | Meaning |
|---|---|---|---|
| `id` | int | yes | Peer id from the payload. |
| `status` | int | yes | Peer's broadcast status code. |
| `color` | int | yes | Peer's broadcast color index. |
| `device` | int | yes | Sender platform: 0 = iOS, 1 = Android. |
| `rssi` | double | no | Raw signal strength (dBm) when the callback carried a measurement. |
| `distance` | double | no | Smoothed estimate in meters — one of 0.5, 1.5, 3.5, 8.0. Present exactly when `rssi` is. |

`rssi` and `distance` are optional because some callbacks carry a payload
without a fresh RSSI sample: a GATT payload read, an immediate-send frame,
and the payload list of a relay (Herald's payload sharing). On iOS, Herald
also reports a relayed payload as a *measured* sighting, but with the relay's
RSSI — see [Known limitations](architecture.md#known-limitations).

## Wire payload (BLE)

What actually travels between devices, encoded by `StatusPayloadSupplier`
identically in Kotlin and Swift. 16 bytes, little-endian:

| Offset | Size | Type | Field |
|---|---|---|---|
| 0 | 8 | UInt64 | peer id |
| 8 | 1 | UInt8 | status code |
| 9 | 1 | UInt8 | color index |
| 10 | 1 | UInt8 | device kind (0 = iOS, 1 = Android) |
| 11 | 1 | UInt8 | flags — bit 0: offline (goodbye) |
| 12 | 4 | UInt32 | protocol version (currently 2) |

Decoding rules, enforced on both platforms:

- A payload shorter than 16 bytes is dropped, never partially parsed.
- A malformed payload must never crash the listener — peers may run other
  builds of this app, or other apps entirely if they collide on the UUID.
- The format is append-only: new fields go after the current 16 bytes and bump
  the protocol version, so old builds keep decoding the prefix they know.
  (Version 2 assigned meaning to the formerly-reserved flags byte.)

The same 16 bytes also travel as **goodbye/hello frames** over Herald's
immediate-send channel (`SensorArray.immediateSendAll`): on logical stop a
device pushes its payload with the offline flag set to its peers; on
restart it pushes the online payload as a hello. Receivers feed these
frames through the same decoder as payload reads — one codec, two
transports. (Which peers a frame reaches depends on the platform; see
[architecture.md](architecture.md#stopping-is-a-protocol-problem).)

## Channel codec notes

Events use the standard message codec (`StandardMethodCodec`). Two
sharp edges worth knowing:

- **Integer width**: Dart `int` arrives in Kotlin as `Integer` *or* `Long`
  depending on magnitude (32-bit range or not). The Android handlers read
  ids as `Number` and normalize (`call.argument<Number>(...)?.toLong()`);
  `status` and `color` are small and read as `Int`.
- **Numeric types are preserved**: a native `Double` arrives in Dart as
  `double` even when it is a whole number (`8.0`), and a native integer as
  `int`. The Dart decoder still reads measurements as `num` and calls
  `toDouble()`, so it stays correct if a native side ever sends them as
  integers (covered by a test).

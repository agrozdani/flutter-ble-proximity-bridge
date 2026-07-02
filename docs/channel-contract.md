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
| `sessionId` | String | 128-bit UUID used as the BLE service UUID. Devices only discover peers started with the same session id. |
| `peerId` | int | This device's identifier in the broadcast payload. |
| `mock` | bool | Start the synthetic peer source instead of the BLE stack. |

Returns `true` when the request was accepted. **Acceptance is not
readiness** — initialization completes asynchronously and is signaled by
the `ready` event. Errors: `bad_args`, `start_failed` (Android only — iOS
accepts the request and surfaces start failures through the ready timeout).

### `updateStatus`

Updates the payload this device broadcasts. Peers see the change the next
time they read our payload (Herald re-reads roughly every 15 s, set by
`payloadDataUpdateTimeInterval`, plus immediately on first contact).

| Argument | Type | Meaning |
|---|---|---|
| `status` | int | Status code (see `PeerStatus` in Dart). |
| `color` | int | Index into the shared color palette. |

Only valid while the bridge is running (`not_running` otherwise). Dart
pushes the current status right after the ready handshake, so the native
side never broadcasts stale state for long.

### `stop`

Stops the proximity source. The long-lived Herald host stays warm for the next
start; a logical stop winds down scanning/advertising rather than tearing the
stack down (see [architecture.md](architecture.md#stopping-is-a-protocol-problem)).
Always succeeds — stopping an already-stopped bridge is a no-op, because Dart
calls it defensively during teardown.

### `forgetPeer`

| Argument | Type | Meaning |
|---|---|---|
| `peerId` | int | Peer whose native distance model should be freed. |

Dart owns the "peer departed" heuristic (no sightings for 20 s) and drives
native cleanup with this call.

## Events

Every event is a map with a `type` discriminator, so new event kinds can be
added without breaking older Dart code (unknown types are ignored).

### `{type: "ready"}`

The native source (BLE or mock) finished initializing. Re-sent to late
subscribers — see the ready-replay pattern in
[architecture.md](architecture.md).

### `{type: "gone", id: int}`

A protocol-level goodbye: peer `id` announced that it stopped. Dart removes
the peer immediately instead of waiting out the staleness eviction.

This event exists because BLE itself has no goodbye. A stopped peripheral
cannot force-disconnect centrals that are already connected to it, and those
centrals keep reading its *cached* payload over the live link — so without
an explicit signal, a stopped device would appear alive indefinitely. The
native side emits `gone` whenever a peer's payload or immediate-send frame
carries the offline flag (see the wire payload below and
[architecture.md](architecture.md#stopping-is-a-protocol-problem)).

### `{type: "peer", ...}`

One sighting of a nearby peer.

| Key | Type | Always present | Meaning |
|---|---|---|---|
| `id` | int | yes | Peer id from the payload. |
| `status` | int | yes | Peer's broadcast status code. |
| `color` | int | yes | Peer's broadcast color index. |
| `device` | int | yes | Sender platform: 0 = iOS, 1 = Android. |
| `rssi` | double | no | Raw signal strength (dBm) when the callback carried a measurement. |
| `distance` | double | no | Smoothed estimate in meters — one of 0.5, 1.5, 3.5, 8.0. Absent until the estimator's window has data. |

`rssi` and `distance` are optional because a payload can be read over GATT
without a fresh RSSI sample, and relayed sightings (Herald's payload
sharing) carry no measurement at all.

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
device pushes its payload with the offline flag set to every peer it holds
a live connection to; on restart it pushes the online payload as a hello.
Receivers feed these frames through the same decoder as payload reads —
one codec, two transports.

## Channel codec notes

Events use the standard message codec (`StandardMethodCodec`). Two
sharp edges worth knowing:

- **Integer width**: Dart `int` arrives in Kotlin as `Integer` *or* `Long`
  depending on magnitude. The Android handlers read `Number` and normalize
  (`call.argument<Number>(...)?.toLong()`).
- **Double narrowing**: a whole-number Double sent from native can arrive
  in Dart as `int`. The Dart decoder reads `num` and calls `toDouble()`
  (covered by a regression test).

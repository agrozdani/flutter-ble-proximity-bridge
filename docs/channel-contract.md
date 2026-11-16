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

Two more channels carry diagnostics only and never affect the bridge; see
[Diagnostics channels](#diagnostics-channels).
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
which this demo logs, as `native.ble`, but does not surface to Dart).

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
though a restart's hello frame still carries the last status pushed before
the restart (see [Known limitations](architecture.md#known-limitations)).

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

Dart owns the "peer departed" heuristic (no sightings for 20 s on iOS, 90 s
on Android, where Herald listens in bursts; see
[android.md](android.md#herald-listens-in-bursts)) and drives native
cleanup with this call.

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

### `{type: "gone", id: int, reason?: String}`

A protocol-level goodbye: peer `id` announced that it stopped. Dart removes
the peer immediately instead of waiting out the staleness eviction.

`reason` is absent for a goodbye. Android also sends `reason: "replaced"`
when a device it last read as `id` is read with another id: the app on that
device started again (ids are per launch), so `id` is gone. Without it, the
old id would stay listed next to the new one until eviction, 90 s on
Android ([android.md](android.md#a-new-id-from-the-same-device)). iOS
never sends a `reason`.

This event exists because BLE itself has no goodbye. A stopped peripheral
cannot force-disconnect centrals that are already connected to it, and those
centrals keep re-reading its payload over the live link (the stopped stack
still answers) and reporting each read — so without an explicit signal, a
stopped device would appear alive indefinitely. The
native side emits `gone` whenever a peer's payload or immediate-send frame
carries the offline flag (see the wire payload below and
[architecture.md](architecture.md#stopping-is-a-protocol-problem)).
Immediate-send frames only ever reach iOS receivers; Herald 2.2.0 for
Android does not deliver them.

After a goodbye frame, the native side stops reporting that peer from
payloads the BLE library merely has cached, until the peer's payload is read
afresh or a timeout passes (5 s for a goodbye from an iPhone, 30 s
otherwise) — otherwise the cached online copy would bring the peer
straight back. The same applies in reverse after a hello. The native side
also remembers the newest revision (see the wire payload below) that each
peer sent it in a frame or a payload read, for 60 s after it last arrived.
While it does, a frame or read with an older revision is ignored, so a
goodbye delivered late cannot remove a peer whose newer payload has already
been read. Older copies that the BLE library holds or a relay passes on are
mostly caught too. The rules are in
[architecture.md](architecture.md#stopping-is-a-protocol-problem), and the
gaps that remain in [Known limitations](architecture.md#known-limitations).

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

A device never reports itself: a payload carrying the id this device was
started with is dropped natively (a relay can hand a device its own payload
back).

## Wire payload (BLE)

What actually travels between devices, encoded by `StatusPayloadSupplier`
identically in Kotlin and Swift. 16 bytes, little-endian:

| Offset | Size | Type | Field |
|---|---|---|---|
| 0 | 8 | UInt64 | peer id |
| 8 | 1 | UInt8 | status code |
| 9 | 1 | UInt8 | color index |
| 10 | 1 | UInt8 | device kind (0 = iOS, 1 = Android) |
| 11 | 1 | UInt8 | flags — bit 0: offline (goodbye); bits 1–7: payload revision (from version 3) |
| 12 | 4 | UInt32 | protocol version (currently 3) |

Decoding rules, enforced on both platforms:

- A payload shorter than 16 bytes is dropped, never partially parsed.
- The peer id is read as a 64-bit pattern: an id with the top bit set
  reaches Dart as the same negative `int` from both platforms. This app
  never broadcasts one (`start` rejects a negative `peerId`), but any device
  on the service UUID could.
- A malformed payload must never crash the listener — peers may run other
  builds of this app, or other apps entirely if they collide on the UUID.
- The revision is a 7-bit counter that wraps after 127. The sender takes
  the next value from one counter per process when its payload supplier is
  created and whenever the status, color, offline flag or peer id it puts
  on the wire changes. Receivers compare revisions with serial-number
  arithmetic: 1–63 steps ahead is newer, 65–127 ahead is older, exactly 64
  apart is unordered. A receiver only compares against a revision it got in
  a frame or payload read within the last 60 s, so a payload is misread as
  older only if its sender changed it more than 64 times in between. Before
  version 3, bits 1–7 were always 0, so a payload with a lower version has
  no revision, and receivers fall back to the timeout rule alone for it.
- The counter starts again in every process, so revisions only order the
  payloads of one launch. This app picks a new peer id at every launch. An
  app that keeps its peer id across launches must persist the counter with
  it; otherwise peers that still remember the previous launch take the new
  one's payloads, its goodbye included, for older ones and ignore them for
  up to about a minute.
- Only bit 0 of the flags is read by builds before version 3, and none of
  them read the version field, so version 3 payloads decode on them
  unchanged.
- The flags byte has no spare bits left (version 2 gave bit 0 of the
  formerly reserved byte its meaning, version 3 bits 1–7), so a new field
  would have to go after the current 16 bytes, with a protocol version
  bump. Appending has two costs, both visible in Herald 2.2.0's source. A
  frame is a 3-byte header plus the payload, and Herald for Android writes
  it to an iPhone in one `writeCharacteristic` call. 3 + 16 = 19 bytes fits
  the 20 that one write carries at the default MTU of 23; anything longer
  needs a long write, whose handling by Herald and CoreBluetooth was not
  verified. And
  Herald's iOS relay splitter cuts a relayed list into pieces the length of
  the *receiver's own* payload, so builds with different payload lengths
  would garble each other's relays.

The same 16 bytes also travel as **goodbye/hello frames** over Herald's
immediate-send channel (`SensorArray.immediateSendAll`): on logical stop a
device pushes its payload with the offline flag set to its peers; on
restart it pushes the online payload as a hello. Receivers feed these
frames through the same decoder as payload reads — one codec, two
transports. (Which peers a frame reaches depends on the platform; see
[architecture.md](architecture.md#stopping-is-a-protocol-problem).)

## Diagnostics channels

The logging system ([logging.md](logging.md)) has its own pair of
channels, declared in `LogChannels` / `LogMethods` / `LogArgs` in
`channel_names.dart` and as `LOG_*` constants next to the bridge's on each
platform.

| Channel | Type | Direction |
|---|---|---|
| `ble_proximity_bridge/log` | MethodChannel | Dart → native |
| `ble_proximity_bridge/logs` | EventChannel | native → Dart |

Methods on `ble_proximity_bridge/log`:

| Method | Arguments | Result |
|---|---|---|
| `configure` | `level` (`debug`/`info`/`warn`/`error`), `herald` (`off`/`fault`/`info`/`debug`) | `{file: String?, echo: bool, printsDart: bool?}`: the native log file's path; whether Dart should print native lines (true on the iOS simulator when native logs to os_log; false where it writes to stderr, e.g. under Xcode's test runner); and whether native writes Dart's lines to the console itself, so that Dart must not print them (true on iOS when the console is stderr; absent on Android). See [logging.md](logging.md) |
| `write` | `lines`: `List<String>` of formatted Dart lines; `printed`: bool, whether Dart printed them itself (absent: it did) | `null`; native appends them to its log file, and writes them to its console when `printed` is false |

Events on `ble_proximity_bridge/logs` are `List<String>` batches of
formatted native lines. Lines logged while nothing listens are held (up to
5000) and sent when Dart subscribes.

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

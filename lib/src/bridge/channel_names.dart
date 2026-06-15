/// Channel and key names shared with the native side.
///
/// Android declares the same strings in MainActivity.kt, iOS in
/// AppDelegate.swift. Nothing checks these across the language boundary,
/// so a typo only shows up at runtime. Keep them in sync.
library;

/// One channel for commands going out, one for events coming back.
abstract final class BridgeChannels {
  static const String methods = 'ble_proximity_bridge/methods';
  static const String events = 'ble_proximity_bridge/events';
}

/// Method names invoked on [BridgeChannels.methods].
abstract final class BridgeMethods {
  /// Starts proximity detection. Takes sessionId, peerId and mock.
  static const String start = 'start';

  /// Stops proximity detection.
  static const String stop = 'stop';

  /// Updates the status/color this device broadcasts.
  static const String updateStatus = 'updateStatus';

  /// Frees native per-peer state for a departed peer.
  static const String forgetPeer = 'forgetPeer';
}

/// Argument keys for the methods above.
abstract final class BridgeArgs {
  static const String sessionId = 'sessionId';
  static const String peerId = 'peerId';
  static const String mock = 'mock';
  static const String status = 'status';
  static const String color = 'color';
}

/// Keys for events arriving on [BridgeChannels.events]. Every event has a
/// `type` field so new kinds can be added without breaking old clients.
abstract final class BridgeEventKeys {
  static const String type = 'type';
  static const String typeReady = 'ready';
  static const String typePeer = 'peer';
  static const String typeGone = 'gone';

  static const String id = 'id';
  static const String status = 'status';
  static const String color = 'color';
  static const String device = 'device';
  static const String rssi = 'rssi';
  static const String distance = 'distance';
}

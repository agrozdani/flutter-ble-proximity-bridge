import 'package:flutter/services.dart';

import '../logging/log.dart';
import '../models/bridge_event.dart';
import 'channel_names.dart';

/// Typed wrapper around the event channel.
///
/// Decodes the raw maps coming from native into [BridgeEvent]s. The caller
/// owns the subscription.
class ProximityEventChannel {
  ProximityEventChannel({EventChannel? channel})
    : _channel = channel ?? const EventChannel(BridgeChannels.events);

  final EventChannel _channel;

  /// The decoded native event stream. Subscribing triggers the native
  /// onListen, cancelling triggers onCancel.
  Stream<BridgeEvent> events() {
    return _channel.receiveBroadcastStream().map(_decode);
  }

  static BridgeEvent _decode(Object? raw) {
    try {
      return BridgeEvent.fromMap((raw as Map).cast<Object?, Object?>());
    } on Object catch (error, stack) {
      // Becomes an error on the stream, as before; log what native sent.
      Log.e('events', 'undecodable event from native: $raw', error, stack);
      rethrow;
    }
  }
}

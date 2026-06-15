import 'package:flutter/services.dart';

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
    return _channel.receiveBroadcastStream().map(
      (raw) => BridgeEvent.fromMap((raw as Map).cast<Object?, Object?>()),
    );
  }
}

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
    _dropEventsNobodyListensTo();
    return _channel.receiveBroadcastStream().map(_decode);
  }

  /// An event that native sent as Dart cancelled must not reach the next
  /// subscription. On cancel, EventChannel removes its Dart handler first
  /// and only then tells native to stop, so events in flight arrive with no
  /// handler. Flutter then keeps the last of them (ChannelBuffers, 1 message
  /// per channel by default) and hands it to the next handler: the last
  /// mock sighting showed up in the next BLE session as a peer that wasn't
  /// there. Events only flow while Dart listens, so one that finds nobody
  /// listening belongs to a subscription that has ended: drop it. Marking
  /// the overflow as expected stops debug builds from warning about it.
  void _dropEventsNobodyListensTo() {
    final buffers = ServicesBinding.instance.channelBuffers;
    buffers.resize(_channel.name, 0);
    buffers.allowOverflow(_channel.name, true);
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

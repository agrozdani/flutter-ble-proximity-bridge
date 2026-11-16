import 'package:ble_proximity_bridge/src/bridge/channel_names.dart';
import 'package:ble_proximity_bridge/src/bridge/proximity_event_channel.dart';
import 'package:ble_proximity_bridge/src/models/bridge_event.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel(BridgeChannels.events);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // Native accepts listen and cancel and sends nothing on its own.
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() => messenger.setMockStreamHandler(channel, null));

  test(
    'an event that arrives between two subscriptions reaches neither',
    () async {
      final events = ProximityEventChannel();
      final first = events.events().listen((_) {});
      await first.cancel();

      // Native sent this sighting as Dart cancelled: EventChannel removes its
      // handler before it tells native to stop, so the engine finds no
      // handler for it. (Seen on a Pixel: the last mock sighting turned up in
      // the next BLE session, 22 s later, as a peer that wasn't there.)
      ServicesBinding.instance.channelBuffers.push(
        BridgeChannels.events,
        const StandardMethodCodec().encodeSuccessEnvelope({
          BridgeEventKeys.type: BridgeEventKeys.typePeer,
          BridgeEventKeys.id: 0xCAFED00D,
        }),
        (_) {},
      );

      final received = <BridgeEvent>[];
      final second = events.events().listen(received.add);
      await pumpEventQueue();
      await second.cancel();

      expect(received, isEmpty);
    },
  );
}

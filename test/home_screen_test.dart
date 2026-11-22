import 'package:ble_proximity_bridge/main.dart';
import 'package:ble_proximity_bridge/src/models/bridge_event.dart';
import 'package:ble_proximity_bridge/src/models/peer.dart';
import 'package:ble_proximity_bridge/src/providers/peers_provider.dart';
import 'package:ble_proximity_bridge/src/ui/home_screen.dart';
import 'package:ble_proximity_bridge/src/ui/peer_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The home screen on screens its cards do not fit: what does not fit
/// scrolls, and Start/Stop and the peer list can always be reached.
///
/// Flutter's test font is larger than the fonts devices draw with, so these
/// check the layout, not how much room a particular device has. The old
/// fixed column overflowed in each of these cases with a device's font: an
/// iPhone SE simulator in landscape (87 px) and at the first accessibility
/// text size (81 px, Start partly cut off), 2026-11-18; and on the Pixel
/// Tablet, which logged 38 px on 2026-11-16 while its keyboard went down
/// (with Roboto, 1280x800 with a 400 px keyboard and a 24 px status bar
/// overflows by 50 px).
void main() {
  /// Lays the app out on a [size] screen (logical pixels) with a keyboard
  /// of [keyboard] pixels up and text scaled by [textScale], and returns the
  /// layout errors it reported.
  Future<List<String>> layOut(
    WidgetTester tester,
    Size size, {
    double keyboard = 0,
    double textScale = 1,
    FakeViewPadding padding = FakeViewPadding.zero,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) =>
        errors.add(details.exceptionAsString().split('\n').first);
    try {
      await tester.pumpWidget(const ProviderScope(child: ProximityBridgeApp()));
      await tester.pump();
    } finally {
      FlutterError.onError = previous;
    }
    return errors;
  }

  /// Disposes the app, and with it the providers' timers.
  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  const screens = {
    'a phone in landscape': (Size(667, 375), 0.0, 1.0),
    'a tablet in landscape with its keyboard up': (Size(1280, 800), 400.0, 1.0),
    // iOS's first accessibility size (AX1) scales body text by 28/17.
    'a phone at an accessibility text size': (Size(375, 667), 0.0, 1.65),
  };

  for (final MapEntry(key: name, value: (size, keyboard, textScale))
      in screens.entries) {
    testWidgets('$name: nothing overflows, Start and the peer list can be '
        'reached', (tester) async {
      final errors = await layOut(
        tester,
        size,
        keyboard: keyboard,
        textScale: textScale,
      );
      expect(errors, isEmpty);

      // scrollUntilVisible jumps; pump so hit testing sees the new layout.
      await tester.scrollUntilVisible(find.text('Start'), 100);
      await tester.pump();
      expect(find.text('Start').hitTestable(), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Start the bridge to discover peers'),
        100,
      );
      await tester.pump();
      expect(find.text('Nearby peers (0)').hitTestable(), findsOneWidget);
      await close(tester);
    });
  }

  /// Lists [count] mock peers, ids 1 to [count], all at the same distance.
  Future<void> listPeers(WidgetTester tester, int count) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    for (var id = 1; id <= count; id++) {
      container
          .read(peersProvider.notifier)
          .applySighting(
            PeerSighting(
              id: id,
              statusCode: PeerStatus.available.code,
              colorIndex: 0,
              deviceKind: DeviceKind.android,
              rssi: -60,
              distance: 1.5,
            ),
          );
    }
    await tester.pump();
  }

  testWidgets('a long peer list scrolls to its last peer', (tester) async {
    final errors = await layOut(tester, const Size(375, 667));
    expect(errors, isEmpty);
    await listPeers(tester, 30);
    expect(tester.takeException(), isNull);
    expect(find.text('Nearby peers (30)'), findsOneWidget);

    // Peers are sorted nearest first, then by id: 30 is last.
    await tester.scrollUntilVisible(find.text('Peer 0000001E'), 200);
    await tester.pump();
    expect(find.text('Peer 0000001E').hitTestable(), findsOneWidget);
    expect(find.byType(PeerTile), findsWidgets);
    await close(tester);
  });

  // iOS's first and largest accessibility sizes (AX1, AX5) scale body text
  // by 28/17 and 53/17.
  for (final textScale in [28 / 17, 53 / 17]) {
    testWidgets(
      'peer tiles fit at text scale ${textScale.toStringAsFixed(2)}',
      (tester) async {
        final errors = await layOut(
          tester,
          const Size(393, 852),
          textScale: textScale,
        );
        expect(errors, isEmpty);
        await listPeers(tester, 3);

        // Each tile shows its distance in two lines on the right, which
        // ListTile gives at most 56 px of height.
        await tester.scrollUntilVisible(find.text('Peer 00000003'), 200);
        await tester.pump();
        expect(find.text('Peer 00000003').hitTestable(), findsOneWidget);
        expect(find.text('~1.5 m'), findsWidgets);
        expect(tester.takeException(), isNull);
        await close(tester);
      },
    );
  }

  testWidgets('the end of the list stays above the home indicator', (
    tester,
  ) async {
    // An iPhone with a home indicator: 59 px status bar, 34 px at the bottom.
    // The ListView this replaced kept its end above that inset by itself.
    const screen = Size(393, 852);
    final errors = await layOut(
      tester,
      screen,
      padding: const FakeViewPadding(top: 59, bottom: 34),
    );
    expect(errors, isEmpty);
    await listPeers(tester, 30);

    // The scrollable that holds the list, whatever kind of scroll view it is.
    final list = find.ancestor(
      of: find.byType(PeerTile).first,
      matching: find.byType(Scrollable),
    );
    await tester.drag(list.first, const Offset(0, -20000));
    await tester.pumpAndSettle();
    final last = tester.getRect(
      find.ancestor(
        of: find.text('Peer 0000001E'),
        matching: find.byType(ListTile),
      ),
    );
    expect(last.bottom, lessThanOrEqualTo(screen.height - 34));
    await close(tester);
  });
}

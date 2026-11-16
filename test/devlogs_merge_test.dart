import 'dart:io';

import 'package:ble_proximity_bridge/src/logging/log_line.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/devlogs.dart';

/// `tool/devlogs.dart merge`: what it keeps from the files it is given.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('devlogs-merge-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  String file(String name, List<String> lines) {
    final path = '${dir.path}/$name';
    File(path).writeAsStringSync('${lines.join('\n')}\n');
    return path;
  }

  /// The merged lines, without the `#` header.
  List<String> merge(
    List<(String, String)> inputs, {
    LogLevel level = LogLevel.debug,
  }) {
    final out = StringBuffer();
    mergeLogs(inputs, level, out);
    return out
        .toString()
        .trimRight()
        .split('\n')
        .where((line) => !line.startsWith('#'))
        .toList();
  }

  const failed =
      '2026-11-16 10:15:03.123 W native.frame [frame-sender] goodbye failed '
      'after 12 ms: java.lang.IllegalStateException: boom';
  const cause = '    java.lang.IllegalStateException: boom';
  const frame = '    \tat com.example.Foo.bar(Foo.kt:1)';
  const stopped =
      '2026-11-16 10:15:03.130 I native.host [main] Herald host stopped';

  test('keeps a stack trace from the device log file', () {
    final merged = merge([
      ('pixel', file('pixel.log', [failed, cause, frame, stopped])),
    ]);
    expect(merged, hasLength(4));
    expect(
      merged[0],
      endsWith(
        'goodbye failed after 12 ms: '
        'java.lang.IllegalStateException: boom',
      ),
    );
    expect(merged[1], endsWith(cause));
    expect(merged[2], endsWith(frame));
    expect(merged[3], endsWith('Herald host stopped'));
  });

  test('keeps a stack trace from a logcat capture (the logcat command)', () {
    // adb logcat -v threadtime puts its prefix on every line of a message.
    String logcat(String line, {String tag = 'BPB     '}) =>
        '11-16 10:15:03.125  4321  4400 W $tag: $line';
    final merged = merge([
      (
        'pixel',
        file('pixel-logcat.log', [
          logcat(failed),
          logcat(cause),
          logcat(frame),
          // Another tag's line is not part of the trace, indented or not.
          logcat('    indented Herald text', tag: 'Sensor::BLE.Receiver'),
          logcat(stopped),
        ]),
      ),
    ]);
    expect(merged, hasLength(4));
    expect(merged[1], endsWith(cause));
    expect(merged[2], endsWith(frame));
    expect(merged[3], endsWith('Herald host stopped'));
  });

  test('keeps a stack trace from flutter run output', () {
    final android = merge([
      (
        'pixel',
        file('android.log', [
          'W/BPB     ( 4321): $failed',
          'W/BPB     ( 4321): $cause',
          'W/BPB     ( 4321): $frame',
        ]),
      ),
    ]);
    expect(android, hasLength(3));
    expect(android[2], endsWith('at com.example.Foo.bar(Foo.kt:1)'));

    const dart = '2026-11-16 10:15:04.000 E dart.dart uncaught error: boom';
    final ios = merge([
      (
        'ipad',
        file('ios.log', [
          'flutter: $dart',
          'flutter:     #0      main (package:app/main.dart:1:1)',
        ]),
      ),
    ]);
    expect(ios, hasLength(2));
    expect(ios[1], endsWith('#0      main (package:app/main.dart:1:1)'));
  });

  test('a line in a pulled file and in a capture of that device is kept '
      'once', () {
    final merged = merge([
      ('pixel', file('pixel.log', [failed, cause, frame, stopped])),
      ('pixel', file('capture.log', ['W/BPB     ( 4321): $failed', stopped])),
    ]);
    expect(merged, hasLength(4));
  });

  group('a line logcat had in pieces', () {
    // As BridgeLog.logcatParts cuts it: 1300 characters, the later pieces
    // after "    \u2026".
    final long =
        '2026-11-16 10:15:03.124 I native.method [main] start ${'x' * 3000} '
        'self=0B5EAFE7';
    List<String> pieces(String line) => [
      for (var i = 0; i < line.length; i += 1300)
        '${i == 0 ? '' : '    \u2026'}'
            '${line.substring(i, (i + 1300).clamp(0, line.length))}',
    ];
    String logcat(String piece) =>
        '11-16 10:15:03.124  4321  4321 I BPB     : $piece';

    test('is joined back into one line', () {
      final merged = merge([
        (
          'pixel',
          file('run.log', [
            for (final p in pieces(long)) 'I/BPB     ( 4321): $p',
          ]),
        ),
      ]);
      expect(merged, hasLength(1));
      expect(merged.single, endsWith(long.substring(24)));
    });

    test('is kept once with the same line from the pulled file', () {
      final merged = merge([
        ('pixel', file('pixel.log', [long, stopped])),
        (
          'pixel',
          file('capture.log', [...pieces(long).map(logcat), logcat(stopped)]),
        ),
      ]);
      expect(merged, hasLength(2));
      expect(merged.first, endsWith(long.substring(24)));
    });

    test('in a stack trace joins the trace line it was cut from', () {
      final longFrame = '    \tat com.example.${'Foo' * 600}.bar(Foo.kt:1)';
      final merged = merge([
        (
          'pixel',
          file('capture.log', [
            logcat(failed),
            ...pieces(longFrame).map(logcat),
            logcat(frame),
          ]),
        ),
      ]);
      expect(merged, hasLength(3));
      expect(merged[1], endsWith(longFrame));
      expect(merged[2], endsWith(frame));
    });
  });

  test('the same line twice in one file is two lines', () {
    const sighting =
        '2026-11-16 10:15:03.123 D native.emit [main] peer 0B5EAFE7 st=1 '
        'col=2 android no rssi';
    final pulled = file('pixel.log', [sighting, sighting, stopped]);
    expect(merge([('pixel', pulled)]), hasLength(3));
    // Still once each when a capture has them too.
    final capture = file('capture.log', [sighting, sighting, sighting]);
    expect(merge([('pixel', pulled), ('pixel', capture)]), hasLength(4));
  });

  test('sorts by time, tags other devices\' ids and filters by level', () {
    final pixel = file('pixel.log', [
      '2026-11-16 10:15:01.000 I native.service [main] start command #1 '
          'self=0B5EAFE7',
      '2026-11-16 10:15:03.120 I native.frame [frame-sender] sending goodbye '
          '0B5EAFE7 android st=3 col=0 rev=5 OFFLINE v3 to recent peers',
      '2026-11-16 10:15:03.121 D native.emit [main] peer 1A2B3C4D st=1',
    ]);
    final ipad = file('ipad.log', [
      '2026-11-16 10:15:00.500 I dart.bridge identity self=1A2B3C4D',
      '2026-11-16 10:15:03.180 I dart.peers - 0B5EAFE7 removed: goodbye',
    ]);
    final merged = merge([
      ('Pixel', pixel),
      ('iPad', ipad),
    ], level: LogLevel.info);
    expect(merged, [
      '10:15:00.500 iPad  I dart.bridge identity self=1A2B3C4D',
      '10:15:01.000 Pixel I native.service [main] start command #1 '
          'self=0B5EAFE7',
      '10:15:03.120 Pixel I native.frame [frame-sender] sending goodbye '
          '0B5EAFE7 android st=3 col=0 rev=5 OFFLINE v3 to recent peers',
      '10:15:03.180 iPad  I dart.peers - 0B5EAFE7«Pixel» removed: goodbye',
    ]);
  });
}

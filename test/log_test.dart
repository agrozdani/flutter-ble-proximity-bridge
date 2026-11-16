import 'package:ble_proximity_bridge/src/logging/log.dart';
import 'package:flutter_test/flutter_test.dart';

/// The log line format is shared with the Kotlin and Swift loggers and
/// parsed by tool/devlogs.dart, so it is pinned here.
void main() {
  group('LogLine', () {
    test('formats and parses back', () {
      final line = LogLine(
        time: DateTime(2026, 11, 16, 9, 5, 3, 7),
        level: LogLevel.warn,
        origin: 'dart',
        component: 'bridge',
        message: 'start #3 failed',
      );
      expect(
        line.format(),
        '2026-11-16 09:05:03.007 W dart.bridge start #3 failed',
      );

      final parsed = LogLine.find(line.format())!;
      expect(parsed.time, line.time);
      expect(parsed.level, LogLevel.warn);
      expect(parsed.origin, 'dart');
      expect(parsed.component, 'bridge');
      expect(parsed.message, 'start #3 failed');
      expect(parsed.isNative, isFalse);
    });

    test('is found behind the prefixes of the places it is captured', () {
      const native =
          '2026-11-16 10:15:03.123 I native.pipeline [main] frame 1A2B3C4D';
      for (final captured in [
        native,
        // adb logcat -v threadtime
        '11-16 10:15:03.125  4321  4321 I BPB     : $native',
        // flutter run on Android
        'I/BPB     ( 4321): $native',
        // an os_log line with its metadata stripped by flutter_tools
        // (category kept)
        '[BPB] $native',
        // Console / log stream
        '2026-11-16 10:15:03.125 Df Runner[1:2] [com.example:BPB] $native',
      ]) {
        final parsed = LogLine.find(captured);
        expect(parsed, isNotNull, reason: captured);
        expect(parsed!.format(), native, reason: captured);
        expect(parsed.isNative, isTrue);
      }

      final dart = LogLine.find(
        'flutter: 2026-11-16 10:15:03.200 D dart.channel → stop',
      )!;
      expect(dart.component, 'channel');
      expect(dart.message, '→ stop');
    });

    test('ignores lines that are not ours', () {
      expect(LogLine.find('Syncing files to device iPhone...'), isNull);
      expect(LogLine.find('I/flutter ( 4321): hello'), isNull);
      expect(
        LogLine.find('2026-11-16 10:15:03.123 X dart.bridge nope'),
        isNull,
      );
    });
  });

  test('peerHex matches the UI and the native loggers', () {
    expect(peerHex(0x51C0FFEE), '51C0FFEE');
    expect(peerHex(0xB5EAFE7), '0B5EAFE7');
    expect(peerHex(0), '00000000');
    // Negative ids: 64-bit two's complement, like Long.toHexString and
    // UInt64(bitPattern:).
    expect(peerHex(-1), 'FFFFFFFFFFFFFFFF');
  });

  test('LogLevel.parse takes names and letters', () {
    expect(LogLevel.parse('debug'), LogLevel.debug);
    expect(LogLevel.parse('INFO'), LogLevel.info);
    expect(LogLevel.parse('warning'), LogLevel.warn);
    expect(LogLevel.parse('e'), LogLevel.error);
    expect(LogLevel.parse(''), isNull);
    expect(LogLevel.parse('loud'), isNull);
  });

  group('Log', () {
    late LogLevel savedLevel;

    setUp(() => savedLevel = Log.minLevel);
    tearDown(() => Log.minLevel = savedLevel);

    test('drops lines below the minimum level', () {
      Log.minLevel = LogLevel.info;
      final before = Log.buffer.length;
      Log.d('test', 'hidden');
      Log.i('test', 'shown');
      final records = Log.buffer.records;
      expect(records.length, before + 1);
      expect(records.last.text, endsWith(' I dart.test shown'));
      expect(records.last.native, isFalse);
    });

    test('appends the error and an indented stack trace', () {
      Log.minLevel = LogLevel.debug;
      Log.w('test', 'failed', StateError('boom'), StackTrace.current);
      final text = Log.buffer.records.last.text;
      final lines = text.split('\n');
      expect(lines.first, endsWith(' W dart.test failed: Bad state: boom'));
      expect(lines.length, greaterThan(1));
      expect(lines.skip(1), everyElement(startsWith('    ')));
    });

    test('takes the level of native lines from the line itself', () {
      Log.addNative('2026-11-16 10:15:03.123 E native.host [main] broke');
      expect(Log.buffer.records.last.level, LogLevel.error);
      expect(Log.buffer.records.last.native, isTrue);
    });
  });

  test('LogBuffer keeps only the newest lines', () {
    final buffer = LogBuffer(capacity: 3);
    for (var index = 0; index < 5; index++) {
      buffer.add(LogRecord('line $index', LogLevel.info, native: false));
    }
    expect(buffer.records.map((record) => record.text), [
      'line 2',
      'line 3',
      'line 4',
    ]);
    expect(buffer.dropped, 2);
  });
}

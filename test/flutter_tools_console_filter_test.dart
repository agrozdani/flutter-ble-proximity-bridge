import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// On an iOS device, `flutter run` drops a console line that matches this
/// pattern (flutter_tools 3.47.9, `IOSCoreDeviceControl._ignorePatterns` in
/// packages/flutter_tools/lib/src/ios/core_devices.dart). BridgeLog writes
/// its lines to stderr there because os_log's mirror copies match it
/// (docs/logging.md, "How native lines reach `flutter run`"), so our own
/// lines must never match.
const String _ignorePattern =
    r'^\S* \S* \S*\[[0-9:]*] ((?!(\[INFO|\[WARNING|\[ERROR|\[IMPORTANT|\[FATAL):))(?!(flutter:))(?!(\[UIKit App Config\] `UIScene` lifecycle))(?!.*UIScene life\s?cycle).*';

void main() {
  final ignored = RegExp(_ignorePattern);

  test('our native lines pass the filter', () {
    for (final line in [
      '2026-11-16 12:37:46.966 I native.log [main] ==== native log start pid=3035 app=1.0.0+3',
      '2026-11-16 12:37:46.970 D native.pipeline [BLE.BLESensor.DelegateQueue] relay via=2B5F shared 1 payload(s)',
      '2026-11-16 12:37:46.971 E native.crash [main] uncaught exception NSInvalidArgumentException: bad',
      // Continuation lines of a multi-line message (a stack trace).
      '    0   CoreFoundation 0x0000000180a1b2c3 __exceptionPreprocess + 164',
      '2026-11-16 12:37:46.972 W native.log [main] 3 earlier lines did not fit while Dart was not listening',
    ]) {
      expect(ignored.hasMatch(line), isFalse, reason: line);
    }
  });

  test("os_log's mirror copy of a native line is dropped", () {
    // As seen in `flutter run -v` on an iPad, 2026-11-16.
    expect(
      ignored.hasMatch(
        '2026-11-16 12:37:46.968125-0500 Runner[3035:1127046] [BPB] '
        '2026-11-16 12:37:46.966 I native.log [main] ==== native log start',
      ),
      isTrue,
    );
  });

  test('the pattern is still the one in the Flutter SDK', () {
    // The test runs in an executable inside the Flutter SDK's bin/cache;
    // walk up to the SDK root.
    const relative = 'packages/flutter_tools/lib/src/ios/core_devices.dart';
    File? source;
    for (
      Directory dir = File(Platform.resolvedExecutable).parent;
      dir.parent.path != dir.path;
      dir = dir.parent
    ) {
      final candidate = File('${dir.path}/$relative');
      if (candidate.existsSync()) {
        source = candidate;
        break;
      }
    }
    if (source == null) {
      markTestSkipped(
        'Flutter SDK source not found above ${Platform.resolvedExecutable}',
      );
      return;
    }
    final text = source.readAsStringSync();
    final start = text.indexOf('_ignorePatterns = <Pattern>[');
    expect(start, isNot(-1), reason: '_ignorePatterns not found');
    final match = RegExp(
      r"RegExp\(\s*r'([^']*)'",
    ).firstMatch(text.substring(start));
    expect(match, isNotNull, reason: 'no RegExp in _ignorePatterns');
    expect(
      match!.group(1),
      _ignorePattern,
      reason:
          'flutter_tools changed its console filter; check that native lines '
          'still show once in `flutter run` on an iOS device',
    );
  });
}

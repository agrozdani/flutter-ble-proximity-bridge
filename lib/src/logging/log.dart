import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'log_line.dart';

export 'log_line.dart' show LogLevel, LogLine, peerHex;

/// The Dart half of the app's logging. See docs/logging.md.
///
/// Every line is kept in [buffer] (for the in-app log viewer). Once
/// `LoggingSetup.init` has run, Dart lines are also printed (`flutter run`
/// shows them; on Android they land in logcat under the `flutter` tag) and
/// forwarded to the native logger, which writes them to the on-device log
/// file next to its own lines. Until then (in tests, say) lines only go to
/// [buffer].
///
/// ```dart
/// Log.i('bridge', 'start #3 mock=false');
/// Log.w('channel', 'stop failed', error, stackTrace);
/// ```
abstract final class Log {
  /// Lines below this level are dropped. Debug in debug and profile builds,
  /// info in release; `--dart-define=LOG_LEVEL=info` overrides it (see
  /// `LoggingSetup`).
  static LogLevel minLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;

  /// The most recent lines from both sides, oldest first.
  static final LogBuffer buffer = LogBuffer();

  /// Print Dart lines to the console. Off until `LoggingSetup.init`.
  static bool printToConsole = false;

  /// Hands a formatted Dart line to the native log file. Set by
  /// `LoggingSetup.init`.
  static void Function(String line)? forwardToNative;

  /// Also print native lines. Only where they would not reach the console
  /// otherwise (the iOS simulator); native says so in `configure`.
  static bool echoNative = false;

  static bool isEnabled(LogLevel level) => level.index >= minLevel.index;

  static void d(String component, String message) =>
      _log(LogLevel.debug, component, message);

  static void i(String component, String message) =>
      _log(LogLevel.info, component, message);

  static void w(
    String component,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) => _log(LogLevel.warn, component, message, error, stack);

  static void e(
    String component,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) => _log(LogLevel.error, component, message, error, stack);

  static void _log(
    LogLevel level,
    String component,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    if (!isEnabled(level)) return;
    final text = StringBuffer(message);
    if (error != null) text.write(': $error');
    if (stack != null) {
      for (final frame in stack.toString().trimRight().split('\n')) {
        text.write('\n    $frame');
      }
    }
    final line = LogLine(
      time: DateTime.now(),
      level: level,
      origin: 'dart',
      component: component,
      message: text.toString(),
    ).format();
    buffer.add(LogRecord(line, level, native: false));
    if (printToConsole) debugPrint(line);
    forwardToNative?.call(line);
  }

  /// Adds lines the native logger sent over its event channel. They are
  /// only buffered: the native side already wrote them to its console
  /// (logcat on Android; stderr or os_log on iOS), which is where
  /// `flutter run` shows them, and to the log file. (Except on the iOS
  /// simulator; see [echoNative].)
  static void addNative(String line) {
    final level = LogLine.find(line)?.level ?? LogLevel.info;
    buffer.add(LogRecord(line, level, native: true));
    if (echoNative && printToConsole) debugPrint(line);
  }
}

/// One line in [LogBuffer].
@immutable
class LogRecord {
  const LogRecord(this.text, this.level, {required this.native});

  /// The formatted line, exactly as it appears everywhere else.
  final String text;
  final LogLevel level;

  /// Logged by the Kotlin/Swift side.
  final bool native;
}

/// A bounded, in-memory list of recent log lines.
class LogBuffer extends ChangeNotifier {
  LogBuffer({this.capacity = 5000});

  final int capacity;
  final ListQueue<LogRecord> _records = ListQueue<LogRecord>();
  int _dropped = 0;

  /// Lines pushed out by newer ones since the app started.
  int get dropped => _dropped;

  /// A snapshot, oldest first.
  List<LogRecord> get records => List<LogRecord>.of(_records);

  int get length => _records.length;

  void add(LogRecord record) {
    _records.addLast(record);
    if (_records.length > capacity) {
      _records.removeFirst();
      _dropped++;
    }
    notifyListeners();
  }
}

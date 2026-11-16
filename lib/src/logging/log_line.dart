/// The one log line format shared by the Dart, Kotlin and Swift loggers.
///
/// ```text
/// 2026-11-16 10:15:03.123 I native.pipeline [main] frame 1A2B3C4D ios ...
/// └── local wall clock ──┘ │ └── origin.component ┘ └ message ───────────
///                          level: D(ebug) I(nfo) W(arn) E(rror)
/// ```
///
/// Native lines put the thread (Android) or dispatch queue (iOS) they were
/// logged on in brackets at the start of the message. A message can span
/// several lines (stack traces); the continuation lines carry no prefix.
///
/// Every place a line ends up (logcat, os_log, `flutter run`, the on-device
/// log file, the in-app viewer) carries it verbatim, so [LogLine.find] can
/// pick it out of any of them, whatever prefix they add. tool/devlogs.dart
/// relies on that to merge the logs of several devices into one timeline.
///
/// Pure Dart (no Flutter imports), so the command-line tool can use it.
library;

/// Severity of a log line. The order is the filter order: a minimum level
/// lets through that level and everything after it.
enum LogLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E');

  const LogLevel(this.letter);

  /// The single letter that appears in the line.
  final String letter;

  static LogLevel? fromLetter(String letter) {
    for (final level in values) {
      if (level.letter == letter) return level;
    }
    return null;
  }

  /// Accepts `debug`/`info`/`warn`/`error` (any case) or the letter.
  static LogLevel? parse(String? value) {
    if (value == null || value.isEmpty) return null;
    final lower = value.toLowerCase();
    for (final level in values) {
      if (level.name == lower || level.letter.toLowerCase() == lower) {
        return level;
      }
    }
    if (lower == 'warning') return warn;
    return null;
  }
}

/// One parsed (or about to be formatted) log line.
class LogLine {
  const LogLine({
    required this.time,
    required this.level,
    required this.origin,
    required this.component,
    required this.message,
  });

  /// Local wall-clock time, millisecond precision.
  final DateTime time;
  final LogLevel level;

  /// `dart` or `native`.
  final String origin;

  /// What logged it, e.g. `bridge`, `pipeline`, `host`.
  final String component;

  /// Everything after the component; may contain newlines.
  final String message;

  bool get isNative => origin == 'native';

  String format() =>
      '${formatLogTime(time)} ${level.letter} $origin.$component $message';

  @override
  String toString() => format();

  static final RegExp _pattern = RegExp(
    r'(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) ([DIWE]) '
    r'(dart|native)\.([A-Za-z0-9_]+) ?(.*)$',
  );

  /// Finds a log line inside [text], which may carry a prefix from wherever
  /// it was captured (`I/flutter (1234): `, `flutter: `, `[BPB] `, ...).
  /// Returns null when [text] holds none.
  static LogLine? find(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    int at(int group) => int.parse(match.group(group)!);
    return LogLine(
      time: DateTime(at(1), at(2), at(3), at(4), at(5), at(6), at(7)),
      level: LogLevel.fromLetter(match.group(8)!)!,
      origin: match.group(9)!,
      component: match.group(10)!,
      message: match.group(11)!,
    );
  }
}

/// `2026-11-16 10:15:03.123`, local time.
String formatLogTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final millis = time.millisecond.toString().padLeft(3, '0');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)} ${two(time.hour)}:${two(time.minute)}:'
      '${two(time.second)}.$millis';
}

/// A peer id as every log line writes it: upper-case hex, at least 8
/// digits, negative ids as their 64-bit two's complement. Matches
/// `Peer.shortId` for the ids this app uses, and the native loggers'
/// `peerHex` for every id.
String peerHex(int id) {
  String hex(int value) => value.toRadixString(16).toUpperCase();
  if (id >= 0) return hex(id).padLeft(8, '0');
  // A Dart int is signed, so a negative id is printed as its two 32-bit
  // halves (toUnsigned(64) cannot make it positive).
  return hex((id >> 32) & 0xFFFFFFFF).padLeft(8, '0') +
      hex(id & 0xFFFFFFFF).padLeft(8, '0');
}

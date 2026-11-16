import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../bridge/channel_names.dart';
import 'log.dart';

/// Wires [Log] to the console and to the native logger, and installs the
/// error and lifecycle hooks. Called once from `main`.
///
/// Build-time switches (`flutter run --dart-define=...`):
///
/// - `LOG_LEVEL=debug|info|warn|error` — the minimum level on both sides.
///   Default: debug, or info in release builds.
/// - `HERALD_LOG=off|fault|info|debug` — Herald's own logging, which goes to
///   logcat / os_log and Herald's `log.txt`, not to this app's log file.
///   Default: fault (Herald's errors), or off in release builds.
/// - `LOG_ECHO_NATIVE=true` — Dart also prints every native line. Only for
///   a console that does not show native lines on its own; where it does,
///   each native line then appears twice.
abstract final class LoggingSetup {
  static const MethodChannel _methods = MethodChannel(LogChannels.methods);
  static const EventChannel _events = EventChannel(LogChannels.events);

  static const String _levelDefine = String.fromEnvironment('LOG_LEVEL');
  static const String _heraldDefine = String.fromEnvironment('HERALD_LOG');
  static const bool _echoDefine = bool.fromEnvironment('LOG_ECHO_NATIVE');
  static const Set<String> _heraldLevels = {'off', 'fault', 'info', 'debug'};

  /// Where the native logger writes, once it has said so.
  static String? nativeLogFile;

  /// Kept so it stays registered; also marks [init] as done.
  static AppLifecycleListener? _lifecycle;

  static void init() {
    if (_lifecycle != null) return;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) => Log.i('app', 'lifecycle ${state.name}'),
    );

    Log.minLevel = LogLevel.parse(_levelDefine) ?? Log.minLevel;
    final herald = _heraldLevels.contains(_heraldDefine)
        ? _heraldDefine
        : (kReleaseMode ? 'off' : 'fault');

    Log.printToConsole = true;
    Log.forwardToNative = (line) {
      // Sent at once, not batched: a message reaches native before any
      // method call Dart makes after logging it, so the file keeps the two
      // sides in order. Failures are ignored; the line was printed anyway.
      _methods.invokeMethod<void>(LogMethods.write, {
        LogArgs.lines: [line],
      }).ignore();
    };

    _events.receiveBroadcastStream().listen(
      (batch) {
        for (final line in batch as List<Object?>) {
          if (line is String) Log.addNative(line);
        }
      },
      onError: (Object error) =>
          Log.w('log', 'native log stream failed', error),
    );

    _installErrorHooks();

    final mode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug';
    Log.i(
      'app',
      '==== dart start build=$mode os=${Platform.operatingSystem} '
          '"${Platform.operatingSystemVersion}" '
          'dart=${Platform.version.split(' ').first} '
          'level=${Log.minLevel.name} herald=$herald',
    );
    unawaited(_configureNative(herald));
  }

  static Future<void> _configureNative(String herald) async {
    try {
      final info = await _methods.invokeMapMethod<String, Object?>(
        LogMethods.configure,
        {LogArgs.level: Log.minLevel.name, LogArgs.herald: herald},
      );
      nativeLogFile = info?[LogArgs.file] as String?;
      Log.echoNative = _echoDefine || info?[LogArgs.echo] == true;
      if (Log.echoNative) {
        // Native lines that arrived before this answer did.
        for (final record in Log.buffer.records.where((r) => r.native)) {
          debugPrint(record.text);
        }
      }
      Log.i(
        'log',
        'native log file: $nativeLogFile'
            '${Log.echoNative ? ' (native lines are echoed here)' : ''}',
      );
    } on Object catch (error) {
      // No native logger (e.g. a platform this demo does not build for).
      Log.w('log', 'native logging unavailable', error);
    }
  }

  static void _installErrorHooks() {
    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      Log.e(
        'flutter',
        'framework error${details.context == null ? '' : ' ${details.context}'}',
        details.exception,
        details.stack,
      );
      previousFlutterError?.call(details);
    };

    final dispatcher = PlatformDispatcher.instance;
    final previousError = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      Log.e('dart', 'uncaught error', error, stack);
      // Keep the default reporting.
      return previousError?.call(error, stack) ?? false;
    };
  }
}

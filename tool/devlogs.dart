// Collects the app's logs from connected devices and merges them into one
// timeline. See docs/logging.md.
//
//   dart run tool/devlogs.dart devices
//   dart run tool/devlogs.dart pull [-o DIR] [-d ID]... [--label ID=NAME]...
//   dart run tool/devlogs.dart merge [--level D|I|W|E] [-o FILE] [LABEL=]FILE...
//   dart run tool/devlogs.dart logcat [-d SERIAL] [-o FILE]
//   dart run tool/devlogs.dart follow [-d ID] [-o FILE] [--every SECONDS]
//
// Works with Android phones and emulators (adb), iPhones and iPads
// (xcrun devicectl, Xcode 15+) and booted iOS simulators (xcrun simctl).
// Pulling from Android uses `run-as`, which needs a debuggable (debug) build.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ble_proximity_bridge/src/logging/log_line.dart';

const String androidPackage = 'com.example.ble_proximity_bridge';
const String iosBundleId = 'com.example.bleProximityBridge';

/// The app's own log files, oldest first (see BridgeLog.kt / .swift).
const List<String> logFiles = ['bridge.2.log', 'bridge.1.log', 'bridge.log'];

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      arguments.first == '-h' ||
      arguments.first == '--help') {
    stdout.writeln(_usage);
    return;
  }
  final command = arguments.first;
  final options = _Options.parse(arguments.skip(1).toList());
  try {
    switch (command) {
      case 'devices':
        await _listDevices();
      case 'pull':
        await _pull(options);
      case 'merge':
        await _mergeCommand(options);
      case 'logcat':
        await _logcat(options);
      case 'follow':
        await _follow(options);
      default:
        stderr.writeln('Unknown command "$command".\n\n$_usage');
        exitCode = 64;
    }
  } on _ToolError catch (error) {
    stderr.writeln('devlogs: ${error.message}');
    exitCode = 1;
  }
}

const String _usage = '''
Collects the BLE Proximity Bridge logs from connected devices.

  devices                        List connected devices and their labels.
  pull   [-o DIR] [-d ID]...     Copy the app's log files, Herald's log.txt and
         [--label ID=NAME]...    (iOS) the app's crash reports from every
                                 connected device, or just the -d ones, into
                                 DIR (default logs/<date-time>), then write
                                 DIR/merged.log.
  merge  [--level L] [-o FILE]   Merge log files into one timeline sorted by
         [LABEL=]FILE...         time. Accepts pulled files and raw captures
                                 (flutter run output, adb logcat). The label
                                 defaults to the file name.
  logcat [-d SERIAL] [-o FILE]   Stream an Android device's logcat for the
                                 app's process, re-attaching when it restarts.
  follow [-d ID] [-o FILE]       Print new lines of an iPhone's or simulator's
         [--every SECONDS]       log file as they arrive, by copying it every
                                 few seconds (default 5). For runs that are
                                 not under `flutter run`.''';

class _ToolError implements Exception {
  _ToolError(this.message);

  final String message;
}

class _Options {
  final List<String> devices = [];
  final Map<String, String> labels = {};
  final List<String> rest = [];
  String? out;
  LogLevel level = LogLevel.debug;
  int everySeconds = 5;

  static _Options parse(List<String> arguments) {
    final options = _Options();
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String value() {
        if (index + 1 >= arguments.length) {
          throw _ToolError('$argument needs a value');
        }
        return arguments[++index];
      }

      switch (argument) {
        case '-d' || '--device':
          options.devices.add(value());
        case '-o' || '--out':
          options.out = value();
        case '--label':
          final pair = value().split('=');
          if (pair.length != 2) throw _ToolError('--label takes ID=NAME');
          options.labels[pair[0]] = pair[1];
        case '--level':
          final raw = value();
          options.level =
              LogLevel.parse(raw) ?? (throw _ToolError('bad level "$raw"'));
        case '--every':
          options.everySeconds = int.tryParse(value()) ?? 5;
        default:
          options.rest.add(argument);
      }
    }
    return options;
  }
}

// ----- Devices ----------------------------------------------------------------

enum _Kind { android, iosDevice, iosSimulator }

class _Device {
  _Device(this.kind, this.id, this.name, this.label);

  final _Kind kind;
  final String id;
  final String name;
  String label;

  String get kindName => switch (kind) {
    _Kind.android => 'android',
    _Kind.iosDevice => 'ios',
    _Kind.iosSimulator => 'ios-simulator',
  };
}

Future<List<_Device>> _discover() async {
  final devices = <_Device>[];

  final adb = _adbPath();
  if (adb != null) {
    final result = await Process.run(adb, ['devices', '-l']);
    for (final line in LineSplitter.split('${result.stdout}')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[1] != 'device') continue;
      final model = parts
          .firstWhere(
            (part) => part.startsWith('model:'),
            orElse: () => 'model:android',
          )
          .substring(6);
      devices.add(_Device(_Kind.android, parts[0], model, _sanitize(model)));
    }
  }

  if (Platform.isMacOS) {
    final json = File('${Directory.systemTemp.path}/devlogs-devices-$pid.json');
    try {
      final result = await Process.run('xcrun', [
        'devicectl',
        'list',
        'devices',
        '--json-output',
        json.path,
        '--quiet',
      ]);
      if (result.exitCode == 0 && json.existsSync()) {
        final decoded =
            jsonDecode(json.readAsStringSync()) as Map<String, Object?>;
        final list =
            ((decoded['result'] as Map?)?['devices'] as List?) ?? const [];
        for (final raw in list.cast<Map<String, Object?>>()) {
          final hardware = (raw['hardwareProperties'] as Map?) ?? const {};
          final connection = (raw['connectionProperties'] as Map?) ?? const {};
          final properties = (raw['deviceProperties'] as Map?) ?? const {};
          if (hardware['reality'] != 'physical') continue;
          // Only devices devicectl can reach right now (cable or network).
          if (connection['transportType'] == null &&
              connection['tunnelState'] != 'connected') {
            continue;
          }
          final name =
              '${properties['name'] ?? hardware['productType'] ?? 'iOS'}';
          final udid = '${hardware['udid'] ?? raw['identifier']}';
          devices.add(_Device(_Kind.iosDevice, udid, name, _sanitize(name)));
        }
      }
    } finally {
      if (json.existsSync()) json.deleteSync();
    }

    final simulators = await Process.run('xcrun', [
      'simctl',
      'list',
      'devices',
      'booted',
      '-j',
    ]);
    if (simulators.exitCode == 0) {
      final decoded =
          jsonDecode('${simulators.stdout}') as Map<String, Object?>;
      final byRuntime = (decoded['devices'] as Map?) ?? const {};
      for (final list in byRuntime.values.cast<List>()) {
        for (final raw in list.cast<Map<String, Object?>>()) {
          if (raw['state'] != 'Booted') continue;
          final name = '${raw['name']}';
          devices.add(
            _Device(
              _Kind.iosSimulator,
              '${raw['udid']}',
              name,
              'sim-${_sanitize(name)}',
            ),
          );
        }
      }
    }
  }

  // Labels must be unique: they name files and tag merged lines.
  final seen = <String, int>{};
  for (final device in devices) {
    final count = seen.update(
      device.label,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    if (count > 1) device.label = '${device.label}-$count';
  }
  return devices;
}

Future<List<_Device>> _select(_Options options) async {
  final all = await _discover();
  for (final device in all) {
    final custom = options.labels[device.id];
    if (custom != null) device.label = custom;
  }
  if (options.devices.isEmpty) return all;
  final chosen = <_Device>[];
  for (final wanted in options.devices) {
    final match = all.where(
      (device) =>
          device.id == wanted ||
          device.label == wanted ||
          device.name == wanted,
    );
    if (match.isEmpty) {
      throw _ToolError('no connected device "$wanted" (see: devices)');
    }
    chosen.add(match.first);
  }
  return chosen;
}

Future<void> _listDevices() async {
  final devices = await _discover();
  if (devices.isEmpty) {
    stdout.writeln(
      'No devices found (adb, devicectl and booted simulators were checked).',
    );
    return;
  }
  for (final device in devices) {
    stdout.writeln(
      '${device.label.padRight(20)} ${device.kindName.padRight(14)} ${device.id}  (${device.name})',
    );
  }
}

String? _adbPath() {
  final candidates = [
    for (final variable in ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
      if (Platform.environment[variable] case final root?)
        '$root/platform-tools/adb',
    if (Platform.environment['HOME'] case final home?)
      '$home/Library/Android/sdk/platform-tools/adb',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  final which = Process.runSync('which', ['adb']);
  return which.exitCode == 0 ? '${which.stdout}'.trim() : null;
}

String _sanitize(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return cleaned.isEmpty ? 'device' : cleaned;
}

// ----- Pull -------------------------------------------------------------------

Future<void> _pull(_Options options) async {
  final devices = await _select(options);
  if (devices.isEmpty) throw _ToolError('no devices connected (see: devices)');
  final stamp = DateTime.now()
      .toIso8601String()
      .substring(0, 19)
      .replaceAll(':', '-');
  final dir = Directory(options.out ?? 'logs/$stamp')
    ..createSync(recursive: true);

  final merged = <(String, String)>[];
  for (final device in devices) {
    stdout.writeln(
      '${device.label}: pulling from ${device.kindName} ${device.id}',
    );
    final raw = Directory('${dir.path}/${device.label}-files')..createSync();
    final found = switch (device.kind) {
      _Kind.android => await _pullAndroid(device, raw),
      _Kind.iosDevice => await _pullIosDevice(device, raw),
      _Kind.iosSimulator => await _pullSimulator(device, raw),
    };
    // One file per device, its launches in order.
    final combined = StringBuffer();
    for (final name in logFiles) {
      final file = _findFile(raw, name);
      if (file != null) combined.write(file.readAsStringSync());
    }
    if (combined.isEmpty) {
      if (raw.listSync().isEmpty) raw.deleteSync();
      stdout.writeln(
        '  no app log found${found.isEmpty ? '' : ' (got: ${found.join(', ')})'}',
      );
      continue;
    }
    final out = File('${dir.path}/${device.label}.log')
      ..writeAsStringSync('$combined');
    merged.add((device.label, out.path));
    stdout.writeln(
      '  ${out.path} (${_lineCount(out)} lines); also: ${found.join(', ')}',
    );
  }

  if (merged.isNotEmpty) {
    final out = File('${dir.path}/merged.log');
    final sink = out.openWrite();
    mergeLogs(merged, LogLevel.debug, sink);
    await sink.close();
    stdout.writeln('Merged timeline: ${out.path}');
  }
}

/// [name] anywhere below [dir] (devicectl keeps the source folder's name).
File? _findFile(Directory dir, String name) {
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.uri.pathSegments.last == name) return entity;
  }
  return null;
}

Future<List<String>> _pullAndroid(_Device device, Directory into) async {
  final adb = _adbPath()!;
  final found = <String>[];
  String? lastError;
  // `shell -T` (no terminal) rather than `exec-out`: exec-out reports exit
  // code 0 and puts a command's errors on stdout, so a missing file came back
  // as a file holding "cat: ...: No such file or directory". Without a
  // terminal the bytes pass through unchanged, and with adb's shell protocol
  // (device feature `shell_v2`) the command's exit code comes back and its
  // errors stay on stderr. Without that protocol it is exec-out again.
  final features = await Process.run(adb, ['-s', device.id, 'features']);
  if (!'${features.stdout}'.split(RegExp(r'[,\s]+')).contains('shell_v2')) {
    stdout.writeln(
      '  warning: this device has no adb shell_v2, so a missing file can be '
      'saved as its error message; check the pulled files',
    );
  }
  Future<bool> save(List<String> command, String name) async {
    final result = await Process.run(adb, [
      '-s',
      device.id,
      'shell',
      '-T',
      ...command,
    ], stdoutEncoding: null);
    final bytes = result.stdout as List<int>;
    if (result.exitCode != 0 || bytes.isEmpty) {
      final error = '${result.stderr}'.trim();
      if (error.isNotEmpty) lastError = error.split('\n').last;
      return false;
    }
    File('${into.path}/$name').writeAsBytesSync(bytes);
    found.add(name);
    return true;
  }

  // A launch keeps the two before it, so on the first launches some of these
  // don't exist yet.
  for (final name in logFiles) {
    await save(['run-as', androidPackage, 'cat', 'files/logs/$name'], name);
  }
  if (found.isEmpty) {
    stdout.writeln(
      '  run-as found no logs${lastError == null ? '' : ' ($lastError)'}: '
      'is a debug build installed and has it run?',
    );
  }
  // Herald's own log (when HERALD_LOG is on): Herald's TextFile writes to
  // getExternalMediaDirs()[0]/Sensor/.
  await save([
    'cat',
    '/sdcard/Android/media/$androidPackage/Sensor/log.txt',
  ], 'herald-log.txt');
  // Crashes Android recorded, for any app.
  await save(['logcat', '-d', '-b', 'crash'], 'logcat-crash.txt');
  return found;
}

Future<List<String>> _pullIosDevice(_Device device, Directory into) async {
  final found = <String>[];
  Future<bool> copy(
    String domain,
    String? identifier,
    String source,
    String dest,
  ) async {
    final result = await Process.run('xcrun', [
      'devicectl',
      'device',
      'copy',
      'from',
      '--device',
      device.id,
      '--domain-type',
      domain,
      if (identifier != null) ...['--domain-identifier', identifier],
      '--source',
      source,
      '--destination',
      dest,
      '--quiet',
    ]);
    if (result.exitCode != 0) {
      final error = '${result.stderr}'.trim().split('\n').last;
      stdout.writeln('  could not copy $source: $error');
      return false;
    }
    return true;
  }

  if (await copy(
    'appDataContainer',
    iosBundleId,
    'Documents/logs',
    '${into.path}/logs',
  )) {
    found.addAll(logFiles.where((name) => _findFile(into, name) != null));
  }
  if (await copy(
    'appDataContainer',
    iosBundleId,
    'Documents/log.txt',
    '${into.path}/herald-log.txt',
  )) {
    found.add('herald-log.txt');
  }

  // Crash reports whose name starts with the app's executable.
  final listing = File(
    '${Directory.systemTemp.path}/devlogs-crashes-$pid.json',
  );
  try {
    final result = await Process.run('xcrun', [
      'devicectl',
      'device',
      'info',
      'files',
      '--device',
      device.id,
      '--domain-type',
      'systemCrashLogs',
      '--json-output',
      listing.path,
      '--quiet',
    ]);
    if (result.exitCode == 0 && listing.existsSync()) {
      final names = RegExp(r'"(Runner[^"/]*\.ips)"')
          .allMatches(listing.readAsStringSync())
          .map((match) => match.group(1)!)
          .toSet();
      for (final name in names) {
        if (await copy('systemCrashLogs', null, name, '${into.path}/$name')) {
          found.add(name);
        }
      }
    }
  } finally {
    if (listing.existsSync()) listing.deleteSync();
  }
  return found;
}

Future<List<String>> _pullSimulator(_Device device, Directory into) async {
  final container = await _simulatorContainer(device);
  final found = <String>[];
  for (final name in logFiles) {
    final file = File('$container/Documents/logs/$name');
    if (file.existsSync()) {
      file.copySync('${into.path}/$name');
      found.add(name);
    }
  }
  final herald = File('$container/Documents/log.txt');
  if (herald.existsSync()) {
    herald.copySync('${into.path}/herald-log.txt');
    found.add('herald-log.txt');
  }
  return found;
}

Future<String> _simulatorContainer(_Device device) async {
  final result = await Process.run('xcrun', [
    'simctl',
    'get_app_container',
    device.id,
    iosBundleId,
    'data',
  ]);
  if (result.exitCode != 0) {
    throw _ToolError('the app is not installed on simulator ${device.name}');
  }
  return '${result.stdout}'.trim();
}

int _lineCount(File file) => LineSplitter.split(file.readAsStringSync()).length;

// ----- Merge ------------------------------------------------------------------

Future<void> _mergeCommand(_Options options) async {
  if (options.rest.isEmpty) throw _ToolError('merge needs at least one file');
  final inputs = <(String, String)>[];
  for (final argument in options.rest) {
    final split = argument.indexOf('=');
    final label = split > 0
        ? argument.substring(0, split)
        : File(
            argument,
          ).uri.pathSegments.last.replaceAll(RegExp(r'\.(log|txt)$'), '');
    inputs.add((label, split > 0 ? argument.substring(split + 1) : argument));
  }
  final out = options.out;
  final IOSink sink = out == null ? stdout : File(out).openWrite();
  mergeLogs(inputs, options.level, sink);
  if (out != null) {
    await sink.close();
    stdout.writeln('Merged timeline: $out');
  }
}

class _Entry {
  _Entry(this.line, this.label, this.order);

  LogLine line;
  final String label;
  final int order;
  final List<String> continuation = [];

  /// Joins a later piece of a long logcat line ([_logcatPiece]) back onto
  /// the line it was cut from: the entry's own line, or its last stack
  /// trace line.
  void appendPiece(String piece) {
    if (continuation.isEmpty) {
      line = LogLine(
        time: line.time,
        level: line.level,
        origin: line.origin,
        component: line.component,
        message: line.message + piece,
      );
    } else {
      continuation.last += piece;
    }
  }
}

/// What starts the later pieces of a line the Android logger cut for
/// logcat (`BridgeLog.LOGCAT_PIECE_PREFIX`); a stack trace line has only the
/// indent.
const String _logcatPiece = '    \u2026';

/// What a capture tool puts in front of a line: logcat as `flutter run`
/// prints it (`I/BPB ( 123): `, `05-01 10:00:00.000 I/flutter ( 123): `),
/// logcat's threadtime format for the two tags our lines have, which is
/// what this tool's `logcat` command writes
/// (`05-01 10:00:00.000  123  456 W BPB     : `), and `flutter run` on iOS
/// (`flutter: `). Only needed for the continuation lines of a stack trace,
/// which carry nothing else to tell them by; [LogLine.find] finds a log
/// line behind any prefix.
final RegExp _capturePrefix = RegExp(
  r'^(?:.*?[VDIWEF]/[^(:]+\(\s*\d+\):\s'
  r'|\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\s+\d+\s+\d+ [VDIWEF] (?:BPB|flutter)\s*: '
  r'|flutter: )',
);

/// Merges log files into one timeline on [out]. [inputs] are (label, path)
/// pairs; several inputs can share a label (a pulled file and a capture of
/// the same device).
void mergeLogs(List<(String, String)> inputs, LogLevel level, StringSink out) {
  final entries = <_Entry>[];
  final selfIds = <String, String>{};
  // How many times each line of a device has been kept so far.
  final kept = <String, int>{};
  final summaries = <String>[];
  var order = 0;

  for (final (label, path) in inputs) {
    final file = File(path);
    if (!file.existsSync()) throw _ToolError('no such file: $path');
    var count = 0;
    final seenHere = <String, int>{};
    // The entry being read: its first line and the lines that follow it.
    _Entry? current;

    // Keeps [current] unless an earlier file of this device had it. The
    // same line from a capture and from the pulled file of one device:
    // keep one. A line that one file holds twice (the same event twice
    // within a millisecond) is two lines, so count: this file's nth copy
    // is new only if no earlier file had n of them. Done once the entry is
    // complete, so that a line logcat had in pieces compares whole.
    void finish() {
      final entry = current;
      current = null;
      if (entry == null) return;
      final key = '$label ${entry.line.format()}';
      final nth = seenHere.update(key, (n) => n + 1, ifAbsent: () => 1);
      if (nth <= (kept[key] ?? 0)) return;
      kept[key] = nth;
      for (final match in RegExp(
        r'self=([0-9A-F]{8,16})\b',
      ).allMatches(entry.line.message)) {
        selfIds[match.group(1)!] = label;
      }
      entries.add(entry);
      count++;
    }

    for (final raw in LineSplitter.split(file.readAsStringSync())) {
      final line = LogLine.find(raw);
      if (line == null) {
        // A stack trace line, or the next piece of a long line, belongs to
        // the entry above it.
        final entry = current;
        final body = raw.replaceFirst(_capturePrefix, '');
        if (entry == null) continue;
        if (body.startsWith(_logcatPiece)) {
          entry.appendPiece(body.substring(_logcatPiece.length));
        } else if (body.startsWith(RegExp(r'\s'))) {
          entry.continuation.add(body);
        }
        continue;
      }
      finish();
      current = _Entry(line, label, order++);
    }
    finish();
    summaries.add('$label: $count new lines from $path');
  }

  entries.sort((a, b) {
    final byTime = a.line.time.compareTo(b.line.time);
    return byTime != 0 ? byTime : a.order.compareTo(b.order);
  });
  final width = inputs
      .map((input) => input.$1)
      .fold<int>(0, (max, label) => label.length > max ? label.length : max);
  final idPattern = selfIds.isEmpty
      ? null
      : RegExp('\\b(${selfIds.keys.map(RegExp.escape).join('|')})\\b');
  // Tag another device's id with its label; a device's own id needs none.
  String annotate(String text, String label) => idPattern == null
      ? text
      : text.replaceAllMapped(idPattern, (match) {
          final owner = selfIds[match[1]];
          return owner == label ? match[0]! : '${match[1]}«$owner»';
        });

  out.writeln('# merged ${summaries.join('; ')}');
  if (selfIds.isNotEmpty) {
    out.writeln(
      '# peer ids: ${selfIds.entries.map((entry) => '${entry.key}=${entry.value}').join(' ')}',
    );
  }
  out.writeln(
    '# times are each device\'s own wall clock; across devices, order is only as good '
    'as their clocks agree',
  );
  final indent = ' ' * (12 + 1 + width + 1);
  for (final entry in entries) {
    if (entry.line.level.index < level.index) continue;
    final time = formatLogTime(entry.line.time).substring(11);
    out.writeln(
      '$time ${entry.label.padRight(width)} ${entry.line.level.letter} '
      '${entry.line.origin}.${entry.line.component} '
      '${annotate(entry.line.message, entry.label)}',
    );
    for (final more in entry.continuation) {
      out.writeln('$indent$more');
    }
  }
}

// ----- Live: Android logcat ------------------------------------------------------

Future<void> _logcat(_Options options) async {
  final adb = _adbPath() ?? (throw _ToolError('adb not found'));
  final devices = (await _select(
    options,
  )).where((device) => device.kind == _Kind.android).toList();
  if (devices.length != 1) {
    throw _ToolError(
      devices.isEmpty
          ? 'no Android device connected'
          : 'several Android devices: pick one with -d',
    );
  }
  final device = devices.single;
  final out = File(options.out ?? 'logs/live/${device.label}-logcat.log')
    ..parent.createSync(recursive: true);
  final sink = out.openWrite(mode: FileMode.append);
  stderr.writeln(
    'Streaming ${device.label} logcat for $androidPackage into ${out.path} (Ctrl-C stops)',
  );

  while (true) {
    final pidResult = await Process.run(adb, [
      '-s',
      device.id,
      'shell',
      'pidof',
      '-s',
      androidPackage,
    ]);
    final appPid = '${pidResult.stdout}'.trim();
    if (appPid.isEmpty) {
      stderr.writeln('(app not running; waiting)');
      await Future<void>.delayed(const Duration(seconds: 2));
      continue;
    }
    stderr.writeln('(attached to pid $appPid)');
    // Everything from the app's process: our lines (BPB, flutter), Herald's
    // (Sensor::...), and Android's Bluetooth stack messages for the app.
    final process = await Process.start(adb, [
      '-s',
      device.id,
      'logcat',
      '-v',
      'threadtime',
      '-T',
      '1',
      '--pid',
      appPid,
    ]);
    final watcher = Timer.periodic(const Duration(seconds: 3), (_) async {
      final again = await Process.run(adb, [
        '-s',
        device.id,
        'shell',
        'pidof',
        '-s',
        androidPackage,
      ]);
      if ('${again.stdout}'.trim() != appPid) process.kill();
    });
    await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          stdout.writeln(line);
          sink.writeln(line);
        });
    watcher.cancel();
    stderr.writeln('(app process $appPid ended)');
  }
}

// ----- Live: iOS file polling ------------------------------------------------------

Future<void> _follow(_Options options) async {
  final devices = (await _select(
    options,
  )).where((device) => device.kind != _Kind.android).toList();
  if (devices.length != 1) {
    throw _ToolError(
      devices.isEmpty
          ? 'no iOS device or simulator connected'
          : 'several iOS devices: pick one with -d',
    );
  }
  final device = devices.single;
  final out = File(options.out ?? 'logs/live/${device.label}-follow.log')
    ..parent.createSync(recursive: true);
  final sink = out.openWrite(mode: FileMode.append);
  final scratch = Directory.systemTemp.createTempSync('devlogs-follow');
  stderr.writeln(
    'Following ${device.label} (copied every ${options.everySeconds}s) into ${out.path} (Ctrl-C stops)',
  );

  var printed = 0;
  String? firstLine;
  while (true) {
    String? text;
    if (device.kind == _Kind.iosSimulator) {
      final file = File(
        '${await _simulatorContainer(device)}/Documents/logs/bridge.log',
      );
      if (file.existsSync()) text = file.readAsStringSync();
    } else {
      final dest = File('${scratch.path}/bridge.log');
      if (dest.existsSync()) dest.deleteSync();
      final result = await Process.run('xcrun', [
        'devicectl',
        'device',
        'copy',
        'from',
        '--device',
        device.id,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        iosBundleId,
        '--source',
        'Documents/logs/bridge.log',
        '--destination',
        dest.path,
        '--quiet',
      ]);
      if (result.exitCode == 0 && dest.existsSync()) {
        text = dest.readAsStringSync();
      }
    }
    if (text != null) {
      final lines = LineSplitter.split(text).toList();
      // A new launch or a rotation starts a new file.
      if (lines.isNotEmpty && lines.first != firstLine) {
        firstLine = lines.first;
        printed = 0;
      }
      for (final line in lines.skip(printed)) {
        stdout.writeln(line);
        sink.writeln(line);
      }
      printed = lines.length;
    }
    await Future<void>.delayed(Duration(seconds: options.everySeconds));
  }
}

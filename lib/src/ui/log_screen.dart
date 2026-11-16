import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../logging/log.dart';
import '../logging/logging_setup.dart';

/// The in-app log viewer: the last few thousand lines from Dart and native,
/// filterable, with a copy button. Meant for testing away from a computer,
/// e.g. walking two phones apart; the on-device log file
/// (tool/devlogs.dart pull) has the complete record.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

enum _Origin { all, dart, native }

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scroll = ScrollController();
  LogLevel _minLevel = LogLevel.debug;
  _Origin _origin = _Origin.all;
  String _query = '';
  bool _follow = true;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    Log.buffer.addListener(_onNewLines);
    _jumpToEndAfterFrame();
  }

  @override
  void dispose() {
    Log.buffer.removeListener(_onNewLines);
    _refresh?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // Lines can arrive dozens per second; rebuild at most 5 times a second.
  void _onNewLines() {
    _refresh ??= Timer(const Duration(milliseconds: 200), () {
      _refresh = null;
      if (!mounted) return;
      setState(() {});
      if (_follow) _jumpToEndAfterFrame();
    });
  }

  void _jumpToEndAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  List<LogRecord> _visible() {
    final query = _query.toLowerCase();
    return Log.buffer.records.where((record) {
      if (record.level.index < _minLevel.index) return false;
      if (_origin == _Origin.dart && record.native) return false;
      if (_origin == _Origin.native && !record.native) return false;
      return query.isEmpty || record.text.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _copy(List<LogRecord> records) async {
    await Clipboard.setData(
      ClipboardData(text: records.map((record) => record.text).join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied ${records.length} lines')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = _visible();
    final file = LoggingSetup.nativeLogFile;

    return Scaffold(
      appBar: AppBar(
        title: Text('Logs (${records.length})'),
        actions: [
          IconButton(
            tooltip: _follow ? 'Stop following' : 'Follow new lines',
            icon: Icon(_follow ? Icons.pause : Icons.vertical_align_bottom),
            onPressed: () {
              setState(() => _follow = !_follow);
              if (_follow) _jumpToEndAfterFrame();
            },
          ),
          IconButton(
            tooltip: 'Copy shown lines',
            icon: const Icon(Icons.copy_all),
            onPressed: () => _copy(records),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<LogLevel>(
                  showSelectedIcon: false,
                  segments: [
                    for (final level in LogLevel.values)
                      ButtonSegment(value: level, label: Text(level.letter)),
                  ],
                  selected: {_minLevel},
                  onSelectionChanged: (selection) =>
                      setState(() => _minLevel = selection.first),
                ),
                SegmentedButton<_Origin>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Origin.all, label: Text('All')),
                    ButtonSegment(value: _Origin.dart, label: Text('Dart')),
                    ButtonSegment(value: _Origin.native, label: Text('Native')),
                  ],
                  selected: {_origin},
                  onSelectionChanged: (selection) =>
                      setState(() => _origin = selection.first),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter (peer id, component, text)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (file != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'File: $file',
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Divider(height: 8),
          Expanded(
            child: NotificationListener<UserScrollNotification>(
              // Scrolling back to read stops following.
              onNotification: (notification) {
                if (_follow &&
                    notification.metrics.extentAfter > 40 &&
                    notification.direction != ScrollDirection.idle) {
                  setState(() => _follow = false);
                }
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                itemCount: records.length,
                itemBuilder: (context, index) =>
                    _LogLineTile(record: records[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogLineTile extends StatelessWidget {
  const _LogLineTile({required this.record});

  final LogRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (record.level) {
      LogLevel.error => scheme.error,
      LogLevel.warn => Colors.orange.shade700,
      LogLevel.info => scheme.onSurface,
      LogLevel.debug => scheme.outline,
    };
    // Drop the date; the time is enough on screen (copies keep it all).
    final text = record.text.length > 11
        ? record.text.substring(11)
        : record.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Courier'],
          fontSize: 11,
          height: 1.25,
          color: color,
          fontWeight: record.native ? FontWeight.normal : FontWeight.w500,
        ),
      ),
    );
  }
}

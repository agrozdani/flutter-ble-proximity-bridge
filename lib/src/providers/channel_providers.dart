import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/proximity_event_channel.dart';
import '../bridge/proximity_method_channel.dart';

/// The channel wrappers as providers, so tests can override them with
/// mocked channels.
final methodChannelProvider = Provider<ProximityMethodChannel>(
  (ref) => ProximityMethodChannel(),
);

final eventChannelProvider = Provider<ProximityEventChannel>(
  (ref) => ProximityEventChannel(),
);

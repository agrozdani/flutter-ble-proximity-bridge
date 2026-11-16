import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logging/log.dart';

/// Asks for whatever BLE permissions this platform needs. Returns true when
/// scanning and advertising are allowed. Mock mode skips this entirely.
Future<bool> ensureProximityPermissions() async {
  if (!Platform.isAndroid) {
    // iOS shows its own prompt when the BLE stack first starts up, so
    // there's nothing to request from Dart. (Native logs the Bluetooth
    // authorization at every start: native.ble.)
    return true;
  }

  final sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  if (sdkInt >= 31) {
    // Android 12+ has proper Bluetooth permissions. BLUETOOTH_SCAN is
    // declared neverForLocation in the manifest, so no location needed.
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    final granted = statuses.values.every((status) => status.isGranted);
    _log(sdkInt, statuses, granted);
    return granted;
  }

  // Before Android 12, BLE scanning is gated behind location instead.
  final status = await Permission.locationWhenInUse.request();
  _log(sdkInt, {Permission.locationWhenInUse: status}, status.isGranted);
  return status.isGranted;
}

void _log(
  int sdkInt,
  Map<Permission, PermissionStatus> statuses,
  bool granted,
) {
  final listed = statuses.entries
      .map(
        (entry) =>
            '${entry.key.toString().split('.').last}=${entry.value.name}',
      )
      .join(' ');
  final message =
      'android sdk=$sdkInt $listed → ${granted ? 'granted' : 'DENIED'}';
  if (granted) {
    Log.i('permissions', message);
  } else {
    Log.w('permissions', message);
  }
}

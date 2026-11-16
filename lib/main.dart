import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/logging/logging_setup.dart';
import 'src/ui/home_screen.dart';

void main() {
  // The logging channels need the binding before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  LoggingSetup.init();
  runApp(const ProviderScope(child: ProximityBridgeApp()));
}

class ProximityBridgeApp extends StatelessWidget {
  const ProximityBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BLE Proximity Bridge',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

import 'package:flutter/material.dart';

import 'screens/map_screen.dart';
import 'services/drive_timer.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final timer = await DriveTimer.load();
  runApp(LkwNavApp(settings: settings, timer: timer));
}

class LkwNavApp extends StatelessWidget {
  final AppSettings settings;
  final DriveTimer timer;
  const LkwNavApp({super.key, required this.settings, required this.timer});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFE65100));
    return MaterialApp(
      title: 'LKW Navi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFE65100), brightness: Brightness.dark),
          useMaterial3: true),
      home: MapScreen(settings: settings, timer: timer),
    );
  }
}

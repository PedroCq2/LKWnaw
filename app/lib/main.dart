import 'package:flutter/material.dart';

import 'screens/map_screen.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(LkwNavApp(settings: settings));
}

class LkwNavApp extends StatelessWidget {
  final AppSettings settings;
  const LkwNavApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFE65100));
    return MaterialApp(
      title: 'LKWnav',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFE65100), brightness: Brightness.dark),
          useMaterial3: true),
      home: MapScreen(settings: settings),
    );
  }
}

import 'package:flutter/material.dart';

import 'screens/map_screen.dart';
import 'services/settings.dart';
import 'theme.dart';

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
    return MaterialApp(
      title: 'LKWnav',
      debugShowCheckedModeBanner: false,
      theme: Lkw.theme(),
      home: MapScreen(settings: settings),
    );
  }
}

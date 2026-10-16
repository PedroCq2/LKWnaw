import 'package:shared_preferences/shared_preferences.dart';

import '../models/truck_profile.dart';

const defaultValhallaUrl = 'https://valhalla1.openstreetmap.de';

class AppSettings {
  TruckProfile profile;
  String valhallaUrl;
  bool voice;

  AppSettings({required this.profile, required this.valhallaUrl, required this.voice});

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    TruckProfile profile;
    try {
      final s = p.getString('profile');
      profile = s == null ? TruckProfile() : TruckProfile.decode(s);
    } catch (_) {
      profile = TruckProfile();
    }
    return AppSettings(
      profile: profile,
      valhallaUrl: p.getString('valhallaUrl') ?? defaultValhallaUrl,
      voice: p.getBool('voice') ?? true,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('profile', profile.encode());
    await p.setString('valhallaUrl', valhallaUrl);
    await p.setBool('voice', voice);
  }
}

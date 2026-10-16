import 'package:shared_preferences/shared_preferences.dart';

import '../models/truck_profile.dart';

const defaultValhallaUrl = 'https://valhalla1.openstreetmap.de';

class AppSettings {
  TruckProfile profile;
  String valhallaUrl;
  bool voice;
  bool simulate; // demo: jízda po trase bez GPS
  int mapStyle; // 0 = auto, 1 = den, 2 = noc
  bool view3d;
  bool delivery; // zásobování

  AppSettings({
    required this.profile,
    required this.valhallaUrl,
    required this.voice,
    this.simulate = false,
    this.mapStyle = 0,
    this.view3d = true,
    this.delivery = false,
  });

  bool get night {
    if (mapStyle == 1) return false;
    if (mapStyle == 2) return true;
    final h = DateTime.now().hour;
    return h >= 20 || h < 6;
  }

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
      simulate: p.getBool('simulate') ?? false,
      mapStyle: p.getInt('mapStyle') ?? 0,
      view3d: p.getBool('view3d') ?? true,
      delivery: p.getBool('delivery') ?? false,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('profile', profile.encode());
    await p.setString('valhallaUrl', valhallaUrl);
    await p.setBool('voice', voice);
    await p.setBool('simulate', simulate);
    await p.setInt('mapStyle', mapStyle);
    await p.setBool('view3d', view3d);
    await p.setBool('delivery', delivery);
  }
}

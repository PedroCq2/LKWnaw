import 'package:shared_preferences/shared_preferences.dart';

import '../models/truck_profile.dart';
import 'map_style.dart';
import 'sun.dart';

const defaultValhallaUrl = 'https://valhalla1.openstreetmap.de';

/// Hlas: vše (pokyny i upozornění) / jen upozornění (rychlost, radar, omezení) / nic.
enum VoiceMode { all, alerts, off }

extension VoiceModeInfo on VoiceMode {
  String get label => switch (this) {
    VoiceMode.all => 'Vše',
    VoiceMode.alerts => 'Jen upozornění',
    VoiceMode.off => 'Nic',
  };

  /// Další režim po klepnutí na tlačítko hlasu.
  VoiceMode get next => VoiceMode.values[(index + 1) % VoiceMode.values.length];
}

class AppSettings {
  TruckProfile profile;
  String valhallaUrl;
  VoiceMode voiceMode;
  bool voiceVerbose; // podrobný odpočet (1 km, 500 m, 200 m) místo jedné hlášky předem
  bool shakeReport; // zatřesením telefonu nahlásit chybu / nápad
  bool simulate; // demo: jízda po trase bez GPS
  int mapStyle; // 0 = auto, 1 = den, 2 = noc
  bool view3d;
  MapLayer mapLayer; // mapa / letecká / hybridní
  bool delivery; // zásobování
  String? voiceName; // vybraný český hlas (null = nejlepší dostupný)
  double speechRate; // 0,3–0,8
  bool routeOnDevice; // počítat trasy v telefonu (stažený balík ČR)
  int speedTolerance; // varovat při překročení limitu o víc než X km/h
  bool speedSound; // hlasové varování „Pozor, rychlost“
  bool bigText; // větší texty pokynů

  AppSettings({
    required this.profile,
    required this.valhallaUrl,
    this.voiceMode = VoiceMode.all,
    this.voiceVerbose = false,
    this.shakeReport = true,
    this.simulate = false,
    this.mapStyle = 0,
    this.view3d = true,
    this.mapLayer = MapLayer.map,
    this.delivery = false,
    this.voiceName,
    this.speechRate = 0.5,
    this.routeOnDevice = true,
    this.speedTolerance = 10,
    this.speedSound = true,
    this.bigText = false,
  });

  /// Noční vzhled: ručně, nebo automaticky podle západu/východu Slunce v místě.
  bool nightAt(double? lat, double? lon) {
    if (mapStyle == 1) return false;
    if (mapStyle == 2) return true;
    if (lat == null || lon == null) {
      final h = DateTime.now().hour;
      return h >= 19 || h < 7;
    }
    return isNight(lat, lon, DateTime.now());
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
      // Dřív jen zapnuto / vypnuto.
      voiceMode: VoiceMode.values[(p.getInt('voiceMode') ?? ((p.getBool('voice') ?? true) ? 0 : 2)).clamp(0, 2)],
      voiceVerbose: p.getBool('voiceVerbose') ?? false,
      shakeReport: p.getBool('shakeReport') ?? true,
      simulate: p.getBool('simulate') ?? false,
      mapStyle: p.getInt('mapStyle') ?? 0,
      view3d: p.getBool('view3d') ?? true,
      mapLayer: MapLayer.values[(p.getInt('mapLayer') ?? 0).clamp(0, MapLayer.values.length - 1)],
      delivery: p.getBool('delivery') ?? false,
      voiceName: p.getString('voiceName'),
      speechRate: p.getDouble('speechRate') ?? 0.5,
      routeOnDevice: p.getBool('routeOnDevice') ?? true,
      speedTolerance: p.getInt('speedTol2') ?? 10,
      speedSound: p.getBool('speedSound') ?? true,
      bigText: p.getBool('bigText') ?? false,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('profile', profile.encode());
    await p.setString('valhallaUrl', valhallaUrl);
    await p.setInt('voiceMode', voiceMode.index);
    await p.setBool('voiceVerbose', voiceVerbose);
    await p.setBool('shakeReport', shakeReport);
    await p.setBool('simulate', simulate);
    await p.setInt('mapStyle', mapStyle);
    await p.setBool('view3d', view3d);
    await p.setInt('mapLayer', mapLayer.index);
    await p.setBool('delivery', delivery);
    if (voiceName == null) {
      await p.remove('voiceName');
    } else {
      await p.setString('voiceName', voiceName!);
    }
    await p.setDouble('speechRate', speechRate);
    await p.setBool('routeOnDevice', routeOnDevice);
    await p.setInt('speedTol2', speedTolerance);
    await p.setBool('speedSound', speedSound);
    await p.setBool('bigText', bigText);
  }
}

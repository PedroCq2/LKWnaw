import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Vlastní vzhled mapy LKWnav nad vektorovými dlaždicemi OpenFreeMap.
///
/// Stáhne styl „liberty“ a přebarví ho paletou LKWnav: den = „Asfalt“
/// (teplá šedá, ocelová voda, ocelově šedé dálnice), noc = „Kabina“ (grafit).
/// Jedinou výraznou barvou na mapě je jantarová trasa.
/// Skryje ikony obchodů a čísla silnic, ať mapa neruší.
const baseStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

class _Palette {
  final String land, residential, green, water, building, building3d, rail;
  final String motorway, motorwayCase, trunk, trunkCase, secondary, secondaryCase, minor, minorCase;
  final String path, label, labelHalo, boundary;
  const _Palette({
    required this.land,
    required this.residential,
    required this.green,
    required this.water,
    required this.building,
    required this.building3d,
    required this.rail,
    required this.motorway,
    required this.motorwayCase,
    required this.trunk,
    required this.trunkCase,
    required this.secondary,
    required this.secondaryCase,
    required this.minor,
    required this.minorCase,
    required this.path,
    required this.label,
    required this.labelHalo,
    required this.boundary,
  });
}

const _day = _Palette(
  land: '#E6E3DC',
  residential: '#DEDAD2',
  green: '#CBD3BC',
  water: '#9DB4C6',
  building: '#D3CEC5',
  building3d: '#D9D4CB',
  rail: '#A9A59C',
  motorway: '#C3CAD3',
  motorwayCase: '#7F8995',
  trunk: '#DCE0E5',
  trunkCase: '#98A0AA',
  secondary: '#FFFFFF',
  secondaryCase: '#B9B3A8',
  minor: '#FBFAF7',
  minorCase: '#C9C3B8',
  path: '#C2BCB1',
  label: '#2A2E35',
  labelHalo: '#F4F2EE',
  boundary: '#8B7D9C',
);

const _night = _Palette(
  land: '#1A1E24',
  residential: '#1F242B',
  green: '#1C2620',
  water: '#0F2333',
  building: '#262B33',
  building3d: '#2D333C',
  rail: '#3B414A',
  motorway: '#56606E',
  motorwayCase: '#2B3038',
  trunk: '#48505C',
  trunkCase: '#262A31',
  secondary: '#4B535F',
  secondaryCase: '#2A2F37',
  minor: '#363C46',
  minorCase: '#23272E',
  path: '#2E343D',
  label: '#C8CDD5',
  labelHalo: '#11151A',
  boundary: '#6E6480',
);

final Map<bool, String> _cache = {};
String? _baseJson;

/// JSON stylu pro `MapLibreMap.styleString`; při chybě vrátí URL původního stylu.
Future<String> lkwStyle({required bool night}) async {
  final cached = _cache[night];
  if (cached != null) return cached;
  try {
    // Styl si pamatujeme – offline (bez signálu) zůstane vzhled LKWnav.
    final prefs = await SharedPreferences.getInstance();
    if (_baseJson == null) {
      try {
        final res = await http.get(Uri.parse(baseStyleUrl)).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          _baseJson = utf8.decode(res.bodyBytes);
          await prefs.setString('baseStyle', _baseJson!);
        }
      } catch (_) {}
      _baseJson ??= prefs.getString('baseStyle');
    }
    if (_baseJson == null) return baseStyleUrl;
    final style = jsonDecode(_baseJson!) as Map<String, dynamic>;
    applyPalette(style, night ? _night : _day);
    return _cache[night] = jsonEncode(style);
  } catch (_) {
    return baseStyleUrl;
  }
}

void applyPalette(Map<String, dynamic> style, Object palette) {
  final p = palette as _Palette;
  final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
  const hidden = {
    'poi_r20', 'poi_r7', 'poi_transit', // obchody, restaurace, zastávky
    'highway-shield-non-us', 'highway-shield-us-interstate', 'road_shield_us', // čísla silnic
    'natural_earth', 'park_outline', 'road_one_way_arrow', 'road_one_way_arrow_opposite',
  };
  for (final l in layers) {
    final id = l['id'] as String;
    final paint = (l['paint'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    l['paint'] = paint;
    if (hidden.contains(id)) {
      l['layout'] = {...?(l['layout'] as Map?)?.cast<String, dynamic>(), 'visibility': 'none'};
      continue;
    }
    final type = l['type'];
    if (type == 'background') {
      paint['background-color'] = p.land;
    } else if (type == 'symbol') {
      if (paint.containsKey('text-color')) {
        paint['text-color'] = id.startsWith('water') ? p.water : p.label;
        paint['text-halo-color'] = p.labelHalo;
      }
    } else if (type == 'fill-extrusion') {
      paint['fill-extrusion-color'] = p.building3d;
      paint['fill-extrusion-opacity'] = 0.85;
    } else if (type == 'fill') {
      if (id == 'water' || id.startsWith('waterway')) {
        paint['fill-color'] = p.water;
      } else if (id == 'building') {
        paint['fill-color'] = p.building;
        paint['fill-outline-color'] = p.building3d;
      } else if (id == 'park' || id.startsWith('landcover_wood') || id.startsWith('landcover_grass')) {
        paint['fill-color'] = p.green;
      } else if (id.startsWith('landuse')) {
        paint['fill-color'] = p.residential;
      }
    } else if (type == 'line') {
      final casing = id.endsWith('_casing');
      final c = _roadColor(id, p, casing);
      if (c != null) {
        paint['line-color'] = c;
      } else if (id.startsWith('waterway')) {
        paint['line-color'] = p.water;
      } else if (id.startsWith('boundary')) {
        paint['line-color'] = p.boundary;
      }
    }
  }
}

String? _roadColor(String id, _Palette p, bool casing) {
  if (!(id.startsWith('road_') || id.startsWith('bridge_') || id.startsWith('tunnel_'))) return null;
  if (id.contains('rail')) return p.rail;
  if (id.contains('path_pedestrian')) return p.path;
  if (id.contains('motorway')) return casing ? p.motorwayCase : p.motorway;
  if (id.contains('trunk_primary')) return casing ? p.trunkCase : p.trunk;
  if (id.contains('secondary_tertiary')) return casing ? p.secondaryCase : p.secondary;
  if (id.contains('minor') || id.contains('street') || id.contains('link') || id.contains('service')) {
    return casing ? p.minorCase : p.minor;
  }
  return null;
}

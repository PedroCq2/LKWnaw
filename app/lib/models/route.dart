import 'package:latlong2/latlong.dart';

/// Jízdní pruhy před manévrem (z OSM `turn:lanes`); [active] = pruhy pro naši trasu.
class LaneInfo {
  final List<Set<String>> turns;
  final List<bool> active;
  final String? want; // kam jedeme: left / right / through (šipka u sdíleného pruhu)
  LaneInfo(this.turns, this.active, {this.want});
}

/// Úsek trasy s atributy z Valhally (trace_attributes).
class EdgeAttr {
  final int begin, end; // indexy do shape
  final int? wayId;
  final String? roadClass, use;
  final List<String> names;
  final int? beginHeading, endHeading;
  final List<Map<String, dynamic>> intersecting; // odbočky v koncovém uzlu
  EdgeAttr({
    required this.begin,
    required this.end,
    this.wayId,
    this.roadClass,
    this.use,
    this.names = const [],
    this.beginHeading,
    this.endHeading,
    this.intersecting = const [],
  });
}

/// Co je na dálniční odpočívce / čerpací stanici k dispozici.
enum ServiceAmenity { parking, fuel, food, wc, shower, adblue, hotel }

/// Služba u dálnice na straně jízdy (odpočívka, čerpací stanice, parkoviště pro kamiony).
class HighwayService {
  final String name;
  final String type; // „Odpočívka s čerpací stanicí“, …
  final LatLng point;
  final double atM; // poloha po trase (m od začátku)
  final double offM; // vzdušně od trasy
  final Set<ServiceAmenity> amenities;
  final List<String> brands; // OMV, Shell, McDonald's, …
  final int? hgvSpaces;
  final List<String> notes; // nonstop, zdarma, hlídané, …
  final String? road; // D1
  HighwayService({
    required this.name,
    required this.type,
    required this.point,
    required this.atM,
    required this.offM,
    required this.amenities,
    this.brands = const [],
    this.hgvSpaces,
    this.notes = const [],
    this.road,
  });
}

class Maneuver {
  final int type;
  final String instruction;
  String? alertInstruction;
  String? preInstruction;
  final String? postInstruction;
  final List<String> streetNames;
  final int beginShapeIndex;
  final int endShapeIndex;
  final double lengthKm;

  /// Dopravní značení výjezdu (Valhalla `sign`): číslo exitu, silnice, směr.
  final String? exitNumber;
  final List<String> exitBranch;
  List<String> exitToward;

  /// Doplněno z OSM: jízdní pruhy a směr („Ostrava“).
  LaneInfo? lanes;

  /// Vložený pokyn „Pokračujte rovně“ na rozdvojení, které Valhalla nehlásí.
  final bool synthetic;

  /// Kruhový objezd: kolikátým výjezdem vyjet.
  final int? roundaboutExit;

  /// Pruhy/směry z OSM už doplněné.
  bool enriched = false;

  Maneuver({
    required this.type,
    required this.instruction,
    this.alertInstruction,
    this.preInstruction,
    this.postInstruction,
    required this.streetNames,
    required this.beginShapeIndex,
    required this.endShapeIndex,
    required this.lengthKm,
    this.exitNumber,
    this.exitBranch = const [],
    this.exitToward = const [],
    this.synthetic = false,
    this.roundaboutExit,
  });

  static List<String> _signTexts(Map? sign, String key) =>
      ((sign?[key] as List?) ?? const []).map((e) => '${(e as Map)['text']}').toList();

  /// Stejný pokyn s indexy posunutými o [offset] (spojení dvou tras za sebou).
  Maneuver shifted(int offset) => Maneuver(
    type: type,
    instruction: instruction,
    alertInstruction: alertInstruction,
    preInstruction: preInstruction,
    postInstruction: postInstruction,
    streetNames: streetNames,
    beginShapeIndex: beginShapeIndex + offset,
    endShapeIndex: endShapeIndex + offset,
    lengthKm: lengthKm,
    exitNumber: exitNumber,
    exitBranch: exitBranch,
    exitToward: exitToward,
    synthetic: synthetic,
    roundaboutExit: roundaboutExit,
  );

  factory Maneuver.fromJson(Map<String, dynamic> j) => Maneuver(
    type: (j['type'] as num).toInt(),
    instruction: j['instruction'] as String? ?? '',
    alertInstruction: j['verbal_transition_alert_instruction'] as String?,
    preInstruction: j['verbal_pre_transition_instruction'] as String?,
    postInstruction: j['verbal_post_transition_instruction'] as String?,
    streetNames: ((j['street_names'] as List?) ?? const []).map((e) => e.toString()).toList(),
    beginShapeIndex: (j['begin_shape_index'] as num).toInt(),
    endShapeIndex: (j['end_shape_index'] as num).toInt(),
    lengthKm: (j['length'] as num?)?.toDouble() ?? 0,
    exitNumber: _signTexts(j['sign'] as Map?, 'exit_number_elements').firstOrNull,
    exitBranch: _signTexts(j['sign'] as Map?, 'exit_branch_elements'),
    exitToward: _signTexts(j['sign'] as Map?, 'exit_toward_elements'),
    roundaboutExit: (j['roundabout_exit_count'] as num?)?.toInt(),
  );
}

class TruckRoute {
  final List<LatLng> shape;
  final List<Maneuver> maneuvers;
  final double lengthKm;
  final double timeSec;
  final bool hasToll;
  final bool hasHighway;

  /// Původní polyline6 (jen u jednoetapové trasy) pro dotaz na atributy silnic.
  final String? encodedShape;

  /// Polyline každé etapy (mezi zastávkami) a její posun v [shape].
  final List<(String, int)> legShapes;

  /// Rychlostní limit (km/h) a název silnice pro každý segment `shape[i]→shape[i+1]`.
  List<int?> speedLimits = const [];

  /// Kumulativní jízdní doba (s) po bodech `shape` při rychlosti kamionu (omezovač 80–90 km/h).
  /// Valhalla počítá na dálnici s rychlostí aut, takže její čas je pro kamion moc optimistický.
  List<double>? truckTime;
  double truckOverheadSec = 0; // křižovatky, semafory… (rozpočítané podle vzdálenosti)

  /// Zbývající doba jízdy od segmentu [segment] (zbývá [remainingM] m).
  double remainingSec(double remainingM, int segment) {
    final total = lengthKm * 1000;
    final ratio = total > 0 ? (remainingM / total).clamp(0.0, 1.0) : 0.0;
    final t = truckTime;
    if (t == null || t.isEmpty) return timeSec * ratio;
    final i = segment.clamp(0, t.length - 1);
    return (t.last - t[i]).clamp(0.0, double.infinity) + truckOverheadSec * ratio;
  }

  /// Celková doba pro kamion (po načtení atributů silnic), jinak odhad Valhally.
  double get truckTimeSec => remainingSec(lengthKm * 1000, 0);
  List<String?> roadNames = const [];
  List<EdgeAttr> edges = const [];
  List<HighwayService> services = const []; // služby u dálnice podél trasy

  /// Zásobování: kolik km trasy jede s výjimkou z hmotnostních zákazů (jen dojezd k cíli / výjezd od startu).
  double deliveryKm = 0;

  /// Cíl je pro vozidlo nedostupný (výška/šířka/délka na příjezdu): trasa končí co nejblíž,
  /// tolik metrů (vzdušně) od cíle. 0 = trasa vede až do cíle.
  double unreachableM = 0;

  /// Začátky sjezdů, které vedou na jinou dálnici (OSM `destination:ref` = D…) –
  /// jen tam je dálniční křižovatka a hlásí se „Pokračujte rovně“.
  List<(LatLng, String)> interchangeLinks = const [];

  bool osmRampsChecked = false;

  /// Kamionová omezení a radary podél trasy (doplňuje se na pozadí).
  List<RouteWarning> warnings = const [];

  /// Proč trasa jede oklikou (kratší cesta vede přes omezení hmotnosti), nebo null.
  RouteDetour? detour;

  /// Exity dálnic na trase: (vzdálenost po trase m, kilometr dálnice, silnice).
  /// V ČR je číslo exitu = kilometr dálnice → staničení se dopočítá mezi nimi.
  List<(double, double, String?)> kmPoints = const [];

  /// Staničení dálnice (km) v místě [traveled] na silnici [road], nebo null.
  double? kilometerAt(double traveled, String road) {
    final pts = kmPoints.where((p) => p.$3 == road).toList();
    if (pts.length < 2) return null;
    var i = pts.lastIndexWhere((p) => p.$1 <= traveled);
    if (i < 0) i = 0;
    if (i >= pts.length - 1) i = pts.length - 2;
    final a = pts[i], b = pts[i + 1];
    final span = b.$1 - a.$1;
    if (span < 200) return null;
    // Exity musí sedět na délku úseku (jinak chybná data / přejezd na jinou dálnici).
    final dk = b.$2 - a.$2;
    if ((dk.abs() * 1000 - span).abs() > span * 0.25 + 1500) return null;
    final km = a.$2 + dk * (traveled - a.$1) / span;
    // Mimo interval (před 1. / za posledním exitem) extrapoluj nejvýš 15 km.
    if (traveled < a.$1 - 15000 || traveled > b.$1 + 15000) return null;
    return km < 0 ? null : km;
  }

  /// Kumulativní vzdálenost (m) od začátku trasy pro každý bod `shape`.
  late final List<double> cumulative = _buildCumulative();

  TruckRoute({
    required this.shape,
    required this.maneuvers,
    required this.lengthKm,
    required this.timeSec,
    required this.hasToll,
    required this.hasHighway,
    this.encodedShape,
    this.legShapes = const [],
  });

  /// Hlavní silnice, po kterých trasa vede (D1, D35, E 50…).
  List<String> get via {
    final out = <String>[];
    final re = RegExp(r'^(D|R|I|II|III|E|A|B|S|M)\s?\d+[a-z]?$');
    for (final m in maneuvers) {
      for (final n in m.streetNames) {
        final t = n.trim();
        if (re.hasMatch(t) && !out.contains(t)) out.add(t);
      }
    }
    // Evropská čísla (E…) jen když chybí národní.
    final national = out.where((e) => !e.startsWith('E')).toList();
    return (national.isNotEmpty ? national : out).take(3).toList();
  }

  /// Spojí trasy za sebou (konec jedné = začátek další) do jedné – bez „Dorazili jste“ / „Vyjeďte“
  /// na spojích.
  static TruckRoute concat(List<TruckRoute> parts) {
    if (parts.length == 1) return parts.first;
    final shape = <LatLng>[];
    final maneuvers = <Maneuver>[];
    final legShapes = <(String, int)>[];
    var length = 0.0, time = 0.0, deliveryKm = 0.0;
    var toll = false, highway = false;
    for (final (i, p) in parts.indexed) {
      // Poslední bod předchozí části = první bod další, nezdvojovat.
      final offset = shape.isEmpty ? 0 : shape.length - 1;
      shape.addAll(shape.isEmpty ? p.shape : p.shape.skip(1));
      final legs = p.legShapes.isNotEmpty ? p.legShapes : [if (p.encodedShape != null) (p.encodedShape!, 0)];
      for (final (enc, o) in legs) {
        legShapes.add((enc, o + offset));
      }
      var ms = p.maneuvers;
      if (i < parts.length - 1 && ms.length > 1) ms = ms.sublist(0, ms.length - 1);
      if (i > 0 && ms.length > 1) ms = ms.sublist(1);
      maneuvers.addAll(ms.map((m) => m.shifted(offset)));
      length += p.lengthKm;
      time += p.timeSec;
      deliveryKm += p.deliveryKm;
      toll |= p.hasToll;
      highway |= p.hasHighway;
    }
    return TruckRoute(
        shape: shape,
        maneuvers: maneuvers,
        lengthKm: length,
        timeSec: time,
        hasToll: toll,
        hasHighway: highway,
        legShapes: legShapes,
      )
      ..deliveryKm = deliveryKm
      ..unreachableM = parts.last.unreachableM;
  }

  int? speedLimitAt(int seg) => seg >= 0 && seg < speedLimits.length ? speedLimits[seg] : null;
  String? roadNameAt(int seg) => seg >= 0 && seg < roadNames.length ? roadNames[seg] : null;

  List<double> _buildCumulative() {
    const dist = Distance();
    final out = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      out[i] = out[i - 1] + dist(shape[i - 1], shape[i]);
    }
    return out;
  }
}

enum WarningType { height, weight, width, length, axleLoad, speedCamera, noOvertakingHgv }

class RouteWarning {
  final WarningType type;
  final double? value; // m nebo t
  final double atMeters; // vzdálenost od začátku trasy
  final LatLng point;
  final bool violates; // vozidlo limit překračuje
  final bool tight; // vozidlo projede, ale s malou rezervou (výška/šířka < 30 cm, hmotnost < 1 t)

  /// Stojí za zobrazení řidiči: radar, zákaz předjíždění, překročený nebo těsný limit.
  /// (Např. „4,8 m“ po celé D8 přes tunely kamion 4 m nijak neomezuje – neukazovat.)
  bool get relevant =>
      violates ||
      tight ||
      overridden ||
      type == WarningType.speedCamera ||
      type == WarningType.noOvertakingHgv;
  final bool onBridge; // omezení je na mostě (fyzická nosnost)

  /// Doplňující text (např. časové omezení „6–22 h“).
  final String? note;

  /// Silnice / ulice (z OSM) a id cesty v OSM – pro „most 12 t (Ve Žlíbku)“ a „omezení neplatí“.
  final String? road;
  final int? wayId;

  /// Řidič označil omezení jako neplatné (značka na místě není) – nepočítá se jako porušení.
  final bool overridden;

  RouteWarning({
    required this.type,
    required this.value,
    this.note,
    required this.atMeters,
    required this.point,
    required this.violates,
    this.tight = false,
    this.onBridge = false,
    this.road,
    this.wayId,
    this.overridden = false,
  });

  /// Krátký popis pro řidiče: „most 12 t (Ve Žlíbku)“, „zákaz nad 6 t (Náchodská)“.
  String get title {
    final what = switch (type) {
      WarningType.weight => onBridge ? 'most $label' : 'zákaz nad $label',
      WarningType.axleLoad => 'náprava $label',
      WarningType.height => 'výška $label',
      WarningType.width => 'šířka $label',
      WarningType.length => 'délka $label',
      WarningType.speedCamera => 'radar',
      WarningType.noOvertakingHgv => 'zákaz předjíždění',
    };
    return road == null || road!.isEmpty ? what : '$what (${roadLabel(road!)})';
  }

  /// Stejné omezení označené jako neplatné.
  RouteWarning asOverridden() => RouteWarning(
    type: type,
    value: value,
    note: note,
    atMeters: atMeters,
    point: point,
    violates: false,
    onBridge: onBridge,
    road: road,
    wayId: wayId,
    overridden: true,
  );

  String get label {
    final v = value;
    String n(double x) => x.toStringAsFixed(x == x.roundToDouble() ? 0 : 1).replaceAll('.', ',');
    switch (type) {
      case WarningType.height:
        return '${n(v!)} m';
      case WarningType.width:
        return '${n(v!)} m';
      case WarningType.length:
        return '${n(v!)} m';
      case WarningType.weight:
        return '${n(v!)} t';
      case WarningType.axleLoad:
        return '${n(v!)} t';
      case WarningType.speedCamera:
        return 'radar';
      case WarningType.noOvertakingHgv:
        return note ?? '';
    }
  }

  String get spokenName {
    switch (type) {
      case WarningType.height:
        return 'omezení výšky';
      case WarningType.width:
        return 'omezení šířky';
      case WarningType.length:
        return 'omezení délky';
      case WarningType.weight:
        return onBridge ? 'most s nosností' : 'omezení hmotnosti';
      case WarningType.axleLoad:
        return 'omezení zatížení nápravy';
      case WarningType.speedCamera:
        return 'radar';
      case WarningType.noOvertakingHgv:
        return 'zákaz předjíždění nákladních vozidel';
    }
  }
}

/// Název silnice pro řidiče: číslo z OSM (`ref` = „16“) jako „silnice 16“, jinak jméno ulice.
String roadLabel(String road) => RegExp(r'^\d+$').hasMatch(road) ? 'silnice $road' : road;

/// Proč trasa kamionu jede oklikou: kratší cesta (bez hmotnostních zákazů) vede přes omezení,
/// které vozidlo překračuje – most 12 t, zákaz nad 6 t…
class RouteDetour {
  /// O kolik je objížďka delší (km, min) než kratší cesta přes omezení.
  final double extraKm;
  final double extraMin;

  /// Omezení na kratší cestě (most 12 t…), kvůli kterým trasa objíždí.
  final List<RouteWarning> causes;

  /// Trasa jede kratší cestou přes [causes], protože je řidič označil jako neplatná.
  final bool viaIgnored;

  const RouteDetour({
    required this.extraKm,
    required this.extraMin,
    required this.causes,
    this.viaIgnored = false,
  });

  String get _what => causes.length == 1 ? causes.first.title : '${causes.first.title} a další';
  String get _km => extraKm.round() < 1 ? '1' : '${extraKm.round()}';

  /// Text do panelu: „Objížďka +14 km: most 12 t (Ve Žlíbku)“ / „Přes most 12 t (Ve Žlíbku) – neplatí“.
  String get short => viaIgnored ? 'Přes $_what – neplatí' : 'Objížďka +$_km km: $_what';

  /// Celé vysvětlení.
  String get explanation => viaIgnored
      ? 'Trasa jede přes $_what – omezení je v telefonu označené jako neplatné. '
            'Ušetří asi $_km km (${extraMin.round()} min).'
      : 'Kratší cesta vede přes $_what. Vaše vozidlo limit překračuje, proto navigace jede jinudy: '
            '+$_km km, +${extraMin.round()} min.';
}

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

  /// Manévr, při kterém se jen jede dál po téže dálnici (rovně, jiné jméno, „držte se vlevo, abyste
  /// zůstali na D1“): odpočet v okénku i „Pokračujte rovně X km“ počítají až k dalšímu opravdovému
  /// manévru (sjezd, odbočka, přejezd na jinou dálnici). Jinak „200 km rovně“ ukazuje jen kilometry
  /// k nejbližší křižovatce a za ní znovu „Pokračujte rovně…“.
  bool isPassThrough(int i) {
    if (!identical(_passEdges, edges) || _pass.length != maneuvers.length) {
      _passEdges = edges;
      _pass = List<bool?>.filled(maneuvers.length, null);
    }
    return _pass[i] ??= _isPassThrough(maneuvers[i]);
  }

  List<EdgeAttr>? _passEdges;
  List<bool?> _pass = const [];

  static final _ref = RegExp(r'^([DEARS])\s?(\d+)$');

  bool _isPassThrough(Maneuver m) {
    if (m.synthetic) return true;
    if (!const {7, 8, 22, 23, 24}.contains(m.type)) return false;
    EdgeAttr? at(int idx) {
      for (final e in edges) {
        if (e.begin <= idx && idx < e.end) return e;
      }
      return null;
    }

    final after = at(m.beginShapeIndex);
    if (after == null) {
      // Bez atributů silnic (ještě se načítají): podle jména za manévrem.
      final ref = m.streetNames.any((n) => _ref.hasMatch(n.trim()));
      return ref && (m.type < 23 || m.instruction.contains('zůstali'));
    }
    if (!(after.roadClass == 'motorway' || after.roadClass == 'trunk') || after.use == 'ramp') return false;
    if (m.type < 23) return true;
    // Rozdvojení: jen když se zůstává na téže dálnici (D1 → D1), ne D1 → D46.
    final before = at(m.beginShapeIndex - 1);
    if (before == null) return false;
    Set<String> refs(EdgeAttr e, bool national) => {
      for (final n in e.names)
        if (_ref.firstMatch(n.trim()) case final r? when (r[1] != 'E') == national) '${r[1]}${r[2]}',
    };
    // Národní čísla (D1, A4); evropská (E 65 vede po D1 i D2) jen když národní chybí.
    final nb = refs(before, true), na = refs(after, true);
    if (nb.isNotEmpty && na.isNotEmpty) return nb.intersection(na).isNotEmpty;
    return refs(before, false).intersection(refs(after, false)).isNotEmpty;
  }

  /// Nejbližší opravdový manévr od indexu [i] (sám [i], když není průjezdný); -1 = žádný.
  int actionFrom(int i) {
    if (i < 0) return -1;
    var k = i;
    while (k < maneuvers.length - 1 && isPassThrough(k)) {
      k++;
    }
    return k < maneuvers.length ? k : -1;
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
      violates || tight || type == WarningType.speedCamera || type == WarningType.noOvertakingHgv;
  final bool onBridge; // omezení je na mostě (fyzická nosnost)

  /// Doplňující text (např. časové omezení „6–22 h“).
  final String? note;

  RouteWarning({
    required this.type,
    required this.value,
    this.note,
    required this.atMeters,
    required this.point,
    required this.violates,
    this.tight = false,
    this.onBridge = false,
  });

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

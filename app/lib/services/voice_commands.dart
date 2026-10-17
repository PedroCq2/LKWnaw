import 'search_fold.dart';

/// Co řidič hlasem chce.
enum VoiceAction {
  navigate,
  addStop,
  start,
  findParking,
  findFuel,
  findService,
  remaining,
  voiceOff,
  voiceOn,
  reroute,
  stop,
  aerial,
  normalMap,
  report,
  help,
  unknown,
}

class VoiceCommand {
  final VoiceAction action;
  final String? arg; // cíl / zastávka („Kaufland Olomouc“)
  const VoiceCommand(this.action, [this.arg]);
}

/// Hlasový příkaz z rozpoznaného textu („naviguj na Kaufland Olomouc“, „najdi parkoviště“, „kolik zbývá“).
VoiceCommand parseCommand(String text) {
  final raw = text.trim();
  final t = fold(raw);
  bool has(String re) => RegExp(re).hasMatch(t);

  if (has(r'(zrus|ukonci|ukoncit|konec|zastav) (navigac|trasu|jizdu)')) {
    return const VoiceCommand(VoiceAction.stop);
  }
  if (has(r'(spatne|chyba|nahlas|nahlasit|zaznamenej)')) {
    return const VoiceCommand(VoiceAction.report);
  }
  if (has(r'^(start|jedeme|jed|spust|spustit|vyraz|pojedme)( navigaci)?$')) {
    return const VoiceCommand(VoiceAction.start);
  }

  // Zastávka: „přidej zastávku Lidl Šternberk“.
  final stop = RegExp(
    r'^(?:pridej|pridat|pridejte)\s+(?:zastavku|zastavka|pruchozi bod|prujezdni bod|zastaveni)\s+(?:na |v |ve |do |u )?(.+)$',
  ).firstMatch(t);
  if (stop != null) return VoiceCommand(VoiceAction.addStop, _original(raw, stop.group(1)!));

  if (has(r'(parkovist|odpocivk|truckpark|zaparkovat|prespat|kde (si )?(muzu )?zastavit)')) {
    return const VoiceCommand(VoiceAction.findParking);
  }
  if (has(r'(pump|benzink|nafta|naftu|natankovat|tankovat|cerpaci)')) {
    return const VoiceCommand(VoiceAction.findFuel);
  }
  if (has(r'(servis|pneu|odtah)')) {
    return const VoiceCommand(VoiceAction.findService);
  }
  if (has(
    r'(kolik (zbyva|jeste|to je|kilometr|km)|kdy (tam )?(budu|dorazim|dojedu|prijedu)|cas prijezdu|prijezd)',
  )) {
    return const VoiceCommand(VoiceAction.remaining);
  }
  if (has(r'(ztlum|vypni (hlas|zvuk|mluveni)|ticho|nemluv|mlc)')) {
    return const VoiceCommand(VoiceAction.voiceOff);
  }
  if (has(r'(zapni (hlas|zvuk|mluveni)|mluv)')) {
    return const VoiceCommand(VoiceAction.voiceOn);
  }
  if (has(r'(prepocitej|prepocitat|jinou trasu|jina trasa|objizdk)')) {
    return const VoiceCommand(VoiceAction.reroute);
  }
  if (has(r'(leteck|satelit|fotk)')) {
    return const VoiceCommand(VoiceAction.aerial);
  }
  if (has(r'(normalni|klasick|obycejn)\w* mapa')) {
    return const VoiceCommand(VoiceAction.normalMap);
  }
  if (has(r'(co umis|napoveda|pomoc|co muzu rict)')) {
    return const VoiceCommand(VoiceAction.help);
  }

  // Cíl: „naviguj na…“, „jeď do…“, „veď mě k…“, „cíl…“.
  final nav = RegExp(
    r'^(?:naviguj|navigovat|navigace|ved me|vez me|jed|jedeme|jedu|chci jet|cil|trasa|trasu|najdi cestu)\s+(?:me\s+)?(?:na |do |k |ke |ku |za |u )?(.+)$',
  ).firstMatch(t);
  if (nav != null && nav.group(1)!.trim().length > 1) {
    return VoiceCommand(VoiceAction.navigate, _original(raw, nav.group(1)!));
  }
  return const VoiceCommand(VoiceAction.unknown);
}

/// Část původního textu (s diakritikou), která odpovídá konci složeného textu.
String _original(String raw, String foldedTail) {
  final n = foldedTail.trim().length;
  return raw.length >= n ? raw.substring(raw.length - n).trim() : foldedTail.trim();
}

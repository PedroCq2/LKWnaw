import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/services/road_via.dart';
import 'package:truck_nav/services/voice_commands.dart';

void main() {
  test('hlasové příkazy', () {
    var c = parseCommand('Naviguj na Kaufland Olomouc');
    expect(c.action, VoiceAction.navigate);
    expect(c.arg, 'Kaufland Olomouc');
    c = parseCommand('jeď do Týnecká 65 Olomouc');
    expect(c.action, VoiceAction.navigate);
    expect(c.arg, 'Týnecká 65 Olomouc');
    c = parseCommand('přidej zastávku Lidl Šternberk');
    expect(c.action, VoiceAction.addStop);
    expect(c.arg, 'Lidl Šternberk');
    expect(parseCommand('najdi parkoviště').action, VoiceAction.findParking);
    expect(parseCommand('kde natankovat naftu').action, VoiceAction.findFuel);
    expect(parseCommand('kolik ještě zbývá').action, VoiceAction.remaining);
    expect(parseCommand('kdy tam budu').action, VoiceAction.remaining);
    expect(parseCommand('ztlum').action, VoiceAction.voiceOff);
    expect(parseCommand('zruš navigaci').action, VoiceAction.stop);
    expect(parseCommand('tady navigovala špatně').action, VoiceAction.report);
    expect(parseCommand('start').action, VoiceAction.start);
    expect(parseCommand('letecká mapa').action, VoiceAction.aerial);
    expect(parseCommand('ahoj').action, VoiceAction.unknown);
    expect(parseCommand('nauč se trasu').action, VoiceAction.learn);
    expect(parseCommand('zapamatuj si cestu').action, VoiceAction.learn);
    expect(parseCommand('ulož trasu').action, VoiceAction.learnSave);
  });

  test('cíl přes města a po dálnici', () {
    var c = parseCommand('Naviguj na Kaufland Děčín přes Neratovice, Mělník, pak na D8 a po dálnici');
    expect(c.action, VoiceAction.navigate);
    expect(c.arg, 'Kaufland Děčín');
    expect(c.via, ['Neratovice', 'Mělník', 'D8']);
    expect(c.highway, isTrue);
    // Rozpoznaná řeč bývá bez čárek, D8 jako „dé osm“.
    c = parseCommand('naviguj na Kaufland Děčín přes Neratovice a Mělník a pak zpět na dé osm');
    expect(c.arg, 'Kaufland Děčín');
    expect(c.via, ['Neratovice', 'Mělník', 'D8']);
    expect(c.highway, isFalse);
    c = parseCommand('jeď přes Mělník do Děčín');
    expect(c.arg, 'Děčín');
    expect(c.via, ['Mělník']);
    c = parseCommand('naviguj na Kaufland Olomouc');
    expect(c.arg, 'Kaufland Olomouc');
    expect(c.via, isEmpty);
  });

  test('dálnice z hlasu a body na ní', () {
    for (final t in ['D8', 'na D8', 'pak zpět na D8', 'dé osm', 'dálnice 8', 'na osmičku']) {
      expect(roadRef(t), 'D8', reason: t);
    }
    expect(roadRef('po desítce'), 'D10');
    expect(roadRef('Děčín'), isNull);
    expect(roadRef('po dálnici'), isNull);
    // Mělník → Děčín po D8: body uvnitř úseku dálnice, na severním pásu (směr Ústí).
    const melnik = LatLng(50.3505, 14.4741), decin = LatLng(50.7716, 14.2069);
    final v = roadVia('D8', melnik, decin);
    expect(v, hasLength(2));
    for (final p in v) {
      expect(p.through && p.motorway, isTrue);
      expect(p.heading, inInclusiveRange(270, 360));
      expect(p.point.latitude, inExclusiveRange(50.35, 50.70));
    }
    expect(v.first.point.latitude, lessThan(v.last.point.latitude));
    // Opačný směr (Děčín → Mělník): jižní pás.
    final back = roadVia('D8', decin, melnik);
    expect(back.first.heading, inInclusiveRange(90, 180));
    expect(back.first.point.latitude, greaterThan(back.last.point.latitude));
  });
}

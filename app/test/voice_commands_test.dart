import 'package:flutter_test/flutter_test.dart';
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
  });
}

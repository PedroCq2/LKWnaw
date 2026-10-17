import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/services/address_parser.dart';

void main() {
  test('dodací list Kaufland: místo vykládky, ne odběratel', () {
    final a = parseAddresses([
      'DODACÍ LIST č. 2026104455',
      'Dodavatel: Hamé s.r.o.',
      'Na Výsluní 201',
      '686 03 Babice',
      'IČO: 44012373',
      'Odběratel: Kaufland Česká republika v.o.s.',
      'Bělehradská 299/132',
      '120 00 Praha 2',
      'Příjemce: DC - Modletice',
      'Ulice: Modletice 91',
      'Místo vykládky: 25101 Říčany u Prahy',
      'Tel: +420 323 600 111',
    ]);
    expect(a, hasLength(1));
    expect(a.single.street, 'Modletice 91');
    expect(a.single.postcode, '25101');
    expect(a.single.city, 'Říčany u Prahy');
    expect(a.single.name, 'DC - Modletice');
    expect(a.single.query, 'Modletice 91, 25101 Říčany u Prahy');
  });

  test('adresa na jednom řádku', () {
    final a = parseAddresses(['Příjemce: DC - Olomouc, Týnecká 65, 77900 Olomouc']);
    expect(a.single.street, 'Týnecká 65');
    expect(a.single.city, 'Olomouc');
    expect(a.single.name, 'DC - Olomouc');
  });

  test('štítek balíku: odesílatel se přeskočí', () {
    final a = parseAddresses([
      'Odesílatel:',
      'Alza.cz a.s.',
      'Jankovcova 1522/53',
      '170 00 Praha 7',
      'Adresát:',
      'Jan Novák',
      'Masarykova 12/4',
      '602 00 Brno',
      'Tel.: 777 123 456',
    ]);
    expect(a.map((e) => e.street), ['Masarykova 12/4']);
    expect(a.single.name, 'Jan Novák');
  });

  test('seznam adres na rozvozovém listu', () {
    final a = parseAddresses([
      '1. Petr Svoboda, Husova 5, 779 00 Olomouc',
      '2. Eva Malá, Dukelská 210, 783 72 Velký Týnec',
      '3. Pekárna, Nádražní 1a, 772 00 Olomouc',
    ]);
    expect(a.map((e) => e.street), ['Husova 5', 'Dukelská 210', 'Nádražní 1a']);
    expect(a[1].city, 'Velký Týnec');
  });

  test('skutečná fotka dodacího listu DC Modletice (razítko přes adresu)', () {
    final a = parseAddresses([
      'ven dne: 16.10.2026',
      'ý náklad povoleného množství (LQ) dle kapitoly 3.4 ADR!',
      'a 12 Příjemce: DC - Modletice',
      'vic Č. filiálky: 9200',
      'Ulice: Modletice 91 123 91',
      'Místo vykládky: 25101 Říčany u Prahy',
      'Tel. Číslo: 323 646 400',
      'Datum dodání: 17.10.2026',
      'Pož. Dodání: 00:00',
      '89 Interní pošta',
      '50 Č. interní TJ 2859211922',
      'Transportní jednotka: C930202610171463 66',
    ]);
    expect(a, hasLength(1));
    expect(a.single.street, 'Modletice 91');
    expect(a.single.postcode, '25101');
    expect(a.single.city, 'Říčany u Prahy');
  });
}

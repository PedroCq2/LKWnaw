# LKWnav – navigace pro kamiony (Android APK)

Flutter aplikace pro navigaci nákladních vozidel nad OpenStreetMap a routing enginem
[Valhalla](https://github.com/valhalla/valhalla) s profilem `truck`.

## Funkce

- **3D vektorová mapa** (MapLibre + OpenFreeMap) – budovy ve 3D, náklon ve směru jízdy,
  přepínání 2D/3D, denní/noční vzhled.
- **Kamionové trasy** – výška, šířka, délka, hmotnost, zatížení nápravy, počet náprav,
  ADR (nebezpečný náklad), max. rychlost vozidla, vyhnutí se mýtu / trajektům.
- **Výstrahy na trase** – omezení výšky, hmotnosti, šířky, délky a nápravy z OSM
  (červeně, pokud je vaše vozidlo překračuje, + hlasové varování) a radary. Vpravo nejvýš dvě
  nejbližší značky, nikdy přes tlačítka (okénko pumpy se na chvíli schová); po projetí další.
- **Zakázané a úzké ulice v mapě** – kolem polohy (i kde si mapu prohlížíte) červeně úseky, kudy
  vaše vozidlo nesmí (nízký most, úzká ulice, nosnost, zákaz vjezdu kamionů), oranžově těsné / jen
  dopravní obsluha; značky s hodnotou („3,5t“, „3,3m“, „zákaz“). Vypínač *Zákazy* v nabídce.
- **Most „21 t“ s tabulkou pro jednotlivé vozidlo** (OSM `maxweight:total`, např. 34 t): karta
  „21t · sám 34 t“, kamion do 34 t oranžově (projede jen sám na mostě), hlasem „jednotlivé vozidlo
  34 tun“.
- **Jízda bez cíle** – aplikace pozná silnici, po které jedete (I/8, D8, ulice), a hlídá na ní
  dopředu do 30 km nízké mosty, hmotnost, šířku, délku a zákazy vjezdu kamionů: karta vpravo
  („3,3 m · 21 km“), značka v mapě a hlas („Na silnici 8 za 20 kilometrů omezení výšky 3,3 metru.
  Vaše vozidlo neprojede.“), znovu kilometr před ním. Klepnutím na kartu mapa ukáže, kde to je.
- **Varianty tras** – nejrychlejší, až 3 alternativy, bez dálnic (po „jedničkách“), bez mýta,
  nejkratší (výběr kartou); první „Doporučená“ pro kamion. „… a po dálnici“ hlasem dá dopředu tu po dálnici.
- **Vyhledávání firem a skladů** (Photon/OSM) – např. „kaufland dc olomouc“.
- **Rozdvojení dálnic a jízdní pruhy** – „Pokračujte rovně na D1 směr Vyškov“ i tam, kde
  Valhalla manévr nehlásí; pruhy z OSM (`turn:lanes`) se zvýrazněním správných pruhů.
- **Staničení dálnice** nahoře („D1 114,0 km“, dopočítané z čísel exitů) a výstraha
  **zákaz předjíždění nákladních vozidel** (i časový).
- **Vlastní vzhled LKWnav** – grafit + jantar, šedá mapa, jantarová trasa.
- **Rychlostní limit** úseku (omezený max. rychlostí kamionu) a aktuální rychlost.
- **Turn-by-turn navigace** – plynulý pohyb, přichycení k trase, tabule s manévrem
  a „Pak …“, název ulice, **české hlasové pokyny**, přepočet při sjetí z trasy.
- **POI pro kamiony** – truckparky a odpočívky (kapacita, placené, hlídané, WC, sprchy…),
  truck servisy a pneuservisy, čerpací stanice pro kamiony (AdBlue, HGV nafta).
- **Zásobování** (přepínač u trasy) – povolí vjezd do zón se zákazem nad X t
  („mimo dopravní obsluhu“, od 6 t, nebo s výjimkou zapsanou v mapě) v obci vykládky; do ulic
  s omezením 3,5 t jen tehdy, když v nich leží cíl. Výjimka platí jen na úsecích, kde ji trasa
  opravdu využívá (dojezd v obci vykládky) – jinde je zóna červeně a trasa se jí vyhne. Výška,
  šířka, délka, náprava a ADR platí dál; mostům s nižší nosností se trasa automaticky vyhne.
- **Uložená místa s vjezdem pro kamiony** – u firmy zvlášť adresa a brána (dlouhé podržení
  na mapě) + poznámka („Příjezd zezadu, vrátnice u rampy 12“), přečte se před cílem.
- **POI podél trasy** – truckparky/pumpy/servisy seřazené podle dojezdu (km, min, odbočka
  od trasy) s filtry WC, sprchy, jídlo, zdarma, hlídané.
- **Objet toto místo** – dlouhé podržení na trase → trasa se přepočítá kolem.
- **Mapa offline** – stažení mapy podél trasy (MapLibre offline regiony, zoom 8–14).
- **Klidné přepočítávání** – krátký výkyv GPS nespouští novou trasu; bez internetu vede dál
  po uložené trase a ukazuje stav.
- **Plán trasy** – začátek (moje poloha / jiné místo), více zastávek (přeřazení tažením), cíl;
  uložené plány. Zastávky číslované a s adresou (ulice, číslo, PSČ, obec) – podle ní se řadí.
  Zastávku lze přidat i za jízdy z hledání parkovišť/pump.
- **Průjezdy** – „přes Neratovice, Mělník a pak po D8“: města se jen projedou (po hlavní silnici,
  bez zastavení), dálnice se vynutí body na správném pásu (`road_anchors.dart`, vjezd a sjezd si
  vybere trasa). V plánu tlačítko *Průjezd*, hlasem „naviguj na Kaufland Děčín přes Neratovice,
  Mělník, pak na D8 a po dálnici“.
- **Naučit trasu** – v nabídce *Naučit* (nebo hlasem „nauč se trasu“) se nahrává jízda; *Uložit*
  („ulož trasu“) ji uloží. Příště k cíli u jejího konce navigace pojede přesně tudy (body podél
  nahrané stopy, typ „via“). Když tudy kamion podle mapy nesmí, spočítá trasu bez ní; v panelu
  trasy jde naučenou trasu pro daný cíl vypnout, v nabídce *Naučené trasy* smazat.
- **Dlouhý úsek po dálnici** – kilometry v okénku a „Pokračujte rovně po D1 350 kilometrů“ až
  k sjezdu, kde se opravdu sjíždí; rozdvojení na téže dálnici („držte se vlevo, abyste zůstali
  na D1“) jen krátce ohlásí a ukáže pruhy, odpočet nepřeruší.
- **Obnovení navigace** po restartu aplikace.
- **Hlas** – nejlepší český hlas v telefonu (volba + rychlost v Nastavení), navigační zvuk
  ztlumí hudbu, hlášky se nepřekrývají; čísla silnic česky („dé čtyřicet šest“, „E čtyři sta
  dvacet dva“).
- **Simulace jízdy** (Nastavení) – vyzkoušení navigace bez jízdy.

## Instalace APK

1. Stáhněte `app-release.apk` z GitHub Actions (záložka **Actions → Build APK → Artifacts**)
   nebo z **Releases** (při vydání tagu `v*`).
2. V telefonu povolte instalaci z neznámých zdrojů a APK nainstalujte.
3. Povolte přístup k poloze a notifikacím. Pro české hlasové pokyny musí být v telefonu
   nainstalován český hlas (Nastavení → Převod textu na řeč).

## Sestavení

```bash
cd app
flutter pub get
flutter test
flutter build apk --release   # → build/app/outputs/flutter-apk/app-release.apk
```

APK je podepsané debug klíčem (vhodné pro instalaci mimo Google Play). Pro Play Store
nastavte vlastní keystore v `app/android/app/build.gradle.kts`.

## Trasy v telefonu (bez internetu)

Aplikace umí počítat trasy přímo v telefonu (knihovna valhalla-mobile, Valhalla 3.9).
Data pro celou ČR staví workflow `.github/workflows/routing-cz.yml` z aktuálního výřezu
OpenStreetMap (1. a 15. den v měsíci, nebo ručně) a zveřejní je jako vydání **routing-cz**
(`cz-routing.tar.gz` ~175 MB ke stažení, v telefonu ~410 MB; `routing-cz.json` = datum dat).
V aplikaci: Profil vozidla → *Trasy v telefonu* → Stáhnout ČR / Aktualizovat.

## Vlastní routing server

Ve výchozím stavu aplikace používá veřejný server `https://valhalla1.openstreetmap.de`
(FOSSGIS, omezený výkon, bez záruky). Pro ostrý provoz spusťte vlastní:

```bash
cd backend
docker compose up -d      # stáhne OSM data ČR + DE a postaví dlaždice
```

a v aplikaci (ikona kamionu → *Valhalla server*) zadejte `http://<IP-serveru>:8002`.

## Struktura

| Soubor | Účel |
|---|---|
| `app/lib/services/valhalla.dart` | Valhalla `/route` klient, dekódování polyline6 |
| `app/lib/navigation/nav_engine.dart` | map matching, postup po trase, detekce sjetí |
| `app/lib/services/geocoding.dart` | vyhledávání adres, POI pro kamiony |
| `app/lib/services/restrictions.dart` | omezení (výška/hmotnost…) a radary podél trasy |
| `app/lib/navigation/simulator.dart` | simulace jízdy |
| `app/lib/screens/map_screen.dart` | mapa, navigační UI, hlasové pokyny |
| `app/lib/screens/profile_screen.dart` | profil vozidla a nastavení |
| `app/lib/services/road_via.dart` | průjezdy městy a po dálnici („přes Mělník, pak po D8“) |
| `backend/roads/build_road_anchors.py` | body na českých dálnicích → `road_anchors.dart` |
| `backend/docker-compose.yml` | vlastní Valhalla server |

## Plán dalšího vývoje

- Offline mapy po státech (CZ, DE, PL…) a offline výpočet tras.
- Uložená místa / vjezdy do areálů a ramp.
- Přehled mýtného (CZ, SK, DE, AT…).
- ADR kategorie tunelů (B–E) v profilu.

Mapová data © přispěvatelé OpenStreetMap (ODbL).

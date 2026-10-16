# LKWnav – navigace pro kamiony (Android APK)

Flutter aplikace pro navigaci nákladních vozidel nad OpenStreetMap a routing enginem
[Valhalla](https://github.com/valhalla/valhalla) s profilem `truck`.

## Funkce

- **3D vektorová mapa** (MapLibre + OpenFreeMap) – budovy ve 3D, náklon ve směru jízdy,
  přepínání 2D/3D, denní/noční vzhled.
- **Kamionové trasy** – výška, šířka, délka, hmotnost, zatížení nápravy, počet náprav,
  ADR (nebezpečný náklad), max. rychlost vozidla, vyhnutí se mýtu / trajektům.
- **Výstrahy na trase** – omezení výšky, hmotnosti, šířky, délky a nápravy z OSM
  (červeně, pokud je vaše vozidlo překračuje, + hlasové varování) a radary.
- **Varianty tras** – nejrychlejší, alternativa, bez mýta, nejkratší (výběr kartou).
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
  („mimo dopravní obsluhu“), výška, šířka, délka, náprava a ADR platí dál; mostům
  s nižší nosností se trasa automaticky vyhne.
- **Uložená místa s vjezdem pro kamiony** – u firmy zvlášť adresa a brána (dlouhé podržení
  na mapě) + poznámka („Příjezd zezadu, vrátnice u rampy 12“), přečte se před cílem.
- **POI podél trasy** – truckparky/pumpy/servisy seřazené podle dojezdu (km, min, odbočka
  od trasy) s filtry WC, sprchy, jídlo, zdarma, hlídané.
- **Objet toto místo** – dlouhé podržení na trase → trasa se přepočítá kolem.
- **Mapa offline** – stažení mapy podél trasy (MapLibre offline regiony, zoom 8–14).
- **Klidné přepočítávání** – krátký výkyv GPS nespouští novou trasu; bez internetu vede dál
  po uložené trase a ukazuje stav.
- **Plán trasy** – začátek (moje poloha / jiné místo), více zastávek (přeřazení tažením), cíl;
  uložené plány. Zastávku lze přidat i za jízdy z hledání parkovišť/pump.
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
| `backend/docker-compose.yml` | vlastní Valhalla server |

## Plán dalšího vývoje

- Offline mapy po státech (CZ, DE, PL…) a offline výpočet tras.
- Uložená místa / vjezdy do areálů a ramp.
- Přehled mýtného (CZ, SK, DE, AT…).
- ADR kategorie tunelů (B–E) v profilu.

Mapová data © přispěvatelé OpenStreetMap (ODbL).

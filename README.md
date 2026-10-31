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
- **Vlastní síť parkovišť** – truckparky, odpočívky a místa k přespání z OSM, které řidiči
  doplňují: **Přidat parkoviště** (nabídka, dlouhé podržení na mapě), oprava údajů (počet míst,
  poplatek, WC, sprchy, hlídané…), **obsazenost Volno / Omezeno / Plno** (platí 3 h, barva bodu
  v mapě, filtr „není plno“) a „místo už neexistuje“. Když kamion stojí 3 min na parkovišti,
  zeptá se „Je tu místo?“; po 10 min stání mimo známé parkoviště nabídne jeho přidání. Funguje
  bez internetu, se serverem sítě se sdílí mezi řidiči (viz níže).
- **Objet toto místo** – dlouhé podržení na trase → trasa se přepočítá kolem.
- **Sjetí z trasy kvůli omezení** – když nová trasa vrací zpět a důvodem je omezení na silnici vpřed
  (např. 3,5 t), aplikace ho řekne a řidič zvolí **Pokračovat** (povolení, dopravní obsluha) nebo
  **Otočit se**; otočení po hlavních silnicích, ne přes obytné ulice. Přes nízký most / úzký
  průjezd pokračovat nelze.
- **Rychlost** – klepnutí na kolečko: hranice upozornění (+0 až +20 km/h) a **„na značce je jiná
  rychlost“** – platí pro tu silnici hned, ostatním po shodě dvou řidičů; kamionové limity
  z OSM (`maxspeed:hgv`).
- **Zpráva pro vývoj** – zatřesením telefonu (když kamion stojí) nebo z nabídky: chyba / vylepšení /
  nová funkce + systémové informace (telefon, Android, verze, nastavení, poloha, trasa).
- **Mapa offline** – stažení mapy podél trasy (MapLibre offline regiony, zoom 8–14).
- **Klidné přepočítávání** – krátký výkyv GPS nespouští novou trasu; bez internetu vede dál
  po uložené trase a ukazuje stav.
- **Plán trasy** – začátek (moje poloha / jiné místo), více zastávek (přeřazení tažením), cíl;
  uložené plány. Zastávku lze přidat i za jízdy z hledání parkovišť/pump.
- **Obnovení navigace** po restartu aplikace.
- **Hlas** – režim **Vše / Jen upozornění / Nic** (tlačítko na mapě za jízdy, nabídka, Nastavení);
  u odbočky jedna hláška předem (dálnice 1 km, město 300 m) a pak v místě, podrobný odpočet
  1 km / 500 m / 200 m volitelně. Nejlepší český hlas v telefonu (volba + rychlost v Nastavení), navigační zvuk
  ztlumí hudbu, hlášky se nepřekrývají; čísla silnic česky („dé čtyřicet šest“, „E čtyři sta
  dvacet dva“).
- **Simulace jízdy** (Nastavení) – vyzkoušení navigace bez jízdy.

## Instalace APK

1. Stáhněte `app-release.apk` z GitHub Actions (záložka **Actions → Build APK → Artifacts**)
   nebo z **Releases** (při vydání tagu `v*`). APK vzniká po sloučení do hlavní větve
   (`claude/friendly-curie-fceifd`); pro jinou větev **Actions → Build APK → Run workflow**.
   Pull request dostane jen kontrolu (analyze + testy), bez APK.
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

## Server sítě parkovišť

APK z GitHub Actions se připojuje k projektu Supabase **LKWnav** (Frankfurt), adresa a veřejný
klíč jsou ve `.github/workflows/build-apk.yml`. Při vlastním sestavení bez `--dart-define` se
přidaná místa a hlášení ukládají jen v telefonu (a čekají na odeslání).

Jiný server:

1. Založte projekt v [Supabase](https://supabase.com) (stačí bezplatný) nebo vlastní PostgreSQL
   s [PostgREST](https://postgrest.org).
2. Spusťte `backend/network/schema.sql` (Supabase → SQL Editor). Vytvoří tabulky, oprávnění
   a funkce `net_save_place`, `net_report`, `net_status` – zápis jde jen přes ně (kontrola údajů,
   limity proti spamu, historie změn, místo se skryje po třech hlášeních „neexistuje“).
   Stejně tak nahlášené rychlosti (`speed_report`, `speed_fixes`) a zprávy z aplikace
   (`send_feedback` → tabulka `app_feedback`, čte jen správce v Supabase → Table Editor).
3. V GitHubu nastavte proměnné repozitáře (*Settings → Secrets and variables → Actions →
   Variables*): `NET_URL` = `https://<projekt>.supabase.co/rest/v1`, `NET_KEY` = veřejný
   klíč (*publishable* / *anon*). Mají přednost před výchozím projektem.

## Struktura

| Soubor | Účel |
|---|---|
| `app/lib/services/valhalla.dart` | Valhalla `/route` klient, dekódování polyline6 |
| `app/lib/navigation/nav_engine.dart` | map matching, postup po trase, detekce sjetí |
| `app/lib/services/geocoding.dart` | vyhledávání adres, POI pro kamiony |
| `app/lib/services/restrictions.dart` | omezení (výška/hmotnost…) a radary podél trasy |
| `app/lib/services/parking_network.dart` | síť parkovišť: místa od řidičů, obsazenost, sdílení se serverem |
| `app/lib/screens/net_place_screen.dart` | přidání / úprava parkoviště |
| `backend/network/schema.sql` | server sítě parkovišť (Supabase / PostgREST) |
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

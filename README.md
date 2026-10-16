# LKW Navi – navigace pro kamiony (Android APK)

Flutter aplikace pro navigaci nákladních vozidel nad OpenStreetMap a routing enginem
[Valhalla](https://github.com/valhalla/valhalla) s profilem `truck`.

## Funkce

- **Kamionové trasy** – výška, šířka, délka, hmotnost, zatížení nápravy, počet náprav,
  ADR (nebezpečný náklad), vyhnutí se mýtu / trajektům. Předvolby: tahač 40 t, sólo 18 t, dodávka 3,5 t.
- **Turn-by-turn navigace** – přichycení GPS k trase, natáčení mapy ve směru jízdy,
  vzdálenost k manévru, **české hlasové pokyny** (TTS), automatické **přepočítání při sjetí z trasy**.
- **Vyhledávání cíle** (Nominatim) nebo dlouhé podržení prstu na mapě.
- **Doba řízení dle 561/2006** – sledování 4,5 h nepřetržitého řízení (přestávka 45 min
  nebo 15 + 30), 9 h denně, hlasové varování 30/15/0 min před limitem,
  upozornění „cestou nutná přestávka“.
- **Parkoviště pro kamiony** (Overpass/OSM) – při navigaci hledá v místě, kam dojedete
  před vypršením doby řízení; jedním ťuknutím na ně naviguje.

> Doba řízení se odhaduje z GPS rychlosti a je pouze orientační – závazný je tachograf.

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
| `app/lib/services/drive_timer.dart` | doba řízení / přestávky (561/2006) |
| `app/lib/services/geocoding.dart` | vyhledávání adres, parkoviště HGV |
| `app/lib/screens/map_screen.dart` | mapa, navigační UI, hlasové pokyny |
| `app/lib/screens/profile_screen.dart` | profil vozidla a nastavení |
| `backend/docker-compose.yml` | vlastní Valhalla server |

## Plán dalšího vývoje

- Offline mapy (vektorové dlaždice z Planetileru + MapLibre) a offline routing.
- Čtení `.ddd` souborů z karty řidiče místo odhadu z GPS.
- Zobrazení omezení (podjezdy, zákazy vjezdu) přímo v mapě.

Mapová data © přispěvatelé OpenStreetMap (ODbL).

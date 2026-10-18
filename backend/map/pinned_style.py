"""Styl mapy LKWnav pro stahování mapy do telefonu (MapLibre offline regiony).

OpenFreeMap má v původním stylu zdroj dlaždic přes TileJSON (https://tiles.openfreemap.org/planet),
který každý týden ukáže na novou verzi dat (…/planet/20261011_080001_pt/{z}/{x}/{y}.pbf).
Stažená mapa by po aktualizaci přestala bez signálu fungovat – TileJSON v telefonu se obnoví
a ukáže na dlaždice, které stažené nejsou. Proto pevná adresa dlaždic (PIN): stejná ve stylu
pro stahování i v aplikaci. Server OpenFreeMap na starší verze odpovídá aktuálními daty
(„wildcard“), takže pevná adresa funguje i po aktualizacích.

PIN musí být stejný jako `pinnedTiles` v app/lib/services/map_style.dart.

Použití: python3 pinned_style.py lkwnav-style.json
"""
import json
import sys
import urllib.request

PIN = 'https://tiles.openfreemap.org/planet/20261011_080001_pt/{z}/{x}/{y}.pbf'
BASE = 'https://tiles.openfreemap.org/styles/liberty'


def build():
    req = urllib.request.Request(BASE, headers={'User-Agent': 'LKWnav-style-build/1.0 (+https://github.com/PedroCq2/LKWnaw)'})
    style = json.load(urllib.request.urlopen(req, timeout=60))
    src = style['sources']['openmaptiles']
    style['sources']['openmaptiles'] = {
        'type': 'vector',
        'tiles': [PIN],
        'minzoom': 0,
        'maxzoom': 14,
        'attribution': src.get('attribution')
        or '<a href="https://openfreemap.org">OpenFreeMap</a> © OpenMapTiles Data from OpenStreetMap',
    }
    return style


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'lkwnav-style.json'
    s = build()
    json.dump(s, open(out, 'w'), ensure_ascii=False, separators=(',', ':'))
    print(out, len(s['layers']), 'vrstev, dlaždice', s['sources']['openmaptiles']['tiles'][0])

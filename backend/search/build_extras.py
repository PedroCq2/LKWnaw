"""Data pro navigaci v telefonu bez Overpass: omezení na silnicích, radary, exity, služby u dálnic.

Tabulka osm_el (+ R-strom osm_el_rtree) drží prvky OSM ve tvaru, jaký vrací Overpass
(typ, id, souřadnice, štítky, u cest geometrie), takže aplikace je zpracuje stejným kódem:
  • cesty s omezením: maxheight / maxweight / maxwidth / maxlength / maxaxleload, overtaking:hgv
  • vjezd pro kamiony: hgv / access / motor_vehicle = no, private, delivery, destination (kontrola zkratek)
  • jízdní pruhy a směry (turn:lanes, destination…) na hlavních silnicích – pruhy bez internetu
  • body: radary (highway=speed_camera), exity (motorway_junction + ref), maxheight na bodech
  • sjezdy motorway_link s destination:ref D… (sjezd na jinou dálnici)
  • služby: odpočívky (services/rest_area), všechny pumpy, parkoviště pro kamiony a parkoviště,
    restaurace, WC, sprchy, motely do 500 m od dálnice / silnice pro motorová vozidla,
    truck servisy a pneuservisy

Použití: python3 build_extras.py cz.osm.pbf search-cz.sqlite   (přidá tabulky do existující databáze)
"""
import json
import math
import sqlite3
import struct
import sys
from collections import defaultdict

import osmium

RESTR_KEYS = ('maxheight', 'maxweight', 'maxwidth', 'maxlength', 'maxaxleload', 'maxheight:physical',
              'maxweight:physical', 'overtaking:hgv', 'overtaking:hgv:conditional')
KEEP = set(RESTR_KEYS) | {'highway', 'bridge', 'tunnel', 'name', 'ref', 'destination:ref', 'destination',
                          'amenity', 'tourism', 'shop', 'craft', 'hgv', 'capacity', 'capacity:hgv', 'fee',
                          'supervised', 'surveillance', 'fenced', 'barrier', 'toilets', 'shower', 'showers',
                          'restaurant', 'food', 'fuel:adblue', 'fuel:HGV_diesel', 'opening_hours', 'brand',
                          'operator', 'access', 'motorroad', 'motor_vehicle', 'vehicle', 'goods',
                          'hgv:conditional', 'maxweight:conditional', 'turn:lanes', 'turn:lanes:forward',
                          'turn:lanes:backward',
                          'destination:lanes', 'destination:ref:lanes', 'destination:forward', 'oneway',
                          'lanes', 'junction:ref'}
# Jízdní pruhy a směry na tabulích (pokyny „držte se vpravo, směr Brno“ i bez internetu).
LANE_KEYS = ('turn:lanes', 'turn:lanes:forward', 'destination', 'destination:ref', 'destination:lanes',
             'destination:ref:lanes', 'destination:forward')
LANE_ROADS = {'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'motorway_link', 'trunk_link',
              'primary_link', 'secondary_link', 'tertiary_link'}
# Vjezd pro kamiony (zákaz / jen dopravní obsluha / soukromé) – kontrola zkratek v zásobování.
ACC_KEYS = ('hgv', 'access', 'motor_vehicle', 'vehicle', 'goods')
ACC_VALUES = {'no', 'private', 'delivery', 'destination', 'permit', 'agricultural', 'forestry'}
DRIVABLE = {'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential',
            'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link',
            'living_street', 'service', 'road'}
NEAR_CELL = 0.004  # mřížka bodů dálnic (~300–450 m)


def tags_of(t):
    return {k: v for k, v in t if k in KEEP}


def svc_kind(t):
    h, a, tr, sh = t.get('highway'), t.get('amenity'), t.get('tourism'), t.get('shop')
    if h in ('services', 'rest_area'):
        return 'anchor'
    if a == 'fuel':
        return 'anchor'
    if a == 'parking':
        return 'anchor' if (t.get('hgv') in ('yes', 'designated') or 'capacity:hgv' in t) else 'near'
    if a in ('restaurant', 'fast_food', 'cafe', 'toilets', 'shower') or tr in ('hotel', 'motel'):
        return 'near'
    if sh in ('truck_repair', 'truck', 'tyres') or t.get('craft') == 'truck_repair':
        return 'anchor'
    if sh == 'car_repair' and t.get('hgv') in ('yes', 'designated'):
        return 'anchor'
    return None


class H(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.rows = []  # (type, id, lat, lon, tags, geom|None, near_needed)
        self.mw = defaultdict(list)  # buňka -> body dálnic

    def node(self, n):
        t = n.tags
        lat, lon = n.location.lat, n.location.lon
        hw = t.get('highway')
        keep = False
        if hw == 'speed_camera' or (hw == 'motorway_junction' and 'ref' in t) or 'maxheight' in t:
            keep = True
        k = svc_kind(t)
        if keep or k:
            self.rows.append(('node', n.id, lat, lon, tags_of(t), None, k == 'near'))

    def way(self, w):
        t = w.tags
        hw = t.get('highway')
        restr = hw and any(k in t for k in RESTR_KEYS)
        link = hw == 'motorway_link' and 'destination:ref' in t
        k = None if hw else svc_kind(t)
        if hw == 'services' or hw == 'rest_area':
            k = 'anchor'
        mw = hw in ('motorway', 'trunk', 'motorway_link', 'trunk_link')
        acc = hw in DRIVABLE and any(t.get(a) in ACC_VALUES for a in ACC_KEYS) and not (
            hw == 'service' and 'hgv' not in t)
        acc = acc or (hw in LANE_ROADS and any(a in t for a in LANE_KEYS))
        if not (restr or link or k or mw or acc):
            return
        try:
            pts = [(n.lat, n.lon) for n in w.nodes]
        except osmium.InvalidLocationError:
            return
        if not pts:
            return
        if mw:
            for p in pts[::2]:
                self.mw[(int(p[0] / NEAR_CELL), int(p[1] / NEAR_CELL))].append(p)
        if restr or link:
            c = pts[len(pts) // 2]
            self.rows.append(('way', w.id, c[0], c[1], tags_of(t), pts, False))
        elif k:
            c = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
            self.rows.append(('way', w.id, c[0], c[1], tags_of(t), None, k == 'near'))
        elif acc:
            # Bez geometrie (hledá se podle id cesty), jen obálka do R-stromu.
            c = pts[len(pts) // 2]
            self.rows.append(('way', w.id, c[0], c[1], tags_of(t), None, False, pts))

    def near_mw(self, lat, lon, m=500):
        cy, cx = int(lat / NEAR_CELL), int(lon / NEAR_CELL)
        k = math.cos(math.radians(lat)) * 111320
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for p in self.mw.get((cy + dy, cx + dx), ()):
                    if math.hypot((p[1] - lon) * k, (p[0] - lat) * 110540) < m:
                        return True
        return False


def build(pbf, out):
    h = H()
    fp = osmium.FileProcessor(pbf).with_locations('flex_mem').with_filter(
        osmium.filter.KeyFilter('highway', 'amenity', 'tourism', 'shop', 'craft', *RESTR_KEYS))
    for o in fp:
        if o.is_node():
            h.node(o)
        elif o.is_way():
            h.way(o)
    db = sqlite3.connect(out)
    db.executescript('''
        DROP TABLE IF EXISTS osm_el; DROP TABLE IF EXISTS osm_el_rtree;
        CREATE TABLE osm_el(id INTEGER PRIMARY KEY, type TEXT, osm_id INTEGER, lat REAL, lon REAL,
                            tags TEXT, geom BLOB);
        CREATE VIRTUAL TABLE osm_el_rtree USING rtree(id, minlat, maxlat, minlon, maxlon);
        DROP TABLE IF EXISTS osm_access_v1; CREATE TABLE osm_access_v1(x);  -- značka: data o vjezdu jsou
        DROP TABLE IF EXISTS osm_lanes_v1; CREATE TABLE osm_lanes_v1(x);    -- značka: pruhy a směry jsou
    ''')
    n = 0
    stats = defaultdict(int)
    for row in h.rows:
        typ, oid, lat, lon, tags, geom, near = row[:7]
        extent = row[7] if len(row) > 7 else None
        if near and not h.near_mw(lat, lon):
            continue
        n += 1
        blob = None
        if geom:
            blob = b''.join(struct.pack('<ii', round(a * 1e6), round(b * 1e6)) for a, b in geom)
            lats = [p[0] for p in geom]
            lons = [p[1] for p in geom]
            box = (min(lats), max(lats), min(lons), max(lons))
        elif extent:
            box = (min(p[0] for p in extent), max(p[0] for p in extent),
                   min(p[1] for p in extent), max(p[1] for p in extent))
        else:
            box = (lat, lat, lon, lon)
        db.execute('INSERT INTO osm_el VALUES (?,?,?,?,?,?,?)',
                   (n, typ, oid, round(lat, 6), round(lon, 6), json.dumps(tags, ensure_ascii=False), blob))
        db.execute('INSERT INTO osm_el_rtree VALUES (?,?,?,?,?)', (n, *box))
        key = tags.get('highway') or tags.get('amenity') or tags.get('tourism') or tags.get('shop') or 'other'
        stats[key] += 1
    db.execute('CREATE INDEX IF NOT EXISTS osm_el_osm ON osm_el(osm_id)')
    db.commit()
    db.execute('VACUUM')
    db.close()
    print('prvků:', n, dict(sorted(stats.items(), key=lambda x: -x[1])[:15]))


if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2])

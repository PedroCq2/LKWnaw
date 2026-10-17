"""Rampy u velkých budov ČR (obchody, sklady, haly) do rejstříku v telefonu.

Kamion nejede na parkoviště před obchodem, ale k rampě – obvykle zezadu. Pro každou velkou budovu
(≥ 800 m² obchod/sklad/hala, ≥ 1500 m² ostatní) se předem určí, kam navigovat:
  1. rampa / služební vchod zakreslený v OSM (amenity=loading_dock, door=loading_dock, entrance=service),
  2. příjezdová cesta jen pro zásobování (access/motor_vehicle/hgv=delivery, service=delivery),
  3. odhad: obslužná cesta u budovy na straně odvrácené od parkoviště.

Tabulky:
  ramp(id, lat, lon, how, sure)                      – how: 1 rampa, 2 služební vchod, 3 zásobování, 4 odhad
  ramp_rtree(id, minlat, maxlat, minlon, maxlon)    – obálka budovy

Použití: python3 build_ramps.py cz.osm.pbf search-cz.sqlite   (přidá tabulky do existující databáze)
"""
import math
import sqlite3
import sys
from array import array
from collections import defaultdict

import osmium

CELL = 0.002  # ~150–220 m
BIG_KINDS = {'retail', 'commercial', 'warehouse', 'industrial', 'supermarket', 'manufacture', 'service',
             'hangar', 'storage_tank', 'factory'}


def cell(lat, lon):
    return (int(lat / CELL), int(lon / CELL))


def area_m2(ring):
    lat0 = ring[0][0]
    k = math.cos(math.radians(lat0)) * 111320
    m = 110540.0
    s = 0.0
    for i in range(len(ring)):
        y1, x1 = ring[i - 1]
        y2, x2 = ring[i]
        s += (x1 * k) * (y2 * m) - (x2 * k) * (y1 * m)
    return abs(s) / 2


def centroid(pts):
    return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))


def inside(ring, lat, lon):
    c = False
    j = len(ring) - 1
    for i in range(len(ring)):
        ay, ax = ring[i]
        by, bx = ring[j]
        if (ay > lat) != (by > lat) and lon < (bx - ax) * (lat - ay) / (by - ay) + ax:
            c = not c
        j = i
    return c


def dist_ring(ring, lat, lon):
    if inside(ring, lat, lon):
        return 0.0
    k = math.cos(math.radians(lat)) * 111320
    m = 110540.0
    best = 1e18
    for i in range(len(ring) - 1):
        ax, ay = (ring[i][1] - lon) * k, (ring[i][0] - lat) * m
        bx, by = (ring[i + 1][1] - lon) * k, (ring[i + 1][0] - lat) * m
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0.0 if l2 == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / l2))
        x, y = ax + t * dx, ay + t * dy
        best = min(best, math.hypot(x, y))
    return best


def dist(a, b):
    k = math.cos(math.radians(a[0])) * 111320
    return math.hypot((a[1] - b[1]) * k, (a[0] - b[0]) * 110540)


class H(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.docks = defaultdict(list)    # cell -> [(lat, lon, kind)]
        self.parking = defaultdict(list)  # cell -> [(lat, lon)]   (body i těžiště ploch)
        self.park_rings = defaultdict(list)  # cell -> [ring]
        self.service = defaultdict(list)  # cell -> [(lat, lon, cat)]  cat 0 běžná, 1 zásobování, 2 soukromá
        self.ends = defaultdict(list)     # cell -> [(lat, lon, node_id, cat)] konce obslužných cest
        self.end_count = defaultdict(int)  # node_id -> kolik obslužných cest v něm začíná/končí/prochází
        self.buildings = []               # (ring)

    def node(self, n):
        t = n.tags
        lat, lon = n.location.lat, n.location.lon
        if t.get('amenity') == 'loading_dock' or t.get('door') == 'loading_dock':
            self.docks[cell(lat, lon)].append((lat, lon, 1))
        elif t.get('entrance') in ('service', 'delivery', 'loading_dock'):
            self.docks[cell(lat, lon)].append((lat, lon, 2))
        elif t.get('amenity') == 'parking':
            self.parking[cell(lat, lon)].append((lat, lon))

    def way(self, w):
        t = w.tags
        hw = t.get('highway')
        b = t.get('building')
        park = t.get('amenity') == 'parking'
        if hw != 'service' and not b and not park:
            return
        try:
            pts = [(n.lat, n.lon) for n in w.nodes]
        except osmium.InvalidLocationError:
            return
        if len(pts) < 2:
            return
        if park:
            c = centroid(pts)
            self.parking[cell(*c)].append(c)
            if len(pts) >= 4 and pts[0] == pts[-1]:
                for cc in {cell(*p) for p in pts}:
                    self.park_rings[cc].append(pts)
        elif hw == 'service':
            sv = t.get('service')
            if sv in ('parking_aisle', 'drive-through', 'emergency_access'):
                return
            cat = 1 if (sv in ('delivery', 'loading') or t.get('access') == 'delivery'
                        or t.get('motor_vehicle') == 'delivery'
                        or t.get('hgv') in ('delivery', 'destination', 'designated')) else 0
            if cat == 0 and t.get('access') in ('private', 'no', 'customers'):
                cat = 2
            for p in pts:
                self.service[cell(*p)].append((p[0], p[1], cat))
            ids = [n.ref for n in w.nodes]
            for nid in ids:
                self.end_count[nid] += 1
            for i in (0, len(ids) - 1):
                self.ends[cell(*pts[i])].append((pts[i][0], pts[i][1], ids[i], cat))
        elif b and len(pts) >= 4 and pts[0] == pts[-1]:
            a = area_m2(pts)
            if a >= 1500 or (a >= 800 and b in BIG_KINDS):
                self.buildings.append(pts)


def around(index, lat, lon, r=1):
    cy, cx = cell(lat, lon)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            yield from index.get((cy + dy, cx + dx), ())


def pick(h, ring):
    c = centroid(ring)
    # 1) Zakreslená rampa / služební vchod u budovy.
    docks = [d for d in around(h.docks, *c) if dist_ring(ring, d[0], d[1]) < 40]
    if docks:
        docks.sort(key=lambda d: (d[2], dist_ring(ring, d[0], d[1])))
        d = docks[0]
        return d[0], d[1], d[2], 1
    serv = [p for p in around(h.service, *c) if dist_ring(ring, p[0], p[1]) < 60]
    # 2) Cesta pro zásobování – bod nejblíž budově.
    deliv = [p for p in serv if p[2] == 1]
    if deliv:
        p = min(deliv, key=lambda p: dist_ring(ring, p[0], p[1]))
        return p[0], p[1], 3, 1
    # 3) Odhad: obslužná cesta za budovou (od nejbližšího parkoviště).
    # 3) Odhad. Rampa nebývá na parkovišti: body na parkovišti / u něj se vyloučí.
    rings = list({id(r): r for r in around(h.park_rings, *c)}.values())
    parks = list(around(h.parking, *c))

    def park_dist(p):
        best = min((dist_ring(r, p[0], p[1]) for r in rings), default=1e9)
        if parks:
            best = min(best, min(dist(q, p) for q in parks) - 25)  # parkoviště jen jako bod: ~25 m
        return best

    best, bp = -1e18, None
    # a) slepé obslužné cesty končící u zdi budovy (typická rampa / zásobovací dvůr)
    for e in around(h.ends, *c):
        if h.end_count[e[2]] != 1:
            continue
        dr = dist_ring(ring, e[0], e[1])
        if dr > 30:
            continue
        pd = park_dist(e)
        if pd < 12:
            continue
        score = 60 + (25 if e[3] else 0) + min(pd, 80) - dr
        if score > best:
            best, bp = score, e
    # b) obslužná cesta podél budovy, co nejdál od parkoviště
    for p in serv:
        dr = dist_ring(ring, p[0], p[1])
        if dr > 25:
            continue
        pd = park_dist(p)
        if pd < 15:
            continue
        score = (15 if p[2] else 0) + min(pd, 80) - dr
        if score > best:
            best, bp = score, p
    if bp is None or best < 25:
        return None
    return bp[0], bp[1], 4, 0


def build(pbf, out):
    h = H()
    fp = osmium.FileProcessor(pbf).with_locations('flex_mem').with_filter(
        osmium.filter.KeyFilter('building', 'highway', 'amenity', 'door', 'entrance'))
    for o in fp:
        if o.is_node():
            h.node(o)
        elif o.is_way():
            h.way(o)
    print('budov:', len(h.buildings), 'ramp v OSM:', sum(len(v) for v in h.docks.values()))
    db = sqlite3.connect(out)
    db.executescript('''
        DROP TABLE IF EXISTS ramp; DROP TABLE IF EXISTS ramp_rtree;
        CREATE TABLE ramp(id INTEGER PRIMARY KEY, lat REAL, lon REAL, how INTEGER, sure INTEGER);
        CREATE VIRTUAL TABLE ramp_rtree USING rtree(id, minlat, maxlat, minlon, maxlon);
    ''')
    n = 0
    stats = defaultdict(int)
    for ring in h.buildings:
        r = pick(h, ring)
        if r is None:
            continue
        n += 1
        stats[r[2]] += 1
        lats = [p[0] for p in ring]
        lons = [p[1] for p in ring]
        db.execute('INSERT INTO ramp VALUES (?,?,?,?,?)', (n, round(r[0], 6), round(r[1], 6), r[2], r[3]))
        db.execute('INSERT INTO ramp_rtree VALUES (?,?,?,?,?)', (n, min(lats), max(lats), min(lons), max(lons)))
    db.commit()
    db.execute('VACUUM')
    db.close()
    print('ramp:', n, dict(stats))


if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2])

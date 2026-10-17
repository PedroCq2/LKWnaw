"""Hranice obcí ČR (OSM boundary=administrative, admin_level=8) do rejstříku v telefonu.

Pro režim zásobování: výjimka ze zákazů nad X t platí v obci vykládky – telefon pozná,
ve které obci leží bod, i bez internetu.

Tabulky:
  town(id, name, rings)            – rings = BLOB: počet kruhů, pak pro každý počet bodů a body
                                     (int32 lat·1e5, lon·1e5), zjednodušeno na ~25 m
  town_rtree(id, minlat, maxlat, minlon, maxlon) – R-strom obálek

Použití: python3 build_towns.py cz.osm.pbf search-cz.sqlite   (přidá tabulky do existující databáze)
"""
import sqlite3
import struct
import sys

import osmium

TOL = 0.00025  # ~25 m


def simplify(pts, tol=TOL):
    """Douglas–Peucker (iterativně)."""
    if len(pts) < 4:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    t2 = tol * tol
    while stack:
        a, b = stack.pop()
        (ay, ax), (by, bx) = pts[a], pts[b]
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            py, px = pts[i]
            if l2 == 0:
                d = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
                d = (px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2
            if d > best:
                best, bi = d, i
        if best > t2:
            keep[bi] = True
            stack.append((a, bi))
            stack.append((bi, b))
    return [p for p, k in zip(pts, keep) if k]


def build(pbf, out):
    db = sqlite3.connect(out)
    db.executescript('''
        DROP TABLE IF EXISTS town; DROP TABLE IF EXISTS town_rtree;
        CREATE TABLE town(id INTEGER PRIMARY KEY, name TEXT, rings BLOB);
        CREATE VIRTUAL TABLE town_rtree USING rtree(id, minlat, maxlat, minlon, maxlon);
    ''')
    fp = (osmium.FileProcessor(pbf)
          .with_areas(osmium.filter.TagFilter(('boundary', 'administrative')))
          .with_filter(osmium.filter.TagFilter(('boundary', 'administrative'))))
    n = 0
    for o in fp:
        if not o.is_area():
            continue
        name = o.tags.get('name')
        level = o.tags.get('admin_level')
        # Obce = úroveň 8; Praha je zároveň kraj (úroveň 4) a jako obec v datech není.
        if not name or not (level == '8' or (level == '4' and name in ('Praha', 'Hlavní město Praha'))):
            continue
        if level == '4':
            name = 'Praha'
        rings = []
        try:
            for outer in o.outer_rings():
                rings.append([(nd.lat, nd.lon) for nd in outer])
                for inner in o.inner_rings(outer):
                    rings.append([(nd.lat, nd.lon) for nd in inner])
        except Exception:
            continue
        rings = [simplify(r) for r in rings if len(r) >= 4]
        rings = [r for r in rings if len(r) >= 4]
        if not rings:
            continue
        blob = bytearray(struct.pack('<i', len(rings)))
        for r in rings:
            blob += struct.pack('<i', len(r))
            for lat, lon in r:
                blob += struct.pack('<ii', round(lat * 1e5), round(lon * 1e5))
        lats = [p[0] for r in rings for p in r]
        lons = [p[1] for r in rings for p in r]
        n += 1
        db.execute('INSERT INTO town VALUES (?,?,?)', (n, name, bytes(blob)))
        db.execute('INSERT INTO town_rtree VALUES (?,?,?,?,?)', (n, min(lats), max(lats), min(lons), max(lons)))
    db.commit()
    db.execute('VACUUM')
    db.close()
    print('obcí:', n)


if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2])

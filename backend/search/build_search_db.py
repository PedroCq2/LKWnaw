"""Rejstřík míst ČR pro vyhledávání v telefonu bez internetu (z OSM PBF → SQLite FTS5).

Tabulky:
  poi(name, city, kind, lat, lon)   – obce, ulice, firmy, sklady, obchody, pumpy, parkoviště (FTS5)
  street(id, name, city, postcode)  – ulice/obce pro adresy (+ FTS5 street_fts)
  addr(sid, num, lat, lon)          – adresní body (číslo popisné/orientační), index podle sid

Použití: python3 build_search_db.py cz.osm.pbf search-cz.sqlite
"""
import sqlite3
import sys

import osmium

KINDS = {
    ('shop', 'supermarket'): 'Supermarket', ('shop', 'wholesale'): 'Velkoobchod',
    ('building', 'warehouse'): 'Sklad', ('landuse', 'industrial'): 'Průmyslový areál',
    ('landuse', 'commercial'): 'Komerční areál', ('landuse', 'retail'): 'Obchodní zóna',
    ('amenity', 'fuel'): 'Čerpací stanice', ('amenity', 'parking'): 'Parkoviště',
    ('highway', 'rest_area'): 'Odpočívka', ('highway', 'services'): 'Odpočívka s ČS',
    ('office', 'company'): 'Firma', ('man_made', 'works'): 'Továrna', ('industrial', 'warehouse'): 'Sklad',
    ('shop', 'truck_repair'): 'Servis nákladních vozidel', ('shop', 'tyres'): 'Pneuservis',
    ('shop', 'car_repair'): 'Autoservis', ('shop', 'doityourself'): 'Hobbymarket',
}
PLACE = {'city': 'Město', 'town': 'Město', 'village': 'Obec', 'suburb': 'Část obce',
         'hamlet': 'Osada', 'neighbourhood': 'Část obce', 'quarter': 'Část obce', 'locality': 'Místo'}


def kind_of(t):
    for (k, v), label in KINDS.items():
        if t.get(k) == v:
            return label
    if 'shop' in t:
        return 'Obchod'
    if 'office' in t or 'craft' in t:
        return 'Firma'
    if t.get('landuse') == 'industrial' or 'industrial' in t:
        return 'Průmyslový areál'
    return None


class H(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.poi = []
        self.streets = {}  # (name, city, postcode) -> id
        self.addr = []

    def _street(self, name, city, pc):
        key = (name, city, pc)
        sid = self.streets.get(key)
        if sid is None:
            sid = self.streets[key] = len(self.streets) + 1
        return sid

    def _handle(self, t, lat, lon, is_way):
        name = t.get('name')
        if 'place' in t and name and t['place'] in PLACE:
            self.poi.append((name, t.get('is_in:municipality', ''), PLACE[t['place']], lat, lon))
            return
        num = t.get('addr:housenumber') or t.get('addr:conscriptionnumber')
        if num:
            street = t.get('addr:street') or t.get('addr:place')
            city = t.get('addr:city') or t.get('addr:place') or ''
            if street:
                sid = self._street(street, city, t.get('addr:postcode', '').replace(' ', ''))
                # „814/65“ = č. popisné / č. orientační → hledat jde podle obou
                nums = {num, t.get('addr:conscriptionnumber'), t.get('addr:streetnumber')}
                for part in list(nums):
                    if part and '/' in part:
                        nums.update(x.strip() for x in part.split('/'))
                for n in nums:
                    if n:
                        self.addr.append((sid, n.strip(), round(lat * 1e6), round(lon * 1e6)))
            if not (name and kind_of(t)):
                return
        if name:
            k = kind_of(t)
            if k:
                self.poi.append((name, t.get('addr:city', ''), k, lat, lon))

    def node(self, n):
        if n.tags:
            self._handle(n.tags, n.location.lat, n.location.lon, False)

    def way(self, w):
        t = w.tags
        if 'highway' in t and 'name' in t and t['highway'] not in ('footway', 'path', 'cycleway', 'steps', 'bus_stop'):
            try:
                mid = w.nodes[len(w.nodes) // 2]
                self.poi.append((t['name'], t.get('addr:city', ''), 'Ulice', mid.location.lat, mid.location.lon))
            except Exception:
                pass
            return
        if not (('addr:housenumber' in t or 'addr:conscriptionnumber' in t) or ('name' in t and kind_of(t))):
            return
        try:
            locs = [n.location for n in w.nodes if n.location.valid()]
            lat = sum(l.lat for l in locs) / len(locs)
            lon = sum(l.lon for l in locs) / len(locs)
        except Exception:
            return
        self._handle(t, lat, lon, True)


def main(pbf, out):
    h = H()
    h.apply_file(pbf, locations=True, idx='flex_mem')
    # Ulice: jedna položka na (název, obec) – blízké úseky stejné ulice sloučit.
    seen, pois = set(), []
    for p in h.poi:
        if p[2] == 'Ulice':
            key = (p[0], round(p[3], 2), round(p[4], 2))
            if key in seen:
                continue
            seen.add(key)
        pois.append(p)
    # Obec k firmám/ulicím bez addr:city: nejbližší obec/město (mřížka ~0,1°).
    def grid_of(kinds):
        g = {}
        for p in h.poi:
            if p[2] in kinds:
                g.setdefault((round(p[3], 1), round(p[4], 1)), []).append(p)
        return g

    small = grid_of(('Město', 'Obec', 'Část obce', 'Osada'))
    towns = grid_of(('Město', 'Obec'))

    def nearest(g, lat, lon):
        best, bd = '', 1e9
        for dy in (-0.1, 0, 0.1):
            for dx in (-0.1, 0, 0.1):
                for p in g.get((round(lat + dy, 1), round(lon + dx, 1)), ()):
                    d = (p[3] - lat) ** 2 + ((p[4] - lon) * 0.65) ** 2
                    if d < bd:
                        best, bd = p[0], d
        return best

    def city_of(c, k, la, lo):
        if k in ('Město', 'Obec'):
            return c
        names = [x for x in (c, nearest(small, la, lo), nearest(towns, la, lo)) if x]
        return ', '.join(dict.fromkeys(names))  # např. „Doubravice, Modletice“

    pois = [(n, city_of(c, k, la, lo), k, la, lo) for (n, c, k, la, lo) in pois]
    db = sqlite3.connect(out)
    db.executescript('''
      PRAGMA page_size=4096;
      CREATE VIRTUAL TABLE poi USING fts5(name, city, kind UNINDEXED, lat UNINDEXED, lon UNINDEXED,
        tokenize="unicode61 remove_diacritics 2");
      CREATE TABLE street(id INTEGER PRIMARY KEY, name TEXT, city TEXT, postcode TEXT);
      CREATE VIRTUAL TABLE street_fts USING fts5(name, city, postcode, content='street', content_rowid='id',
        tokenize="unicode61 remove_diacritics 2");
      CREATE TABLE addr(sid INTEGER, num TEXT, lat INTEGER, lon INTEGER,
        PRIMARY KEY (sid, num, lat, lon)) WITHOUT ROWID;
    ''')
    db.executemany('INSERT INTO poi VALUES (?,?,?,?,?)', pois)
    db.executemany('INSERT INTO street VALUES (?,?,?,?)',
                   [(i, n, c, pc) for (n, c, pc), i in h.streets.items()])
    db.execute("INSERT INTO street_fts(street_fts) VALUES ('rebuild')")
    db.executemany('INSERT OR IGNORE INTO addr VALUES (?,?,?,?)', h.addr)
    db.executescript('''
      CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
      INSERT INTO poi(poi) VALUES ('optimize');
      INSERT INTO street_fts(street_fts) VALUES ('optimize');
    ''')
    db.commit()
    db.execute('VACUUM')
    db.close()
    print('poi', len(pois), 'streets', len(h.streets), 'addr', len(h.addr))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

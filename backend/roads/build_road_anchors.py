#!/usr/bin/env python3
"""Body na českých dálnicích pro „naviguj … přes Mělník a pak po D8“.

Pro každou dálnici spočítá Valhalla trasu mezi jejími konci, vybere úseky, které nesou označení
dálnice (D8 …), a uloží bod zhruba každé 2 km ve směru staničení. Aplikace z nich vybere vjezd
a výjezd a pošle je Valhalle jako průjezdní body (správný pás podle směru jízdy).

Použití: python3 build_road_anchors.py [URL Valhally] > ../../app/lib/services/road_anchors.dart
"""
import json
import math
import sys
import urllib.request

URL = sys.argv[1] if len(sys.argv) > 1 else 'https://valhalla1.openstreetmap.de'
STEP_M = 2000

# Dálnice: konce (lat, lon) ve směru staničení, případně mezilehlé body, kudy trasa vede.
ROADS = {
    'D0': [(50.0485, 14.2905), (49.9690, 14.4020), (49.9900, 14.6420), (50.1300, 14.6160)],
    'D1': [(50.0380, 14.5050), (49.2050, 16.5600), (49.8300, 18.1900), (49.9230, 18.4250)],
    'D2': [(49.1630, 16.6500), (48.7020, 16.9790)],
    'D3': [(49.9070, 14.7160), (49.4130, 14.6750), (48.9200, 14.4700), (48.7600, 14.4800)],
    'D4': [(49.9770, 14.4000), (49.6800, 14.0300), (49.3600, 14.1100)],
    'D5': [(50.0450, 14.3050), (49.7400, 13.3200), (49.6720, 12.5520)],
    'D6': [(50.0740, 14.2940), (50.1800, 13.7300), (50.2200, 12.9000), (50.0800, 12.3800)],
    'D7': [(50.0950, 14.2700), (50.2300, 14.0800), (50.4500, 13.4100)],
    'D8': [(50.1650, 14.4520), (50.6600, 13.9900), (50.7850, 13.9450)],
    'D10': [(50.1250, 14.5700), (50.4100, 14.9200), (50.5800, 15.1300)],
    'D11': [(50.1150, 14.6250), (50.2100, 15.6800), (50.3500, 15.9100)],
    'D35': [(50.2600, 15.6900), (50.0700, 15.8200), (49.7600, 16.9300), (49.5300, 17.5700)],
    'D46': [(49.2800, 16.9900), (49.4600, 17.0800), (49.5650, 17.2100)],
    'D48': [(49.5800, 17.7900), (49.6800, 18.3300), (49.7450, 18.5900)],
    'D49': [(49.3150, 17.4500), (49.2900, 17.6800)],
    'D52': [(49.1450, 16.6280), (48.9800, 16.5600)],
    'D55': [(49.3050, 17.4300), (49.1300, 17.4600), (49.0400, 17.4600)],
    'D56': [(49.8200, 18.2400), (49.6700, 18.3300)],
}


def post(action, body):
    req = urllib.request.Request(
        f'{URL.rstrip("/")}/{action}',
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json', 'User-Agent': 'LKWnav-build/1.0'},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def decode(enc):
    out, i, lat, lon = [], 0, 0, 0
    while i < len(enc):
        for k in range(2):
            res = shift = 0
            while True:
                b = ord(enc[i]) - 63
                i += 1
                res |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            v = ~(res >> 1) if res & 1 else res >> 1
            if k == 0:
                lat += v
            else:
                lon += v
        out.append((lat / 1e6, lon / 1e6))
    return out


def dist(a, b):
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    x = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dl / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(x))


def bearing(a, b):
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def edge_names(shape):
    """Jména (bez mezer) a třída silnice pro každý úsek shape[i] → shape[i+1] (po kusech ~60 km)."""
    out = [None] * (len(shape) - 1)
    i = 0
    while i < len(shape) - 1:
        j, d = i, 0.0
        while j < len(shape) - 1 and d < 60000:
            d += dist(shape[j], shape[j + 1])
            j += 1
        attrs = post('trace_attributes', {
            'shape': [{'lat': a, 'lon': b} for (a, b) in shape[i:j + 1]],
            'costing': 'auto',
            'shape_match': 'map_snap',
            'filters': {'attributes': ['edge.names', 'edge.road_class', 'edge.use',
                                       'edge.begin_shape_index', 'edge.end_shape_index'],
                        'action': 'include'},
        })
        for e in attrs.get('edges', []):
            ok = e.get('use') != 'ramp' and e.get('road_class') in ('motorway', 'trunk')
            names = {n.replace(' ', '') for n in e.get('names', [])} if ok else set()
            for k in range(e['begin_shape_index'], e['end_shape_index']):
                if i + k < len(out):
                    out[i + k] = names
        i = j
    return out


def anchors(ref, pts):
    # Body přichycené na dálnici (ne na sjezd) a na pás ve směru jízdy.
    locs = []
    for k, p in enumerate(pts):
        a, b = (pts[k - 1], p) if k > 0 else (p, pts[1])
        locs.append({
            'lat': p[0], 'lon': p[1],
            'type': 'through' if 0 < k < len(pts) - 1 else 'break',
            'heading': round(bearing(a, b)), 'heading_tolerance': 70,
            'search_filter': {'min_road_class': 'motorway', 'exclude_ramp': True},
        })
    trip = post('route', {'locations': locs, 'costing': 'auto'})['trip']
    shape = []
    for leg in trip['legs']:
        s = decode(leg['shape'])
        shape.extend(s if not shape else s[1:])
    names = edge_names(shape)
    out, total, last, covered, run = [], 0.0, None, 0.0, None
    for i in range(1, len(shape)):
        d = dist(shape[i - 1], shape[i])
        total += d
        if ref not in (names[i - 1] or ()):
            run = None
            continue
        if run is None:
            run = total - d
        covered += d
        if total - run >= 500 and (last is None or total - last >= STEP_M):
            out.append(shape[i])
            last = total
    print(f'// {ref}: trasa {total / 1000:.0f} km, z toho {ref} {covered / 1000:.0f} km, {len(out)} bodů',
          file=sys.stderr)
    return out


def main():
    lines = [
        '// Vygenerováno: backend/roads/build_road_anchors.py (OSM přes Valhallu). Neupravovat ručně.',
        '',
        '/// Body na českých dálnicích zhruba po 2 km ve směru staničení: lat, lon (× 1e5) za sebou.',
        'const roadAnchorData = <String, List<int>>{',
    ]
    for ref, pts in ROADS.items():
        a = anchors(ref, pts)
        if not a:
            continue
        nums = [str(round(v * 1e5)) for p in a for v in p]
        lines.append(f"  '{ref}': [")
        for i in range(0, len(nums), 12):
            lines.append('    ' + ', '.join(nums[i:i + 12]) + ',')
        lines.append('  ],')
    lines.append('};')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()

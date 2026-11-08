#!/usr/bin/env python3
"""
Ask your map / Parla con la tua mappa - generatore della flotta sintetica.

Input (tutti GeoJSON/JSON una riga per feature):
  --roads   strade OSM dell'Abruzzo esportate da BigQuery (02_export.sql)
  --schools scuole OSM esportate da BigQuery (02_export.sql)            [opzionale]
  --flood   aree ISPRA prodotte da load_flood.sh (proprieta' "hazard")    [opzionale]

Output (in --out):
  positions_raw.csv.gz, incidents.csv, vehicles.csv, depots.csv, report.json

Storie piantate:
  1. hotspot di eccessi di velocita' sulla costa Pescara-Montesilvano
  2. MZ-07: 3 incidenti negli ultimi 90 giorni a meno di 5 km da zone P3 (Val Pescara)
  3. deposito Val Pescara dentro un'area P2 (non P3)
  4. frenate brusche concentrate vicino a 2 scuole di Pescara
  5. eccessi notturni concentrati su MZ-23
  6. passaggi attorno alla sede del DevFest, ogni giorno e soprattutto 7-8 novembre

Dipendenze: pip install numpy networkx scipy shapely
"""
import argparse
import csv
import datetime as dt
import gzip
import json
import math
import os
import random
import re
import sys
import time
from zoneinfo import ZoneInfo

import networkx as nx
import numpy as np
from scipy.spatial import cKDTree
from shapely import STRtree
from shapely.geometry import Point, shape
from shapely.ops import transform

ROME = ZoneInfo("Europe/Rome")
LAT0 = 42.3
KX = math.cos(math.radians(LAT0)) * 111_320.0   # metri per grado di longitudine
KY = 110_574.0                                    # metri per grado di latitudine

VENUE = (14.22502, 42.45187)  # Universita' d'Annunzio, Viale Pindaro, Pescara (da rifinire)
COAST_HOTSPOT = (14.150, 42.462, 14.218, 42.530)  # lon_min, lat_min, lon_max, lat_max
VAL_PESCARA = (13.95, 42.25, 14.20, 42.40)
PESCARA_CITY = (14.17, 42.43, 14.25, 42.49)

DEPOTS = [
    # depot_id, nome, lon, lat, n_mezzi
    ("D1", "Deposito Pescara", 14.1850, 42.4300, 20),
    ("D2", "Deposito Val Pescara", 14.1300, 42.3600, 15),
    ("D3", "Deposito L'Aquila", 13.4000, 42.3500, 13),
    ("D4", "Deposito Teramo", 13.7000, 42.6600, 12),
]
HIGHWAY_DEFAULT = {
    "motorway": 130, "motorway_link": 80, "trunk": 110, "trunk_link": 70,
    "primary": 90, "primary_link": 60, "secondary": 90, "secondary_link": 60,
    "tertiary": 70, "tertiary_link": 50, "unclassified": 50, "residential": 50,
    "living_street": 30, "service": 30,
}
KINDS = ["tamponamento", "uscita di strada", "urto ostacolo", "manovra in retromarcia", "urto laterale"]


def proj(lon, lat):
    return lon * KX, lat * KY


def proj_geom(g):
    return transform(lambda x, y, z=None: (np.asarray(x) * KX, np.asarray(y) * KY), g)


def parse_limit(tag, highway):
    if tag:
        t = tag.strip().lower()
        m = re.match(r"^(\d+)", t)
        if m:
            v = int(m.group(1))
            if "mph" in t:
                v = int(v * 1.609)
            if 5 <= v <= 150:
                return v
        if "urban" in t:
            return 50
        if "rural" in t:
            return 90
        if "motorway" in t:
            return 130
        if "trunk" in t:
            return 110
    return HIGHWAY_DEFAULT.get(highway or "", 50)


def in_box(lon, lat, box):
    return box[0] <= lon <= box[2] and box[1] <= lat <= box[3]


# ----------------------------------------------------------------------------- input
def read_jsonl(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)


def geom_of(rec):
    """Record da EXPORT DATA (campo geojson stringa) oppure feature GeoJSON."""
    if "geojson" in rec:
        g = rec["geojson"]
        return shape(json.loads(g) if isinstance(g, str) else g)
    if "geometry" in rec:
        return shape(rec["geometry"])
    raise ValueError("record senza geometria")


def build_graph(roads_path):
    G = nx.Graph()
    n_roads = 0
    for rec in read_jsonl(roads_path):
        hw = rec.get("highway")
        lim = parse_limit(rec.get("maxspeed_tag"), hw)
        g = geom_of(rec)
        lines = [g] if g.geom_type == "LineString" else list(getattr(g, "geoms", []))
        for ln in lines:
            cs = [(round(x, 7), round(y, 7)) for x, y in ln.coords]
            for a, b in zip(cs[:-1], cs[1:]):
                if a == b:
                    continue
                L = math.hypot((b[0] - a[0]) * KX, (b[1] - a[1]) * KY)
                tt = L / (lim / 3.6)
                if G.has_edge(a, b) and G[a][b]["time"] <= tt:
                    continue
                G.add_edge(a, b, length=L, limit=lim, time=tt)
        n_roads += 1
    comp = max(nx.connected_components(G), key=len)
    G = G.subgraph(comp).copy()
    print(f"[grafo] {n_roads} strade, {G.number_of_nodes()} nodi, {G.number_of_edges()} archi", flush=True)
    return G


class Snapper:
    def __init__(self, G):
        self.nodes = list(G.nodes)
        arr = np.array(self.nodes)
        self.tree = cKDTree(np.c_[arr[:, 0] * KX, arr[:, 1] * KY])

    def nearest(self, lon, lat, k=1):
        d, i = self.tree.query([lon * KX, lat * KY], k=k)
        if k == 1:
            return self.nodes[i]
        return [self.nodes[j] for j in np.atleast_1d(i)]

    def within(self, lon, lat, radius_m):
        idx = self.tree.query_ball_point([lon * KX, lat * KY], radius_m)
        return [self.nodes[j] for j in idx]


def load_flood(path):
    by_h = {"P1": [], "P2": [], "P3": []}
    for rec in read_jsonl(path):
        props = rec.get("properties", rec)
        h = str(props.get("hazard") or "").upper()
        m = re.search(r"P[123]", h)
        if not m:
            continue
        try:
            g = geom_of(rec)
        except Exception:
            continue
        if not g.is_valid:
            g = g.buffer(0)
        by_h[m.group(0)].append(proj_geom(g))
    print("[ispra] " + ", ".join(f"{k}: {len(v)} poligoni" for k, v in by_h.items()), flush=True)
    return {k: (STRtree(v), v) for k, v in by_h.items() if v}


def near(flood, hz, lon, lat, dist_m):
    if hz not in flood:
        return False
    tree, _ = flood[hz]
    p = Point(lon * KX, lat * KY)
    return len(tree.query(p, predicate="dwithin", distance=dist_m)) > 0


def inside(flood, hz, lon, lat):
    if hz not in flood:
        return False
    tree, _ = flood[hz]
    return len(tree.query(Point(lon * KX, lat * KY), predicate="within")) > 0


# ----------------------------------------------------------------------------- percorsi
class Route:
    __slots__ = ("lon", "lat", "seglen", "seglim", "segmid_lon", "segmid_lat", "hot")

    def __init__(self, G, path):
        a = np.array(path)
        self.lon, self.lat = a[:, 0], a[:, 1]
        self.seglen = np.array([G[u][v]["length"] for u, v in zip(path[:-1], path[1:])])
        self.seglim = np.array([G[u][v]["limit"] for u, v in zip(path[:-1], path[1:])], dtype=float)
        self.segmid_lon = (self.lon[:-1] + self.lon[1:]) / 2
        self.segmid_lat = (self.lat[:-1] + self.lat[1:]) / 2
        b = COAST_HOTSPOT
        self.hot = ((self.segmid_lon >= b[0]) & (self.segmid_lon <= b[2]) &
                    (self.segmid_lat >= b[1]) & (self.segmid_lat <= b[3]))


def compute_routes(G, origins_targets):
    """origins_targets: {origine: [destinazioni]} -> {(o, d): Route}"""
    routes = {}
    for o, ds in origins_targets.items():
        # predecessori invece dei percorsi completi: memoria contenuta anche con ~500k nodi
        pred, _ = nx.dijkstra_predecessor_and_distance(G, o, weight="time")
        for d in ds:
            if d == o or d not in pred:
                continue
            path, cur = [d], d
            while cur != o:
                cur = pred[cur][0]
                path.append(cur)
            path.reverse()
            if len(path) > 2:
                routes[(o, d)] = Route(G, path)
    return routes


def drive(route, t0, factor, rng, night=False):
    """Percorre un Route partendo all'epoch t0. Ritorna dict di array + epoch di arrivo."""
    lim = route.seglim
    v = lim * factor * np.clip(1 + 0.06 * rng.standard_normal(len(lim)), 0.8, 1.25)
    v = np.where(route.hot, v * 1.22, v)                       # storia 1: costa
    if night:
        v = v * 1.30                                           # storia 5: MZ-23 di notte
    urban = lim <= 50
    v = np.where(urban, v * rng.uniform(0.55, 1.0), v)          # traffico urbano
    v = np.clip(v, 8, np.minimum(lim * 1.75, 175))
    seg_t = route.seglen / (v / 3.6)
    cum = np.concatenate([[0.0], np.cumsum(seg_t)])
    total = cum[-1]
    if total < 30:
        return None, t0 + total
    ts_rel = np.arange(rng.uniform(0, 30), total, 30.0)
    lon = np.interp(ts_rel, cum, route.lon)
    lat = np.interp(ts_rel, cum, route.lat)
    seg = np.clip(np.searchsorted(cum, ts_rel, side="right") - 1, 0, len(v) - 1)
    spd = np.round(v[seg] + rng.normal(0, 1.5, len(seg))).astype(int)
    out = dict(t=t0 + ts_rel, lon=lon, lat=lat, speed=np.maximum(spd, 0), limit=lim[seg].astype(int))
    return out, t0 + total


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roads", required=True)
    ap.add_argument("--schools")
    ap.add_argument("--flood")
    ap.add_argument("--out", default="out")
    ap.add_argument("--end", default="2026-11-08T10:50", help="fine dati, ora locale Europe/Rome")
    ap.add_argument("--days", type=int, default=120)
    ap.add_argument("--vehicles-scale", type=float, default=1.0, help="per test rapidi, es. 0.2")
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--venue", default=f"{VENUE[0]},{VENUE[1]}", help="lon,lat della sala del talk")
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    random.seed(a.seed)
    os.makedirs(a.out, exist_ok=True)
    venue = tuple(float(x) for x in a.venue.split(","))
    end_local = dt.datetime.fromisoformat(a.end).replace(tzinfo=ROME)
    end_ep = end_local.timestamp()
    last_day = end_local.date()
    first_day = last_day - dt.timedelta(days=a.days - 1)

    t_start = time.time()
    G = build_graph(a.roads)
    snap = Snapper(G)
    flood = load_flood(a.flood) if a.flood else {}

    # --- depositi (storia 3: Val Pescara in P2 e non in P3)
    depots = []
    for did, name, lon, lat, n in DEPOTS:
        node = snap.nearest(lon, lat)
        if did == "D2" and "P2" in flood:
            cands = snap.within(lon, lat, 15_000)
            cands = [c for c in cands if in_box(c[0], c[1], VAL_PESCARA)
                     and inside(flood, "P2", *c) and not inside(flood, "P3", *c)]
            if cands:
                node = min(cands, key=lambda c: (c[0] - lon) ** 2 + (c[1] - lat) ** 2)
            else:
                print("[attenzione] nessun nodo stradale in P2 vicino a Chieti Scalo: deposito non piantato", flush=True)
        depots.append(dict(depot_id=did, name=name, node=node, n=max(1, round(n * a.vehicles_scale))))

    # --- cantieri per deposito
    all_nodes = snap.nodes
    for d in depots:
        lon, lat = d["node"]
        near_nodes = snap.within(lon, lat, 35_000)
        sites = random.sample(near_nodes, min(12, len(near_nodes)))
        if d["depot_id"] == "D2":   # MZ-07 lavora lungo la Val Pescara
            vp = [n for n in near_nodes if in_box(n[0], n[1], VAL_PESCARA)]
            if flood.get("P3"):
                vp_near = [n for n in vp if near(flood, "P3", *n, 3000)]
                vp = vp_near or vp
            sites = random.sample(vp, min(6, len(vp))) + sites[:6]
        if d["depot_id"] == "D1":   # un paio di cantieri sulla costa e in citta'
            coast = [n for n in near_nodes if in_box(n[0], n[1], COAST_HOTSPOT)]
            sites = random.sample(coast, min(3, len(coast))) + sites[:9]
        d["sites"] = sites
    venue_node = snap.nearest(*venue)

    # --- percorsi
    ot = {}
    for d in depots:
        pts = [d["node"]] + d["sites"]
        for o in pts:
            ot.setdefault(o, set()).update(p for p in pts if p != o)
    d1 = depots[0]
    ot.setdefault(d1["node"], set()).add(venue_node)
    ot.setdefault(venue_node, set()).add(d1["node"])
    routes = compute_routes(G, ot)
    print(f"[percorsi] {len(routes)} percorsi calcolati ({time.time() - t_start:.0f}s)", flush=True)

    # --- scuole (storia 4): le 2 scuole di Pescara piu' attraversate dai percorsi
    hot_schools = []
    if a.schools:
        schools = []
        for rec in read_jsonl(a.schools):
            g = geom_of(rec)
            p = g.centroid if g.geom_type != "Point" else g
            if in_box(p.x, p.y, PESCARA_CITY):
                schools.append((rec.get("name") or rec.get("poi_id"), p.x, p.y))
        if schools:
            sx = np.array([[s[1] * KX, s[2] * KY] for s in schools])
            stree = cKDTree(sx)
            hits = np.zeros(len(schools))
            for r in routes.values():
                for lst in stree.query_ball_point(np.c_[r.lon * KX, r.lat * KY], 300):
                    for j in set(lst):
                        hits[j] += 1
            order = np.argsort(-hits)
            hot_schools = [schools[i] for i in order[:2] if hits[i] > 0]
        print(f"[scuole] {len(schools)} scuole a Pescara, scelte: {[s[0] for s in hot_schools]}", flush=True)
    school_tree = cKDTree(np.array([[s[1] * KX, s[2] * KY] for s in hot_schools])) if hot_schools else None

    # --- mezzi
    vehicles = []
    k = 1
    for d in depots:
        for _ in range(d["n"]):
            vehicles.append(dict(vehicle_id=f"MZ-{k:02d}", depot=d,
                                 type=random.choice(["furgone", "furgone", "autocarro", "pick-up"]),
                                 factor=float(np.clip(rng.normal(0.93, 0.04), 0.84, 1.03))))
            k += 1
    vid = {v["vehicle_id"]: v for v in vehicles}
    # MZ-07 deve stare in Val Pescara, MZ-23 a Pescara
    def force(vehicle_id, depot_id):
        if vehicle_id in vid:
            vid[vehicle_id]["depot"] = next(d for d in depots if d["depot_id"] == depot_id)
    force("MZ-07", "D2")
    force("MZ-23", "D1")
    for v in vehicles:
        if v["vehicle_id"] in ("MZ-12", "MZ-31", "MZ-44"):
            v["factor"] = 1.04   # qualche autista "spinto" per rendere varie le classifiche

    # --- incidenti casuali: slot (mezzo, giorno)
    days = [first_day + dt.timedelta(days=i) for i in range(a.days)]
    others = [v for v in vehicles if v["vehicle_id"] != "MZ-07"]
    slots = {}
    for _ in range(max(5, round(55 * a.vehicles_scale))):
        slots[(random.choice(others)["vehicle_id"], random.choice(days))] = True
    mz07_from = last_day - dt.timedelta(days=85)
    mz07_to = last_day - dt.timedelta(days=4)
    mz07_cands = []           # (epoch, lon, lat) di MZ-07 vicino a P3 negli ultimi 90 giorni
    incidents = []
    near_p3_count = {}

    # --- generazione
    out_pos = gzip.open(os.path.join(a.out, "positions_raw.csv.gz"), "wt", encoding="utf-8", newline="")
    out_pos.write("vehicle_id,ts,lat,lon,speed_kmh,speed_limit_kmh,harsh_event\n")
    n_rows = 0
    venue_trips = 0

    def routes_from(node, pool):
        return [r for r in pool if r[0] == node and r in routes]

    def emit(v, seg):
        nonlocal n_rows
        n = len(seg["t"])
        harsh = np.full(n, "", dtype=object)
        p_brake = np.full(n, 0.0015)
        if school_tree is not None:
            dist, _ = school_tree.query(np.c_[seg["lon"] * KX, seg["lat"] * KY])
            p_brake = np.where(dist <= 300, 0.08, p_brake)
        u = rng.random(n)
        harsh[u < p_brake] = "HARSH_BRAKING"
        harsh[(u >= p_brake) & (u < p_brake + 0.0008)] = "HARSH_ACCELERATION"
        ts = np.datetime_as_string(seg["t"].astype("datetime64[s]"), unit="s")
        lines = [f"{v['vehicle_id']},{t.replace('T', ' ')},{la:.6f},{lo:.6f},{s},{l},{h}"
                 for t, la, lo, s, l, h in zip(ts, seg["lat"], seg["lon"], seg["speed"], seg["limit"], harsh)]
        out_pos.write("\n".join(lines) + "\n")
        n_rows += n
        return seg

    for day in days:
        wd = day.weekday()
        p_active = 0.92 if wd < 5 else (0.30 if wd == 5 else 0.10)
        special = day >= last_day - dt.timedelta(days=1)   # 7 e 8 novembre
        venue_today = set(random.sample([v["vehicle_id"] for v in vehicles if v["depot"] is d1],
                                        min(6 if special else 2, sum(1 for v in vehicles if v["depot"] is d1))))
        for v in vehicles:
            vid_ = v["vehicle_id"]
            d = v["depot"]
            segs = []
            active = random.random() < p_active or vid_ in venue_today
            if active:
                start = dt.datetime.combine(day, dt.time(7, 0), ROME) + dt.timedelta(minutes=random.uniform(0, 60))
                t = start.timestamp()
                target = random.uniform(4.5, 6.0) * 3600
                driven = 0.0
                pos = d["node"]
                pool = [(o, x) for (o, x) in routes if o in [d["node"]] + d["sites"]]
                if vid_ in venue_today and (d["node"], venue_node) in routes:
                    for leg in [(d["node"], venue_node), (venue_node, d["node"])]:
                        seg, t2 = drive(routes[leg], t, v["factor"], rng)
                        if seg is not None:
                            segs.append(seg)
                        driven += t2 - t
                        t = t2 + random.uniform(600, 1800)
                    venue_trips += 1
                guard = 0
                while driven < target and guard < 8:
                    guard += 1
                    opts = routes_from(pos, pool)
                    if not opts:
                        break
                    leg = random.choice(opts)
                    if driven > target * 0.8 and (pos, d["node"]) in routes:
                        leg = (pos, d["node"])
                    seg, t2 = drive(routes[leg], t, v["factor"], rng)
                    if seg is not None:
                        segs.append(seg)
                    driven += t2 - t
                    t = t2 + random.uniform(600, 1800)
                    pos = leg[1]
                    if pos == d["node"] and driven > target * 0.8:
                        break
                if pos != d["node"] and (pos, d["node"]) in routes:
                    seg, t2 = drive(routes[(pos, d["node"])], t, v["factor"], rng)
                    if seg is not None:
                        segs.append(seg)
            # storia 5: MZ-23 turni notturni
            if vid_ == "MZ-23" and random.random() < 0.45:
                pool = [(o, x) for (o, x) in routes if o == d["node"]]
                if pool:
                    leg = random.choice(pool)
                    t = (dt.datetime.combine(day, dt.time(22, 0), ROME) + dt.timedelta(minutes=random.uniform(0, 80))).timestamp()
                    seg, t2 = drive(routes[leg], t, v["factor"], rng, night=True)
                    if seg is not None:
                        segs.append(seg)
                    back = (leg[1], leg[0])
                    if back in routes:
                        seg, _ = drive(routes[back], t2 + 900, v["factor"], rng, night=True)
                        if seg is not None:
                            segs.append(seg)
            # taglio alla fine dei dati (8 novembre, prima del talk)
            segs = [{k2: s[k2][s["t"] <= end_ep] for k2 in s} for s in segs]
            segs = [s for s in segs if len(s["t"])]
            for s in segs:
                emit(v, s)
            if not segs:
                continue
            # incidenti casuali
            if (vid_, day) in slots:
                # gli altri mezzi: al massimo 1 incidente vicino a P3, cosi' MZ-07 resta la risposta
                for _try in range(30):
                    s = random.choice(segs)
                    i = random.randrange(len(s["t"]))
                    lo, la = s["lon"][i], s["lat"][i]
                    is_near = "P3" in flood and near(flood, "P3", lo, la, 6000)
                    if not (is_near and near_p3_count.get(vid_, 0) >= 1):
                        break
                else:
                    is_near = None
                if is_near is not None:
                    near_p3_count[vid_] = near_p3_count.get(vid_, 0) + int(bool(is_near))
                    incidents.append((vid_, s["t"][i], lo, la,
                                      random.choices([1, 2, 3, 4, 5], [30, 30, 20, 15, 5])[0], random.choice(KINDS)))
            # candidati MZ-07 (storia 2)
            if vid_ == "MZ-07" and mz07_from <= day <= mz07_to:
                for s in segs:
                    for i in range(0, len(s["t"]), 10):
                        lo, la = s["lon"][i], s["lat"][i]
                        ok = in_box(lo, la, VAL_PESCARA) and (near(flood, "P3", lo, la, 4000) if "P3" in flood else True)
                        if ok:
                            mz07_cands.append((day, s["t"][i], lo, la))
        if day.day == 1 or day == last_day:
            print(f"[{day}] righe finora: {n_rows:,} ({time.time() - t_start:.0f}s)", flush=True)
    out_pos.close()

    # --- incidenti MZ-07: 3 giorni diversi
    by_day = {}
    for c in mz07_cands:
        by_day.setdefault(c[0], []).append(c)
    chosen_days = random.sample(sorted(by_day), min(3, len(by_day)))
    for dday, sev in zip(sorted(chosen_days), [3, 4, 2]):
        c = random.choice(by_day[dday])
        incidents.append(("MZ-07", c[1], c[2], c[3], sev, random.choice(KINDS)))
    if len(chosen_days) < 3:
        print("[attenzione] MZ-07: trovati solo", len(chosen_days), "giorni candidati vicino a P3", flush=True)

    # --- scrittura tabelle piccole
    incidents.sort(key=lambda r: r[1])
    with open(os.path.join(a.out, "incidents.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["incident_id", "vehicle_id", "ts", "lat", "lon", "severity", "kind"])
        for i, (v_, t_, lo, la, sev, kind) in enumerate(incidents, 1):
            ts = dt.datetime.fromtimestamp(t_, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            w.writerow([f"INC-{i:03d}", v_, ts, f"{la:.6f}", f"{lo:.6f}", sev, kind])
    with open(os.path.join(a.out, "vehicles.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["vehicle_id", "type", "depot_id"])
        for v in vehicles:
            w.writerow([v["vehicle_id"], v["type"], v["depot"]["depot_id"]])
    with open(os.path.join(a.out, "depots.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["depot_id", "name", "lat", "lon"])
        for d in depots:
            w.writerow([d["depot_id"], d["name"], f"{d['node'][1]:.6f}", f"{d['node'][0]:.6f}"])
    report = dict(
        rows=n_rows, first_day=str(first_day), end_local=a.end, vehicles=len(vehicles),
        incidents=len(incidents), mz07_incident_days=[str(x) for x in sorted(chosen_days)],
        hot_schools=[dict(name=s[0], lon=s[1], lat=s[2]) for s in hot_schools],
        depots={d["depot_id"]: dict(name=d["name"], lon=d["node"][0], lat=d["node"][1]) for d in depots},
        venue=dict(lon=venue[0], lat=venue[1]), venue_trips=venue_trips,
        flood_loaded=sorted(flood), seconds=round(time.time() - t_start),
    )
    with open(os.path.join(a.out, "report.json"), "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

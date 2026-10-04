"""Dragon Haven layout: building pads, cottages, lamps, bridges, trees, rocks,
egg spots. Computed offline against the terrain, exported to Luau data
(ServerScriptService/World/HavenLayout.luau)."""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import paths  # noqa: E402
import haven as HV  # noqa: E402
from noise import catmull, polyline_distance, fbm2, hash01  # noqa: E402

STATIONS = {
    "Shop": {"pos": (0.0, -118.0), "pad": (40, 32), "kind": "market"},
    "Forge": {"pos": (-104.0, -66.0), "pad": (30, 26), "kind": "forge"},
    "Library": {"pos": (-122.0, 32.0), "pad": (44, 40), "kind": "hall"},
    "Quests": {"pos": (116.0, -28.0), "pad": (30, 26), "kind": "elder"},
}


def yaw_toward(frm, to):
    """Roblox yaw (radians) so that a model's -Z faces from -> to."""
    dx, dz = to[0] - frm[0], to[1] - frm[1]
    return math.atan2(-dx, -dz)


class Layout:
    def __init__(self, hv: HV.Haven, seed=7):
        self.hv = hv
        self.rng = np.random.default_rng(seed)
        self.pads = []  # (cx, cz, yaw, w, d, height)
        self.buildings = []  # dicts: kind, x, y, z, yaw, seed, extra
        self.lamps = []
        self.bridges = []
        self.trees = []
        self.rocks = []
        self.bushes = []
        self.eggs = []
        self.road_lines = {k: catmull(v, 20) for k, v in HV.ROADS.items()}

    # ---------------------------------------------------------- helpers
    def ground(self, x, z):
        return self.hv.height_at(x, z)

    def footprint_height(self, cx, cz, yaw, w, d):
        c, s = math.cos(yaw), math.sin(yaw)
        hs = []
        for u in np.linspace(-w / 2, w / 2, 5):
            for v in np.linspace(-d / 2, d / 2, 5):
                x = cx + u * c + v * s
                z = cz - u * s + v * c
                hs.append(self.ground(x, z))
        return float(np.median(hs)), float(min(hs)), float(max(hs))

    def plot_clear(self, x, z, margin=12.0):
        """True when (x, z) is outside every sanctuary plot (+ margin)."""
        X, Z = np.array([x]), np.array([z])
        for p in HV.PLOTS:
            u, v = HV.plot_local(X, Z, p)
            if HV.rect_dist(u, v, HV.PLOT_SIZE[0] / 2 + margin, HV.PLOT_SIZE[1] / 2 + margin)[0] < 0:
                return False
        return True

    def road_dist(self, x, z):
        best = 1e9
        P = np.array([[x, z]])
        for pts in self.road_lines.values():
            d, _ = polyline_distance(P[:, 0], P[:, 1], pts)
            best = min(best, float(d[0]))
        return best

    def add_pad(self, cx, cz, yaw, w, d, h):
        self.pads.append((cx, cz, yaw, w, d, h))

    # ---------------------------------------------------------- village
    def plan_village(self):
        hub = (0.0, 0.0)
        for sid, s in STATIONS.items():
            x, z = s["pos"]
            yaw = yaw_toward((x, z), hub)
            w, d = s["pad"]
            h, lo, hi = self.footprint_height(x, z, yaw, w, d)
            h = max(h, HV.HUB_Y)
            self.add_pad(x, z, yaw, w + 6, d + 6, h)
            self.buildings.append({"kind": s["kind"], "station": sid, "x": x, "y": h, "z": z, "yaw": yaw, "seed": 0})
        # cottages on rings between the plaza and the village edge
        placed = [(b["x"], b["z"], 30.0) for b in self.buildings]
        seed = 100
        for ring, step_deg, w_rng in ((96, 14, (12, 15)), (128, 12, (12, 16)), (158, 10, (12, 16))):
            off = self.rng.uniform(0, step_deg)
            for k in range(int(360 / step_deg)):
                a = math.radians(off + k * step_deg)
                rr = ring + self.rng.uniform(-6, 6)
                x, z = math.sin(a) * rr, -math.cos(a) * rr
                w = int(self.rng.integers(w_rng[0], w_rng[1] + 1))
                d = int(self.rng.integers(11, 15))
                rad = math.hypot(w, d) / 2
                if self.road_dist(x, z) < rad + 10:
                    continue
                if any(math.hypot(x - px, z - pz) < rad + pr + 6 for px, pz, pr in placed):
                    continue
                yaw = yaw_toward((x, z), hub) + self.rng.uniform(-0.12, 0.12)
                h, lo, hi = self.footprint_height(x, z, yaw, w + 2, d + 2)
                if hi - lo > 6:
                    continue
                seed += 1
                self.add_pad(x, z, yaw, w + 5, d + 5, h)
                self.buildings.append({"kind": "cottage", "x": x, "y": h, "z": z, "yaw": yaw, "seed": seed,
                                       "w": w, "d": d, "stories": 2 if self.rng.random() < 0.5 else 1})
                placed.append((x, z, rad))
        # lamps: plaza ring + along roads inside the village
        for k in range(12):
            a = math.radians(15 + k * 30)
            x, z = math.sin(a) * (HV.PLAZA_R + 3), -math.cos(a) * (HV.PLAZA_R + 3)
            if self.road_dist(x, z) > 6:
                self.lamps.append((x, z, yaw_toward((x, z), hub)))
        for name, pts in self.road_lines.items():
            seg = np.diff(pts, axis=0)
            L = np.concatenate([[0], np.cumsum(np.linalg.norm(seg, axis=1))])
            for s_ in np.arange(30, min(L[-1], 260), 34):
                i = int(np.searchsorted(L, s_) - 1)
                t = (s_ - L[i]) / max(L[i + 1] - L[i], 1e-6)
                p = pts[i] + (pts[i + 1] - pts[i]) * t
                dvec = (pts[i + 1] - pts[i]) / max(np.linalg.norm(pts[i + 1] - pts[i]), 1e-6)
                side = 1 if int(s_ / 34) % 2 == 0 else -1
                q = p + np.array([-dvec[1], dvec[0]]) * side * 9
                if math.hypot(*q) < HV.PLAZA_R + 6:
                    continue
                if any(math.hypot(q[0] - px, q[1] - pz) < pr + 4 for px, pz, pr in placed):
                    continue
                self.lamps.append((float(q[0]), float(q[1]), 0.0))

    # ---------------------------------------------------------- bridges
    def plan_bridges(self):
        river = catmull(HV.RIVER, 24)
        for name, pts in self.road_lines.items():
            for i in range(len(pts) - 1):
                a, b = pts[i], pts[i + 1]
                for j in range(len(river) - 1):
                    c, d = river[j], river[j + 1]
                    # segment intersection
                    r_ = b - a
                    s_ = d - c
                    den = r_[0] * s_[1] - r_[1] * s_[0]
                    if abs(den) < 1e-9:
                        continue
                    t = ((c[0] - a[0]) * s_[1] - (c[1] - a[1]) * s_[0]) / den
                    u = ((c[0] - a[0]) * r_[1] - (c[1] - a[1]) * r_[0]) / den
                    if 0 <= t <= 1 and 0 <= u <= 1:
                        p = a + r_ * t
                        yaw = yaw_toward(p, p + r_)  # bridge -Z along the road direction
                        tr = (j + u) / (len(river) - 1)
                        water = HV.RIVER_W0 + (HV.RIVER_W1 - HV.RIVER_W0) * tr
                        hw = HV.RIVER_HW0 + (HV.RIVER_HW1 - HV.RIVER_HW0) * tr
                        span = 2 * hw + 26
                        ends = [p + r_ / np.linalg.norm(r_) * span / 2 * s for s in (-1, 1)]
                        deck = max(water + 7, max(self.ground(*e) for e in ends) + 0.5)
                        self.bridges.append({"road": name, "x": float(p[0]), "z": float(p[1]), "yaw": yaw,
                                             "span": span, "deck": deck, "water": water, "width": 16})
                        for e in ends:
                            self.add_pad(float(e[0]), float(e[1]), yaw, 18, 12, deck - 1.2)

    # ---------------------------------------------------------- vegetation
    def plan_vegetation(self):
        hv = self.hv
        X, Z = hv.X, hv.Z
        # candidate points: jittered grid, density from masks
        rng = self.rng
        pts = []
        cell = 13.0
        xs = np.arange(-HV.EXTENT + 20, HV.EXTENT - 20, cell)
        gx, gz = np.meshgrid(xs, xs)
        gx = gx + rng.uniform(-cell * 0.45, cell * 0.45, gx.shape)
        gz = gz + rng.uniform(-cell * 0.45, cell * 0.45, gz.shape)
        gx, gz = gx.ravel(), gz.ravel()
        r = np.hypot(gx, gz)
        fx = np.clip((gx + HV.EXTENT) / HV.GRID, 0, HV.N - 1.001)
        fz = np.clip((gz + HV.EXTENT) / HV.GRID, 0, HV.N - 1.001)
        ix, iz = fx.astype(int), fz.astype(int)
        h = hv.H[iz, ix]
        slope = hv.slope[iz, ix]
        wet = hv.W[iz, ix] > hv.H[iz, ix] - 0.5
        mat = hv.M[iz, ix]
        # forest density
        dens = np.zeros_like(gx)
        for name, c, rad, dn in HV.FORESTS:
            d = np.hypot(gx - c[0], gz - c[1])
            dens = np.maximum(dens, dn * np.clip(1.15 - d / rad, 0, 1) ** 0.7)
        noise = fbm2(gx, gz, 140, 3, seed=303)
        dens = np.clip(dens * (0.55 + 0.9 * noise), 0, 1)
        # scattered trees across the valley + foothills
        dens = np.maximum(dens, 0.05 + 0.07 * (noise > 0.55))
        # restrictions
        road = np.full(gx.shape, 1e9)
        for pts in self.road_lines.values():
            d, _ = polyline_distance(gx, gz, pts)
            road = np.minimum(road, d)
        ok = (slope < 0.75) & ~wet & (road > 11) & (r > HV.VILLAGE_R + 20) & (h < 230) & (h > HV.LAKE_W + 1.5)
        ok &= np.array([hv.plot_mask[iz[k], ix[k]] < 0.05 for k in range(len(gx))])
        ok &= mat != HV.MI["Cobblestone"]
        # keep clear of buildings / bridges / cave mouth / sky pillar base
        blocks = [(b["x"], b["z"], 26) for b in self.buildings] + [(b["x"], b["z"], b["span"] / 2 + 10) for b in self.bridges]
        blocks += [(HV.CAVE_MOUTH[0], HV.CAVE_MOUTH[1], 40), (HV.PILLAR_C[0], HV.PILLAR_C[1], HV.PILLAR_R + 30),
                   (HV.FALL_BOTTOM[0], HV.FALL_BOTTOM[2], 50)]
        for bx, bz, br in blocks:
            ok &= np.hypot(gx - bx, gz - bz) > br
        roll = rng.random(len(gx))
        tree = ok & (roll < dens)
        for k in np.where(tree)[0]:
            x, z = float(gx[k]), float(gz[k])
            y = self.ground(x, z)
            high = y > 120
            in_forest = dens[k] > 0.3
            # species mix: pines up high / north, broadleaf in the valley, birch near water
            n2 = hash01(int(x * 7), int(z * 7), 91)
            if high or (z < -500 and n2 < 0.7):
                kind = "Pine"
            elif np.hypot(x - HV.LAKE_C[0], z - HV.LAKE_C[1]) < HV.LAKE_R + 160 and n2 < 0.45:
                kind = "Birch"
            else:
                kind = "Oak" if n2 < 0.62 else "Pine"
            s = 0.8 + 0.5 * rng.random() + (0.15 if in_forest else 0)
            self.trees.append((kind, x, y, z, float(rng.uniform(0, 2 * math.pi)), round(s, 2)))
        # bushes near trees and along forest edges
        for kind, x, y, z, yaw, s in self.trees[::3]:
            a = rng.uniform(0, 2 * math.pi)
            bx, bz = x + math.cos(a) * 8, z + math.sin(a) * 8
            if self.road_dist(bx, bz) > 8 and self.plot_clear(bx, bz):
                self.bushes.append((float(bx), self.ground(bx, bz), float(bz), float(rng.uniform(0, 6.28)), round(0.8 + 0.6 * rng.random(), 2)))
        # rocks: valley scatter + mountain foot
        rocks_ok = (slope < 1.2) & ~wet & (road > 9) & (r > HV.VILLAGE_R + 10)
        rk = rocks_ok & (roll > 0.985 - 0.02 * (r > 650))
        for k in np.where(rk)[0]:
            x, z = float(gx[k]), float(gz[k])
            if not self.plot_clear(x, z):
                continue
            self.rocks.append((x, self.ground(x, z) - 0.6, z, float(rng.uniform(0, 6.28)), round(0.7 + 1.6 * rng.random() ** 2, 2),
                               int(rng.integers(0, 4))))

    # ---------------------------------------------------------- eggs
    def plan_eggs(self):
        spots = [
            ("Hub", (40, 52)), ("Westwood", (-520, -20)), ("Westwood", (-610, 120)), ("Eastwood", (660, 20)),
            ("Eastwood", (720, 140)), ("Lakeside", (-60, 610)), ("Lakeside", (300, 640)), ("Island", (196, 790)),
            ("Ruins", (-500, -540)), ("Ruins", (-460, -590)), ("Falls", (390, -700)), ("Falls", (470, -720)),
            ("Plateau", (430, -900)), ("Cave", (740, -640)), ("Pillar", (-905, 300)), ("NorthPines", (-160, -700)),
            ("Hills", (-300, 380)), ("Hills", (280, -260)), ("Pass", (-100, -930)), ("Meadow", (-250, 200)),
            ("Meadow", (230, 230)), ("Riverside", (440, 60)), ("Riverside", (400, -350)), ("Outcrop", (-200, -280)),
        ]
        for name, (x, z) in spots:
            y = self.ground(x, z)
            if name == "Pillar":
                y = float(self.hv.H.max())  # resolved precisely in game by raycast
            self.eggs.append((name, float(x), y, float(z)))


def write_luau(lay: Layout, path):
    def f(v, nd=2):
        return f"{v:.{nd}f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)
    L = ["-- GENERATED by toolchain/worldgen/layout.py - do not edit by hand.", "return {"]
    L.append("\tBuildings = {")
    for b in lay.buildings:
        extra = "".join(f", {k} = {f(float(v)) if isinstance(v, (int, float)) and not isinstance(v, bool) else repr(v)}"
                        for k, v in b.items() if k in ("w", "d", "stories"))
        st = f', Station = "{b["station"]}"' if "station" in b else ""
        L.append(f'\t\t{{ Kind = "{b["kind"]}"{st}, X = {f(b["x"])}, Y = {f(b["y"])}, Z = {f(b["z"])}, Yaw = {f(b["yaw"], 4)}, Seed = {b["seed"]}{extra} }},')
    L.append("\t},")
    L.append("\tLamps = {")
    for x, z, yaw in lay.lamps:
        L.append(f"\t\t{{ {f(x)}, {f(lay.ground(x, z))}, {f(z)}, {f(yaw, 3)} }},")
    L.append("\t},")
    L.append("\tBridges = {")
    for b in lay.bridges:
        L.append(f'\t\t{{ Road = "{b["road"]}", X = {f(b["x"])}, Z = {f(b["z"])}, Yaw = {f(b["yaw"], 4)}, Span = {f(b["span"])}, Deck = {f(b["deck"])}, Water = {f(b["water"])}, Width = {b["width"]} }},')
    L.append("\t},")
    kinds = {"Oak": 1, "Pine": 2, "Birch": 3}
    L.append("\tTreeKinds = { \"Oak\", \"Pine\", \"Birch\" },")
    L.append("\t-- trees: { kind, x, y, z, yaw, scale }")
    L.append("\tTrees = {")
    for kind, x, y, z, yaw, s in lay.trees:
        L.append(f"\t\t{{ {kinds[kind]}, {f(x, 1)}, {f(y, 1)}, {f(z, 1)}, {f(yaw, 2)}, {f(s)} }},")
    L.append("\t},")
    L.append("\tBushes = {")
    for x, y, z, yaw, s in lay.bushes:
        L.append(f"\t\t{{ {f(x, 1)}, {f(y, 1)}, {f(z, 1)}, {f(yaw, 2)}, {f(s)} }},")
    L.append("\t},")
    L.append("\t-- rocks: { x, y, z, yaw, scale, variant }")
    L.append("\tRocks = {")
    for x, y, z, yaw, s, v in lay.rocks:
        L.append(f"\t\t{{ {f(x, 1)}, {f(y, 1)}, {f(z, 1)}, {f(yaw, 2)}, {f(s)}, {v} }},")
    L.append("\t},")
    L.append("\tEggSpots = {")
    for name, x, y, z in lay.eggs:
        L.append(f'\t\t{{ Name = "{name}", X = {f(x, 1)}, Y = {f(y, 1)}, Z = {f(z, 1)} }},')
    L.append("\t},")
    L.append("}")
    src = "\n".join(L) + "\n"
    with open(path, "w") as fh:
        fh.write(src)
    return len(src)


def build_all():
    hv = HV.Haven().build()
    lay = Layout(hv)
    lay.plan_village()
    lay.plan_bridges()
    hv2 = HV.Haven(pads=lay.pads).build()
    lay.hv = hv2
    # re-sample heights on the final terrain
    for b in lay.buildings:
        b["y"] = round(max(b["y"], 0), 2)
    lay.plan_vegetation()
    lay.plan_eggs()
    return hv2, lay


if __name__ == "__main__":
    hv, lay = build_all()
    print(f"buildings {len(lay.buildings)} (cottages {sum(b['kind'] == 'cottage' for b in lay.buildings)}), lamps {len(lay.lamps)}, "
          f"bridges {len(lay.bridges)}, trees {len(lay.trees)}, bushes {len(lay.bushes)}, rocks {len(lay.rocks)}, eggs {len(lay.eggs)}")
    n = write_luau(lay, os.path.join(paths.WORLD_SRC, "HavenLayout.luau"))
    print("layout module", n // 1024, "KB")

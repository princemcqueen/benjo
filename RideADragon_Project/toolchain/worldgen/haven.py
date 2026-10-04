"""Dragon Haven terrain generator (offline).

Produces an 8-stud heightmap, a material map and a water-level map for the
valley described in ReplicatedStorage/Configs/WorldConfig.luau, plus 3D cave
carves. The game ships these as data and writes Roblox Terrain from them.

Grid: GRID-stud samples covering [-EXTENT, EXTENT]^2 (X east, Z south)."""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from noise import fbm2, ridged2, value2, smoothstep, catmull, polyline_distance  # noqa: E402

GRID = 8.0
EXTENT = 1152.0
N = int(2 * EXTENT / GRID) + 1  # 289

# --- layout (mirrors WorldConfig.luau) ------------------------------------
HUB = np.array([0.0, 0.0])
HUB_Y = 30.0
PLAZA_R = 64.0
VILLAGE_R = 175.0
PLOT_RING = 335.0
PLOT_SIZE = (124.0, 104.0)
PLOTS = []
for i in range(8):
    a = math.radians(22.5 + i * 45)
    c = np.array([math.sin(a) * PLOT_RING, -math.cos(a) * PLOT_RING])
    h = 34 + ((((i + 1) % 3) - 1) * 4)
    PLOTS.append({"id": i + 1, "c": c, "h": float(h), "yaw": math.atan2(-(0 - c[0]), -(0 - c[1]))})

RIVER = [(424, -742), (452, -600), (486, -430), (470, -220), (452, -20), (474, 170), (430, 380), (330, 560), (214, 676)]
RIVER_W0, RIVER_W1 = 37.0, 25.0
RIVER_HW0, RIVER_HW1 = 13.0, 20.0
RIVER_DEPTH, RIVER_BANK = 8.0, 20.0
UPPER = [(400, -1010), (416, -900), (424, -786)]
UPPER_W, UPPER_HW, UPPER_DEPTH = 176.0, 11.0, 6.0
FALL_TOP = np.array([424.0, 176.0, -786.0])
FALL_BOTTOM = np.array([424.0, 37.0, -748.0])
CLIFF_Z, CLIFF_X, PLATEAU_H = -774.0, (300.0, 560.0), 182.0
LAKE_C, LAKE_R, LAKE_W = np.array([150.0, 742.0]), 196.0, 25.0
ISLAND_C, ISLAND_R, ISLAND_H = np.array([196.0, 790.0]), 34.0, 33.0
RUINS_C, RUINS_R, RUINS_H = np.array([-500.0, -540.0]), 120.0, 78.0
CAVE_MOUTH, CAVE_FACING, CAVE_DEPTH = np.array([706.0, -600.0]), math.radians(220), 150.0
PILLAR_C, PILLAR_R, PILLAR_H = np.array([-905.0, 300.0]), 48.0, 360.0
FORESTS = [("Westwood", (-560, -40), 330, 1.0), ("Eastwood", (690, 60), 250, 0.85),
           ("Lakeside Grove", (-120, 640), 200, 0.6), ("North Pines", (-180, -720), 210, 0.75)]
PASSES = {"North": (math.radians(-7), math.radians(9), 128.0), "East": (math.radians(78), math.radians(8), 92.0)}
ROADS = {
    "North": [(-34, -58), (-62, -150), (-52, -300), (-90, -620), (-120, -1000)],
    "East": [(70, 0), (300, 40), (455, 96), (700, 160), (1060, 220)],
    "South": [(0, 70), (30, 300), (110, 520)],
    "West": [(-70, 0), (-320, 60), (-620, 180), (-860, 290)],
    "Ruins": [(-60, -60), (-300, -330), (-470, -500)],
    "Falls": [(60, -60), (280, -420), (400, -700)],
}

MATS = ["Grass", "LeafyGrass", "Ground", "Mud", "Sand", "Rock", "Slate", "Snow", "Cobblestone", "Limestone", "Basalt"]
MI = {m: i for i, m in enumerate(MATS)}
TERRAIN_COLORS = {
    "Grass": (92, 124, 64), "LeafyGrass": (78, 108, 54), "Ground": (118, 98, 72), "Mud": (82, 66, 50),
    "Sand": (196, 180, 142), "Rock": (118, 116, 110), "Slate": (92, 96, 100), "Snow": (234, 240, 246),
    "Cobblestone": (130, 124, 112), "Limestone": (190, 176, 150), "Basalt": (58, 56, 60), "Water": (36, 92, 104),
}


def grid():
    xs = -EXTENT + GRID * np.arange(N)
    X, Z = np.meshgrid(xs, xs)  # [iz, ix]
    return xs, X, Z


def plot_local(X, Z, p):
    """Plot-local coords: u across (right), v radial (toward hub = -v?)."""
    dx, dz = X - p["c"][0], Z - p["c"][1]
    # facing direction (toward hub) in XZ
    f = -p["c"] / np.linalg.norm(p["c"])
    r = np.array([-f[1], f[0]])
    return dx * r[0] + dz * r[1], dx * f[0] + dz * f[1]


def rect_dist(u, v, hw, hd):
    qx = np.abs(u) - hw
    qy = np.abs(v) - hd
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0)


class Haven:
    def __init__(self, pads=None):
        self.xs, self.X, self.Z = grid()
        self.carves = []  # 3D capsules (air): (a(x,y,z), b, r0, r1)
        self.pads = pads or []  # building pads: (cx, cz, yaw, w, d, height)

    def build(self):
        X, Z = self.X, self.Z
        r = np.hypot(X, Z)
        ang = np.arctan2(X, -Z)
        # ---- base valley: broad undulation + finer rolls
        h = HUB_Y + (fbm2(X, Z, 260, 4, seed=11) - 0.5) * 16 + (fbm2(X, Z, 90, 3, seed=12) - 0.5) * 5
        n1 = fbm2(X, Z, 300, 3, seed=31)
        # ---- foothills band between the valley and the mountains
        fh = smoothstep(430, 800, r + (n1 - 0.5) * 220) * (30 + 85 * ridged2(X, Z, 300, 4, seed=22))
        fh *= 0.55 + 0.9 * fbm2(X, Z, 420, 2, seed=23)
        # ---- rocky outcrops scattered in the valley
        o = ridged2(X, Z, 150, 3, seed=24)
        crop = smoothstep(0.845, 0.9, o) * smoothstep(160, 320, r) * (1 - smoothstep(640, 760, r))
        h = h + fh + crop * (14 + 26 * fbm2(X, Z, 40, 2, seed=25))
        # ---- mountain ring (wobbly inner edge, ridged peaks) with two passes
        edge = 860 + (n1 - 0.5) * 200
        ring = smoothstep(edge, edge + 240, r)
        peaks = 95 + 205 * ridged2(X, Z, 420, 5, seed=41)
        mount = ring * peaks
        for name, (pa, pw, ph) in PASSES.items():
            da = np.angle(np.exp(1j * (ang - pa)))
            m = np.exp(-(da / pw) ** 2)
            floor = HUB_Y + (ph - HUB_Y) * smoothstep(650, 1000, r)
            mount = mount * (1 - m) + (floor - HUB_Y) * m * ring
            h = h - fh * m * 0.8
        h = h + mount
        # ---- NE plateau with the waterfall cliff
        cz = CLIFF_Z + 10 * np.sin(X / 37.0) + 6 * np.sin(X / 13.0 + 1.3)
        # the plateau curls north away from the cliff span so the cliff ends naturally
        span = smoothstep(CLIFF_X[0] - 90, CLIFF_X[0] + 10, X) * (1 - smoothstep(CLIFF_X[1] - 10, CLIFF_X[1] + 110, X))
        curl = (1 - span) * 220
        plateau_mask = smoothstep(cz + 6 - curl, cz - 14 - curl, Z) * smoothstep(150, 330, X) * (1 - smoothstep(700, 820, X))
        plateau = PLATEAU_H + (fbm2(X, Z, 120, 3, seed=51) - 0.5) * 10
        h = np.maximum(h, h * (1 - plateau_mask) + plateau * plateau_mask)
        # ---- ruins mesa
        d = np.hypot(X - RUINS_C[0], Z - RUINS_C[1]) + (fbm2(X, Z, 60, 3, seed=61) - 0.5) * 30
        mesa = smoothstep(RUINS_R + 40, RUINS_R - 10, d)
        top = RUINS_H + (fbm2(X, Z, 40, 2, seed=62) - 0.5) * 3
        h = np.maximum(h, h * (1 - mesa) + top * mesa)
        # ---- sky pillar spire
        d = np.hypot(X - PILLAR_C[0], Z - PILLAR_C[1])
        jag = (fbm2(X, Z, 26, 3, seed=71) - 0.5) * 22
        rb, rt = PILLAR_R + 30, PILLAR_R * 0.45
        prof = np.clip((rb - (d + jag)) / (rb - rt), 0, 1) ** 0.55
        top = PILLAR_H + (fbm2(X, Z, 18, 2, seed=72) - 0.5) * 30
        h = np.maximum(h, h + (top - h) * prof)
        base = smoothstep(PILLAR_R * 2.8, PILLAR_R, d)
        h = np.maximum(h, h + base * 34)
        # ---- flatten hub, village and sanctuary plots
        village = smoothstep(VILLAGE_R + 60, VILLAGE_R - 20, r)
        h = h * (1 - village) + (HUB_Y + 0.5 + (fbm2(X, Z, 90, 2, seed=81) - 0.5) * 2.5) * village
        plaza = smoothstep(PLAZA_R + 14, PLAZA_R, r)
        h = h * (1 - plaza) + HUB_Y * plaza
        self.plot_mask = np.zeros_like(h)
        for p in PLOTS:
            u, v = plot_local(X, Z, p)
            dd = rect_dist(u, v, PLOT_SIZE[0] / 2 + 10, PLOT_SIZE[1] / 2 + 10)
            w = smoothstep(55, 0, dd)
            h = h * (1 - w) + p["h"] * w
            self.plot_mask = np.maximum(self.plot_mask, smoothstep(6, -2, dd))
        # ---- building / bridge pads (flat, with a short falloff)
        self.pad_mask = np.zeros_like(h)
        for cx, cz, yaw, pw, pd, ph in self.pads:
            dx, dz = X - cx, Z - cz
            c, s_ = math.cos(yaw), math.sin(yaw)
            u = dx * c - dz * s_
            v = dx * s_ + dz * c
            dd = rect_dist(u, v, pw / 2, pd / 2)
            wgt = smoothstep(14, 0, dd)
            h = h * (1 - wgt) + ph * wgt
            self.pad_mask = np.maximum(self.pad_mask, smoothstep(2, -2, dd))
        # ---- roads: soften along the road (material later)
        self.road_d = np.full(h.shape, 1e9)
        for name, pts in ROADS.items():
            c = catmull(pts, 20)
            dd, _ = polyline_distance(X, Z, c)
            self.road_d = np.minimum(self.road_d, dd)
        # ---- river (carve only)
        rc = catmull(RIVER, 24)
        dr, tr = polyline_distance(X, Z, rc)
        self.river_d, self.river_t = dr, tr
        water = RIVER_W0 + (RIVER_W1 - RIVER_W0) * tr
        hw = RIVER_HW0 + (RIVER_HW1 - RIVER_HW0) * tr
        wob = (fbm2(X, Z, 50, 2, seed=91) - 0.5) * 6
        bed = water - RIVER_DEPTH * smoothstep(hw + 2, hw * 0.25, dr + wob)
        bank_top = water + 1.2 + 6 * smoothstep(hw, hw + RIVER_BANK * 2.2, dr)
        target = np.where(dr < hw + 2, bed, np.minimum(bank_top, water + 1.2 + (dr - hw) * 0.35))
        carve = smoothstep(hw + RIVER_BANK * 3, hw + RIVER_BANK, dr)
        h = np.where(dr < hw + RIVER_BANK * 3, np.minimum(h, h * (1 - carve) + target * carve), h)
        h = np.where(dr < hw + 2, np.minimum(h, bed), h)
        W = np.full(h.shape, -1e4)
        in_river = dr < hw + 4
        W = np.where(in_river, np.maximum(W, water), W)
        # ---- waterfall pool
        dp = np.hypot(X - FALL_BOTTOM[0], Z - FALL_BOTTOM[2])
        pool = smoothstep(46, 20, dp)
        h = np.minimum(h, h * (1 - pool) + (RIVER_W0 - 7) * pool)
        W = np.where(dp < 44, np.maximum(W, RIVER_W0), W)
        # ---- upper stream on the plateau
        uc = catmull(UPPER, 16)
        du, tu = polyline_distance(X, Z, uc)
        ub = UPPER_W - UPPER_DEPTH * smoothstep(UPPER_HW + 2, UPPER_HW * 0.3, du)
        ucarve = smoothstep(UPPER_HW + 18, UPPER_HW + 2, du) * (Z < CLIFF_Z + 30)
        h = np.where(ucarve > 0, np.minimum(h, h * (1 - ucarve) + np.minimum(ub, UPPER_W + 1.5) * ucarve), h)
        W = np.where((du < UPPER_HW + 2) & (Z < CLIFF_Z + 10), np.maximum(W, UPPER_W), W)
        # ---- lake + island
        dl = np.hypot(X - LAKE_C[0], Z - LAKE_C[1]) + (fbm2(X, Z, 70, 3, seed=101) - 0.5) * 40
        lake_bed = LAKE_W - 3 - 14 * smoothstep(LAKE_R - 10, LAKE_R - 120, dl)
        shore = smoothstep(LAKE_R + 50, LAKE_R - 6, dl)
        h = np.minimum(h, h * (1 - shore) + np.where(dl < LAKE_R, lake_bed, LAKE_W + 0.8 + (dl - LAKE_R) * 0.12) * shore)
        W = np.where(dl < LAKE_R + 4, np.maximum(W, LAKE_W), W)
        di = np.hypot(X - ISLAND_C[0], Z - ISLAND_C[1])
        isl = smoothstep(ISLAND_R + 16, ISLAND_R - 10, di)
        h = np.maximum(h, h * (1 - isl) + (ISLAND_H + (fbm2(X, Z, 20, 2, seed=111) - 0.5) * 3) * isl)
        self.lake_d = dl
        # ---- outer world edge: keep mountains closed beyond the ring
        self.H = h
        self.W = np.where(W > h + 0.3, W, -1e4)
        self._caves()
        self._materials()
        return self

    def _caves(self):
        """Tunnel into the eastern mountains (3D carve capsules)."""
        mouth = CAVE_MOUTH
        d = np.array([math.sin(CAVE_FACING + math.pi), -math.cos(CAVE_FACING + math.pi)])  # inward (away from facing)
        g = self.height_at(mouth[0], mouth[1])
        y0 = max(g, 40.0)
        pts = []
        for i in range(7):
            t = i / 6
            p = mouth + d * CAVE_DEPTH * t + np.array([-d[1], d[0]]) * math.sin(t * 3.1) * 18
            pts.append((p[0], y0 + 10 + 6 * math.sin(t * 2.0) - 4 * t, p[1]))
        for i in range(len(pts) - 1):
            self.carves.append((pts[i], pts[i + 1], 22 - i * 1.2, 21 - (i + 1) * 1.2))
        self.cave_path = pts

    def height_at(self, x, z):
        fx = (x + EXTENT) / GRID
        fz = (z + EXTENT) / GRID
        ix, iz = int(np.clip(np.floor(fx), 0, N - 2)), int(np.clip(np.floor(fz), 0, N - 2))
        tx, tz = fx - ix, fz - iz
        H = self.H
        return float((H[iz, ix] * (1 - tx) + H[iz, ix + 1] * tx) * (1 - tz) + (H[iz + 1, ix] * (1 - tx) + H[iz + 1, ix + 1] * tx) * tz)

    def _materials(self):
        X, Z, H = self.X, self.Z, self.H
        gz, gx = np.gradient(H, GRID)
        slope = np.hypot(gx, gz)
        self.slope = slope
        r = np.hypot(X, Z)
        M = np.full(H.shape, MI["Grass"], np.int16)
        n = fbm2(X, Z, 70, 3, seed=201)
        # forests -> leafy grass floors
        for name, c, rad, dens in FORESTS:
            d = np.hypot(X - c[0], Z - c[1]) + (n - 0.5) * 120
            M = np.where(d < rad * 0.92, MI["LeafyGrass"], M)
        # dirt on moderate slopes and patches
        M = np.where((slope > 0.55) | (n < 0.24), MI["Ground"], M)
        # rock on steep slopes, slate cliffs
        M = np.where(slope > 0.95, MI["Rock"], M)
        M = np.where(slope > 1.9, MI["Slate"], M)
        # snow caps
        snow_line = 262 + (n - 0.5) * 60
        M = np.where((H > snow_line) & (slope < 1.6), MI["Snow"], M)
        # water edges
        river_edge = (self.river_d < (RIVER_HW0 + RIVER_HW1) * 0.5 + 9) & (H < 45)
        M = np.where(river_edge, MI["Mud"], M)
        beach = (self.lake_d < LAKE_R + 22) & (H < LAKE_W + 3.5)
        M = np.where(beach, MI["Sand"], M)
        # roads, village streets, plaza
        M = np.where((self.road_d < 7 + (n - 0.5) * 3) & (slope < 0.8), MI["Ground"], M)
        street = (r < VILLAGE_R) & (self.road_d < 9)
        M = np.where(street | (r < PLAZA_R + 2), MI["Cobblestone"], M)
        # ruins mesa top: pale stone dust
        d = np.hypot(X - RUINS_C[0], Z - RUINS_C[1])
        M = np.where((d < RUINS_R - 25) & (slope < 0.4) & (n > 0.45), MI["Limestone"], M)
        # sky pillar: dark basalt column
        d = np.hypot(X - PILLAR_C[0], Z - PILLAR_C[1])
        M = np.where((d < PILLAR_R + 40) & (slope > 0.9), MI["Basalt"], M)
        # plots stay lush grass
        M = np.where(self.plot_mask > 0.5, MI["Grass"], M)
        self.M = M

    # ------------------------------------------------------------- preview
    def preview_terrain(self, step=1):
        """Scene-terrain dict for preview3d (8-stud grid)."""
        H = self.H[::step, ::step]
        Mm = self.M[::step, ::step]
        W = self.W[::step, ::step]
        cols = np.zeros(H.shape + (3,), np.float32)
        for name, i in MI.items():
            cols[Mm == i] = TERRAIN_COLORS[name]
        # subtle variation
        v = value2(self.X[::step, ::step], self.Z[::step, ::step], 24, 333)
        cols *= (0.92 + 0.16 * v)[..., None]
        return {"x0": float(-EXTENT), "z0": float(-EXTENT), "step": float(GRID * step), "nx": int(H.shape[1]),
                "nz": int(H.shape[0]), "h": H.astype(np.float32).tolist(), "c": cols.tolist(),
                "w": np.where(W > H, W, -9999.0).astype(np.float32).tolist()}

    def topdown(self, path, scale=2):
        from PIL import Image
        H, Mm, W = self.H, self.M, self.W
        cols = np.zeros(H.shape + (3,), np.float32)
        for name, i in MI.items():
            cols[Mm == i] = TERRAIN_COLORS[name]
        gz, gx = np.gradient(H, GRID)
        light = np.clip(0.75 + (-gx * 0.5 - gz * 0.4) * 0.9, 0.35, 1.3)
        cols = cols * light[..., None]
        water = W > H
        depth = np.clip((W - H) / 10, 0, 1)
        wc = np.array(TERRAIN_COLORS["Water"], float)
        cols = np.where(water[..., None], cols * (1 - 0.6 - 0.3 * depth[..., None]) + wc * (0.6 + 0.3 * depth[..., None]), cols)
        img = Image.fromarray(np.clip(cols, 0, 255).astype(np.uint8), "RGB")
        img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
        img.save(path)
        return path


if __name__ == "__main__":
    hv = Haven().build()
    print("height range", hv.H.min(), hv.H.max())
    print(hv.topdown(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "haven_top.png")))

"""Stylized nature props for Dragon Haven: oaks, pines, birches, bushes and
rocks as textured meshes (one GLB, one MeshPart per prop).

Canopies are unions of noisy leaf clumps (SDF -> surface nets -> decimate),
trunks/branches are tubes with flared roots, rocks are faceted noisy SDF
solids. Textures (512 color + normal) are baked from 3D functions."""
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import bake  # noqa: E402
import geom  # noqa: E402
import layout as L  # noqa: E402
import meshops as M  # noqa: E402
from bake import worley, fbm, value_noise, smoothstep  # noqa: E402
from gltf import GLB  # noqa: E402
from export_dragon import safe_normals  # noqa: E402
from sdf import Grid, Ellipsoid, smin  # noqa: E402
from surfacenets import surface_nets, orient_outward  # noqa: E402

OUT = os.path.join(HERE, "out")


def C(rgb):
    return np.asarray(rgb, float) / 255.0


# ------------------------------------------------------------------ SDF helpers
class Noisy:
    """Wraps an SDF grid evaluation with fbm displacement."""
    def __init__(self, amp, cell, seed):
        self.amp, self.cell, self.seed = amp, cell, seed

    def apply(self, g):
        n = g.n
        idx = np.indices(n).reshape(3, -1).T
        P = g.lo + idx * g.h
        D = g.D.reshape(-1)
        near = np.abs(D) < self.amp * 3 + g.h * 3
        Pn = P[near]
        d = (fbm(Pn, self.cell, 3, seed=self.seed) - 0.5) * 2 * self.amp
        D2 = D.copy()
        D2[near] = D[near] + d
        g.D = D2.reshape(n).astype(np.float32)


def merge2(meshes):
    V, F, _ = M.merge([(v, f, None) for v, f in meshes])
    return V, F


def sdf_mesh(prims, h, target, noise=None, smooth=3, pad=2.0):
    lo = np.min([p.bounds()[0] for p in prims], axis=0) - pad
    hi = np.max([p.bounds()[1] for p in prims], axis=0) + pad
    g = Grid(lo, hi, h)
    for p in prims:
        g.add(p)
    if noise is not None:
        noise.apply(g)
    V, F = surface_nets(g.D, g.lo, g.h)
    F = orient_outward(V, F)
    V = M.taubin(V, F, smooth)
    if len(F) > target:
        V, F = M.decimate(V, F, target)
    return V, F, g


# ------------------------------------------------------------------ trees
def branch_tube(a, b, r0, r1, sides=6, samples=6, bend=None):
    pts = [a, (a + b) / 2 + (bend if bend is not None else 0), b]
    V, F, t = geom.tube(pts, lambda u: r0 + (r1 - r0) * u, sides=sides, samples=samples, cap_tip=True)
    return V, geom.fix_winding_local(V, F)


def trunk_with_roots(height, r_base, r_top, lean, rng, sides=9):
    """Trunk tube + flared root buttresses."""
    top = np.array([lean[0], height, lean[1]])
    mid = np.array([lean[0] * 0.35 + rng.uniform(-0.4, 0.4), height * 0.5, lean[1] * 0.35 + rng.uniform(-0.4, 0.4)])
    V, F, t = geom.tube([np.array([0.0, -0.8, 0.0]), mid, top], lambda u: r_base * (1 - u) + r_top * u + r_base * 0.35 * max(0, 1 - u * 6) ** 2,
                        sides=sides, samples=10, cap_tip=True)
    meshes = [(V, geom.fix_winding_local(V, F))]
    n_roots = rng.integers(3, 6)
    for i in range(n_roots):
        a = i / n_roots * 2 * math.pi + rng.uniform(-0.3, 0.3)
        d = np.array([math.cos(a), 0, math.sin(a)])
        p0 = np.array([0.0, r_base * 1.4, 0.0]) + d * r_base * 0.3
        p1 = d * r_base * (2.2 + rng.uniform(0, 0.8)) + np.array([0, -0.5, 0])
        Vr, Fr = branch_tube(p0, p1, r_base * 0.45, r_base * 0.12, sides=6, samples=5)
        meshes.append((Vr, Fr))
    return merge2(meshes), top


def oak(seed, scale=1.0):
    rng = np.random.default_rng(seed)
    H = (9.5 + rng.uniform(-1, 1.5)) * scale
    lean = rng.uniform(-0.8, 0.8, 2) * scale
    (Vt, Ft), top = trunk_with_roots(H, 1.25 * scale, 0.75 * scale, lean, rng)
    trunks = [(Vt, Ft)]
    clumps = []
    # main branches fan out from near the top
    nb = rng.integers(3, 5)
    for i in range(nb):
        a = i / nb * 2 * math.pi + rng.uniform(-0.4, 0.4)
        out = rng.uniform(4.5, 7.0) * scale
        up = rng.uniform(3.0, 5.0) * scale
        start = top - np.array([0, rng.uniform(0.5, 2.5) * scale, 0])
        end = start + np.array([math.cos(a) * out, up, math.sin(a) * out])
        Vb, Fb = branch_tube(start, end, 0.55 * scale, 0.22 * scale, sides=6, samples=6,
                             bend=np.array([0, 0.8 * scale, 0]))
        trunks.append((Vb, Fb))
        clumps.append((end + np.array([0, 1.2 * scale, 0]), rng.uniform(3.6, 4.6) * scale))
        # a sub clump between
        clumps.append((start + (end - start) * 0.55 + np.array([0, 2.2, 0]) * scale, rng.uniform(3.0, 3.8) * scale))
    clumps.append((top + np.array([0, 3.8 * scale, 0]), 4.8 * scale))
    clumps.append((top + np.array([rng.uniform(-1, 1), 6.5, rng.uniform(-1, 1)]) * scale, 3.4 * scale))
    prims = [Ellipsoid(c, np.eye(3), np.array([r * 1.12, r * 0.86, r * 1.12]), k=1.6 * scale) for c, r in clumps]
    Vc, Fc, g = sdf_mesh(prims, 0.42 * scale, 1500, Noisy(0.55 * scale, 2.4 * scale, seed), smooth=4)
    Vt, Ft = merge2(trunks)
    Vt, Ft = M.decimate(Vt, Ft, 520) if len(Ft) > 520 else (Vt, Ft)
    return {"canopy": (Vc, Fc), "trunk": (Vt, Ft), "grid": g, "kind": "Oak"}


def birch(seed, scale=1.0):
    rng = np.random.default_rng(seed)
    H = (12 + rng.uniform(-1, 2)) * scale
    lean = rng.uniform(-0.6, 0.6, 2) * scale
    (Vt, Ft), top = trunk_with_roots(H, 0.75 * scale, 0.42 * scale, lean, rng, sides=8)
    trunks = [(Vt, Ft)]
    clumps = []
    for i in range(5):
        y = H * (0.55 + 0.11 * i)
        a = rng.uniform(0, 2 * math.pi)
        base = np.array([lean[0] * y / H, y, lean[1] * y / H])
        end = base + np.array([math.cos(a) * 2.6, 1.6, math.sin(a) * 2.6]) * scale
        Vb, Fb = branch_tube(base, end, 0.25 * scale, 0.1 * scale, sides=5, samples=4)
        trunks.append((Vb, Fb))
        clumps.append((end + np.array([0, 0.6, 0]) * scale, rng.uniform(2.2, 2.9) * scale))
    clumps.append((top + np.array([0, 1.8, 0]) * scale, 3.0 * scale))
    prims = [Ellipsoid(c, np.eye(3), np.array([r, r * 1.15, r]), k=1.2 * scale) for c, r in clumps]
    Vc, Fc, g = sdf_mesh(prims, 0.36 * scale, 1200, Noisy(0.45 * scale, 1.8 * scale, seed + 5), smooth=4)
    Vt, Ft = merge2(trunks)
    Vt, Ft = M.decimate(Vt, Ft, 420) if len(Ft) > 420 else (Vt, Ft)
    return {"canopy": (Vc, Fc), "trunk": (Vt, Ft), "grid": g, "kind": "Birch"}


class Cone:
    """Rounded cone SDF (apex up), radius rb at the base (y=yb), apex at yt."""
    op = "union"

    def __init__(self, cx, cz, yb, yt, rb, k, droop=0.0):
        self.cx, self.cz, self.yb, self.yt, self.rb, self.k = cx, cz, yb, yt, rb, k
        self.droop = droop
        self.tag = None
        self.color = None

    def bounds(self):
        return (np.array([self.cx - self.rb, self.yb - 2, self.cz - self.rb]),
                np.array([self.cx + self.rb, self.yt + 1, self.cz + self.rb]))

    def eval(self, P):
        x, y, z = P[..., 0] - self.cx, P[..., 1], P[..., 2] - self.cz
        r = np.sqrt(x * x + z * z)
        h = self.yt - self.yb
        # drooping rim: the cone's lower edge bends down with radius
        yy = y - self.yb + self.droop * (r / self.rb) ** 2
        t = np.clip(yy / h, 0, 1)
        rad = self.rb * (1 - t)
        side = (r - rad) * (h / math.hypot(h, self.rb))
        bottom = -yy
        return np.maximum(side, bottom)


def pine(seed, scale=1.0):
    rng = np.random.default_rng(seed)
    H = (17 + rng.uniform(-1.5, 3)) * scale
    (Vt, Ft), top = trunk_with_roots(H * 0.82, 0.95 * scale, 0.3 * scale, np.zeros(2), rng, sides=8)
    tiers = rng.integers(5, 7)
    prims = []
    for i in range(tiers):
        f = i / (tiers - 1)
        yb = H * (0.18 + 0.68 * f)
        rb = (5.6 - 3.6 * f) * scale * rng.uniform(0.9, 1.08)
        yt = yb + (5.2 - 1.2 * f) * scale
        prims.append(Cone(rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2), yb, yt, rb, 0.6, droop=1.2 * scale))
    prims.append(Cone(0, 0, H * 0.86, H * 1.04, 1.6 * scale, 0.3))
    Vc, Fc, g = sdf_mesh(prims, 0.34 * scale, 1500, Noisy(0.42 * scale, 1.3 * scale, seed + 9), smooth=2)
    Vt, Ft = M.decimate(Vt, Ft, 300) if len(Ft) > 300 else (Vt, Ft)
    return {"canopy": (Vc, Fc), "trunk": (Vt, Ft), "grid": g, "kind": "Pine"}


def bush(seed, scale=1.0):
    rng = np.random.default_rng(seed)
    clumps = []
    for i in range(rng.integers(4, 7)):
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(0.5, 2.2)
        clumps.append((np.array([math.cos(a) * r, rng.uniform(1.0, 2.2), math.sin(a) * r]) * scale, rng.uniform(1.4, 2.2) * scale))
    prims = [Ellipsoid(c, np.eye(3), np.array([rr * 1.1, rr * 0.85, rr * 1.1]), k=0.9 * scale) for c, rr in clumps]
    Vc, Fc, g = sdf_mesh(prims, 0.24 * scale, 700, Noisy(0.3 * scale, 1.0 * scale, seed + 3), smooth=4)
    keep = Vc[:, 1] > -0.4
    return {"canopy": (Vc, Fc), "trunk": None, "grid": g, "kind": "Bush"}


class Facets:
    """Rock: intersection of random half-spaces around an ellipsoid (faceted)."""
    op = "union"

    def __init__(self, radii, n_planes, rng, k=0.3):
        self.r = np.asarray(radii, float)
        self.k = k
        self.tag = None
        self.color = None
        dirs = rng.normal(size=(n_planes, 3))
        dirs[:, 1] = np.abs(dirs[:, 1]) * 0.6 + dirs[:, 1] * 0.4
        self.n = dirs / np.linalg.norm(dirs, axis=1, keepdims=True)
        self.d = rng.uniform(0.78, 0.98, n_planes)

    def bounds(self):
        return -self.r * 1.1, self.r * 1.1

    def eval(self, P):
        q = P / self.r
        e = (np.linalg.norm(q, axis=-1) - 1) * self.r.min()
        cut = np.max((q[..., None, :] * self.n).sum(-1) - self.d, axis=-1) * self.r.min()
        return np.maximum(e, cut)


def rock(seed, scale=1.0):
    rng = np.random.default_rng(seed)
    radii = np.array([rng.uniform(3.2, 4.4), rng.uniform(2.0, 2.8), rng.uniform(2.6, 3.6)]) * scale
    prims = [Facets(radii, 14, rng)]
    if rng.random() < 0.6:
        f2 = Facets(radii * rng.uniform(0.5, 0.7), 10, rng)
        off = np.array([rng.uniform(-2, 2), -0.4, rng.uniform(-2, 2)]) * scale

        class Shift:
            op = "union"
            k = 0.4
            tag = None
            color = None

            def bounds(s):
                lo, hi = f2.bounds()
                return lo + off, hi + off

            def eval(s, P):
                return f2.eval(P - off)
        prims.append(Shift())
    Vc, Fc, g = sdf_mesh(prims, 0.18 * scale, 700, Noisy(0.18 * scale, 1.4 * scale, seed + 1), smooth=1)
    Vc[:, 1] -= Vc[:, 1].min() + 0.6 * scale  # sink slightly into the ground
    return {"canopy": None, "rock": (Vc, Fc), "grid": g, "kind": "Rock"}


# ------------------------------------------------------------------ shading
LEAF_COLORS = {
    "Oak": (C((64, 104, 46)), C((112, 146, 58)), C((34, 62, 38))),
    "Pine": (C((40, 74, 52)), C((78, 108, 62)), C((22, 44, 36))),
    "Birch": (C((108, 150, 62)), C((168, 188, 82)), C((60, 96, 46))),
    "Bush": (C((70, 108, 48)), C((120, 150, 64)), C((36, 64, 38))),
}
BARK = {"Oak": C((92, 70, 52)), "Pine": C((86, 62, 46)), "Birch": C((222, 216, 204)), "Bush": C((80, 60, 44))}


def shade_leaves(P, N, kind, grid, s):
    base, light, dark = LEAF_COLORS[kind]
    cell = (0.24 if kind == "Pine" else 0.3) * s
    F1, F2, rid = worley(P, cell, seed=11, stretch=(1, 1.25, 1))
    edge = 1 - smoothstep(0.0, 0.07 * s, F2 - F1)
    # leaf clusters: patches of lighter / darker leaves at a larger scale
    clus = fbm(P, 1.1 * s, 3, seed=13)
    col = base[None, :] * (0.86 + 0.26 * rid)[:, None] * (0.85 + 0.3 * clus)[:, None]
    up = np.clip(N[:, 1], -1, 1)
    col = col + (light - base)[None, :] * np.clip(up * 0.6 + 0.25, 0, 1)[:, None] * (0.55 + 0.45 * clus)[:, None]
    col = col * (1 - 0.16 * edge)[:, None]
    # small dark gaps between leaves
    gaps = smoothstep(0.62, 0.75, value_noise(P, 0.22 * s, seed=17))
    col = col * (1 - 0.35 * gaps)[:, None]
    # ambient occlusion from the canopy SDF (darker toward the inside / underside)
    from shade import sample_grid
    ao = np.ones(len(P))
    for d in (0.6 * s, 1.5 * s, 3.0 * s):
        v = sample_grid(grid, P + N * d)
        ao *= np.clip(0.4 + 0.6 * v / d, 0, 1) ** 0.5
    col = col * (0.42 + 0.58 * ao)[:, None] + dark[None, :] * (1 - ao)[:, None] * 0.25
    big = fbm(P, 3.0 * s, 2, seed=5)
    col *= (0.9 + 0.2 * big)[:, None]
    h = (1 - edge) * 0.025 * s + rid * 0.015 * s - gaps * 0.03 * s
    return np.clip(col, 0, 1), h


def shade_bark(P, N, kind, s):
    base = BARK[kind]
    Q = P * np.array([1.0, 0.18, 1.0])
    streak = fbm(Q, 0.35 * s, 3, seed=21)
    if kind == "Birch":
        marks = smoothstep(0.62, 0.7, fbm(P * np.array([1.4, 3.2, 1.4]), 0.8 * s, 2, seed=31))
        col = base[None, :] * (0.92 + 0.12 * streak)[:, None]
        col = col * (1 - 0.82 * marks)[:, None]
        h = -marks * 0.05 * s
    else:
        groove = 1 - smoothstep(0.35, 0.55, streak)
        col = base[None, :] * (0.78 + 0.36 * streak)[:, None] * (1 - 0.3 * groove)[:, None]
        h = streak * 0.09 * s
    return np.clip(col, 0, 1), h


def shade_rock(P, N, s, seed):
    base = C((128, 126, 120))
    F1, F2, rid = worley(P, 2.6 * s, seed=seed, stretch=(1, 1.6, 1))
    crack = (1 - smoothstep(0.0, 0.05 * s, F2 - F1)) * smoothstep(0.35, 0.6, fbm(P, 1.5 * s, 2, seed=seed + 4))
    n = fbm(P, 0.9 * s, 4, seed=seed + 3)
    strata = 0.5 + 0.5 * np.sin(P[:, 1] / (0.55 * s) + 2.0 * fbm(P, 2.0 * s, 2, seed=seed + 5))
    col = base[None, :] * (0.78 + 0.32 * n)[:, None] * (0.94 + 0.1 * rid)[:, None] * (0.94 + 0.08 * strata)[:, None]
    col = col * (1 - 0.4 * crack)[:, None]
    moss_mask = smoothstep(0.45, 0.8, N[:, 1] + (fbm(P, 1.2 * s, 2, seed=seed + 7) - 0.5) * 0.6)
    moss = C((84, 110, 56)) * (0.85 + 0.3 * fbm(P, 0.3 * s, 2, seed=seed + 9))[:, None]
    col = col * (1 - moss_mask[:, None] * 0.85) + moss * moss_mask[:, None] * 0.85
    h = n * 0.08 * s - crack * 0.05 * s
    return np.clip(col, 0, 1), h


# ------------------------------------------------------------------ assembly / bake
def bake_prop(parts, size=512, pad=3):
    """parts: list of (V, F, shader(P, N) -> (col, height)). Returns merged
    mesh + per-corner UVs + images."""
    at = L.Atlas(size, pad)
    items = []
    for gi, (V, F, shader) in enumerate(parts):
        for ch in L.charts_3d(V, F, min_faces=8, max_ext=None):
            basis = L.oriented_basis(V[F[ch["faces"]].reshape(-1)], ch["basis"][2])
            items.append((gi, at.add_chart(V, F, ch["faces"], basis, 1.0, tag=gi)))
    at.pack()
    col = np.zeros((size, size, 3))
    nrm = np.zeros((size, size, 3))
    nrm[..., 2] = 1
    mask = np.zeros((size, size), bool)
    UVc = [np.zeros((len(F), 3, 2)) for V, F, _ in parts]
    fb = [np.zeros((len(F), 2, 3)) for V, F, _ in parts]
    for gi, it in items:
        UVc[gi][it["faces"]] = at.chart_uv(it)
        u, v, n = it["basis"]
        fb[gi][it["faces"], 0] = -u
        fb[gi][it["faces"], 1] = -v
    for gi, (V, F, shader) in enumerate(parts):
        N = safe_normals(V, F)
        fidx, bary, ix, iy = bake.rasterize(UVc[gi] * size, size)
        P = bake.interp(V[F], fidx, bary)
        Nn = bake.interp(N[F], fidx, bary)
        Nn /= np.maximum(np.linalg.norm(Nn, axis=1, keepdims=True), 1e-9)
        c, h = shader(P, Nn)
        Tr = fb[gi][fidx, 0]
        Tu = fb[gi][fidx, 1]
        Tr = Tr - Nn * np.sum(Tr * Nn, 1, keepdims=True)
        Tr /= np.maximum(np.linalg.norm(Tr, axis=1, keepdims=True), 1e-9)
        Tu = Tu - Nn * np.sum(Tu * Nn, 1, keepdims=True) - Tr * np.sum(Tu * Tr, 1, keepdims=True)
        Tu /= np.maximum(np.linalg.norm(Tu, axis=1, keepdims=True), 1e-9)
        eps = 0.05
        h1 = shader(P + Tr * eps, Nn)[1]
        h2 = shader(P - Tr * eps, Nn)[1]
        h3 = shader(P + Tu * eps, Nn)[1]
        h4 = shader(P - Tu * eps, Nn)[1]
        dr = (h1 - h2) / (2 * eps)
        du = (h3 - h4) / (2 * eps)
        nt = np.stack([-dr, -du, np.ones_like(dr)], 1)
        nt /= np.linalg.norm(nt, axis=1, keepdims=True)
        col[iy, ix] = c
        nrm[iy, ix] = nt
        mask[iy, ix] = True
    col = bake.dilate(col, mask, pad + 4)
    nrm = bake.dilate(nrm, mask, pad + 4)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=2, keepdims=True), 1e-9)
    img_c = Image.fromarray((np.clip(col, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    img_n = Image.fromarray(((nrm * 0.5 + 0.5) * 255 + 0.5).clip(0, 255).astype(np.uint8), "RGB")
    # merge + split by uv
    import uvatlas
    Vs, Fs, UVs, Ns = [], [], [], []
    off = 0
    for gi, (V, F, _) in enumerate(parts):
        N = safe_normals(V, F)
        V2, F2, UV2, N2 = uvatlas.split_by_uv(V, F, UVc[gi], N)
        Vs.append(V2)
        Fs.append(F2 + off)
        UVs.append(UV2)
        Ns.append(N2)
        off += len(V2)
    return np.vstack(Vs), np.vstack(Fs), np.vstack(Ns), np.vstack(UVs), img_c, img_n


def build_props():
    specs = []
    for i, seed in enumerate((11, 23, 37)):
        specs.append((f"Oak{i + 1}", oak(seed, 1.0 + 0.08 * i)))
    for i, seed in enumerate((41, 53, 67)):
        specs.append((f"Pine{i + 1}", pine(seed, 1.0 + 0.06 * i)))
    for i, seed in enumerate((71, 83)):
        specs.append((f"Birch{i + 1}", birch(seed)))
    for i, seed in enumerate((91, 97)):
        specs.append((f"Bush{i + 1}", bush(seed)))
    for i, seed in enumerate((101, 113, 127, 131)):
        specs.append((f"Rock{i + 1}", rock(seed)))
    out = []
    for name, sp in specs:
        kind = sp["kind"]
        parts = []
        s = 1.0
        if sp.get("canopy") is not None:
            V, F = sp["canopy"]
            g = sp["grid"]
            parts.append((V, F, lambda P, N, kind=kind, g=g: shade_leaves(P, N, kind, g, s)))
        if sp.get("trunk") is not None:
            V, F = sp["trunk"]
            parts.append((V, F, lambda P, N, kind=kind: shade_bark(P, N, kind, s)))
        if sp.get("rock") is not None:
            V, F = sp["rock"]
            sd = int(name[-1]) * 7
            parts.append((V, F, lambda P, N, sd=sd: shade_rock(P, N, s, sd)))
        V, F, N, UV, ic, inn = bake_prop(parts)
        out.append((name, V, F, N, UV, ic, inn))
        print(f"  {name}: {len(F)} tris, bbox {np.round(V.min(0), 1)} .. {np.round(V.max(0), 1)}")
    return out


def write_glb(props, path):
    glb = GLB()
    x = 0.0
    for name, V, F, N, UV, ic, inn in props:
        tc = glb.image_png(ic, name + "_Color")
        tn = glb.image_png(inn, name + "_Normal")
        mat = glb.material(name + "Mat", base_tex=tc, normal_tex=tn, roughness=0.9, metallic=0.0)
        mesh = glb.mesh(name, V, N, UV, F, material=mat)
        width = V[:, 0].max() - V[:, 0].min()
        glb.node(name, translation=[x, 0, 0], mesh=mesh, root=True)
        x += width + 6
    glb.write(path)
    return path


if __name__ == "__main__":
    import pickle
    props = build_props()
    with open(os.path.join(OUT, "props.pkl"), "wb") as f:
        pickle.dump(props, f)
    p = write_glb(props, os.path.join(OUT, "HavenProps.glb"))
    print("wrote", p, os.path.getsize(p) // 1024, "KB")

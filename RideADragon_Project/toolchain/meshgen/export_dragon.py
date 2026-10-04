"""Builds a premium skinned dragon mesh for Roblox:
  organic flesh + explicit horns/spines/claws/teeth/wing fingers/membranes,
  skin weights (<=4 per vertex), UV atlas, baked 1024 color / normal /
  metal-roughness textures, exported as a skinned .glb (Roblox 3D Importer).

usage: python3 export_dragon.py GreenDrake [out_dir]"""
import json
import os
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

import meshops as M  # noqa: E402
import bake  # noqa: E402
import layout as L  # noqa: E402
import shade as SH  # noqa: E402
from bake import smoothstep  # noqa: E402
from dragon import DragonMesh  # noqa: E402
from gltf import GLB  # noqa: E402
from rig import Rig  # noqa: E402

TRIM_SCALE = {"HornMain": 1.1, "HornSmall": 0.9, "Spine": 1.0, "Claw": 1.0, "Tooth": 0.9, "Finger": 0.75}
MEMBRANE_SCALE = 0.8
MAX_TRIS = 19800


# ---------------------------------------------------------------- weights
def flesh_weights(dm, V, sigma=0.55):
    S = dm.S
    bones = sorted({p.tag for p in dm.prims if p.tag})
    D = np.full((len(V), len(bones)), 1e3)
    for p in dm.prims:
        if not p.tag:
            continue
        j = bones.index(p.tag)
        lo, hi = p.bounds()
        pad = 3.0 * S
        m = np.all((V > lo - pad) & (V < hi + pad), axis=1)
        if not np.any(m):
            continue
        D[m, j] = np.minimum(D[m, j], p.eval(V[m]))
    s = sigma * S
    W = np.exp(-(np.maximum(D, 0) / s) ** 2)
    near = np.argmin(D, axis=1)
    r = np.arange(len(V))
    W[r, near] = np.maximum(W[r, near], 1e-3)
    return bones, W


def fix_jaw(dm, V, bidx, W):
    mb = dm.mouth_box
    if mb is None or "Jaw" not in bidx:
        return W
    S = dm.S
    H, J = bidx["Head"], bidx["Jaw"]
    R = mb.R
    fwd, up, right = -R[:, 2], R[:, 1], R[:, 0]
    d = V - mb.c
    along = d @ fwd
    vert = d @ up
    hinge = -mb.h[2]
    infront = smoothstep(hinge - 0.7 * S, hinge + 0.05 * S, along)
    hj = W[:, H] + W[:, J]
    tot = W.sum(axis=1)
    near = (hj > 0.05 * tot).astype(float)
    above = vert > 0
    th = np.where(above, hj, 0.0)
    tj = np.where(above, 0.0, hj)
    k = infront * near
    W = W.copy()
    W[:, H] = W[:, H] * (1 - k) + th * k
    W[:, J] = W[:, J] * (1 - k) + tj * k
    return W


def dense_weights(wspec, nv, bidx):
    Wd = np.zeros((nv, len(bidx)))
    if isinstance(wspec, dict):
        for b, w in wspec.items():
            Wd[:, bidx[b]] += w
    else:
        for i, d in enumerate(wspec):
            for b, w in d.items():
                Wd[i, bidx[b]] += w
    return Wd


def top4(W):
    idx = np.argsort(-W, axis=1)[:, :4]
    w = np.take_along_axis(W, idx, 1)
    w = np.where(w < 0.03 * w[:, :1], 0.0, w)
    s = w.sum(axis=1, keepdims=True)
    w = w / np.maximum(s, 1e-12)
    idx = np.where(w > 0, idx, 0)
    return idx.astype(np.uint16), w.astype(np.float32)


# ---------------------------------------------------------------- tangents
def tangents(V, F, UV, N):
    """Per-vertex tangent (xyz,w) for image-right / image-up (v_up = -v)."""
    p0, p1, p2 = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    t0, t1, t2 = UV[F[:, 0]], UV[F[:, 1]], UV[F[:, 2]]
    e1, e2 = p1 - p0, p2 - p0
    du1, dv1 = t1[:, 0] - t0[:, 0], -(t1[:, 1] - t0[:, 1])
    du2, dv2 = t2[:, 0] - t0[:, 0], -(t2[:, 1] - t0[:, 1])
    det = du1 * dv2 - du2 * dv1
    r = np.where(np.abs(det) < 1e-14, 0.0, 1.0 / np.where(np.abs(det) < 1e-14, 1.0, det))
    T = (e1 * dv2[:, None] - e2 * dv1[:, None]) * r[:, None]
    B = (e2 * du1[:, None] - e1 * du2[:, None]) * r[:, None]
    Tv = np.zeros_like(V)
    Bv = np.zeros_like(V)
    for k in range(3):
        np.add.at(Tv, F[:, k], T)
        np.add.at(Bv, F[:, k], B)
    Tv = Tv - N * np.sum(Tv * N, axis=1, keepdims=True)
    ln = np.linalg.norm(Tv, axis=1, keepdims=True)
    fallback = np.cross(N, np.array([0.0, 1.0, 0.0]))
    fallback[np.linalg.norm(fallback, axis=1) < 1e-6] = [1, 0, 0]
    Tv = np.where(ln > 1e-9, Tv / np.maximum(ln, 1e-12), fallback / np.linalg.norm(fallback, axis=1, keepdims=True))
    w = np.sign(np.sum(np.cross(N, Tv) * Bv, axis=1))
    w[w == 0] = 1.0
    return np.concatenate([Tv, w[:, None]], axis=1)


def safe_normals(V, F):
    """Vertex normals with fallbacks for degenerate spots (tips, cap centers)."""
    N = M.vertex_normals(V, F)
    ln = np.linalg.norm(N, axis=1)
    bad = ~np.isfinite(ln) | (ln < 0.5)
    if bad.any():
        # unweighted average of unit face normals around the vertex
        a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
        fn = np.cross(b - a, c - a)
        fl = np.linalg.norm(fn, axis=1, keepdims=True)
        fn = np.where(fl > 1e-12, fn / np.maximum(fl, 1e-12), 0.0)
        acc = np.zeros_like(V)
        for k in range(3):
            np.add.at(acc, F[:, k], fn)
        al = np.linalg.norm(acc, axis=1)
        use = bad & (al > 1e-6)
        N[use] = acc[use] / al[use][:, None]
        still = bad & ~use
        if still.any():
            d = V[still] - V.mean(axis=0)
            dl = np.linalg.norm(d, axis=1, keepdims=True)
            N[still] = np.where(dl > 1e-9, d / np.maximum(dl, 1e-9), np.array([0.0, 1.0, 0.0]))
    return N / np.linalg.norm(N, axis=1, keepdims=True)


# ---------------------------------------------------------------- main build
class Group:
    def __init__(self, name, V, F, N, W, family, piece=None):
        self.name, self.V, self.F, self.N, self.W = name, V, F, N, W
        self.family, self.piece = family, piece
        self.UVc = None  # per-corner uv (nf,3,2)
        self.face_basis = None  # (nf,2,3) image-right/-up directions for 3D charts
        self.attrs = {}


def build_dragon(species, flesh_target=12000):
    import pickle
    src_json = os.path.join(HERE, "out", f"{species}.json")
    rig = Rig.load(src_json)
    dm = DragonMesh(rig)
    t0 = time.time()
    dm.collect_flesh()
    dm.collect_carves()
    cache = os.path.join(HERE, "out", f".{species}_flesh_{flesh_target}.pkl")
    deps = [src_json] + [os.path.join(HERE, f) for f in ("dragon.py", "sdf.py", "surfacenets.py", "meshops.py")]
    if os.path.exists(cache) and os.path.getmtime(cache) > max(os.path.getmtime(p) for p in deps):
        with open(cache, "rb") as f:
            dm.flesh, dm.grid, dm.raw_faces = pickle.load(f)
    else:
        dm.build_flesh(target_faces=flesh_target)
        with open(cache, "wb") as f:
            pickle.dump((dm.flesh, dm.grid, dm.raw_faces), f)
    # drape layers evaluate against the final body field (also after a cache hit)
    from shade import sample_grid
    for dp in getattr(dm, "drapes", []):
        dp.D0 = lambda P, g=dm.grid: sample_grid(g, P.reshape(-1, 3)).reshape(P.shape[:-1])
    print(f"[mesh] flesh {len(dm.flesh[1])} faces (raw {dm.raw_faces}) in {time.time() - t0:.1f}s")
    dm.add_horns()
    dm.add_spines()
    dm.add_claws_teeth()
    dm.add_tail_tip()
    dm.add_wing_bones_and_membranes()
    return rig, dm


def assemble(rig, dm):
    bones = rig.bone_order()
    bidx = {b: i for i, b in enumerate(bones)}
    groups = []
    Vf, Ff = dm.flesh
    Nf = safe_normals(Vf, Ff)
    fb, Wf = flesh_weights(dm, Vf)
    Wd = np.zeros((len(Vf), len(bones)))
    for j, b in enumerate(fb):
        Wd[:, bidx[b]] = Wf[:, j]
    Wd = fix_jaw(dm, Vf, bidx, Wd)
    g = Group("flesh", Vf, Ff, Nf, Wd, "3d")
    regs, Wr = dm.flesh_regions(Vf)
    reg = {r: Wr[:, j] for j, r in enumerate(regs)}
    for k in ("Main", "Dark", "Belly", "Leather", "Cloth", "Gold", "Eye"):
        reg.setdefault(k, np.zeros(len(Vf)))
    # crisp edges for tack (blanket / trims / leather): they are separate materials
    hard = ("Cloth", "Gold", "Leather")
    before = sum(reg[k] for k in hard)
    for k in hard:
        reg[k] = smoothstep(0.32, 0.62, reg[k])
    after = np.clip(sum(reg[k] for k in hard), 0, 1)
    tot = sum(reg[k] for k in hard)
    for k in hard:
        reg[k] = np.where(tot > 1, reg[k] / np.maximum(tot, 1e-9), reg[k])
    scale_soft = (1 - after) / np.maximum(1 - before, 1e-6)
    for k in ("Main", "Dark", "Belly", "Eye"):
        reg[k] = reg[k] * np.clip(scale_soft, 0, 4)
    g.attrs["reg"] = reg
    sfb = np.array([SH.bone_scale_factor(b) for b in bones])
    exb = np.array([SH.bone_extremity(b) for b in bones])
    Wn = Wd / np.maximum(Wd.sum(axis=1, keepdims=True), 1e-12)
    g.attrs["sf"] = Wn @ sfb
    g.attrs["ext"] = Wn @ exb
    groups.append(g)
    for i, pc in enumerate(dm.pieces):
        N = safe_normals(pc.V, pc.F)
        W = dense_weights(pc.W, len(pc.V), bidx)
        if pc.kind == "solid3d":
            fam = "3d"
        elif pc.kind.startswith("membrane"):
            fam = "membrane"
        else:
            fam = "trim"
        gg = Group(f"{pc.region}_{i}", pc.V, pc.F, N, W, fam, piece=pc)
        if fam == "3d":
            n = len(pc.V)
            gg.attrs["reg"] = {k: (np.ones(n) if k == "Dark" else np.zeros(n))
                               for k in ("Main", "Dark", "Belly", "Leather", "Cloth", "Gold", "Eye")}
            Wn = W / np.maximum(W.sum(axis=1, keepdims=True), 1e-12)
            gg.attrs["sf"] = Wn @ sfb
            gg.attrs["ext"] = Wn @ exb
        groups.append(gg)
    return bones, bidx, groups


def layout_atlas(rig, groups, size=1024, pad=4):
    def make(trim_px=None):
        at = L.Atlas(size, pad)
        items = []
        for g in groups:
            if g.family == "3d":
                for ch in L.charts_3d(g.V, g.F, min_faces=24 if g.name == "flesh" else 1, max_ext=6.5 * rig.S):
                    basis = L.oriented_basis(g.V[g.F[ch["faces"]].reshape(-1)], ch["basis"][2])
                    it = at.add_chart(g.V, g.F, ch["faces"], basis, 1.0, tag=g.name)
                    items.append((g, it))
            elif g.family == "membrane":
                ex = g.piece.extra
                if ex["side"] == "R" and ex["sheet"] == "top":
                    basis = L.oriented_basis(g.V, ex["normal"])
                    it = at.add_chart(g.V, g.F, np.arange(len(g.F)), basis, MEMBRANE_SCALE, tag=("mem", ex["panel"]))
                    items.append((g, it))
        rects = {}
        if trim_px:
            for name, (w, h) in trim_px.items():
                rects[name] = at.add_rect(w, h, name)
        at.pack()
        return at, items, rects

    at0, _, _ = make()
    d0 = at0.density
    # trim physical sizes: mean circumference x max length
    trims = {}
    for g in groups:
        if g.family != "trim":
            continue
        ex = g.piece.extra
        name = ex["trim"]
        P = g.V
        if g.piece.kind == "tube":
            sides = ex["sides"]
            rings = P[: (len(P) - 1) // sides * sides].reshape(-1, sides, 3)
            circ = np.mean(np.sum(np.linalg.norm(np.diff(np.concatenate([rings, rings[:, :1]], 1), axis=1), axis=2), axis=1))
            length = ex.get("length", np.linalg.norm(P[-1] - P[0]))
        else:
            rings = P[: (len(P) - 2) // 4 * 4].reshape(-1, 4, 3)
            circ = np.mean(np.sum(np.linalg.norm(np.diff(np.concatenate([rings, rings[:, :1]], 1), axis=1), axis=2), axis=1))
            length = np.linalg.norm(P[-2] - P[0])
        c0, l0 = trims.get(name, (0.0, 0.0))
        trims[name] = (max(c0, circ), max(l0, length))
    trim_px = {}
    for name, (circ, length) in trims.items():
        k = d0 * TRIM_SCALE.get(name, 1.0)
        trim_px[name] = (int(np.clip(np.ceil(circ * k * 0.75), 12, 256)), int(np.clip(np.ceil(length * k), 12, 512)))
    at, items, rects = make(trim_px)
    print(f"[atlas] density {at.density:.1f} px/stud (pre {d0:.1f}); charts {len(items)}; trims {trim_px}")
    # assign UVs
    mem_uv = {}
    for g, it in items:
        uvc = at.chart_uv(it)
        if g.UVc is None:
            g.UVc = np.zeros((len(g.F), 3, 2))
            g.face_basis = np.zeros((len(g.F), 2, 3))
        g.UVc[it["faces"]] = uvc
        u, v, n = it["basis"]
        g.face_basis[it["faces"], 0] = -u
        g.face_basis[it["faces"], 1] = -v
        g.attrs.setdefault("charts", []).append(it)
        if g.family == "membrane":
            vuv = np.zeros((len(g.V), 2))
            vuv[g.F.reshape(-1)] = uvc.reshape(-1, 2)
            mem_uv[g.piece.extra["panel"]] = vuv
    for g in groups:
        if g.family == "membrane":
            g.UVc = mem_uv[g.piece.extra["panel"]][g.F]
        elif g.family == "trim":
            ex = g.piece.extra
            sides = ex.get("sides", 4)
            Sc, Tc = L.ring_param_uv(g.piece, sides, reverse=(g.piece.kind == "blade"))
            g.UVc = at.rect_uv(rects[ex["trim"]], Sc, Tc)
    return at, rects


# ---------------------------------------------------------------- baking
def bake_textures(rig, dm, groups, at, rects, size=1024):
    S = rig.S
    col = np.zeros((size, size, 3))
    rough = np.zeros((size, size))
    metal = np.zeros((size, size))
    nrm = np.zeros((size, size, 3))
    nrm[..., 2] = 1.0
    mask = np.zeros((size, size), bool)
    fs = SH.FleshShader(rig, dm)
    t0 = time.time()
    # ---- 3D families (flesh + solid pieces)
    for g in groups:
        if g.family != "3d":
            continue
        uvpx = g.UVc * size
        fidx, bary, ix, iy = bake.rasterize(uvpx, size)
        P = bake.interp(g.V[g.F], fidx, bary)
        N = bake.interp(g.N[g.F], fidx, bary)
        N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
        reg = {k: bake.interp(v[g.F][..., None], fidx, bary)[:, 0] for k, v in g.attrs["reg"].items()}
        sf = bake.interp(g.attrs["sf"][g.F][..., None], fidx, bary)[:, 0]
        ext = bake.interp(g.attrs["ext"][g.F][..., None], fidx, bary)[:, 0]
        c, r, m, (skin, bel, lea, clo) = fs.shade(P, N, reg, sf, ext)
        # tangent frame of the chart (image right / up projected on the surface)
        Tr = g.face_basis[fidx, 0]
        Tu = g.face_basis[fidx, 1]
        Tr = Tr - N * np.sum(Tr * N, 1, keepdims=True)
        Tr /= np.maximum(np.linalg.norm(Tr, axis=1, keepdims=True), 1e-9)
        Tu = Tu - N * np.sum(Tu * N, 1, keepdims=True) - Tr * np.sum(Tu * Tr, 1, keepdims=True)
        Tu /= np.maximum(np.linalg.norm(Tu, axis=1, keepdims=True), 1e-9)
        eps = 0.02 * S
        hfun = lambda Q: fs.height(Q, sf, skin, bel, True, (lea, clo))  # noqa: E731
        dr = (hfun(P + Tr * eps) - hfun(P - Tr * eps)) / (2 * eps)
        du = (hfun(P + Tu * eps) - hfun(P - Tu * eps)) / (2 * eps)
        nt = np.stack([-dr, -du, np.ones(len(dr))], axis=1)
        nt /= np.linalg.norm(nt, axis=1, keepdims=True)
        col[iy, ix] = c
        rough[iy, ix] = r
        metal[iy, ix] = m
        nrm[iy, ix] = nt
        mask[iy, ix] = True
        print(f"[bake] {g.name}: {len(fidx)} texels  {time.time() - t0:.1f}s")
    # ---- membranes (bake the right top sheet once; all copies share UVs)
    pinfo = {}
    for g in groups:
        if g.family == "membrane" and g.piece.extra["side"] == "R" and g.piece.extra["sheet"] == "top":
            ex = g.piece.extra
            pid = ex["panel"]
            mid = ex["mid"]
            # angular span (arc length at r=1) for fan panels: |A-W| * angle
            bary_v = ex["bary"]
            # corners: vertices with bary (1,0,0), (0,1,0), (0,0,1)
            ia = int(np.argmax(bary_v[:, 0]))
            ib = int(np.argmax(bary_v[:, 1]))
            ic = int(np.argmax(bary_v[:, 2]))
            A, B, Cc = mid[ia], mid[ib], mid[ic]
            da, db = B - A, Cc - A
            ang = np.arccos(np.clip(da @ db / (np.linalg.norm(da) * np.linalg.norm(db)), -1, 1))
            pinfo[pid] = {"span": ang * 0.5 * (np.linalg.norm(da) + np.linalg.norm(db))}
    for g in groups:
        if not (g.family == "membrane" and g.piece.extra["side"] == "R" and g.piece.extra["sheet"] == "top"):
            continue
        ex = g.piece.extra
        uvpx = g.UVc * size
        fidx, bary, ix, iy = bake.rasterize(uvpx, size)
        P = bake.interp(g.V[g.F], fidx, bary)
        B3 = bake.interp(ex["bary"][g.F], fidx, bary)
        pid = np.full(len(fidx), ex["panel"])
        c, r, m = SH.membrane_shade(pid, B3, P, rig, pinfo)
        col[iy, ix] = c
        rough[iy, ix] = r
        metal[iy, ix] = m
        nrm[iy, ix] = [0, 0, 1]
        mask[iy, ix] = True
    print(f"[bake] membranes  {time.time() - t0:.1f}s")
    # ---- trims
    trim_geo = {}
    for g in groups:
        if g.family == "trim":
            ex = g.piece.extra
            trim_geo.setdefault(ex["trim"], ex.get("length", 1.0))
    for name, it in rects.items():
        x0, y0 = it["x"], it["y"]
        w, h = it["wpx"] + 2 * at.pad, it["hpx"] + 2 * at.pad
        yy, xx = np.mgrid[y0:y0 + h, x0:x0 + w]
        xx, yy = xx.reshape(-1), yy.reshape(-1)
        s = np.clip((xx + 0.5 - x0 - at.pad) / it["wpx"], 0, 1)
        t = np.clip(1 - (yy + 0.5 - y0 - at.pad) / it["hpx"], 0, 1)
        length = trim_geo.get(name, 1.0)
        c, r, m, hgt = SH.trim_shade(name, s, t, rig, length=length)
        # normal from height along t: d/dl = d/dt / length
        dt = 1.0 / max(it["hpx"], 1)
        _, _, _, h2 = SH.trim_shade(name, s, np.clip(t + dt, 0, 1), rig, length=length)
        _, _, _, h1 = SH.trim_shade(name, s, np.clip(t - dt, 0, 1), rig, length=length)
        dl = (h2 - h1) / (2 * dt * max(length, 1e-3))
        nt = np.stack([np.zeros_like(dl), -dl, np.ones_like(dl)], 1)
        nt /= np.linalg.norm(nt, axis=1, keepdims=True)
        col[yy, xx] = c
        rough[yy, xx] = r
        metal[yy, xx] = m
        nrm[yy, xx] = nt
        mask[yy, xx] = True
    print(f"[bake] trims  {time.time() - t0:.1f}s; coverage {mask.mean() * 100:.1f}%")
    it = at.pad + 6
    col = bake.dilate(col, mask, it)
    rough = bake.dilate(rough[..., None], mask, it)[..., 0]
    metal = bake.dilate(metal[..., None], mask, it)[..., 0]
    nrm = bake.dilate(nrm, mask, it)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=2, keepdims=True), 1e-9)
    img_c = Image.fromarray((np.clip(col, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    img_n = Image.fromarray(((nrm * 0.5 + 0.5) * 255 + 0.5).clip(0, 255).astype(np.uint8), "RGB")
    mr = np.stack([np.full_like(rough, 1.0), rough, metal], axis=2)
    img_mr = Image.fromarray((mr * 255 + 0.5).clip(0, 255).astype(np.uint8), "RGB")
    img_r = Image.fromarray((rough * 255 + 0.5).clip(0, 255).astype(np.uint8), "L")
    img_m = Image.fromarray((metal * 255 + 0.5).clip(0, 255).astype(np.uint8), "L")
    return img_c, img_n, img_mr, img_r, img_m


# ---------------------------------------------------------------- export
def merge_groups(groups, bones):
    Vs, Fs, Ns, UVs, Ws = [], [], [], [], []
    off = 0
    for g in groups:
        V2, F2, UV2, N2, W2 = L_split(g)
        Vs.append(V2)
        Fs.append(F2 + off)
        Ns.append(N2)
        UVs.append(UV2)
        Ws.append(W2)
        off += len(V2)
    return np.vstack(Vs), np.vstack(Fs), np.vstack(Ns), np.vstack(UVs), np.vstack(Ws)


def L_split(g):
    import uvatlas
    V2, F2, UV2, N2, W2 = uvatlas.split_by_uv(g.V, g.F, g.UVc, g.N, g.W)
    return V2, F2, UV2, N2, W2


def socket_list(rig, dm):
    """Extra (unweighted) bones that mark effect / logic points. In Roblox a
    Bone is an Attachment, so trails, particles and Animator fold-solving can
    use them by name exactly like the part-built dragon's attachments."""
    keep = ("MemF1", "MemF2", "MemF3", "WingTip", "WingTipInner", "SaddlePoint", "FootFL", "FootFR", "FootBL",
            "FootBR", "Mouth")
    out = []
    for name, a in rig.atts.items():
        if name == "RootAttachment" or not name.startswith(keep):
            continue
        bone = a["bone"] if a["bone"] in rig.bones else "Root"
        pos = np.array(a["pos"], float)
        if name == "Mouth" and getattr(dm, "head_spec", None) is not None:
            hs = dm.head_spec
            pos = hs["P"](0, hs["m"] - 0.02, 3.0 * hs["sn"])
            bone = "Jaw" if "Jaw" in rig.bones else bone
        out.append((name, bone, pos))
    return out


def write_glb(path, name, rig, bones, V, F, N, UV, W, imgs, sockets=()):
    img_c, img_n, img_mr = imgs
    glb = GLB()
    ji, jw = top4(W)
    T4 = tangents(V, F, UV, N)
    # joint nodes: rig bones (weighted) followed by sockets (unweighted)
    joints = [(b, rig.bones[b]["parent"], rig.pivot(b)) for b in bones]
    joints += [(s, parent, pos) for s, parent, pos in sockets]
    pivot = {j[0]: j[2] for j in joints}
    node_of = {}
    for jn, _, _ in joints:
        node_of[jn] = len(glb.json["nodes"])
        glb.json["nodes"].append({"name": jn})
    for jn, p, piv in joints:
        if p is None or p not in node_of:
            glb.json["nodes"][node_of[jn]]["translation"] = [float(x) for x in piv]
            glb.json["scenes"][0]["nodes"].append(node_of[jn])
        else:
            glb.json["nodes"][node_of[jn]]["translation"] = [float(x) for x in (piv - pivot[p])]
            glb.json["nodes"][node_of[p]].setdefault("children", []).append(node_of[jn])
    ibm = np.zeros((len(joints), 16), np.float32)
    for i, (jn, _, piv) in enumerate(joints):
        m = np.eye(4)
        m[:3, 3] = -piv
        ibm[i] = m.T.reshape(16)  # column-major
    bones_all = [j[0] for j in joints]
    tc = glb.image_png(img_c, name + "_Color")
    tn = glb.image_png(img_n, name + "_Normal")
    tm = glb.image_png(img_mr, name + "_MR")
    mat = glb.material(name + "Skin", base_tex=tc, normal_tex=tn, rough_tex=tm, roughness=1.0, metallic=1.0)
    attrs = {
        "POSITION": glb.accessor(V.astype(np.float32), "VEC3", 34962, minmax=True),
        "NORMAL": glb.accessor(N.astype(np.float32), "VEC3", 34962),
        "TANGENT": glb.accessor(T4.astype(np.float32), "VEC4", 34962),
        "TEXCOORD_0": glb.accessor(UV.astype(np.float32), "VEC2", 34962),
        "JOINTS_0": glb.accessor(ji.astype(np.uint16), "VEC4", 34962),
        "WEIGHTS_0": glb.accessor(jw.astype(np.float32), "VEC4", 34962),
    }
    idx_dtype = np.uint32 if len(V) > 65535 else np.uint16
    prim = {"attributes": attrs, "indices": glb.accessor(F.reshape(-1).astype(idx_dtype), "SCALAR", 34963),
            "mode": 4, "material": mat}
    glb.json["meshes"].append({"name": name, "primitives": [prim]})
    acc = glb.accessor(ibm, "MAT4")
    glb.json["skins"].append({"name": name + "Skin", "joints": [node_of[b] for b in bones_all],
                              "inverseBindMatrices": acc, "skeleton": node_of[bones[0]]})
    mesh_node = len(glb.json["nodes"])
    glb.json["nodes"].append({"name": name, "mesh": 0, "skin": 0})
    glb.json["scenes"][0]["nodes"].append(mesh_node)
    glb.write(path)
    return ji, jw, T4


def main(species="GreenDrake", out_dir=None):
    out_dir = out_dir or os.path.join(HERE, "out")
    os.makedirs(out_dir, exist_ok=True)
    t0 = time.time()
    rig, dm = build_dragon(species, flesh_target=12000)
    bones, bidx, groups = assemble(rig, dm)
    tris = sum(len(g.F) for g in groups)
    print(f"[mesh] total triangles {tris} ({len(groups)} groups)")
    assert tris <= MAX_TRIS, f"too many triangles: {tris}"
    at, rects = layout_atlas(rig, groups)
    imgs = bake_textures(rig, dm, groups, at, rects)
    img_c, img_n, img_mr, img_r, img_m = imgs
    for im, suf in ((img_c, "color"), (img_n, "normal"), (img_mr, "mr"), (img_r, "rough"), (img_m, "metal")):
        im.save(os.path.join(out_dir, f"{species}_{suf}.png"))
    V, F, N, UV, W = merge_groups(groups, bones)
    path = os.path.join(out_dir, f"{species}.glb")
    sockets = socket_list(rig, dm)
    ji, jw, T4 = write_glb(path, species, rig, bones, V, F, N, UV, W, (img_c, img_n, img_mr), sockets)
    np.savez_compressed(os.path.join(out_dir, f"{species}_mesh.npz"), V=V, F=F, N=N, UV=UV, ji=ji, jw=jw, T4=T4,
                        bones=np.array(bones))
    meta = {"species": species, "bones": bones, "pivots": {b: [float(x) for x in rig.pivot(b)] for b in bones},
            "parents": {b: rig.bones[b]["parent"] for b in bones}, "triangles": int(len(F)), "vertices": int(len(V)),
            "sockets": [{"name": s, "bone": b, "pos": [float(x) for x in p]} for s, b, p in sockets]}
    with open(os.path.join(out_dir, f"{species}_rig.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(f"[done] {path}: {len(V)} verts, {len(F)} tris, {os.path.getsize(path) / 1e6:.2f} MB, {time.time() - t0:.1f}s")
    return rig, dm, groups, (V, F, N, UV, W, T4), imgs


if __name__ == "__main__":
    main(*(sys.argv[1:] or []))

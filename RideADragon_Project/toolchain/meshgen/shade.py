"""Procedural surface shading for baked dragon textures.

Everything is evaluated per texel from 3D position / normal (flesh) or from
(around, along) parameters (trims) or panel barycentrics (membranes).
Returns base color (sRGB 0..1), roughness, metalness and a height field used
to derive the tangent-space normal map."""
import numpy as np

from bake import worley, fbm, value_noise, smoothstep
from rig import Rig, ellipsoid_axis_endpoints

EXTRA_COLORS = {"Leather": (92, 56, 33), "Cloth": (96, 22, 28), "Gold": (196, 156, 78), "Mouth": (40, 16, 18)}


def C(rgb):
    return np.asarray(rgb, float) / 255.0


def mix(a, b, t):
    t = np.asarray(t, float)
    if t.ndim == 1 and np.ndim(a) >= 1 and np.shape(a)[-1] == 3:
        t = t[:, None]
    return a + (b - a) * t


def sample_grid(grid, P):
    q = (P - grid.lo) / grid.h
    i0 = np.floor(q).astype(np.int64)
    f = q - i0
    n = np.asarray(grid.n)
    out = np.full(len(P), 1e3)
    ok = np.all((i0 >= 0) & (i0 < n - 1), axis=1)
    i, ff = i0[ok], f[ok]
    acc = np.zeros(len(i))
    D = grid.D
    for dx in (0, 1):
        wx = ff[:, 0] if dx else 1 - ff[:, 0]
        for dy in (0, 1):
            wy = ff[:, 1] if dy else 1 - ff[:, 1]
            for dz in (0, 1):
                wz = ff[:, 2] if dz else 1 - ff[:, 2]
                acc += wx * wy * wz * D[i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz]
    out[ok] = acc
    return out


# per-bone scale-size factor (relative scale cell size) and extremity darkness
def bone_scale_factor(name):
    if name in ("Head", "Jaw"):
        return 0.42
    if name.startswith("Neck"):
        return 0.75 + 0.05 * (4 - min(int(name[4:] or 1), 4)) if name[4:].isdigit() else 0.8
    if name in ("Chest", "Body", "Pelvis"):
        return 1.2
    if name.startswith("Tail") and name[4:].isdigit():
        i = int(name[4:])
        return max(0.55, 1.1 - 0.08 * i)
    if name.startswith(("Hand", "Foot")):
        return 0.55
    if name.startswith(("Arm", "Leg")):
        return 0.78 if name.endswith("1") else 0.65
    if name.startswith("Wing"):
        return 0.6
    return 1.0


def bone_extremity(name):
    if name.startswith(("Hand", "Foot")):
        return 1.0
    if name.startswith(("Arm", "Leg")) and name.endswith("2"):
        return 0.55
    if name.startswith("Wing"):
        return 0.6
    if name.startswith("Tail") and name[4:].isdigit():
        return max(0.0, (int(name[4:]) - 3) / 4.0)
    return 0.0


class FleshShader:
    def __init__(self, rig, dm):
        self.rig, self.dm = rig, dm
        S = self.S = rig.S
        pal = rig.defn["Palette"]
        self.col = {k: C(v) for k, v in pal.items()}
        for k, v in EXTRA_COLORS.items():
            self.col[k] = C(v)
        mesh = rig.defn.get("Mesh", {})
        self.cell = mesh.get("ScaleSize", 0.42) * S
        self.pattern = mesh.get("Pattern", "Dapples")
        bones = rig.bones
        neck = sorted([n for n in bones if n.startswith("Neck") and n[4:].isdigit()], key=lambda n: -int(n[4:]))
        tail = sorted([n for n in bones if n.startswith("Tail") and n[4:].isdigit()], key=lambda n: int(n[4:]))
        names = ["Head"] + neck + ["Chest", "Body", "Pelvis"] + tail
        pts = [rig.pivot(n) for n in names]
        # extend forward to the snout tip and back to the tail end
        sc, R, fwd, up, right = dm.head_frame()
        snout = rig.one("Snout")
        if snout:
            a, b = ellipsoid_axis_endpoints(snout)
            front = a if (a - sc) @ fwd > (b - sc) @ fwd else b
            pts = [front] + pts
        last = rig.one(tail[-1], tail[-1]) if tail else None
        if last:
            a, b = ellipsoid_axis_endpoints(last)
            pts.append(b if b[2] > a[2] else a)
        self.chain = np.array(pts)
        seg = np.diff(self.chain, axis=0)
        self.seg_len = np.linalg.norm(seg, axis=1)
        self.cum = np.concatenate([[0], np.cumsum(self.seg_len)])
        # local body radius at each chain node (for belly-plate spacing)
        rad = []
        for p in self.chain:
            q = dm.surface_point(p, [0, -1, 0], max_dist=12 * S)
            rad.append(max(0.25 * S, np.linalg.norm(q - p)))
        self.chain_rad = np.array(rad)
        spacing = np.clip(self.chain_rad * 0.34, 0.16 * S, 0.5 * S)
        # plate index x(s) = integral ds / spacing(s)
        mid = 0.5 * (spacing[:-1] + spacing[1:])
        self.plate_x = np.concatenate([[0], np.cumsum(self.seg_len / mid)])
        self.head = (sc, fwd, up, right)
        self.eyes = []
        hs = getattr(dm, "head_spec", None)
        eye_src = [(c, r) for c, r, side in hs["eyes"]] if hs else [(Rig.frame(e)[0], max(e["size"]) * 0.5) for e in rig.find("Eye")]
        for c, r in eye_src:
            o = c - sc
            o = o - up * (o @ up) * 0.6
            o = o / np.linalg.norm(o) + fwd * 0.35
            o /= np.linalg.norm(o)
            uy = up - o * (up @ o)
            uy /= np.linalg.norm(uy)
            rx = np.cross(uy, o)
            self.eyes.append((c, r, o, rx, uy))
        self.nostrils = hs["nostrils"] if hs else [(Rig.frame(n)[0], n["size"][0] * 0.62) for n in rig.find("Nostril")]
        self.mouth = dm.mouth_box

    # ---------------------------------------------------------------- fields
    def chain_coords(self, P):
        A = self.chain[:-1]
        best = np.full(len(P), 1e9)
        s = np.zeros(len(P))
        x = np.zeros(len(P))
        for i in range(len(A)):
            seg = self.chain[i + 1] - A[i]
            L2 = max(seg @ seg, 1e-9)
            t = np.clip(((P - A[i]) @ seg) / L2, 0, 1)
            q = A[i] + t[:, None] * seg
            d = np.linalg.norm(P - q, axis=1)
            m = d < best
            best = np.where(m, d, best)
            s = np.where(m, self.cum[i] + t * self.seg_len[i], s)
            x = np.where(m, self.plate_x[i] + t * (self.plate_x[i + 1] - self.plate_x[i]), x)
        return s, x, best

    def scales(self, P, sf):
        """Scale pattern blended over three cell sizes. Returns height (studs),
        groove (1 in the gaps), per-scale random value and plateau."""
        n = len(P)
        levels = np.array([0.5, 0.8, 1.25])
        h = np.zeros(n)
        groove = np.zeros(n)
        rid = np.zeros(n)
        top = np.zeros(n)
        sfc = np.clip(sf, levels[0], levels[-1])
        for li, lv in enumerate(levels):
            # hat weight
            if li == 0:
                w = np.clip((levels[1] - sfc) / (levels[1] - levels[0]), 0, 1)
            elif li == len(levels) - 1:
                w = np.clip((sfc - levels[-2]) / (levels[-1] - levels[-2]), 0, 1)
            else:
                w = np.clip(1 - np.abs(sfc - lv) / np.where(sfc < lv, lv - levels[li - 1], levels[li + 1] - lv), 0, 1)
            m = w > 1e-4
            if not m.any():
                continue
            cell = self.cell * lv
            F1, F2, r = worley(P[m], cell, seed=3 + li, stretch=(1.0, 1.0, 0.82))
            e = (F2 - F1) / cell
            plate = smoothstep(0.0, 0.26, e)
            dome = 1.0 - np.clip(F1 / cell, 0, 1) ** 2 * 0.55
            hh = cell * 0.06 * plate * (0.6 + 0.4 * dome)
            h[m] += w[m] * hh
            groove[m] += w[m] * (1 - smoothstep(0.0, 0.1, e))
            rid[m] += w[m] * r
            top[m] += w[m] * plate * dome
        return h, groove, rid, top

    def plates(self, x, S):
        fr = x - np.floor(x)
        dist = np.minimum(fr, 1 - fr)  # in plate units
        h = 0.045 * S * smoothstep(0.0, 0.22, dist) * (0.75 + 0.25 * np.cos((fr - 0.45) * np.pi))
        groove = 1 - smoothstep(0.0, 0.12, dist)
        idx = np.floor(x)
        return h, groove, idx

    def box_sdf(self, P):
        mb = self.mouth
        if mb is None:
            return np.full(len(P), 1e3)
        return mb.eval(P)

    # ---------------------------------------------------------------- shading
    def masks(self, P, N, reg):
        S = self.S
        up = N[:, 1]
        skin = reg["Main"] + reg["Dark"] + reg["Belly"]
        jitter = (fbm(P, 0.7 * S, 3, seed=41) - 0.5) * 0.5
        bel = np.clip(reg["Belly"] * 1.35 + jitter * 0.6, 0, 1) * smoothstep(0.42, -0.15, up + jitter * 0.4)
        return skin, bel

    def height(self, P, sf, skin, bel, x_plate, extras):
        S = self.S
        hs, _, _, _ = self.scales(P, sf)
        if x_plate is not None:
            s, x, _ = self.chain_coords(P)
            hp, _, _ = self.plates(x, S)
        else:
            hp = 0.0
        h = hs * skin * (1 - bel) + hp * bel
        if extras is not None:
            lea, clo = extras
            if lea.any():
                h += lea * (fbm(P, 0.25 * S, 2, seed=77) * 0.02 * S)
            if clo.any():
                h += clo * (np.sin(P[:, 0] / (0.05 * S)) * np.sin(P[:, 2] / (0.05 * S))) * 0.006 * S
        return h

    def shade(self, P, N, reg, sf, ext):
        """Returns color (n,3), roughness (n), metal (n), height-params."""
        S = self.S
        cc = self.col
        n = len(P)
        up = N[:, 1]
        skin, bel = self.masks(P, N, reg)
        # --- base region color
        base = np.zeros((n, 3))
        for k in ("Main", "Dark", "Belly", "Leather", "Cloth", "Gold"):
            if k in reg:
                base += reg[k][:, None] * cc[k][None, :]
        eyew = reg.get("Eye", np.zeros(n))
        base += eyew[:, None] * cc["Eye"][None, :]
        col = base.copy()
        # dorsal darkening + belly
        back = smoothstep(0.2, 0.9, up) * skin * (1 - bel)
        col = mix(col, cc["Dark"][None, :] * 1.08, back * 0.5)
        col = mix(col, cc["Belly"][None, :], bel)
        # flank warmth band between belly and back (subtle olive-gold)
        flank = smoothstep(-0.35, 0.0, up) * smoothstep(0.35, 0.05, up) * skin * (1 - bel)
        col = mix(col, cc["Main"][None, :] * np.array([1.12, 1.06, 0.88])[None, :], flank * 0.35)
        # extremities darker
        col = mix(col, cc["Dark"][None, :] * 0.85, np.clip(ext, 0, 1) * 0.55 * skin * (1 - bel * 0.6))
        # --- scales
        hs, groove, rid, top = self.scales(P, sf)
        sk = skin * (1 - bel)
        col *= (1 + (rid - 0.5) * 0.18 * sk)[:, None]
        col *= (1 - 0.42 * groove * sk)[:, None]
        col *= (1 + 0.07 * top * sk * smoothstep(0.0, 0.6, up))[:, None]
        # --- belly plates
        s, x, dch = self.chain_coords(P)
        hp, gp, pidx = self.plates(x, S)
        pr = value_noise(np.stack([pidx, pidx * 0.37, np.zeros(n)], 1), 1.0, seed=5)
        col *= (1 + (pr - 0.5) * 0.12 * bel)[:, None]
        col *= (1 - 0.38 * gp * bel)[:, None]
        # --- pattern
        if self.pattern == "Dapples":
            cellp = 2.1 * S
            F1, F2, r = worley(P, cellp, seed=21, stretch=(1.0, 1.0, 0.72))
            warp = (fbm(P, 0.55 * S, 3, seed=23) - 0.5) * 0.32
            dd = F1 / cellp + warp
            spot = (1 - smoothstep(0.24, 0.36, dd)) * (r > 0.3)
            rim = (smoothstep(0.26, 0.36, dd) - smoothstep(0.36, 0.48, dd)) * (r > 0.3)
            dmask = smoothstep(-0.25, 0.35, up) * sk
            col = mix(col, cc["Dark"][None, :] * 0.78, spot * dmask * 0.75)
            col = mix(col, cc["Main"][None, :] * 1.22, rim * dmask * 0.3)
        # fine speckles
        sp = value_noise(P, 0.11 * S, seed=31)
        col *= (1 + smoothstep(0.82, 0.95, sp) * 0.12 * sk)[:, None]
        # broad hue/value variation
        big = fbm(P, 3.0 * S, 3, seed=51)
        col *= (0.92 + 0.16 * big)[:, None]
        # --- head: lips, mouth interior, nostrils
        bd = self.box_sdf(P)
        mouth_in = 1 - smoothstep(0.02 * S, 0.07 * S, bd)
        col = mix(col, cc["Mouth"][None, :], mouth_in)
        lip = (1 - smoothstep(0.05 * S, 0.12 * S, np.abs(bd))) * (1 - mouth_in)
        col = mix(col, cc["Dark"][None, :] * 0.55, lip * 0.7)
        for c, r in self.nostrils:
            dn = np.linalg.norm(P - c, axis=1)
            nm = 1 - smoothstep(r * 0.9, r * 1.6, dn)
            col = mix(col, np.array([0.06, 0.05, 0.04])[None, :], nm * 0.9)
        # --- eyes
        if eyew.max() > 0.05:
            ecol, erough = self.eye_color(P)
            col = mix(col, ecol, smoothstep(0.35, 0.75, eyew))
        # --- saddle details
        lea = reg.get("Leather", np.zeros(n))
        clo = reg.get("Cloth", np.zeros(n))
        gold = reg.get("Gold", np.zeros(n))
        if lea.max() > 0:
            grain = fbm(P, 0.18 * S, 3, seed=61)
            col = mix(col, col * (0.86 + 0.22 * grain)[:, None], lea)
            # stitch line: thin light dashes along the saddle rim (approx by height band)
        if clo.max() > 0:
            weave = 0.5 + 0.5 * np.sin(P[:, 0] / (0.04 * S)) * np.sin(P[:, 2] / (0.04 * S))
            col = mix(col, col * (0.9 + 0.12 * weave)[:, None], clo)
        # --- ambient occlusion from the SDF
        ao = np.ones(n)
        for d in (0.22 * S, 0.55 * S, 1.2 * S):
            v = sample_grid(self.dm.grid, P + N * d)
            ao *= np.clip(0.35 + 0.65 * v / d, 0.0, 1.0) ** 0.5
        ao = np.clip(ao, 0, 1)
        col *= (0.5 + 0.5 * ao)[:, None]
        # roughness / metal
        rough = 0.66 + 0.14 * groove * sk - 0.08 * top * sk
        rough = np.where(bel > 0.5, 0.58 + 0.14 * gp, rough)
        rough = rough * (1 - mouth_in) + 0.32 * mouth_in
        rough = rough * (1 - smoothstep(0.35, 0.75, eyew)) + 0.08 * smoothstep(0.35, 0.75, eyew)
        rough = rough * (1 - lea) + 0.52 * lea
        rough = rough * (1 - clo) + 0.9 * clo
        rough = rough * (1 - gold) + 0.3 * gold
        metal = gold.copy()
        col = np.clip(col, 0, 1)
        return col, np.clip(rough, 0.04, 1), np.clip(metal, 0, 1), (skin, bel, lea, clo)

    def eye_color(self, P):
        cc = self.col
        n = len(P)
        out = np.zeros((n, 3))
        best = np.full(n, 1e9)
        for c, r, o, rx, uy in self.eyes:
            d = P - c
            ln = np.linalg.norm(d, axis=1)
            m = ln < best
            dn = d / np.maximum(ln, 1e-9)[:, None]
            x, y, z = dn @ rx, dn @ uy, dn @ o
            radial = np.sqrt(x * x + y * y)
            ang = np.arctan2(y, x)
            iris_c = mix(cc["Eye"] * 1.12, cc["Eye"] * np.array([0.62, 0.42, 0.22]), smoothstep(0.08, 0.85, radial))
            streak = 0.5 + 0.5 * np.sin(ang * 29 + 3 * np.sin(ang * 7))
            iris_c = iris_c * (0.9 + 0.16 * streak)[:, None]
            iris = smoothstep(0.38, 0.5, z)
            col = mix(np.tile(np.array([0.10, 0.07, 0.04]), (n, 1)), iris_c, iris)
            limbal = smoothstep(0.38, 0.47, z) * (1 - smoothstep(0.5, 0.62, z))
            col = mix(col, np.array([0.12, 0.06, 0.02]), limbal * 0.75)
            yy = np.clip(np.abs(y) / 0.82, 0, 1)
            width = 0.075 * np.sqrt(np.maximum(1 - yy * yy, 0.0)) + 0.004
            pupil = (1 - smoothstep(width * 0.75, width * 1.25, np.abs(x))) * smoothstep(0.55, 0.68, z)
            col = mix(col, cc["Pupil"], pupil)
            out = np.where(m[:, None], col, out)
            best = np.where(m, ln, best)
        return np.clip(out, 0, 1), None


# ---------------------------------------------------------------- trims
def periodic_noise(s, t, freq_t, cell=0.5, seed=1, octaves=2):
    """Noise periodic in s (around) via a circle embedding."""
    P = np.stack([np.cos(2 * np.pi * s) * 1.2, np.sin(2 * np.pi * s) * 1.2, t * freq_t], axis=1)
    return fbm(P, cell, octaves, seed=seed)


def trim_shade(kind, s, t, rig, length=1.0, radius=0.2):
    """Returns color, rough, metal, normal_ts for trim rect texels."""
    cc = {k: C(v) for k, v in rig.defn["Palette"].items()}
    n = len(s)
    S = rig.S
    h = np.zeros(n)  # height along t only (keeps normals mirror-safe)
    if kind in ("HornMain", "HornSmall"):
        base = np.array([0.27, 0.23, 0.19])
        mid = cc["Horn"] * 0.88
        tip = cc["Horn"] * 1.04
        col = mix(np.tile(base, (n, 1)), mid, smoothstep(0.02, 0.6, t))
        col = mix(col, tip, smoothstep(0.6, 1.0, t))
        nr = 15 if kind == "HornMain" else 9
        ring = 0.5 + 0.5 * np.cos(2 * np.pi * t * nr)
        amp = (1 - t) ** 0.6
        h = 0.035 * S * amp * ring
        col *= (1 - 0.22 * amp * (1 - ring) ** 2)[:, None]
        st = periodic_noise(s, t, 9.0, 0.35, seed=4)
        col *= (0.9 + 0.2 * st)[:, None]
        rough = 0.46 - 0.12 * t
        metal = np.zeros(n)
    elif kind == "Spine":
        col = mix(np.tile(cc["Dark"] * 0.9, (n, 1)), cc["Accent"] * 0.95, smoothstep(0.15, 0.95, t))
        st = periodic_noise(s, t, 6.0, 0.3, seed=8)
        col *= (0.88 + 0.22 * st)[:, None]
        ring = 0.5 + 0.5 * np.cos(2 * np.pi * t * 6)
        h = 0.012 * S * ring * (1 - t)
        col *= (1 - 0.1 * (1 - ring) * (1 - t))[:, None]
        rough = 0.52 - 0.12 * t
        metal = np.zeros(n)
    elif kind == "Claw":
        col = mix(np.tile(cc["Claw"], (n, 1)), np.array([0.36, 0.32, 0.27]), smoothstep(0.35, 1.0, t))
        st = periodic_noise(s, t, 5.0, 0.3, seed=9)
        col *= (0.88 + 0.2 * st)[:, None]
        rough = 0.34 - 0.08 * t
        metal = np.zeros(n)
    elif kind == "Tooth":
        col = mix(np.tile(np.array([0.72, 0.62, 0.45]), (n, 1)), cc["Tooth"], smoothstep(0.0, 0.6, t))
        rough = np.full(n, 0.28)
        metal = np.zeros(n)
    elif kind == "Finger":
        col = mix(np.tile(cc["Main"] * 0.75, (n, 1)), cc["Dark"] * 0.95, smoothstep(0.0, 1.0, t))
        knuckle = 1 - smoothstep(0.0, 0.06, t)
        col *= (1 - 0.25 * knuckle)[:, None]
        bands = 0.5 + 0.5 * np.cos(2 * np.pi * t * length / (0.5 * S))
        col *= (0.94 + 0.06 * bands)[:, None]
        tipm = smoothstep(0.93, 1.0, t)
        col = mix(col, cc["Claw"], tipm)
        rough = np.full(n, 0.62)
        metal = np.zeros(n)
    else:
        col = np.tile(np.array([0.5, 0.5, 0.5]), (n, 1))
        rough = np.full(n, 0.6)
        metal = np.zeros(n)
    # normal from height along t (image-up direction)
    dt = 1e-3
    return np.clip(col, 0, 1), rough, metal, h


def membrane_shade(pid, bary, P, rig, panel_info):
    """pid: panel id per texel; bary: (n,3); P: 3D position on the R top sheet."""
    cc = {k: C(v) for k, v in rig.defn["Palette"].items()}
    S = rig.S
    n = len(pid)
    a, b, c = bary[:, 0], bary[:, 1], bary[:, 2]
    base = cc["Membrane"]
    col = np.tile(base, (n, 1))
    mott = fbm(P, 0.9 * S, 3, seed=71)
    col *= (0.88 + 0.22 * mott)[:, None]
    vein = np.zeros(n)
    edge = np.zeros(n)
    fan = pid >= 2
    # fan panels: corners (W, A, B): a = wrist weight
    if fan.any():
        bb, cb = b[fan], c[fan]
        r = bb + cb
        tang = cb / np.maximum(r, 1e-6)
        span = np.array([panel_info[p]["span"] for p in pid[fan]])
        vv = np.zeros(fan.sum())
        for k, tk in enumerate((1 / 3, 2 / 3)):
            wob = 0.03 * np.sin(r * 8.0 + pid[fan] * 1.7 + k * 2.1)
            d = np.abs(tang - tk - wob) * r * span
            vv = np.maximum(vv, 1 - smoothstep(0.035 * S, 0.075 * S, d))
            # branches toward the edge
            for sgn in (-1, 1):
                br = tk + wob + sgn * 0.13 * np.clip((r - 0.55) / 0.45, 0, 1)
                d2 = np.abs(tang - br) * r * span
                vv = np.maximum(vv, (1 - smoothstep(0.025 * S, 0.055 * S, d2)) * (r > 0.55))
        # thin wrinkles radiating from the wrist
        wr = 0.5 + 0.5 * np.sin(tang * 60 + 2.0 * np.sin(r * 5))
        col[fan] *= (0.95 + 0.06 * wr)[:, None]
        vein[fan] = vv
        e = 1 - smoothstep(0.015, 0.07, a[fan])
        edge[fan] = e
        # darker near the wrist / along the finger bones
        col[fan] *= (0.82 + 0.18 * smoothstep(0.0, 0.35, r))[:, None]
        nearb = np.minimum(tang, 1 - tang) * r * span
        col[fan] *= (0.86 + 0.14 * smoothstep(0.05 * S, 0.35 * S, nearb))[:, None]
    inner = ~fan
    if inner.any():
        ai, bi, ci = a[inner], b[inner], c[inner]
        q = ai / np.maximum(ai + bi, 1e-6)
        vv = np.zeros(inner.sum())
        for tk in (0.25, 0.5, 0.75):
            d = np.abs(q - tk - 0.02 * np.sin(ci * 9)) * (1 - ci) * 6.0 * S
            vv = np.maximum(vv, 1 - smoothstep(0.035 * S, 0.075 * S, d))
        vein[inner] = vv * (1 - smoothstep(0.7, 0.95, ci))
        # trailing edge of panel 1 (E-F3-B): scallop between F3 and B (a = E weight small)
        p1 = pid[inner] == 1
        e = np.zeros(inner.sum())
        e[p1] = 1 - smoothstep(0.015, 0.07, ai[p1])
        edge[inner] = e
    col = mix(col, col * np.array([0.55, 0.5, 0.42]), vein * 0.7)
    col = mix(col, cc["Dark"] * 0.6, edge * 0.8)
    rough = 0.7 - 0.08 * vein
    metal = np.zeros(n)
    return np.clip(col, 0, 1), rough, metal

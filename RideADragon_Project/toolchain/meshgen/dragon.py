"""Dragon mesh generator: turns a species dump (rig + part volumes from the
Lua Builder) into one organic skinned mesh with crisp horns, spines, claws,
teeth and real wing membranes.

Body flesh = smooth union of the Builder's volumes (SDF) -> Surface Nets ->
Taubin smoothing -> QEM decimation. Eye sockets, nostrils and the mouth gap
are carved; explicit pieces are generated and merged afterwards."""
import math

import numpy as np

import geom
import meshops as M
from rig import Rig, ellipsoid_axis_endpoints
from sdf import Grid, Ellipsoid, RoundCone, Box
from surfacenets import surface_nets, orient_outward

REGION_COLORS_EXTRA = {
    "Leather": (92, 56, 33), "Cloth": (124, 30, 34), "Gold": (196, 156, 78), "Mouth": (104, 34, 36),
}

# ------------------------------------------------------------------ helpers
FLESH_K = {
    "Body": 1.1, "Chest": 1.0, "Pelvis": 1.0, "Belly": 0.9, "Ridge": 0.8,
    "Throat": 0.5, "NeckJoint": 0.55, "TailJoint": 0.5, "TailBelly": 0.45,
    "Head": 0.45, "Snout": 0.4, "Bridge": 0.28, "Jaw": 0.22, "Brow": 0.16,
    "Shoulder": 0.55, "Elbow": 0.35, "Knee": 0.4, "Knuckle": 0.2,
    "Saddle": 0.06, "Pommel": 0.08, "Cantle": 0.08,
}
REGION_OF = {
    "Belly": "Belly", "Throat": "Belly", "TailBelly": "Belly",
    "Ridge": "Dark", "Bridge": "Dark", "Brow": "Dark",
    "Saddle": "Leather", "Pommel": "Leather", "Cantle": "Leather",
    "SaddleCloth": "Cloth", "SaddleTrim": "Gold",
}
HEAD_PARTS = {"Head", "Snout", "Bridge", "Brow", "Jaw"}
HEAD_STYLES = {
    # proportions in head units (S * Head.Size); mouth = mouth-line height below the skull center
    "Drake": {"snout": 1.0, "snout_w": 1.0, "skull_w": 0.95, "skull_h": 0.85, "mouth": -0.68, "brow_tilt": 0.32,
              "k": 0.32},
}
SKIP_FLESH = {"Horn", "HornTip", "Eye", "Pupil", "Nostril", "Tooth", "Claw", "Spine", "Frill", "WingClaw",
              "TailTip", "Membrane", "Glow", "Finger"}


def is_finger(name):
    return name in ("WingL3", "WingL4", "WingL5", "WingR3", "WingR4", "WingR5")


class Drape:
    """A layer of `thickness` lying on the body surface inside a footprint
    region (saddle blanket, trims). eval() = distance-ish to the layer."""
    op = "union"

    def __init__(self, thickness, region_fn, lo, hi, tag="Body", color="Cloth"):
        self.t = thickness
        self.region = region_fn
        self.lo, self.hi = np.asarray(lo, float), np.asarray(hi, float)
        self.tag, self.color = tag, color
        self.k = 0.0
        self.D0 = None  # grid sampler set at build time

    def bounds(self):
        return self.lo, self.hi

    def eval(self, P):
        d0 = self.D0(P)
        shell = np.maximum(d0 - self.t, -d0 - self.t * 0.5)
        return np.maximum(shell, self.region(P))


def rounded_rect_region(xc, zc, hw, hl, r, y_min):
    def f(P):
        qx = np.abs(P[..., 0] - xc) - (hw - r)
        qz = np.abs(P[..., 2] - zc) - (hl - r)
        d2 = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qz, 0) ** 2) + np.minimum(np.maximum(qx, qz), 0) - r
        return np.maximum(d2, y_min - P[..., 1])
    return f


def band_region(zc, w, hw, y_min):
    def f(P):
        return np.maximum(np.maximum(np.abs(P[..., 2] - zc) - w / 2, np.abs(P[..., 0]) - hw), y_min - P[..., 1])
    return f


class Piece:
    """Explicit geometry with per-vertex bone weights and a region."""
    def __init__(self, V, F, weights, region, t=None, uv=None, kind="solid", extra=None):
        self.V = np.asarray(V, float)
        self.F = np.asarray(F, np.int64)
        self.W = weights  # list of dicts (per vertex) or a single dict for all
        self.region = region
        self.t = t  # 0..1 along the piece (horn/spine gradients)
        self.uv = uv
        self.kind = kind
        self.extra = extra or {}


class DragonMesh:
    def __init__(self, rig: Rig, voxel=0.11):
        self.rig = rig
        self.S = rig.S
        self.voxel = voxel * max(1.0, rig.S * 0.85)
        self.prims = []
        self.pieces = []
        self.carves = []
        # triangle budget knobs (Roblox: <= 20k triangles per MeshPart)
        self.lod = {"horn_sides": 9, "horn_samples": 22, "horn2_sides": 7, "horn2_samples": 12,
                    "finger_sides": 6, "finger_samples": 10, "membrane_res": 10}

    # -------------------------------------------------------------- flesh
    def collect_flesh(self, sculpt_head=True):
        S = self.S
        self.head_spec = None
        self.drapes = []
        self.trim_specs = []
        self.cloth_spec = None
        for p in self.rig.parts:
            name = p["name"]
            if name in SKIP_FLESH or name == "Root" or p["transparency"] >= 0.98:
                continue
            bone = p["bone"]
            if sculpt_head and bone in ("Head", "Jaw") and name in HEAD_PARTS:
                continue
            if is_finger(name) or is_finger(bone):
                continue
            c, R = Rig.frame(p)
            region = REGION_OF.get(name, "Main")
            k = FLESH_K.get(name, 0.42) * S
            if name.startswith("Neck") and name[4:].isdigit():
                k = 0.55 * S
            elif name.startswith("Tail") and name[4:].isdigit():
                k = 0.5 * S
            elif name.startswith(("Arm", "Leg", "Hand", "Foot")):
                k = 0.42 * S
            elif name.startswith("Wing"):
                k = 0.28 * S
            shape = p["shape"]
            size = np.array(p["size"], float)
            if shape == "Ball":
                self.prims.append(Ellipsoid(c, np.eye(3), size / 2, k=k, tag=bone, color=region))
            elif shape == "Ellipsoid":
                self.prims.append(Ellipsoid(c, R, size / 2, k=k, tag=bone, color=region))
            elif shape == "Block" and name == "SaddleCloth":
                hw, hl = size[0] / 2, size[2] / 2
                y_min = c[1] - 1.15 * S
                lo = np.array([c[0] - hw - 0.5, y_min - 0.5, c[2] - hl - 0.5])
                hi = np.array([c[0] + hw + 0.5, c[1] + 2.0 * S, c[2] + hl + 0.5])
                self.drapes.append(Drape(0.085 * S, rounded_rect_region(c[0], c[2], hw, hl, 0.35 * S, y_min), lo, hi,
                                         tag=bone, color="Cloth"))
                self.cloth_spec = (c, hw, hl, y_min)
            elif shape == "Block" and name == "SaddleTrim":
                self.trim_specs.append((c, size))
        self._muscles(skip_jaw=sculpt_head)
        if sculpt_head:
            self._sculpt_head()
        # gold trims: raised bands on the blanket's front/back edges
        if self.cloth_spec is not None:
            c, hw, hl, y_min = self.cloth_spec
            for tc, tsize in self.trim_specs:
                w = max(tsize[2], 0.2 * S)
                lo = np.array([-hw - 0.5, y_min - 0.5, tc[2] - w - 0.5])
                hi = np.array([hw + 0.5, c[1] + 2.0 * S, tc[2] + w + 0.5])
                self.drapes.append(Drape(0.085 * S + 0.04 * S, band_region(tc[2], w, hw - 0.05 * S, y_min + 0.05 * S),
                                         lo, hi, tag="Body", color="Gold"))

    # -------------------------------------------------------------- head
    def _sculpt_head(self):
        """Sleek reptilian head built in the skull frame: long tapering snout,
        hooded brow ridges, cheekbones, jaw muscles, nostril nubs. Records eyes,
        nostrils, mouth gap and tooth sites for carving, texturing, skinning."""
        rig, S = self.rig, self.S
        hd = rig.defn.get("Head", {})
        st = dict(HEAD_STYLES["Drake"])
        st.update(hd.get("Sculpt", {}))
        sc, R, fwd, up, right = self.head_frame()
        u = S * hd.get("Size", 1.0)
        sn = hd.get("Snout", 1.0) * st["snout"]
        m = st["mouth"]

        def P(x, y, z):  # head-local (right, up, fwd) in head units -> world
            return sc + (right * x + up * y + fwd * z) * u

        def axes(dirz, upv=None):
            z = np.asarray(dirz, float)
            z /= np.linalg.norm(z)
            yv = up if upv is None else upv
            x = np.cross(yv, z)
            x /= np.linalg.norm(x)
            y = np.cross(z, x)
            return np.stack([x, y, z], axis=1)  # columns: local x, y, z

        Rh = np.stack([right, up, -fwd], axis=1)
        k = st["k"] * S

        def add(center, radii, tag="Head", color="Main", rot=None, kk=None):
            self.prims.append(Ellipsoid(center, Rh if rot is None else rot, np.asarray(radii, float) * u,
                                        k=k if kk is None else kk * S, tag=tag, color=color))

        # cranium + occiput
        add(P(0, 0.1, -0.15), (st["skull_w"], st["skull_h"], 1.2))
        add(P(0, 0.32, -1.0), (0.72, 0.6, 0.78))
        # snout: tapering chain whose lower edge sits just below the mouth line
        prof = []
        for f, rx, ry, rz in ((0.95, 0.80, 0.62, 0.95), (1.75, 0.66, 0.50, 0.85),
                              (2.45, 0.53, 0.42, 0.72), (3.05, 0.44, 0.36, 0.45)):
            rx *= st["snout_w"]
            c = P(0, m + ry * 0.4, f * sn)
            add(c, (rx, ry, rz))
            prof.append((f * sn, rx, ry, rz, m + ry * 0.4))
        self.snout_profile = prof
        # nasal bridge ridge (dark)
        add(P(0, m + 0.62 * 0.4 + 0.5, 1.55 * sn), (0.26, 0.2, 1.45), color="Dark", kk=0.18)
        # brow ridges: front end lower and inward = a hooded, menacing eye line
        eyes = []
        for side in (-1, 1):
            d = fwd * 1.0 - up * st["brow_tilt"] - right * side * 0.26
            add(P(side * 0.6, 0.53, 0.5), (0.3, 0.2, 0.78), color="Dark", rot=axes(d), kk=0.16)
            # cheekbone
            add(P(side * 0.76, -0.3, 0.12), (0.34, 0.3, 0.92), rot=axes(fwd - up * 0.15), kk=0.2)
            # jaw muscle at the hinge (moves with the jaw)
            add(P(side * 0.55, m - 0.28, -0.25), (0.42, 0.4, 0.68), tag="Jaw", kk=0.22)
            # nostril nub
            add(P(side * 0.25, m + 0.36 * 0.4 + 0.3, 3.15 * sn), (0.15, 0.11, 0.22), kk=0.1)
            eyes.append((P(side * 0.69, 0.3, 0.62), 0.27 * u, side))
        # lower jaw chain + chin (overlaps the snout; the mouth gap splits them)
        for f, rx, ry, rz in ((0.9, 0.70, 0.34, 1.0), (1.9, 0.55, 0.28, 0.85), (2.75, 0.40, 0.24, 0.5)):
            add(P(0, m - ry * 0.45, f * sn), (rx * st["snout_w"], ry, rz), tag="Jaw")
        # mouth gap box from the hinge to past the nose
        z0, z1 = -0.3, 3.05 * sn + 0.6
        gap_c = P(0, m, (z0 + z1) / 2)
        half = np.array([0.98 * u, 0.032 * S, (z1 - z0) / 2 * u])
        self.mouth_box = Box(gap_c, Rh, half, rounding=0.02 * S, k=0.03 * S)
        nostrils = [(P(side * 0.27, m + 0.36 * 0.4 + 0.33, 3.3 * sn) + fwd * 0.05 * u, 0.075 * u) for side in (-1, 1)]
        # tooth sites along the upper/lower mouth edge
        teeth = []
        for f in np.linspace(0.45, 3.0, 7) * sn:
            hw = 0.0
            for fz, rx, ry, rz, cy in prof:
                q = 1 - ((f - fz) / rz) ** 2
                if q > 0:
                    hw = max(hw, rx * 0.92 * np.sqrt(q))
            hw = max(hw, 0.3)
            teeth.append((f, hw * 0.82))
        self.head_spec = {"c": sc, "fwd": fwd, "up": up, "right": right, "u": u, "m": m, "sn": sn,
                          "eyes": eyes, "nostrils": nostrils, "teeth": teeth, "P": P}

    def _muscles(self, skip_jaw=False):
        """Extra sculpt volumes for a stronger silhouette."""
        rig, S = self.rig, self.S
        for side in ("L", "R"):
            sgn = -1 if side == "L" else 1
            # shoulder blade bulge where the wing meets the back
            if "Wing" + side + "1" in rig.bones:
                p = rig.pivot("Wing" + side + "1")
                self.prims.append(Ellipsoid(p + np.array([-sgn * 0.15, -0.35, 0.35]) * S, np.eye(3),
                                            np.array([0.85, 0.75, 1.25]) * S, k=0.6 * S, tag="Chest", color="Main"))
            # haunch muscle over the thigh
            if "Leg" + side + "1" in rig.bones:
                p = rig.pivot("Leg" + side + "1")
                self.prims.append(Ellipsoid(p + np.array([sgn * 0.2, -0.6, 0.15]) * S, np.eye(3),
                                            np.array([0.95, 1.5, 1.35]) * S, k=0.55 * S, tag="Leg" + side + "1", color="Main"))
            # forearm muscle
            if "Arm" + side + "1" in rig.bones:
                a = rig.pivot("Arm" + side + "1")
                b = rig.pivot("Arm" + side + "2")
                self.prims.append(RoundCone(a + (b - a) * 0.1, b, 0.78 * S, 0.5 * S, k=0.45 * S, tag="Arm" + side + "1", color="Main"))
        # chin + jaw corner fill so the lower jaw reads as bone
        jaw = None if skip_jaw else rig.one("Jaw")
        if jaw:
            c, R = Rig.frame(jaw)
            fwd = -R[:, 2]
            up = R[:, 1]
            size = np.array(jaw["size"])
            self.prims.append(Ellipsoid(c + fwd * size[2] * 0.32 - up * size[1] * 0.12, R,
                                        np.array([size[0] * 0.36, size[1] * 0.42, size[2] * 0.24]), k=0.2 * S, tag="Jaw", color="Main"))

    def head_frame(self):
        skull = self.rig.one("Head", "Head")
        c, R = Rig.frame(skull)
        return c, R, -R[:, 2], R[:, 1], R[:, 0]

    def collect_carves(self):
        """Eye sockets, nostrils and the mouth gap (subtracted after union)."""
        rig, S = self.rig, self.S
        hs = getattr(self, "head_spec", None)
        if hs is not None:
            fwd = hs["fwd"]
            for c, r, side in hs["eyes"]:
                self.carves.append(("sub", Ellipsoid(c, np.eye(3), np.array([r, r, r]) * 1.12, k=0.1 * S)))
            for c, r in hs["nostrils"]:
                self.carves.append(("sub", Ellipsoid(c, np.eye(3), np.array([r * 1.25, r * 0.8, r * 1.6]), k=0.04 * S)))
            self.carves.append(("sub", self.mouth_box))
            for c, r, side in hs["eyes"]:
                self.carves.append(("add", Ellipsoid(c - hs["right"] * side * r * 0.08, np.eye(3), np.array([r, r, r]),
                                                     k=0.02 * S, tag="Head", color="Eye")))
            return
        for eye in rig.find("Eye"):
            c, R = Rig.frame(eye)
            r = max(eye["size"]) * 0.62
            self.carves.append(("sub", Ellipsoid(c, np.eye(3), np.array([r, r, r]), k=0.12 * S)))
        for n in rig.find("Nostril"):
            c, _ = Rig.frame(n)
            r = n["size"][0] * 0.62
            self.carves.append(("sub", Ellipsoid(c, np.eye(3), np.array([r, r * 0.8, r]), k=0.06 * S)))
        jaw = rig.one("Jaw")
        if jaw:
            c, R = Rig.frame(jaw)
            size = np.array(jaw["size"])
            up = R[:, 1]
            fwd = -R[:, 2]
            gap_c = c + up * size[1] * 0.42 + fwd * size[2] * 0.12
            half = np.array([size[0] * 0.9, 0.035 * S, size[2] * 0.52])
            self.mouth_box = Box(gap_c, R, half, rounding=0.02 * S, k=0.03 * S)
            self.carves.append(("sub", self.mouth_box))
        else:
            self.mouth_box = None
        # eyeballs re-added inside the sockets
        for eye in rig.find("Eye"):
            c, R = Rig.frame(eye)
            r = max(eye["size"]) * 0.5
            self.carves.append(("add", Ellipsoid(c - R[:, 2] * r * 0.05, np.eye(3), np.array([r, r, r]), k=0.03 * S,
                                                 tag="Head", color="Eye")))

    def build_flesh(self, target_faces=15000, smooth_iters=5):
        lo = np.min([p.bounds()[0] for p in self.prims], axis=0) - 1.0
        hi = np.max([p.bounds()[1] for p in self.prims], axis=0) + 1.0
        g = Grid(lo, hi, self.voxel)
        for p in self.prims:
            g.add(p)
        for op, p in self.carves:
            if op == "sub":
                p.op = "subtract"
            g.add(p)
        if self.drapes:
            D0 = g.D.copy()
            g0 = type("G0", (), {})()
            g0.lo, g0.h, g0.n, g0.D = g.lo, g.h, g.n, D0
            from shade import sample_grid
            sampler = lambda P, g0=g0: sample_grid(g0, P.reshape(-1, 3)).reshape(P.shape[:-1])  # noqa: E731
            for dp in self.drapes:
                dp.D0 = sampler
                i0, i1 = g.sub(dp.lo, dp.hi, 2 * g.h)
                sl = tuple(slice(i0[k], i1[k]) for k in range(3))
                Pg = g.points(i0, i1)
                layer = np.maximum(D0[sl] - dp.t, dp.region(Pg)).astype(np.float32)
                g.D[sl] = np.minimum(g.D[sl], layer)
        self.grid = g
        V, F = surface_nets(g.D, g.lo, g.h)
        F = orient_outward(V, F)
        V = M.taubin(V, F, smooth_iters)
        self.raw_faces = len(F)
        V, F = M.decimate(V, F, target_faces)
        self.flesh = (V, F)
        return V, F

    # -------------------------------------------------------------- explicit
    def surface_point(self, origin, direction, max_dist=8.0):
        """March from inside along direction until leaving the flesh."""
        g = self.grid
        d = np.asarray(direction, float)
        d /= np.linalg.norm(d)
        p = np.asarray(origin, float).copy()
        step = g.h * 0.5
        for _ in range(int(max_dist / step)):
            idx = np.round((p - g.lo) / g.h).astype(int)
            if np.any(idx < 0) or np.any(idx >= g.n):
                break
            if g.D[tuple(idx)] > 0:
                return p
            p = p + d * step
        return p

    def add_horns(self):
        rig, S = self.rig, self.S
        sc, R, fwd, up, right = self.head_frame()
        hd = rig.defn["Head"]
        hs = hd.get("Size", 1.0)
        thick = hd.get("HornThickness", 0.55) * hs * S
        for side in (-1, 1):
            # chain this side's horn parts from root to tip
            hp = [p for p in rig.find("Horn") + rig.find("HornTip") if (Rig.frame(p)[0] - sc) @ right * side > 0]
            if not hp:
                continue
            pts = []
            for p in hp:
                a, b = ellipsoid_axis_endpoints(p)
                pts += [a, b]
            pts = np.array(pts)
            # order by distance from the skull center
            dist = np.linalg.norm(pts - sc, axis=1)
            root = pts[np.argmin(dist)]
            tip = pts[np.argmax(dist)]
            if getattr(self, "head_spec", None) is not None:
                dr = root - sc
                surf = self.surface_point(sc, dr, max_dist=np.linalg.norm(dr) * 2 + 2 * S)
                root = surf - dr / np.linalg.norm(dr) * 0.12 * S
            mid1 = root + (tip - root) * 0.35 + up * 0.25 * S
            mid2 = root + (tip - root) * 0.7 + up * 0.18 * S
            root = root - (tip - root) * 0.06
            hs_, hn_ = self.lod["horn_sides"], self.lod["horn_samples"]
            V, F, t = geom.tube([root, mid1, mid2, tip], lambda u: thick * 0.62 * (1 - u) ** 0.85 + 0.01, sides=hs_, samples=hn_)
            F = geom.fix_winding_local(V, F)
            self.pieces.append(Piece(V, F, {"Head": 1.0}, "Horn", t=t, kind="tube",
                                     extra={"sides": hs_, "trim": "HornMain", "length": float(np.linalg.norm(tip - root))}))
            # small secondary horn below/behind
            r2 = root + up * -0.45 * S - fwd * 0.25 * S + right * side * 0.18 * S
            tip2 = r2 - fwd * 1.3 * S + up * -0.05 * S + right * side * 0.45 * S
            hs2, hn2 = self.lod["horn2_sides"], self.lod["horn2_samples"]
            V, F, t = geom.tube([r2, (r2 + tip2) / 2 + up * 0.1 * S, tip2], lambda u: thick * 0.38 * (1 - u) + 0.01, sides=hs2, samples=hn2)
            F = geom.fix_winding_local(V, F)
            self.pieces.append(Piece(V, F, {"Head": 1.0}, "Horn", t=t, kind="tube",
                                     extra={"sides": hs2, "trim": "HornSmall", "length": float(np.linalg.norm(tip2 - r2))}))

    def add_spines(self):
        """Continuous dorsal crest from the back of the head to the tail tip."""
        rig, S = self.rig, self.S
        names = ["Head"] + [f"Neck{i}" for i in range(8, 0, -1) if f"Neck{i}" in rig.bones]
        neck = sorted([n for n in rig.bones if n.startswith("Neck") and n[4:].isdigit()], key=lambda n: int(n[4:]))
        tail = sorted([n for n in rig.bones if n.startswith("Tail") and n[4:].isdigit()], key=lambda n: int(n[4:]))
        chain = [("Head", rig.pivot("Head"))]
        for n in reversed(neck):
            chain.append((n, rig.pivot(n)))
        chain.append(("Chest", rig.pivot("Chest")))
        chain.append(("Body", rig.pivot("Body")))
        chain.append(("Pelvis", rig.pivot("Pelvis")))
        for n in tail:
            chain.append((n, rig.pivot(n)))
        # tail end point
        last = rig.one(tail[-1], tail[-1]) if tail else None
        if last:
            a, b = ellipsoid_axis_endpoints(last)
            chain.append((tail[-1], b))
        pts = np.array([c[1] for c in chain])
        bones = [c[0] for c in chain]
        seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
        cum = np.concatenate([[0], np.cumsum(seg)])
        total = cum[-1]
        sp = rig.defn.get("Spines", {})
        h0 = sp.get("Height", 0.9) * S
        saddle = rig.one("Saddle")
        saddle_c = Rig.frame(saddle)[0] if saddle else None
        s = 0.9 * S
        x = 0.6 * S
        while x < total - 0.3 * S:
            i = min(np.searchsorted(cum, x) - 1, len(pts) - 2)
            i = max(i, 0)
            u = (x - cum[i]) / max(seg[i], 1e-6)
            p = pts[i] + (pts[i + 1] - pts[i]) * u
            bone = bones[i + 1] if u > 0.5 else bones[i]
            frac = x / total
            # height profile: small on the neck, tallest over shoulders/hips, tapering on the tail
            prof = 0.55 + 0.45 * math.sin(min(1.0, frac * 2.2) * math.pi * 0.5)
            if frac > 0.45:
                prof *= max(0.22, 1.0 - (frac - 0.45) * 1.35)
            h = h0 * prof * 1.15
            if saddle_c is not None and abs(p[2] - saddle_c[2]) < 2.2 * S:
                x += s * 0.7
                continue
            base = self.surface_point(p + np.array([0, -0.5 * S, 0]), [0, 1, 0], max_dist=10 * S)
            base = base - np.array([0, 0.18 * S, 0])
            tangent = pts[i + 1] - pts[i]
            tangent /= max(np.linalg.norm(tangent), 1e-6)
            back = tangent  # chain runs head -> tail (towards +Z)
            tip = base + np.array([0, 1, 0]) * h + back * h * 0.55
            V, F, t = geom.blade(base, tip, side=[1, 0, 0], width=h * 0.95, thickness=0.16 * S, curve=-0.12, rows=4)
            F = geom.fix_winding_local(V, F)
            self.pieces.append(Piece(V, F, {bone: 1.0}, "Spine", t=t, kind="blade", extra={"rows": 4, "trim": "Spine"}))
            x += s * (0.75 + 0.35 * prof)

    def add_claws_teeth(self):
        rig, S = self.rig, self.S
        for p in rig.find("Claw") + rig.find("WingClaw"):
            c, R = Rig.frame(p)
            size = np.array(p["size"])
            up = R[:, 1]
            base = c - up * size[1] / 2
            tip = c + up * size[1] / 2 * 1.25
            side = R[:, 0]
            V, F, t = geom.blade(base, tip, side=side, width=size[2] * 0.9, thickness=size[0] * 0.95, curve=0.25, rows=4)
            F = geom.fix_winding_local(V, F)
            self.pieces.append(Piece(V, F, {p["bone"]: 1.0}, "Claw", t=t, kind="blade", extra={"rows": 4, "trim": "Claw"}))
        # teeth along the mouth line (upper on Head, lower on Jaw)
        hs = getattr(self, "head_spec", None)
        if hs is not None:
            P, u, m = hs["P"], hs["u"], hs["m"]
            fwd, up = hs["fwd"], hs["up"]
            for i, (f, lat) in enumerate(hs["teeth"]):
                fr = f / (3.0 * hs["sn"])
                sz = (0.2 + 0.08 * (i in (4, 5))) * u * (0.75 + 0.35 * fr)
                for side in (-1, 1):
                    for upper in (True, False):
                        if not upper and i % 2 == 1:
                            continue
                        lat2 = lat * (1.13 if upper else 0.88)
                        base = P(side * lat2, m + (0.07 if upper else -0.06), f)
                        tip = base + up * (-sz if upper else sz * 0.75) + fwd * sz * 0.08 + hs["right"] * side * sz * 0.05
                        V, F, t = geom.blade(base, tip, side=fwd, width=sz * 0.5, thickness=sz * 0.4, curve=0.0, rows=2)
                        F = geom.fix_winding_local(V, F)
                        self.pieces.append(Piece(V, F, {"Head" if upper else "Jaw": 1.0}, "Tooth", t=t, kind="blade",
                                                 extra={"rows": 2, "trim": "Tooth"}))
            # cheek spikes sweeping back from the jaw hinge
            right = hs["right"]
            for side in (-1, 1):
                for (x, y, z, ln, wd) in ((0.86, m + 0.15, -0.45, 0.95, 0.30), (0.78, m - 0.22, -0.7, 0.75, 0.26),
                                          (0.66, m + 0.48, -0.95, 0.6, 0.22)):
                    base = P(side * x * 0.92, y, z)
                    d = -fwd * 1.0 + right * side * 0.38 + up * 0.06
                    d /= np.linalg.norm(d)
                    tip = base + d * ln * u
                    V, F, t = geom.blade(base, tip, side=np.cross(d, up), width=wd * u, thickness=0.07 * u, curve=0.1, rows=3)
                    F = geom.fix_winding_local(V, F)
                    self.pieces.append(Piece(V, F, {"Head": 1.0}, "Spine", t=t, kind="blade", extra={"rows": 3, "trim": "Spine"}))
            return
        if self.mouth_box is not None:
            mb = self.mouth_box
            R = mb.R
            fwd, up, right = -R[:, 2], R[:, 1], R[:, 0]
            L = mb.h[2]
            for side in (-1, 1):
                for i in range(6):
                    f = 0.92 - i * 0.16
                    pos = mb.c + fwd * L * f + right * side * (mb.h[0] * (0.42 + 0.3 * (1 - f))) * 0.62
                    sz = (0.2 + 0.08 * (i == 1)) * S
                    for upper in (True, False):
                        if not upper and i % 2 == 0:
                            continue
                        base = pos + up * (0.07 * S if upper else -0.07 * S)
                        tip = base + up * (-sz if upper else sz * 0.8)
                        V, F, t = geom.blade(base, tip, side=fwd, width=sz * 0.55, thickness=sz * 0.45, curve=0.0, rows=2)
                        F = geom.fix_winding_local(V, F)
                        self.pieces.append(Piece(V, F, {"Head" if upper else "Jaw": 1.0}, "Tooth", t=t, kind="blade",
                                                 extra={"rows": 2, "trim": "Tooth"}))

    def add_tail_tip(self):
        rig, S = self.rig, self.S
        tail = sorted([n for n in rig.bones if n.startswith("Tail") and n[4:].isdigit()], key=lambda n: int(n[4:]))
        if not tail:
            return
        last = rig.one(tail[-1], tail[-1])
        a, b = ellipsoid_axis_endpoints(last)
        d = (b - a) / np.linalg.norm(b - a)
        right = np.cross(d, [0, 1, 0])
        right /= np.linalg.norm(right)
        up = np.cross(right, d)
        base = a + (b - a) * 0.55
        L = 2.6 * S
        W = 1.1 * S
        th = 0.16 * S
        # diamond spade: 4 points + thickness
        pts = [base, base + d * L * 0.45 + right * W, base + d * L, base + d * L * 0.45 - right * W]
        V = []
        for p in pts:
            V.append(p + up * th / 2)
        for p in pts:
            V.append(p - up * th / 2)
        V.append(base + d * L * 0.45 + up * th * 1.4)
        V.append(base + d * L * 0.45 - up * th * 1.4)
        V = np.array(V)
        top, bot = 8, 9
        F = []
        for i in range(4):
            j = (i + 1) % 4
            F.append((i, j, top))
            F.append((4 + j, 4 + i, bot))
            F.append((i, 4 + i, 4 + j))
            F.append((i, 4 + j, j))
        F = np.array(F, np.int64)
        F = geom.orient_faces_outward_from(V, F, base + d * L * 0.45)
        self.pieces.append(Piece(V, F, {tail[-1]: 1.0}, "Dark", t=None, kind="solid3d"))

    def add_wing_bones_and_membranes(self, res=None):
        rig, S = self.rig, self.S
        res = res or self.lod["membrane_res"]
        for side in ("L", "R"):
            n = "Wing" + side
            if n + "3" not in rig.bones:
                continue
            P = {k: rig.att("Mem" + k + side) for k in ("S", "E", "W", "F1", "F2", "F3", "B")}
            W = P["W"]
            # finger bones
            for fi, (key, bone) in enumerate((("F1", n + "3"), ("F2", n + "4"), ("F3", n + "5"))):
                tip = P[key]
                r0 = (0.2 if fi == 0 else 0.16) * S
                fs_, fn_ = self.lod["finger_sides"], self.lod["finger_samples"]
                V, F, t = geom.tube([W, W + (tip - W) * 0.5, tip], lambda u, r0=r0: r0 * (1 - 0.8 * u) + 0.02 * S, sides=fs_, samples=fn_)
                F = geom.fix_winding_local(V, F)
                self.pieces.append(Piece(V, F, {bone: 1.0}, "WingBone", t=t, kind="tube",
                                         extra={"sides": fs_, "trim": "Finger", "length": float(np.linalg.norm(tip - W))}))

            def mix(*pairs):
                out = {}
                for wgt, d in pairs:
                    for b, w in d.items():
                        out[b] = out.get(b, 0) + w * wgt
                return out

            dS = {n + "1": 0.75, "Chest": 0.25}
            dE = {n + "2": 0.5, n + "1": 0.5}
            dB = {"Body": 1.0}
            panels = []
            # inner panels (barycentric blends)
            panels.append(((P["S"], P["E"], P["B"]), lambda b: mix((b[0], dS), (b[1], dE), (b[2], dB)), None))
            panels.append(((P["E"], P["F3"], P["B"]), lambda b: mix((b[0], dE), (b[1], {n + "5": 1.0}), (b[2], dB)), 0.16))

            # fan panels around the wrist: angular interpolation between bones
            def fan(boneA, boneB, A, B):
                da = (A - W) / np.linalg.norm(A - W)
                db = (B - W) / np.linalg.norm(B - W)
                tot = math.acos(np.clip(da @ db, -1, 1))

                def f(bary, A=A, B=B):
                    p = W * bary[0] + A * bary[1] + B * bary[2]
                    v = p - W
                    ln = np.linalg.norm(v)
                    if ln < 1e-6:
                        return {boneA: 0.5, boneB: 0.5}
                    ang = math.acos(np.clip((v / ln) @ da, -1, 1))
                    t = min(1.0, ang / max(tot, 1e-6))
                    return {boneA: 1 - t, boneB: t}
                return f

            panels.append(((W, P["E"], P["F3"]), fan(n + "2", n + "5", P["E"], P["F3"]), None))
            panels.append(((W, P["F3"], P["F2"]), fan(n + "5", n + "4", P["F3"], P["F2"]), 0.2))
            panels.append(((W, P["F2"], P["F1"]), fan(n + "4", n + "3", P["F2"], P["F1"]), 0.2))
            thick = 0.05 * S
            for pid, (corners, wfn, scallop) in enumerate(panels):
                V, F, BW, bary = geom.membrane_panel(corners, wfn, res=res, scallop=scallop)
                nrm = np.cross(corners[1] - corners[0], corners[2] - corners[0])
                nrm /= np.linalg.norm(nrm)
                if nrm[1] < 0:
                    nrm = -nrm
                    F = F[:, ::-1]
                # top and bottom sheets
                Vt = V + nrm * thick
                Vb = V - nrm * thick
                Ft = F if (np.cross(V[F[0, 1]] - V[F[0, 0]], V[F[0, 2]] - V[F[0, 0]]) @ nrm) > 0 else F[:, ::-1]
                Fb = Ft[:, ::-1]
                ex = {"panel": pid, "side": side, "bary": bary, "mid": V, "normal": nrm}
                self.pieces.append(Piece(Vt, Ft, BW, "Membrane", uv=None, kind="membrane_top", extra=dict(ex, sheet="top")))
                self.pieces.append(Piece(Vb, Fb, BW, "Membrane", uv=None, kind="membrane_bottom", extra=dict(ex, sheet="bottom")))

    # -------------------------------------------------------------- weights
    def flesh_weights(self, V, sigma=0.5):
        """Per-vertex bone weights from distance to each bone's volumes."""
        S = self.S
        bones = sorted({p.tag for p in self.prims if p.tag})
        D = np.full((len(V), len(bones)), 1e3)
        for p in self.prims:
            if not p.tag:
                continue
            j = bones.index(p.tag)
            lo, hi = p.bounds()
            pad = 2.0 * S
            m = np.all((V > lo - pad) & (V < hi + pad), axis=1)
            if not np.any(m):
                continue
            d = p.eval(V[m])
            D[m, j] = np.minimum(D[m, j], d)
        s = sigma * S
        W = np.exp(-np.maximum(D, 0) / s)
        W[D > 3 * S] = 0
        return bones, W

    def flesh_regions(self, V, sigma=0.12):
        S = self.S
        regs = sorted({p.color for p in self.prims if p.color} | {"Eye"} | {d.color for d in getattr(self, "drapes", [])})
        D = np.full((len(V), len(regs)), 1e3)
        for p in self.prims + [c[1] for c in self.carves if c[0] == "add"] + list(getattr(self, "drapes", [])):
            if not p.color:
                continue
            j = regs.index(p.color)
            d = p.eval(V)
            D[:, j] = np.minimum(D[:, j], d)
        s = sigma * S
        Wr = np.exp(-np.maximum(D - D.min(axis=1, keepdims=True), 0) / s)
        Wr /= Wr.sum(axis=1, keepdims=True)
        return regs, Wr

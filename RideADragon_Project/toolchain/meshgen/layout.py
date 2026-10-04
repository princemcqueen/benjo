"""Atlas layout for a dragon: 3D charts (flesh, solid pieces), shared
membrane charts (one copy baked, reused by both wings and both sheets) and
trim rectangles (horns, spines, claws, teeth, finger bones) parameterized by
(around, along). Every chart is laid out so that (image-right, image-up,
outward normal) is a right-handed frame, which keeps tangent-space normal
maps valid without mirrored tangents."""
import numpy as np

AXES = np.array([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]], float)


def basis_for_normal(n, prefer=None):
    n = np.asarray(n, float)
    n = n / np.linalg.norm(n)
    u = np.array([0.0, 1.0, 0.0]) if abs(n[1]) < 0.8 else np.array([1.0, 0.0, 0.0])
    if prefer is not None:
        u = np.asarray(prefer, float)
    u = u - n * (u @ n)
    u /= np.linalg.norm(u)
    v = np.cross(n, u)
    return u, v, n  # right-handed: u x v = n


def face_normals(V, F):
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    fn = np.cross(b - a, c - a)
    return fn / np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)


def face_adjacency(F, nv):
    E = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]], axis=0)
    fid = np.tile(np.arange(len(F)), 3)
    Es = np.sort(E, axis=1)
    key = Es[:, 0] * (nv + 1) + Es[:, 1]
    order = np.argsort(key, kind="stable")
    ks, fs = key[order], fid[order]
    same = ks[1:] == ks[:-1]
    return np.stack([fs[:-1][same], fs[1:][same]], axis=1)


def charts_3d(V, F, min_faces=24, min_dot=0.3, max_ext=None):
    """Dominant-axis charts with connectivity; tiny charts merged into the
    neighbour they share most edges with (if their faces still face that axis)."""
    fn = face_normals(V, F)
    lab = np.argmax(fn @ AXES.T, axis=1)
    pairs = face_adjacency(F, len(V))
    parent = np.arange(len(F))

    def find(x):
        r = x
        while parent[r] != r:
            r = parent[r]
        while parent[x] != r:
            parent[x], x = r, parent[x]
        return r

    for p, q in pairs[lab[pairs[:, 0]] == lab[pairs[:, 1]]]:
        rp, rq = find(p), find(q)
        if rp != rq:
            parent[rq] = rp
    comp = np.array([find(i) for i in range(len(F))])
    axis_of = {c: lab[c] for c in np.unique(comp)}
    for _ in range(6):
        sizes = {c: n for c, n in zip(*np.unique(comp, return_counts=True))}
        small = sorted([c for c, n in sizes.items() if n < min_faces], key=lambda c: sizes[c])
        if not small:
            break
        changed = False
        cp = comp[pairs]
        cross = cp[:, 0] != cp[:, 1]
        cpx = cp[cross]
        for c in small:
            if sizes.get(c, 0) == 0:
                continue
            m = (cpx[:, 0] == c) | (cpx[:, 1] == c)
            if not m.any():
                continue
            nb = np.where(cpx[m][:, 0] == c, cpx[m][:, 1], cpx[m][:, 0])
            cand, cnt = np.unique(nb, return_counts=True)
            faces = np.where(comp == c)[0]
            for k in np.argsort(-cnt):
                tgt = cand[k]
                ax = AXES[axis_of[tgt]]
                if np.all(fn[faces] @ ax >= min_dot):
                    comp[faces] = tgt
                    sizes[tgt] = sizes.get(tgt, 0) + len(faces)
                    sizes[c] = 0
                    changed = True
                    break
        if not changed:
            break
        cp = comp[pairs]
    charts = []
    for c in np.unique(comp):
        faces = np.where(comp == c)[0]
        u, v, n = basis_for_normal(AXES[axis_of[c]])
        charts.extend(split_chart(V, F, faces, (u, v, n), pairs, max_ext))
    return charts


def split_chart(V, F, faces, basis, pairs, max_ext):
    """Cut charts larger than max_ext (studs) into slabs along their longer
    projected axis; each slab's connected pieces become separate charts."""
    if max_ext is None:
        return [{"faces": faces, "basis": basis}]
    u, v, n = basis
    cen = V[F[faces]].mean(axis=1)
    P = V[F[faces].reshape(-1)]
    eu = np.ptp(P @ u)
    ev = np.ptp(P @ v)
    if max(eu, ev) <= max_ext:
        return [{"faces": faces, "basis": basis}]
    nu = int(np.ceil(eu / max_ext))
    nv = int(np.ceil(ev / max_ext))
    cu = cen @ u
    cv = cen @ v
    bu = np.minimum(((cu - cu.min()) / max(np.ptp(cu), 1e-9) * nu).astype(int), nu - 1)
    bv = np.minimum(((cv - cv.min()) / max(np.ptp(cv), 1e-9) * nv).astype(int), nv - 1)
    cell = bu * nv + bv
    # connected components inside each cell
    local = -np.ones(len(F), np.int64)
    local[faces] = np.arange(len(faces))
    pm = (local[pairs[:, 0]] >= 0) & (local[pairs[:, 1]] >= 0)
    lp = local[pairs[pm]]
    lp = lp[cell[lp[:, 0]] == cell[lp[:, 1]]]
    parent = np.arange(len(faces))

    def find(x):
        r = x
        while parent[r] != r:
            r = parent[r]
        while parent[x] != r:
            parent[x], x = r, parent[x]
        return r

    for p, q in lp:
        rp, rq = find(p), find(q)
        if rp != rq:
            parent[rq] = rp
    roots = np.array([find(i) for i in range(len(faces))])
    out = []
    for r in np.unique(roots):
        out.append({"faces": faces[roots == r], "basis": basis})
    return out


def oriented_basis(P, n):
    """In-plane basis aligned with the principal axes of the points (tight boxes)."""
    u0, v0, n = basis_for_normal(n)
    q = np.stack([P @ u0, P @ v0], axis=1)
    q = q - q.mean(axis=0)
    w, vec = np.linalg.eigh(q.T @ q)
    d = vec[:, np.argmax(w)]
    u = u0 * d[0] + v0 * d[1]
    return basis_for_normal(n, prefer=u)


class Atlas:
    """Collects charts (3D-projected or fixed-size rects) and packs them."""
    def __init__(self, size=1024, pad=4):
        self.size, self.pad = size, pad
        self.items = []

    def add_chart(self, V, F, faces, basis, scale=1.0, tag="flesh"):
        it = {"type": "chart", "V": V, "F": F, "faces": faces, "scale": scale, "tag": tag}
        self._set_basis(it, basis)
        it["basis0"] = basis
        self.items.append(it)
        return it

    @staticmethod
    def _set_basis(it, basis):
        u, v, n = basis
        P = it["V"][it["F"][it["faces"]].reshape(-1)]
        pu, pv = P @ u, P @ v
        it["basis"] = basis
        it["umax"], it["vmin"] = pu.max(), pv.min()
        it["w"], it["h"] = pu.max() - pu.min(), pv.max() - pv.min()

    def add_rect(self, w_px, h_px, tag):
        it = {"type": "rect", "wpx": int(w_px), "hpx": int(h_px), "tag": tag}
        self.items.append(it)
        return it

    def _dims(self, it, d):
        if it["type"] == "rect":
            return it["wpx"] + 2 * self.pad, it["hpx"] + 2 * self.pad
        k = d * it["scale"]
        return int(np.ceil(it["w"] * k)) + 2 * self.pad, int(np.ceil(it["h"] * k)) + 2 * self.pad

    def _try(self, d):
        """Skyline bottom-left packing (tallest first)."""
        dims = [self._dims(it, d) for it in self.items]
        order = sorted(range(len(self.items)), key=lambda i: (-dims[i][1], -dims[i][0]))
        W = self.size
        sky = [[0, 0, W]]  # segments: x, y, width
        pos = {}
        for i in order:
            w, h = dims[i]
            if w > W or h > W:
                return None
            best = None
            for si in range(len(sky)):
                x = sky[si][0]
                if x + w > W:
                    break
                # max y over the segments covered by [x, x+w)
                y = 0
                rem = w
                sj = si
                while rem > 0 and sj < len(sky):
                    y = max(y, sky[sj][1])
                    rem -= sky[sj][2]
                    sj += 1
                if rem > 0 or y + h > W:
                    continue
                if best is None or y + h < best[1] + best_h or (y + h == best[1] + best_h and x < best[0]):
                    best = (x, y, si)
                    best_h = h
            if best is None:
                return None
            x, y, si = best
            pos[i] = (x, y, False)
            # update skyline
            new = []
            for seg in sky:
                sx, sy, sw = seg
                ex = sx + sw
                if ex <= x or sx >= x + w:
                    new.append(seg)
                    continue
                if sx < x:
                    new.append([sx, sy, x - sx])
                if ex > x + w:
                    new.append([x + w, sy, ex - (x + w)])
            new.append([x, y + h, w])
            new.sort(key=lambda s: s[0])
            # merge equal-height neighbours
            merged = []
            for seg in new:
                if merged and merged[-1][1] == seg[1] and merged[-1][0] + merged[-1][2] == seg[0]:
                    merged[-1][2] += seg[2]
                else:
                    merged.append(seg)
            sky = merged
        return pos

    def pack(self, raster=True, fill=0.8):
        area = 0.0
        fixed = 0.0
        for it in self.items:
            if it["type"] == "rect":
                fixed += (it["wpx"] + 2 * self.pad) * (it["hpx"] + 2 * self.pad)
            else:
                faces = it["F"][it["faces"]]
                P = it["V"]
                a = np.linalg.norm(np.cross(P[faces[:, 1]] - P[faces[:, 0]], P[faces[:, 2]] - P[faces[:, 0]]), axis=1).sum() * 0.5
                area += a * it["scale"] ** 2
        free = self.size * self.size * fill - fixed
        d = np.sqrt(max(free, 1.0) / max(area, 1e-6))
        while True:
            pos = self._try_raster(d) if raster else self._try(d)
            if pos is not None:
                break
            d *= 0.96
        self.density = d
        for i, it in enumerate(self.items):
            x, y, rot = pos[i]
            if rot and it["type"] == "chart":
                u, v, n = it["basis0"]
                self._set_basis(it, (v, -u, n))
            elif it["type"] == "chart":
                self._set_basis(it, it["basis0"])
            it["x"], it["y"] = x, y
            it["k"] = d * it.get("scale", 1.0)
        return d

    def _chart_mask(self, it, d, basis, cell):
        """Occupancy (in cells) of a chart incl. padding, plus its px size."""
        from bake import rasterize
        import scipy.ndimage as ndi
        u, v, n = basis
        k = d * it["scale"]
        P = it["V"][it["F"][it["faces"]]]
        pu = P @ u
        pv = P @ v
        px = (pu.max() - pu) * k + self.pad
        py = (pv - pv.min()) * k + self.pad
        w = int(np.ceil(np.ptp(pu) * k)) + 2 * self.pad + 1
        h = int(np.ceil(np.ptp(pv) * k)) + 2 * self.pad + 1
        S = max(w, h)
        uvpx = np.stack([px, py], axis=-1)
        fidx, bary, ix, iy = rasterize(uvpx, S)
        m = np.zeros((S, S), bool)
        m[iy, ix] = True
        # conservative: also mark triangle vertices (thin slivers)
        vx = np.clip(px.reshape(-1).astype(int), 0, S - 1)
        vy = np.clip(py.reshape(-1).astype(int), 0, S - 1)
        m[vy, vx] = True
        m = m[:h, :w]
        m = ndi.binary_dilation(m, iterations=self.pad)
        gh, gw = int(np.ceil(h / cell)), int(np.ceil(w / cell))
        mm = np.zeros((gh * cell, gw * cell), bool)
        mm[:h, :w] = m
        mm = mm.reshape(gh, cell, gw, cell).any(axis=(1, 3))
        return mm

    def _try_raster(self, d, cell=2):
        from scipy.signal import fftconvolve
        G = self.size // cell
        occ = np.zeros((G, G), np.float32)
        cand = []
        for i, it in enumerate(self.items):
            if it["type"] == "rect":
                gw = int(np.ceil((it["wpx"] + 2 * self.pad) / cell))
                gh = int(np.ceil((it["hpx"] + 2 * self.pad) / cell))
                cand.append([(np.ones((gh, gw), bool), False)])
            else:
                u, v, n = it["basis0"]
                m0 = self._chart_mask(it, d, (u, v, n), cell)
                m1 = self._chart_mask(it, d, (v, -u, n), cell)
                cand.append([(m0, False), (m1, True)])
        order = sorted(range(len(self.items)), key=lambda i: -max(c[0].sum() for c in cand[i]))
        pos = {}
        for i in order:
            best = None
            for m, rot in cand[i]:
                gh, gw = m.shape
                if gh > G or gw > G:
                    continue
                ov = fftconvolve(occ, m[::-1, ::-1].astype(np.float32), mode="valid")
                ok = np.argwhere(ov < 0.5)
                if len(ok) == 0:
                    continue
                # lowest top edge first (fills the atlas from the top down)
                score = ok[:, 0] * G + ok[:, 1]
                j = np.argmin(score)
                y, x = ok[j]
                key = (y + gh, x)
                if best is None or key < best[0]:
                    best = (key, y, x, m, rot)
            if best is None:
                return None
            _, y, x, m, rot = best
            gh, gw = m.shape
            occ[y:y + gh, x:x + gw] += m
            pos[i] = (int(x * cell), int(y * cell), rot)
        return pos

    def chart_uv(self, it):
        """Per-corner UVs (nf, 3, 2) in [0,1] for a packed chart."""
        u, v, n = it["basis"]
        P = it["V"][it["F"][it["faces"]]]  # nf,3,3
        k = it["k"]
        px = (it["umax"] - P @ u) * k + it["x"] + self.pad  # image right = -u
        py = (P @ v - it["vmin"]) * k + it["y"] + self.pad  # image down = +v
        return np.stack([px, py], axis=-1) / self.size

    def rect_uv(self, it, s, t):
        """s (around 0..1, image right) and t (along 0..1, image up)."""
        px = it["x"] + self.pad + s * it["wpx"]
        py = it["y"] + self.pad + (1.0 - t) * it["hpx"]
        return np.stack([px, py], axis=-1) / self.size


def ring_param_uv(piece, sides, reverse=False):
    """Per-corner (s, t) for tube/blade pieces built from rings of `sides`
    vertices plus optional tip / base-cap vertices. Returns (nf, 3, 2)."""
    V, F, T = piece.V, piece.F, piece.t
    idx = np.arange(len(V))
    j = idx % sides
    s_raw = j / sides
    is_ring = np.ones(len(V), bool)
    # caps: tube tip = last vertex; blade tip + base-cap center = last two
    if piece.kind == "tube":
        rows = (len(V) - 1) // sides
        extras = list(range(rows * sides, len(V)))
    else:
        rows = (len(V) - 2) // sides
        extras = list(range(rows * sides, len(V)))
    is_ring[extras] = False
    S = s_raw[F].astype(float)
    Tt = T[F].astype(float)
    ring_c = is_ring[F]
    # wrap fix on ring corners
    for f in range(len(F)):
        rc = ring_c[f]
        if rc.sum() >= 2:
            vals = S[f][rc]
            if vals.max() - vals.min() > 0.5:
                S[f][rc & (S[f] < 0.5)] += 1.0
        if (~rc).any() and rc.any():
            S[f][~rc] = S[f][rc].mean()
    if reverse:
        S = 1.0 - S + 0.0
    # base cap of blades lies at t=0 (hidden inside the body)
    return S, Tt

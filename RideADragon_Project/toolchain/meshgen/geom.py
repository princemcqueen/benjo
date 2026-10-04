"""Explicit geometry generators: tubes (horns, fingers), blades (spines,
claws, teeth), membranes (wing panels) and simple shells."""
import numpy as np


def _frame(t, hint=np.array([0.0, 1.0, 0.0])):
    t = t / max(np.linalg.norm(t), 1e-9)
    if abs(t @ hint) > 0.95:
        hint = np.array([1.0, 0.0, 0.0])
    b = np.cross(t, hint)
    b /= np.linalg.norm(b)
    n = np.cross(b, t)
    return t, n, b


def catmull(points, samples):
    P = np.asarray(points, float)
    if len(P) == 2:
        s = np.linspace(0, 1, samples)[:, None]
        return P[0] * (1 - s) + P[1] * s
    ext = np.vstack([2 * P[0] - P[1], P, 2 * P[-1] - P[-2]])
    out = []
    segs = len(P) - 1
    per = max(2, samples // segs)
    for i in range(segs):
        p0, p1, p2, p3 = ext[i], ext[i + 1], ext[i + 2], ext[i + 3]
        for j in range(per):
            t = j / per
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(P[-1])
    return np.array(out)


def tube(points, radii, sides=10, samples=24, cap_tip=True, cap_base=False, flatten=1.0, up_hint=None):
    """Tube along a smooth curve through `points`; radii: callable(t in 0..1)
    or (r0, r1). A pointed tip when radius reaches 0. flatten scales one axis."""
    C = catmull(points, samples)
    n = len(C)
    if not callable(radii):
        r0, r1 = radii
        radii_f = lambda t: r0 + (r1 - r0) * t
    else:
        radii_f = radii
    V, F, T = [], [], []
    hint = np.array([0.0, 1.0, 0.0]) if up_hint is None else np.asarray(up_hint, float)
    prev_n = None
    for i in range(n):
        tdir = C[min(i + 1, n - 1)] - C[max(i - 1, 0)]
        t, nn, bb = _frame(tdir, hint)
        if prev_n is not None:  # parallel transport for a twist-free frame
            nn = prev_n - t * (prev_n @ t)
            if np.linalg.norm(nn) < 1e-6:
                nn = _frame(tdir, hint)[1]
            nn /= np.linalg.norm(nn)
            bb = np.cross(t, nn)
        prev_n = nn
        u = i / (n - 1)
        r = max(radii_f(u), 0.0)
        for j in range(sides):
            a = 2 * np.pi * j / sides
            off = (np.cos(a) * nn + np.sin(a) * bb * flatten) * r
            V.append(C[i] + off)
            T.append(u)
    for i in range(n - 1):
        for j in range(sides):
            a = i * sides + j
            b = i * sides + (j + 1) % sides
            c = (i + 1) * sides + j
            d = (i + 1) * sides + (j + 1) % sides
            F.append((a, c, b))
            F.append((b, c, d))
    V = np.array(V)
    T = np.array(T)
    if cap_tip:
        tip = len(V)
        V = np.vstack([V, C[-1] + (C[-1] - C[-2]) * 0.15])
        T = np.append(T, 1.0)
        base = (n - 1) * sides
        for j in range(sides):
            F.append((base + j, tip, base + (j + 1) % sides))
    if cap_base:
        cb = len(V)
        V = np.vstack([V, C[0]])
        T = np.append(T, 0.0)
        for j in range(sides):
            F.append((cb, j, (j + 1) % sides))
    return V, np.array(F, np.int64), T


def blade(base, tip, side, width, thickness, curve=0.15, rows=5):
    """Curved double-sided blade/spike: base point, tip point, `side` = the
    thin direction (normal of the blade plane). Returns V, F, t(0 base..1 tip)."""
    base = np.asarray(base, float)
    tip = np.asarray(tip, float)
    axis = tip - base
    L = np.linalg.norm(axis)
    a = axis / max(L, 1e-9)
    s = np.asarray(side, float)
    s = s - a * (s @ a)
    s /= max(np.linalg.norm(s), 1e-9)
    w = np.cross(a, s)  # width direction
    V, T = [], []
    for i in range(rows + 1):
        t = i / rows
        center = base + axis * t + w * (curve * L * np.sin(t * np.pi) * 0.5)
        half_w = width * 0.5 * (1 - t) ** 0.9
        half_t = thickness * 0.5 * (1 - t) ** 0.8
        # ring of 4: front, side+, back, side-
        V += [center + w * half_w, center + s * half_t, center - w * half_w, center - s * half_t]
        T += [t] * 4
    F = []
    for i in range(rows):
        for j in range(4):
            p = i * 4 + j
            q = i * 4 + (j + 1) % 4
            r = (i + 1) * 4 + j
            u = (i + 1) * 4 + (j + 1) % 4
            F += [(p, q, r), (q, u, r)]
    tipi = len(V)
    V.append(tip)
    T.append(1.0)
    last = rows * 4
    for j in range(4):
        F.append((last + j, last + (j + 1) % 4, tipi))
    # base cap
    bc = len(V)
    V.append(base)
    T.append(0.0)
    for j in range(4):
        F.append((bc, (j + 1) % 4, j))
    return np.array(V), np.array(F, np.int64), np.array(T)


def orient_faces_outward_from(V, F, center):
    """Flip faces whose normals point toward `center` (for convex-ish pieces)."""
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    n = np.cross(b - a, c - a)
    m = (a + b + c) / 3 - center
    flip = np.einsum("ij,ij->i", n, m) < 0
    F = F.copy()
    F[flip] = F[flip][:, ::-1]
    return F


def fix_winding_local(V, F):
    """Orient a closed tube/blade outward using each face's distance to the
    piece's local axis (per-face centroid vs. nearby vertex average)."""
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    n = np.cross(b - a, c - a)
    cen = (a + b + c) / 3
    # signed volume test: if overall inside-out, flip all
    vol = np.sum(np.einsum("ij,ij->i", a, np.cross(b, c))) / 6.0
    if vol < 0:
        return F[:, ::-1].copy()
    return F


def membrane_panel(corners, bones_at, res=10, scallop=None):
    """Triangle panel between 3 corner points, subdivided (res per edge).
    corners: (A, B, C) ; bones_at: callable(barycentric (a,b,c)) -> dict bone->w.
    scallop: (edge index 1 = B-C, depth) pulls the B-C edge inward.
    Returns V, F, weights list, bary."""
    A, B, C = [np.asarray(x, float) for x in corners]
    V, BW, BARY = [], [], []
    index = {}
    for i in range(res + 1):
        for j in range(res + 1 - i):
            k = res - i - j
            a, b, c = i / res, j / res, k / res
            p = A * a + B * b + C * c
            if scallop is not None and a < 1e-9 and b > 0 and c > 0:
                depth = scallop * 4 * b * c
                p = p + (A - p) * depth
            elif scallop is not None and a > 0 and b > 0 and c > 0:
                # pull interior rows near the trailing edge a little too
                depth = scallop * 4 * b * c * (1 - a) ** 3 * 0.85
                p = p + (A - p) * depth
            index[(i, j)] = len(V)
            V.append(p)
            BW.append(bones_at((a, b, c)))
            BARY.append((a, b, c))
    F = []
    for i in range(res):
        for j in range(res - i):
            p = index[(i, j)]
            q = index[(i + 1, j)]
            r = index[(i, j + 1)]
            F.append((p, q, r))
            if j < res - i - 1:
                s = index[(i + 1, j + 1)]
                F.append((q, s, r))
    return np.array(V), np.array(F, np.int64), BW, np.array(BARY)

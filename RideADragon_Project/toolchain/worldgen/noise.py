"""Deterministic noise shared by the offline world generator and the Luau
terrain writer. hash01() is bit-for-bit identical to the Luau version in
ServerScriptService/World/TerrainWriter.luau (integer math kept < 2^53)."""
import numpy as np

M32 = 4294967296


def hash01(ix, iy, seed):
    """ix, iy integer arrays -> uniform [0,1) (same as Luau hash01)."""
    ix = np.asarray(ix, np.int64)
    iy = np.asarray(iy, np.int64)
    h = (ix * 73856093) % M32
    h = h ^ ((iy * 19349663) % M32)
    h = h ^ (seed % M32)
    h = (h * 69069 + 1013904223) % M32
    h = h ^ (h >> 15)
    h = (h * 40503 + 12345) % M32
    h = h ^ (h >> 13)
    return (h % 16777216) / 16777216.0


def value2(x, y, cell, seed):
    """Smooth 2D value noise in [0,1] (bilinear of hash01 with smoothstep)."""
    qx = np.asarray(x, float) / cell
    qy = np.asarray(y, float) / cell
    x0 = np.floor(qx).astype(np.int64)
    y0 = np.floor(qy).astype(np.int64)
    fx = qx - x0
    fy = qy - y0
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    a = hash01(x0, y0, seed)
    b = hash01(x0 + 1, y0, seed)
    c = hash01(x0, y0 + 1, seed)
    d = hash01(x0 + 1, y0 + 1, seed)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm2(x, y, cell, octaves=4, seed=1, gain=0.5):
    tot, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        tot = tot + value2(x, y, cell / (2 ** o), seed + o * 101) * amp
        norm += amp
        amp *= gain
    return tot / norm


def ridged2(x, y, cell, octaves=4, seed=7):
    tot, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        n = value2(x, y, cell / (2 ** o), seed + o * 131)
        r = 1.0 - np.abs(n * 2 - 1)
        tot = tot + r * r * amp
        norm += amp
        amp *= 0.5
    return tot / norm


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, float) - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def catmull(points, per_seg=24):
    P = np.asarray(points, float)
    ext = np.vstack([2 * P[0] - P[1], P, 2 * P[-1] - P[-2]])
    out = []
    for i in range(len(P) - 1):
        p0, p1, p2, p3 = ext[i], ext[i + 1], ext[i + 2], ext[i + 3]
        for j in range(per_seg):
            t = j / per_seg
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(P[-1])
    return np.array(out)


def polyline_distance(X, Z, pts):
    """Distance from grid points to a polyline + normalized arc parameter."""
    pts = np.asarray(pts, float)
    seg = np.diff(pts, axis=0)
    L = np.linalg.norm(seg, axis=1)
    cum = np.concatenate([[0], np.cumsum(L)])
    best = np.full(X.shape, 1e9)
    tpar = np.zeros(X.shape)
    for i in range(len(seg)):
        ax, az = pts[i]
        dx, dz = seg[i]
        l2 = max(dx * dx + dz * dz, 1e-9)
        t = np.clip(((X - ax) * dx + (Z - az) * dz) / l2, 0, 1)
        px, pz = ax + t * dx, az + t * dz
        d = np.hypot(X - px, Z - pz)
        m = d < best
        best = np.where(m, d, best)
        tpar = np.where(m, (cum[i] + t * L[i]) / cum[-1], tpar)
    return best, tpar

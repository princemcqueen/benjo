"""Texture baking: rasterize triangles in UV space, interpolate per-texel
3D attributes, run vectorized shading functions, dilate chart borders."""
import numpy as np


def rasterize(UVpx, size):
    """UVpx: (F,3,2) texel coords. Returns (face, bary(3), ix, iy) per covered texel."""
    F = UVpx.shape[0]
    mn = np.floor(UVpx.min(axis=1)).astype(np.int64)
    mx = np.ceil(UVpx.max(axis=1)).astype(np.int64)
    mn = np.clip(mn - 1, 0, size - 1)
    mx = np.clip(mx + 1, 0, size - 1)
    w = mx[:, 0] - mn[:, 0] + 1
    h = mx[:, 1] - mn[:, 1] + 1
    counts = w * h
    total = int(counts.sum())
    fidx = np.repeat(np.arange(F), counts)
    start = np.repeat(np.cumsum(counts) - counts, counts)
    local = np.arange(total) - start
    lw = w[fidx]
    ix = mn[fidx, 0] + local % lw
    iy = mn[fidx, 1] + local // lw
    # texel centers
    px = ix + 0.5
    py = iy + 0.5
    a = UVpx[fidx, 0]
    b = UVpx[fidx, 1]
    c = UVpx[fidx, 2]
    v0 = b - a
    v1 = c - a
    v2x = px - a[:, 0]
    v2y = py - a[:, 1]
    d00 = np.einsum("ij,ij->i", v0, v0)
    d01 = np.einsum("ij,ij->i", v0, v1)
    d11 = np.einsum("ij,ij->i", v1, v1)
    d20 = v2x * v0[:, 0] + v2y * v0[:, 1]
    d21 = v2x * v1[:, 0] + v2y * v1[:, 1]
    den = d00 * d11 - d01 * d01
    den = np.where(np.abs(den) < 1e-12, 1e-12, den)
    bv = (d11 * d20 - d01 * d21) / den
    bw = (d00 * d21 - d01 * d20) / den
    bu = 1 - bv - bw
    eps = -0.02
    inside = (bu >= eps) & (bv >= eps) & (bw >= eps)
    fidx, ix, iy = fidx[inside], ix[inside], iy[inside]
    bary = np.stack([bu[inside], bv[inside], bw[inside]], axis=1)
    bary = np.clip(bary, 0, None)
    bary /= bary.sum(axis=1, keepdims=True)
    # one face per texel (last write wins; fine because neighbours agree)
    flat = iy * size + ix
    _, keep = np.unique(flat[::-1], return_index=True)
    keep = len(flat) - 1 - keep
    return fidx[keep], bary[keep], ix[keep], iy[keep]


def interp(corner_attr, fidx, bary):
    """corner_attr: (F,3,k) -> per texel (n,k)."""
    A = corner_attr[fidx]
    return np.einsum("nij,ni->nj", A, bary)


def dilate(img, mask, iters=8):
    """Grow chart borders into empty texels (avoids seams with mipmapping)."""
    img = img.copy()
    mask = mask.copy()
    H, W = mask.shape
    for _ in range(iters):
        acc = np.zeros_like(img, dtype=np.float64)
        cnt = np.zeros((H, W))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                sm = np.roll(np.roll(mask, dy, 0), dx, 1)
                si = np.roll(np.roll(img, dy, 0), dx, 1)
                acc += si * sm[..., None]
                cnt += sm
        grow = (~mask) & (cnt > 0)
        img[grow] = (acc[grow] / cnt[grow][:, None]).astype(img.dtype)
        mask = mask | grow
    # fill the rest with the mean color
    if (~mask).any():
        img[~mask] = img[mask].mean(axis=0)
    return img


# ------------------------------------------------------------------ noise
def _hash(ix, iy, iz, seed):
    h = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791) ^ (seed * 2654435761)
    h = h.astype(np.uint64)
    h ^= h >> np.uint64(13)
    h *= np.uint64(0x5bd1e995)
    h ^= h >> np.uint64(15)
    return h


def _u01(h, salt):
    x = (h ^ np.uint64(salt * 0x9E3779B97F4A7C15 & 0xFFFFFFFFFFFFFFFF)) * np.uint64(0xBF58476D1CE4E5B9)
    x ^= x >> np.uint64(31)
    return (x & np.uint64(0xFFFFFF)).astype(np.float64) / float(0x1000000)


def worley(P, cell, seed=1, stretch=(1.0, 1.0, 1.0)):
    """Returns F1, F2 (studs) and a per-cell random value in [0,1)."""
    Q = P / cell * np.asarray(stretch)
    base = np.floor(Q).astype(np.int64)
    f1 = np.full(len(P), 1e9)
    f2 = np.full(len(P), 1e9)
    rid = np.zeros(len(P))
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                cx, cy, cz = base[:, 0] + dx, base[:, 1] + dy, base[:, 2] + dz
                h = _hash(cx, cy, cz, seed)
                jx, jy, jz = _u01(h, 1), _u01(h, 2), _u01(h, 3)
                d = np.sqrt((Q[:, 0] - cx - jx) ** 2 + (Q[:, 1] - cy - jy) ** 2 + (Q[:, 2] - cz - jz) ** 2)
                closer = d < f1
                f2 = np.where(closer, f1, np.minimum(f2, d))
                rid = np.where(closer, _u01(h, 4), rid)
                f1 = np.where(closer, d, f1)
    return f1 * cell, f2 * cell, rid


def value_noise(P, cell, seed=7):
    """Smooth 3D value noise in [0,1]."""
    Q = P / cell
    b = np.floor(Q).astype(np.int64)
    f = Q - b
    f = f * f * (3 - 2 * f)
    out = np.zeros(len(P))
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                h = _hash(b[:, 0] + dx, b[:, 1] + dy, b[:, 2] + dz, seed)
                v = _u01(h, 5)
                wx = f[:, 0] if dx else 1 - f[:, 0]
                wy = f[:, 1] if dy else 1 - f[:, 1]
                wz = f[:, 2] if dz else 1 - f[:, 2]
                out += v * wx * wy * wz
    return out


def fbm(P, cell, octaves=3, seed=11):
    out = np.zeros(len(P))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += value_noise(P, cell / (2 ** o), seed + o * 17) * amp
        tot += amp
        amp *= 0.5
    return out / tot


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)

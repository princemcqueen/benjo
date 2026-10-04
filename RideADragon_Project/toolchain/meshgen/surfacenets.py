"""Naive Surface Nets on a signed distance grid (vectorized numpy).
One vertex per sign-changing cell (average of edge crossings), one quad per
sign-changing grid edge. Produces a closed, well-shaped mesh without tables."""
import numpy as np

# cube corners (dx, dy, dz) and the 12 edges as corner index pairs
CORNERS = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]])
EDGES = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]


def surface_nets(D, origin, h, iso=0.0):
    D = np.asarray(D, np.float64) - iso
    nx, ny, nz = D.shape
    cx, cy, cz = nx - 1, ny - 1, nz - 1
    corner_vals = [D[dx:dx + cx, dy:dy + cy, dz:dz + cz] for dx, dy, dz in CORNERS]
    inside = [v < 0 for v in corner_vals]
    count = np.zeros((cx, cy, cz), np.int32)
    for m in inside:
        count += m
    active = (count > 0) & (count < 8)
    acc = np.zeros((cx, cy, cz, 3))
    num = np.zeros((cx, cy, cz))
    for a, b in EDGES:
        va, vb = corner_vals[a], corner_vals[b]
        cross = (va < 0) != (vb < 0)
        t = np.where(cross, va / np.where(cross, va - vb, 1.0), 0.0)
        pa = CORNERS[a].astype(float)
        pb = CORNERS[b].astype(float)
        p = pa[None, None, None, :] + t[..., None] * (pb - pa)[None, None, None, :]
        acc += np.where(cross[..., None], p, 0.0)
        num += cross
    idx = -np.ones((cx, cy, cz), np.int64)
    act = np.argwhere(active)
    idx[active] = np.arange(len(act))
    rel = acc[active] / np.maximum(num[active], 1)[:, None]
    verts = origin + (act + rel) * h

    faces = []
    # x-edges: between grid points (i,j,k) and (i+1,j,k); cells sharing it: (i, j-1..j, k-1..k)
    def quads(axis):
        if axis == 0:
            a = D[:-1, 1:-1, 1:-1]
            b = D[1:, 1:-1, 1:-1]
        elif axis == 1:
            a = D[1:-1, :-1, 1:-1]
            b = D[1:-1, 1:, 1:-1]
        else:
            a = D[1:-1, 1:-1, :-1]
            b = D[1:-1, 1:-1, 1:]
        cross = (a < 0) != (b < 0)
        ids = np.argwhere(cross)
        if len(ids) == 0:
            return
        flip = (a[cross] < 0)  # inside -> outside along +axis
        if axis == 0:
            i, j, k = ids[:, 0], ids[:, 1] + 1, ids[:, 2] + 1
            c0 = idx[i, j - 1, k - 1]
            c1 = idx[i, j, k - 1]
            c2 = idx[i, j, k]
            c3 = idx[i, j - 1, k]
        elif axis == 1:
            i, j, k = ids[:, 0] + 1, ids[:, 1], ids[:, 2] + 1
            c0 = idx[i - 1, j, k - 1]
            c1 = idx[i - 1, j, k]
            c2 = idx[i, j, k]
            c3 = idx[i, j, k - 1]
        else:
            i, j, k = ids[:, 0] + 1, ids[:, 1] + 1, ids[:, 2]
            c0 = idx[i - 1, j - 1, k]
            c1 = idx[i, j - 1, k]
            c2 = idx[i, j, k]
            c3 = idx[i - 1, j, k]
        q = np.stack([c0, c1, c2, c3], axis=1)
        q[~flip] = q[~flip][:, ::-1]
        ok = np.all(q >= 0, axis=1)
        q = q[ok]
        faces.append(np.concatenate([q[:, [0, 1, 2]], q[:, [0, 2, 3]]], axis=0))

    for ax in range(3):
        quads(ax)
    F = np.concatenate(faces, axis=0) if faces else np.zeros((0, 3), np.int64)
    return verts, F


def orient_outward(V, F):
    """Flip all faces if the mesh is inside-out (signed volume < 0)."""
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    vol = np.sum(np.einsum("ij,ij->i", a, np.cross(b, c))) / 6.0
    if vol < 0:
        F = F[:, ::-1].copy()
    return F

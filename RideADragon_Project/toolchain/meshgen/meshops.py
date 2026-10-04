"""Mesh utilities: normals, adjacency, Taubin smoothing, QEM decimation,
merging and validation."""
import heapq

import numpy as np


def face_normals(V, F):
    n = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    return n / np.maximum(ln, 1e-12), ln[:, 0] * 0.5


def vertex_normals(V, F):
    n = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])  # area weighted
    vn = np.zeros_like(V)
    for k in range(3):
        np.add.at(vn, F[:, k], n)
    ln = np.linalg.norm(vn, axis=1, keepdims=True)
    return vn / np.maximum(ln, 1e-12)


def edges_unique(F):
    E = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]], axis=0)
    E = np.sort(E, axis=1)
    return np.unique(E, axis=0)


def laplacian_step(V, E, factor, fixed=None):
    n = len(V)
    acc = np.zeros_like(V)
    cnt = np.zeros(n)
    np.add.at(acc, E[:, 0], V[E[:, 1]])
    np.add.at(acc, E[:, 1], V[E[:, 0]])
    np.add.at(cnt, E[:, 0], 1)
    np.add.at(cnt, E[:, 1], 1)
    avg = acc / np.maximum(cnt, 1)[:, None]
    d = (avg - V) * factor
    if fixed is not None:
        d[fixed] = 0
    return V + d


def taubin(V, F, iters=6, lam=0.5, mu=-0.53, fixed=None):
    E = edges_unique(F)
    V = V.copy()
    for _ in range(iters):
        V = laplacian_step(V, E, lam, fixed)
        V = laplacian_step(V, E, mu, fixed)
    return V


def compact(V, F, *extra):
    used = np.unique(F)
    remap = -np.ones(len(V), np.int64)
    remap[used] = np.arange(len(used))
    out = [V[used], remap[F]]
    for e in extra:
        out.append(e[used])
    return out


def merge(meshes):
    """meshes: list of (V, F, extra_dict) -> concatenated."""
    Vs, Fs, off = [], [], 0
    extras = {}
    for V, F, ex in meshes:
        Vs.append(V)
        Fs.append(F + off)
        off += len(V)
        for k, v in (ex or {}).items():
            extras.setdefault(k, []).append(v)
    return np.concatenate(Vs), np.concatenate(Fs), {k: np.concatenate(v) for k, v in extras.items()}


def is_watertight(F):
    E = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]], axis=0)
    Es = np.sort(E, axis=1)
    _, counts = np.unique(Es, axis=0, return_counts=True)
    return bool(np.all(counts == 2)), int(np.sum(counts != 2))


# ------------------------------------------------------------------ QEM
def _plane_quadrics(V, F):
    n, area = face_normals(V, F)
    d = -np.einsum("ij,ij->i", n, V[F[:, 0]])
    p = np.concatenate([n, d[:, None]], axis=1)  # (f, 4)
    K = np.einsum("fi,fj->fij", p, p) * area[:, None, None]
    Q = np.zeros((len(V), 4, 4))
    for k in range(3):
        np.add.at(Q, F[:, k], K)
    return Q


def decimate(V, F, target_faces, max_normal_change=0.25, boundary_weight=1e3, locked=None):
    """Garland-Heckbert edge-collapse decimation. locked: bool mask of
    vertices that must not move (e.g. seams)."""
    V = V.astype(np.float64).copy()
    F = F.astype(np.int64).copy()
    nV = len(V)
    Q = _plane_quadrics(V, F)
    faces = [list(f) for f in F]
    alive = [True] * len(faces)
    vfaces = [set() for _ in range(nV)]
    for fi, f in enumerate(faces):
        for v in f:
            vfaces[v].add(fi)
    vver = [0] * nV
    removed_v = [False] * nV
    locked = np.zeros(nV, bool) if locked is None else locked

    def neighbors(v):
        s = set()
        for fi in vfaces[v]:
            s.update(faces[fi])
        s.discard(v)
        return s

    def optimal(a, b):
        Qs = Q[a] + Q[b]
        if locked[a] and locked[b]:
            return None, np.inf
        if locked[a]:
            cands = [V[a]]
        elif locked[b]:
            cands = [V[b]]
        else:
            A = Qs.copy()
            A[3] = [0, 0, 0, 1]
            try:
                if abs(np.linalg.det(A)) > 1e-10:
                    x = np.linalg.solve(A, np.array([0, 0, 0, 1.0]))[:3]
                    # keep the solution near the edge (avoid spikes)
                    mid = (V[a] + V[b]) * 0.5
                    if np.linalg.norm(x - mid) > np.linalg.norm(V[a] - V[b]) * 1.5:
                        raise np.linalg.LinAlgError
                    cands = [x]
                else:
                    raise np.linalg.LinAlgError
            except np.linalg.LinAlgError:
                cands = [V[a], V[b], (V[a] + V[b]) * 0.5]
        best, bc = None, np.inf
        for c in cands:
            h = np.append(c, 1.0)
            cost = float(h @ Qs @ h)
            if cost < bc:
                best, bc = c, cost
        return best, bc

    heap = []
    for a, b in edges_unique(F):
        p, c = optimal(a, b)
        if p is not None:
            heapq.heappush(heap, (c, int(a), int(b), 0, 0))
    nfaces = len(faces)

    def fnormal(f, pos_override):
        p = [pos_override.get(v, V[v]) for v in f]
        n = np.cross(p[1] - p[0], p[2] - p[0])
        ln = np.linalg.norm(n)
        return n / ln if ln > 1e-14 else None

    while nfaces > target_faces and heap:
        cost, a, b, va, vb = heapq.heappop(heap)
        if removed_v[a] or removed_v[b]:
            continue
        if va != vver[a] or vb != vver[b]:
            continue
        # link condition (manifold): common neighbours must equal the 2 opposite verts
        na, nb = neighbors(a), neighbors(b)
        shared_faces = vfaces[a] & vfaces[b]
        if len(na & nb) != len(shared_faces):
            continue
        p, _ = optimal(a, b)
        if p is None:
            continue
        # reject collapses that flip or squash faces
        bad = False
        override = {a: p, b: p}
        for fi in (vfaces[a] | vfaces[b]) - shared_faces:
            f = faces[fi]
            n0 = fnormal(f, {})
            n1 = fnormal(f, override)
            if n0 is None or n1 is None or float(n0 @ n1) < max_normal_change:
                bad = True
                break
        if bad:
            continue
        # collapse b -> a
        V[a] = p
        Q[a] = Q[a] + Q[b]
        for fi in shared_faces:
            alive[fi] = False
            nfaces -= 1
            for v in faces[fi]:
                vfaces[v].discard(fi)
        for fi in list(vfaces[b]):
            f = faces[fi]
            faces[fi] = [a if v == b else v for v in f]
            vfaces[a].add(fi)
        vfaces[b] = set()
        removed_v[b] = True
        vver[a] += 1
        for n in neighbors(a):
            pp, c = optimal(a, n)
            if pp is not None:
                heapq.heappush(heap, (c, a, n, vver[a], vver[n]))
    Fout = np.array([f for f, al in zip(faces, alive) if al], np.int64)
    Vout, Fout = compact(V, Fout)[:2]
    return Vout, Fout

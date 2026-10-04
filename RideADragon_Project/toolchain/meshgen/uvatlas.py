"""UV atlas: charts by dominant normal direction + connectivity, orthographic
projection per chart, shelf packing with padding. Texture content is baked
from 3D functions, so chart seams are invisible."""
import numpy as np

AXES = np.array([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]], float)


def _basis(axis_id):
    n = AXES[axis_id]
    # u, v axes spanning the projection plane (right-handed with n)
    if abs(n[1]) > 0.5:
        u = np.array([1.0, 0, 0])
    else:
        u = np.array([0, 1.0, 0])
    v = np.cross(n, u)
    u = np.cross(v, n)
    return u, v, n


def make_charts(V, F, face_group=None, normals_override=None, min_faces=1):
    """Returns list of charts: dict(faces=array of face ids, basis=(u,v,n))."""
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    fn = np.cross(b - a, c - a)
    fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
    if normals_override is not None:
        fn = normals_override
    lab = np.argmax(fn @ AXES.T, axis=1)
    if face_group is not None:
        lab = lab + 6 * face_group  # never merge faces of different groups
    # connected components among faces with the same label via shared edges
    E = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]], axis=0)
    fid = np.tile(np.arange(len(F)), 3)
    Es = np.sort(E, axis=1)
    key = Es[:, 0] * (len(V) + 1) + Es[:, 1]
    order = np.argsort(key)
    key_s, fid_s = key[order], fid[order]
    same = key_s[1:] == key_s[:-1]
    pairs = np.stack([fid_s[:-1][same], fid_s[1:][same]], axis=1)
    pairs = pairs[lab[pairs[:, 0]] == lab[pairs[:, 1]]]
    parent = np.arange(len(F))

    def find(x):
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:
            parent[x], x = root, parent[x]
        return root

    for p, q in pairs:
        rp, rq = find(p), find(q)
        if rp != rq:
            parent[rq] = rp
    roots = np.array([find(i) for i in range(len(F))])
    charts = []
    for r in np.unique(roots):
        faces = np.where(roots == r)[0]
        charts.append({"faces": faces, "axis": int(lab[faces[0]] % 6)})
    return charts


def pack(V, F, charts, size=1024, pad=4, density=None, density_scale=None):
    """Assigns per-corner UVs (F x 3 x 2). density: texels per stud (auto)."""
    rects = []
    for ch in charts:
        u, v, n = _basis(ch["axis"])
        ch["basis"] = (u, v, n)
        pts = V[F[ch["faces"]].reshape(-1)]
        pu, pv = pts @ u, pts @ v
        ch["min"] = (pu.min(), pv.min())
        ch["ext"] = (pu.max() - pu.min(), pv.max() - pv.min())
    scale_of = lambda ch: (density_scale or {}).get(ch.get("group", 0), 1.0)

    def try_pack(d):
        x = y = rowh = 0
        place = []
        order = sorted(range(len(charts)), key=lambda i: -charts[i]["ext"][1] * scale_of(charts[i]))
        for i in order:
            ch = charts[i]
            k = d * scale_of(ch)
            w = int(np.ceil(ch["ext"][0] * k)) + 2 * pad
            h = int(np.ceil(ch["ext"][1] * k)) + 2 * pad
            if w > size:
                return None
            if x + w > size:
                x = 0
                y += rowh
                rowh = 0
            if y + h > size:
                return None
            place.append((i, x, y, k))
            x += w
            rowh = max(rowh, h)
        return place

    if density is None:
        area = sum(max(ch["ext"][0], 1e-3) * max(ch["ext"][1], 1e-3) * scale_of(ch) ** 2 for ch in charts)
        d = np.sqrt(size * size * 0.62 / max(area, 1e-6))
        while True:
            placed = try_pack(d)
            if placed is not None:
                break
            d *= 0.95
    else:
        d = density
        placed = try_pack(d)
        assert placed is not None, "atlas overflow"
    UV = np.zeros((len(F), 3, 2))
    for i, x, y, k in placed:
        ch = charts[i]
        u, v, n = ch["basis"]
        pts = V[F[ch["faces"]]]  # (nf, 3, 3)
        pu = (pts @ u - ch["min"][0]) * k + x + pad
        pv = (pts @ v - ch["min"][1]) * k + y + pad
        UV[ch["faces"], :, 0] = pu / size
        UV[ch["faces"], :, 1] = pv / size
        ch["texel_density"] = k
    return UV, d


def split_by_uv(V, F, UV, *attrs):
    """Unique (vertex, uv) pairs -> new vertex list (seams duplicated).
    attrs: per-vertex arrays to carry. Returns V2, F2, UV2, [attrs2]."""
    nF = len(F)
    corner_v = F.reshape(-1)
    corner_uv = UV.reshape(-1, 2)
    key = np.concatenate([corner_v[:, None].astype(np.float64), np.round(corner_uv * 1e6)], axis=1)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    V2 = V[uniq[:, 0].astype(np.int64)]
    UV2 = np.zeros((len(uniq), 2))
    UV2[inv] = corner_uv
    F2 = inv.reshape(nF, 3)
    out = [V2, F2, UV2]
    for a in attrs:
        out.append(a[uniq[:, 0].astype(np.int64)])
    return out

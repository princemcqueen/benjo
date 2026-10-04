"""Structural sanity checks for our .glb exports (no external validator)."""
import json
import struct
import sys

import numpy as np

CT = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load(path):
    b = open(path, "rb").read()
    magic, ver, total = struct.unpack("<4sII", b[:12])
    assert magic == b"glTF" and ver == 2 and total == len(b), "bad header"
    jl, jt = struct.unpack("<I4s", b[12:20])
    js = json.loads(b[20:20 + jl])
    bl, bt = struct.unpack("<I4s", b[20 + jl:28 + jl])
    assert bt == b"BIN\x00"
    binb = b[28 + jl:28 + jl + bl]
    return js, binb


def acc(js, binb, i):
    a = js["accessors"][i]
    bv = js["bufferViews"][a["bufferView"]]
    dt = CT[a["componentType"]]
    n = NC[a["type"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    cnt = a["count"]
    nbytes = cnt * n * np.dtype(dt).itemsize
    assert off + nbytes <= bv.get("byteOffset", 0) + bv["byteLength"], f"accessor {i} overflows its bufferView"
    assert off % np.dtype(dt).itemsize == 0, f"accessor {i} misaligned"
    return np.frombuffer(binb, dt, cnt * n, off).reshape(cnt, n)


def main(path):
    js, binb = load(path)
    ok = True
    for i, bv in enumerate(js["bufferViews"]):
        assert bv["byteOffset"] + bv["byteLength"] <= len(binb), f"bufferView {i} out of range"
    mesh = js["meshes"][0]
    prim = mesh["primitives"][0]
    at = prim["attributes"]
    P = acc(js, binb, at["POSITION"])
    N = acc(js, binb, at["NORMAL"])
    UV = acc(js, binb, at["TEXCOORD_0"])
    J = acc(js, binb, at["JOINTS_0"])
    W = acc(js, binb, at["WEIGHTS_0"])
    T = acc(js, binb, at["TANGENT"]) if "TANGENT" in at else None
    I = acc(js, binb, prim["indices"]).reshape(-1)
    nv = len(P)
    print(f"verts {nv}, tris {len(I) // 3}, joints in skin {len(js['skins'][0]['joints'])}")
    checks = {
        "indices < verts": I.max() < nv,
        "normals unit": np.allclose(np.linalg.norm(N, axis=1), 1, atol=1e-3),
        "uv in [0,1]": UV.min() >= -1e-6 and UV.max() <= 1 + 1e-6,
        "weights sum 1": np.allclose(W.sum(axis=1), 1, atol=1e-4),
        "weights >= 0": W.min() >= 0,
        "joint idx < joints": J.max() < len(js["skins"][0]["joints"]),
        "no NaN": not (np.isnan(P).any() or np.isnan(N).any() or np.isnan(W).any()),
        "pos min/max match": np.allclose(P.min(axis=0), js["accessors"][at["POSITION"]]["min"], atol=1e-4)
                             and np.allclose(P.max(axis=0), js["accessors"][at["POSITION"]]["max"], atol=1e-4),
    }
    if T is not None:
        checks["tangent w = +-1"] = np.all(np.isin(T[:, 3], [-1.0, 1.0]))
        checks["tangent unit"] = np.allclose(np.linalg.norm(T[:, :3], axis=1), 1, atol=1e-3)
    # zero-weight joints must index 0 by convention
    checks["unused joint slots zeroed"] = bool(np.all(J[W == 0] == 0))
    # skin
    sk = js["skins"][0]
    ibm = acc(js, binb, sk["inverseBindMatrices"]).reshape(-1, 4, 4)
    checks["ibm count"] = len(ibm) == len(sk["joints"])
    checks["ibm affine"] = np.allclose(ibm[:, :, 3][:, :3], 0) and np.allclose(ibm[:, 3, 3], 1)  # column-major: last col of each stored row
    # node hierarchy: every joint reachable from a scene root; no node with two parents
    parents = {}
    for i, nd in enumerate(js["nodes"]):
        for c in nd.get("children", []):
            assert c not in parents, f"node {c} has two parents"
            parents[c] = i
    roots = js["scenes"][0]["nodes"]
    for j in sk["joints"]:
        k = j
        seen = 0
        while k in parents:
            k = parents[k]
            seen += 1
            assert seen < 1000, "cycle"
        if k not in roots:
            checks[f"joint {j} reachable"] = False
    # bind-pose consistency: world(joint) * ibm == identity for rest pose
    def world(i):
        t = np.array(js["nodes"][i].get("translation", [0, 0, 0]), float)
        return t + (world(parents[i]) if i in parents else 0)
    errs = []
    for k, j in enumerate(sk["joints"]):
        wpos = world(j)
        m = ibm[k].T  # back to row-major
        errs.append(np.abs(m[:3, 3] + wpos).max())
    checks["bind pose consistent"] = max(errs) < 1e-4
    for k, v in checks.items():
        ok &= bool(v)
        print(f"  {'OK ' if v else 'BAD'} {k}")
    mat = js["materials"][prim["material"]]
    print("  material:", json.dumps(mat)[:220])
    print("  images:", [im.get("name") for im in js["images"]])
    print("RESULT:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    main(sys.argv[1])

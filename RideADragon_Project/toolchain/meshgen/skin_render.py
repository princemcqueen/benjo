"""Linear blend skinning of the exported dragon mesh driven by Bone instances
inside the simulator, plus a helper that builds an importer-like template
(MeshPart + Bones) in the sim from <species>_rig.json."""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import rbx_api  # noqa: E402
from rbx_types import CFrame, Vector3, _cf_angles  # noqa: E402


def cf_matrix(cf):
    m = np.eye(4)
    r = cf.r
    m[:3, :3] = np.array(r, float).reshape(3, 3)
    m[:3, 3] = cf.p
    return m


def make_template(sim, species="GreenDrake", parent=None, at=(0, 12, 40), importer_extras=True):
    """Mimics what Studio's 3D importer produces for our .glb: Model > MeshPart
    (at the mesh bbox center) > Bone 'Root' (180 deg yaw + offset) > bone tree."""
    meta = json.load(open(os.path.join(HERE, "out", f"{species}_rig.json")))
    d = np.load(os.path.join(HERE, "out", f"{species}_mesh.npz"))
    V = d["V"]
    lo, hi = V.min(axis=0), V.max(axis=0)
    center = (lo + hi) / 2
    parent = parent or sim.services["Workspace"]
    model = sim.new("Model", parent=parent, Name=species)
    mp = sim.new("MeshPart", parent=model, Name=species, Anchored=True,
                 Size=Vector3(*(hi - lo).tolist()), CFrame=CFrame(tuple(at)))
    # importer: glTF (+Z front) -> Roblox (-Z front) = 180 deg yaw on the root bone,
    # positioned relative to the MeshPart (bbox center)
    rot = _cf_angles(0, math.pi, 0)
    root_pos = rot.point_to_world(Vector3(*(-center).tolist()))
    root = sim.new("Bone", parent=mp, Name="Root", CFrame=CFrame(root_pos.tup(), rot.r))
    bones = {"Root": root}
    piv = {b: np.array(p, float) for b, p in meta["pivots"].items()}
    order = meta["bones"]
    for b in order:
        if b == "Root":
            continue
        p = meta["parents"][b] or "Root"
        rel = piv[b] - piv.get(p, np.zeros(3))
        bones[b] = sim.new("Bone", parent=bones[p], Name=b, CFrame=CFrame(tuple(rel.tolist())))
    for s in meta.get("sockets", []):
        pb = s["bone"] if s["bone"] in bones else "Root"
        rel = np.array(s["pos"]) - piv.get(pb, np.zeros(3))
        sim.new("Bone", parent=bones[pb], Name=s["name"], CFrame=CFrame(tuple(rel.tolist())))
    if importer_extras:
        ac = sim.new("AnimationController", parent=model, Name="AnimationController")
        sim.new("Animator", parent=ac, Name="Animator")
        sim.new("Folder", parent=model, Name="InitialPoses")
    return model


class Skinner:
    def __init__(self, species="GreenDrake"):
        d = np.load(os.path.join(HERE, "out", f"{species}_mesh.npz"))
        meta = json.load(open(os.path.join(HERE, "out", f"{species}_rig.json")))
        self.V = d["V"]
        self.N = d["N"]
        self.F = d["F"]
        self.UV = d["UV"]
        self.T4 = d["T4"]
        self.ji = d["ji"].astype(np.int64)
        self.jw = d["jw"].astype(np.float64)
        self.names = meta["bones"] + [s["name"] for s in meta.get("sockets", [])]
        piv = {b: np.array(p, float) for b, p in meta["pivots"].items()}
        for s in meta.get("sockets", []):
            piv[s["name"]] = np.array(s["pos"], float)
        self.ibm = np.stack([self._inv_bind(piv[n]) for n in self.names])

    @staticmethod
    def _inv_bind(p):
        m = np.eye(4)
        m[:3, 3] = -p
        return m

    def pose(self, sim, mesh_part, scale=1.0):
        """World-space positions/normals for the bones' current transforms.
        scale: uniform Model:ScaleTo factor applied to the rig (bone-local
        vertex offsets shrink with it, exactly like Roblox skinning)."""
        S = np.diag([scale, scale, scale, 1.0])
        bones = {}
        for dsc in mesh_part.descendants():
            if dsc.cls.name == "Bone":
                bones[dsc.props.get("Name")] = dsc
        mats = np.zeros((len(self.names), 4, 4))
        for i, n in enumerate(self.names):
            b = bones.get(n)
            if b is None:
                mats[i] = np.eye(4)
                continue
            wcf = rbx_api.attachment_world_cf(sim, b)
            mats[i] = cf_matrix(wcf) @ S @ self.ibm[i]
        Vh = np.concatenate([self.V, np.ones((len(self.V), 1))], axis=1)
        out = np.zeros((len(self.V), 3))
        nrm = np.zeros((len(self.V), 3))
        tg = np.zeros((len(self.V), 3))
        for k in range(4):
            M = mats[self.ji[:, k]]  # (n,4,4)
            w = self.jw[:, k][:, None]
            out += w * np.einsum("nij,nj->ni", M, Vh)[:, :3]
            nrm += w * np.einsum("nij,nj->ni", M[:, :3, :3], self.N)
            tg += w * np.einsum("nij,nj->ni", M[:, :3, :3], self.T4[:, :3])
        nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        tg /= np.maximum(np.linalg.norm(tg, axis=1, keepdims=True), 1e-9)
        T4 = np.concatenate([tg, self.T4[:, 3:4]], axis=1)
        return out, nrm, T4

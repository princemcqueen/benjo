"""Renders the exported dragon (textured, normal-mapped) from several views."""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import preview3d  # noqa: E402


def load(species="GreenDrake"):
    d = np.load(os.path.join(HERE, "out", f"{species}_mesh.npz"))
    imgs = [Image.open(os.path.join(HERE, "out", f"{species}_{k}.png")).convert("RGB") for k in ("color", "normal", "mr")]
    return d, imgs


def render(species="GreenDrake", out=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "export_preview.png"), views=None, V=None, N=None, T4=None,
           dist=52, target=(0, 1.5, 4), size=(800, 520), normal=True, hip=6.5, sun=None):
    d, (ic, inn, imr) = load(species)
    V = d["V"] if V is None else V
    N = d["N"] if N is None else N
    T4 = d["T4"] if T4 is None else T4
    views = views or ((35, 15), (120, 10), (200, 30), (300, 60))
    ent = preview3d.texmesh_entry(V, d["F"], N, d["UV"], ic, inn if normal else None, imr, T4 if normal else None)
    ground = {"shape": "Block", "cf": [0, -hip - 0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
              "size": [300, 1, 300], "color": [86, 104, 70], "mat": "plastic", "t": 0}
    jobs, paths = [], []
    for i, v in enumerate(views):
        yaw, pitch = v[0], v[1]
        dd = v[2] if len(v) > 2 else dist
        tg = v[3] if len(v) > 3 else target
        cam = preview3d.orbit_camera(list(tg), dd, yaw, pitch, fov=45)
        sc = preview3d.make_scene([ground], cam, fog_density=0.0008, shadow_center=[0, 0, 4], shadow_extent=32, sun=sun)
        sc["texMeshes"] = [ent]
        p = f"{out[:-4]}_{i}.png"
        jobs.append((sc, p, size[0], size[1]))
        paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, [f"view {v[:2]}" for v in views], out, cols=2)
    return out


if __name__ == "__main__":
    print(render())

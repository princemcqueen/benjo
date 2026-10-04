import os, sys, pickle
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, ".."))
import preview3d
import meshops as M
from export_dragon import tangents

def entries(props, layout_xz):
    out = []
    for (name, V, F, N, UV, ic, inn), (x, z) in zip(props, layout_xz):
        V2 = V + np.array([x, 0, z])
        T4 = tangents(V2, F, UV, N)
        out.append(preview3d.texmesh_entry(V2, F, N, UV, ic, inn, None, T4))
    return out

if __name__ == "__main__":
    props = pickle.load(open(os.path.join(HERE, "out", "props.pkl"), "rb"))
    xz = []
    x = 0
    for i, p in enumerate(props):
        w = p[1][:, 0].max() - p[1][:, 0].min()
        xz.append((x, 0 if i < 8 else 18))
        x += w + 4 if i < 7 else 0
    # arrange: trees in a row, small props in a second row
    xz = [(-60 + i * 18, 0) for i in range(8)] + [(-44 + i * 13, 28) for i in range(6)]
    ents = entries(props, xz)
    ground = {"shape": "Block", "cf": [0, -0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [400, 1, 400], "color": [92, 124, 64], "mat": "plastic", "t": 0}
    jobs = []
    paths = []
    for i, (yaw, pitch, dist, tgt) in enumerate([(10, 12, 110, (5, 10, 8)), (30, 25, 55, (-35, 8, 10)), (340, 20, 45, (-5, 3, 28))]):
        cam = preview3d.orbit_camera(list(tgt), dist, yaw, pitch, fov=50)
        sc = preview3d.make_scene([ground], cam, fog_density=0.0006, shadow_center=list(tgt), shadow_extent=90)
        sc["texMeshes"] = ents
        p = f"/tmp/claude-0/out/props_{i}.png"
        jobs.append((sc, p, 1100, 560)); paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, ["all props", "oaks + pines", "bushes + rocks"], "/tmp/claude-0/out/props_sheet.png", cols=1)
    print("ok")

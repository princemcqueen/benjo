"""Builds the dragon mesh and renders vertex-colored previews (shape QA)."""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import numpy as np
import preview3d
import meshops as M
from rig import Rig
from dragon import DragonMesh, REGION_COLORS_EXTRA


def region_color(rig, name):
    if name in REGION_COLORS_EXTRA:
        return np.array(REGION_COLORS_EXTRA[name]) / 255.0
    key = {"WingBone": "Dark", "Spine": "Dark", "Tooth": "Tooth"}.get(name, name)
    return rig.color(key)


def build(species="GreenDrake", target=15000):
    rig = Rig.load(os.path.join(os.path.dirname(__file__), "out", f"{species}.json"))
    dm = DragonMesh(rig)
    t = time.time()
    dm.collect_flesh()
    dm.collect_carves()
    V, F = dm.build_flesh(target_faces=target)
    print(f"flesh: raw {dm.raw_faces} -> {len(F)} faces, grid {tuple(dm.grid.n)} h={dm.grid.h:.3f}  {time.time()-t:.1f}s")
    dm.add_horns(); dm.add_spines(); dm.add_claws_teeth(); dm.add_tail_tip(); dm.add_wing_bones_and_membranes()
    return rig, dm


def preview(rig, dm, out, views=((35, 15), (120, 10), (200, 30), (300, 60))):
    V, F = dm.flesh
    N = M.vertex_normals(V, F)
    regs, Wr = dm.flesh_regions(V)
    cols = np.zeros((len(V), 3))
    for j, r in enumerate(regs):
        cols += Wr[:, j:j + 1] * region_color(rig, r)[None, :]
    # countershading
    up = N[:, 1]
    belly = np.clip((-up - 0.1) / 0.5, 0, 1)[:, None]
    back = np.clip((up - 0.55) / 0.4, 0, 1)[:, None]
    main_mask = np.zeros(len(V))
    for j, r in enumerate(regs):
        if r in ("Main", "Belly", "Dark"):
            main_mask += Wr[:, j]
    main_mask = main_mask[:, None]
    cols = cols * (1 - belly * main_mask) + rig.color("Belly")[None, :] * belly * main_mask
    cols = cols * (1 - back * main_mask * 0.6) + rig.color("Dark")[None, :] * back * main_mask * 0.6
    meshes = [preview3d.mesh_entry(V, F, N, cols)]
    for pc in dm.pieces:
        c = np.tile(region_color(rig, pc.region), (len(pc.V), 1))
        if pc.t is not None and pc.region in ("Horn", "Spine"):
            base = rig.color("Dark") if pc.region == "Spine" else np.array([0.45, 0.4, 0.33])
            tipc = rig.color("Horn") if pc.region == "Horn" else rig.color("Accent")
            c = base[None, :] * (1 - pc.t[:, None]) + tipc[None, :] * pc.t[:, None]
        meshes.append(preview3d.mesh_entry(pc.V, pc.F, None, c))
    ground = {"shape": "Block", "cf": [0, -rig.defn["HipHeight"] * rig.S - 0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
              "size": [200, 1, 200], "color": [92, 120, 70], "mat": "plastic", "t": 0}
    jobs, paths = [], []
    for i, (yaw, pitch) in enumerate(views):
        cam = preview3d.orbit_camera([0, 1.5, 4], 52, yaw, pitch, fov=45)
        sc = preview3d.make_scene([ground], cam, fog_density=0.001, shadow_center=[0, 0, 4], shadow_extent=30)
        sc["meshes"] = meshes
        p = f"{out[:-4]}_{i}.png"
        jobs.append((sc, p, 800, 520))
        paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, [f"yaw {v[0]} pitch {v[1]}" for v in views], out, cols=2)
    return out


if __name__ == "__main__":
    rig, dm = build()
    tot = len(dm.flesh[1]) + sum(len(p.F) for p in dm.pieces)
    print("pieces", len(dm.pieces), "total faces", tot)
    print(preview(rig, dm, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "dragon_mesh.png")))

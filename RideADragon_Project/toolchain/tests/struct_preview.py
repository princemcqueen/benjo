"""Builds a world structure recipe in the simulator from a Luau snippet and
renders it (fast iteration on building designs)."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import build_place  # noqa: E402
import paths  # noqa: E402
import luau_interp as LI  # noqa: E402
import preview3d  # noqa: E402
from rbx_sim import Sim  # noqa: E402
from sim_runner import PROJECT  # noqa: E402

PRE = r'''
local SSS = game:GetService("ServerScriptService")
local World = SSS:WaitForChild("World")
local folder = Instance.new("Folder")
folder.Name = "Preview"
folder.Parent = workspace
local ground = Instance.new("Part")
ground.Anchored = true
ground.Size = Vector3.new(600, 2, 600)
ground.CFrame = CFrame.new(0, -1, 0)
ground.Color = Color3.fromRGB(92, 124, 64)
ground.Material = Enum.Material.Grass
ground.Parent = folder
'''


def run(snippet, views, out, target=(0, 8, 0), size=(900, 560), ground=True):
    sim = Sim(instant_tweens=True)
    name, tree = build_place.load_project(PROJECT)
    build_place.load_into_sim(sim, tree)
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    src = (PRE if ground else PRE.split("local ground")[0]) + snippet
    t = time.time()
    fn = LI.load(src, "struct_preview", env)
    sim.in_ctx(ctx, fn)
    parts = preview3d.part_records(sim)
    print(f"built in {time.time() - t:.1f}s, {len(parts)} parts, errors: {sim.errors[:3]}")
    jobs, paths = [], []
    for i, (yaw, pitch, dist) in enumerate(views):
        cam = preview3d.orbit_camera(list(target), dist, yaw, pitch, fov=50)
        sc = preview3d.make_scene(parts, cam, fog_density=0.0008, shadow_center=list(target), shadow_extent=dist)
        p = f"{out[:-4]}_{i}.png"
        jobs.append((sc, p, size[0], size[1]))
        paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, [f"yaw {v[0]} pitch {v[1]}" for v in views], out, cols=2)
    return sim, out


if __name__ == "__main__":
    snippet = open(sys.argv[1]).read()
    run(snippet, [(30, 20, 60), (210, 25, 60)], paths.OUT + "/struct.png")

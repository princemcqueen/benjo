"""Renders the egg of the Egg Hunter pass card (EggVisual at Scale 2 with sparkles) from a few angles,
the way the shop frames it, for visual QA.

    python3 toolchain/tests/egg_view.py [EggType]       -> out/egg_view_*.png and a sheet
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import preview3d  # noqa: E402
from sim_runner import boot  # noqa: E402
from paths import OUT  # noqa: E402


def main():
    egg = sys.argv[1] if len(sys.argv) > 1 else "CelestialEgg"
    sim = boot()
    sim.add_player("Viewer", 1001)
    sim.run_for(4, 1 / 30)
    ctx = sim.server_ctx
    fn = LI.load(f'''
local EggVisual = require(game:GetService("ReplicatedStorage").Shared.EggVisual)
local m = EggVisual.build("{egg}", {{ Scale = 2, Sparkles = true }})
m.Name = "ViewEgg"
m:PivotTo(CFrame.new(0, 500, 0))
m.Parent = workspace
local cf, size = m:GetBoundingBox()
shared.R = {{ x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z, sx = size.X, sy = size.Y, sz = size.Z }}
''', "egg", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    from sim_runner import lua_table_to_py
    box = lua_table_to_py(ctx.shared.get("R"))
    print("bounding box", box)
    ws = sim.services["Workspace"]
    parts = preview3d.part_records(sim, ws.find_child("ViewEgg"))
    print("parts:", len(parts))
    target = [box["x"], box["y"], box["z"]]
    jobs, paths, labels = [], [], []
    for i, (yaw, pitch) in enumerate([(19, 3), (0, 0), (90, 5), (180, 5), (270, 5), (45, 25)]):
        cam = preview3d.orbit_camera(target, max(box["sx"], box["sy"], box["sz"]) * 3.4, yaw, pitch, fov=30)
        scene = preview3d.make_scene(parts, cam, fog_density=0.0, shadow_center=target, shadow_extent=12)
        path = f"{OUT}/egg_view_{i}.png"
        jobs.append((scene, path, 420, 420))
        paths.append(path)
        labels.append(f"{egg} yaw={yaw} pitch={pitch}")
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{OUT}/egg_view_sheet.png", cols=3)
    print("sheet:", f"{OUT}/egg_view_sheet.png", "errors:", len(sim.errors), sim.errors[:2])


if __name__ == "__main__":
    main()

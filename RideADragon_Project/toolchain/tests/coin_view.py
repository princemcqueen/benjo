"""Renders the three kinds of coins (copper, sky coin, treasure gem) from a few angles for visual QA.

    python3 toolchain/tests/coin_view.py       -> out/coin_view_*.png and a sheet
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import preview3d  # noqa: E402
from sim_runner import boot, run_client_lua  # noqa: E402
from paths import OUT  # noqa: E402


def main():
    sim = boot()
    player = sim.add_player("Viewer", 1001)
    sim.run_for(5, 1 / 30)
    run_client_lua(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local CC = require(LP.PlayerScripts.Controllers.CoinController)
local folder = Instance.new("Folder")
folder.Name = "ViewCoins"
folder.Parent = workspace
for i, kind in { "Copper", "Gold", "Gem" } do
	local m = CC.build(kind)
	CC.place(m, Vector3.new((i - 2) * 9, 500, 0), math.rad(35), kind)
	m.Parent = folder
end
shared.R = {}''')
    ws = sim.services["Workspace"]
    parts = preview3d.part_records(sim, ws.find_child("ViewCoins"))
    print("parts:", len(parts))
    jobs, paths, labels = [], [], []
    views = [("all three, front", [0, 500, 0], 34, 0, 8), ("all three, 3/4", [0, 500, 0], 34, 40, 18),
             ("copper", [-9, 500, 0], 9, 35, 10), ("sky coin", [0, 500, 0], 12, 35, 10), ("gem", [9, 500, 0], 11, 35, 10),
             ("copper, edge", [-9, 500, 0], 9, 125, 10)]
    for i, (label, target, dist, yaw, pitch) in enumerate(views):
        cam = preview3d.orbit_camera(target, dist, yaw, pitch, fov=35)
        scene = preview3d.make_scene(parts, cam, fog_density=0.0, shadow_center=target, shadow_extent=24)
        path = f"{OUT}/coin_view_{i}.png"
        jobs.append((scene, path, 480, 360))
        paths.append(path)
        labels.append(label)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{OUT}/coin_view_sheet.png", cols=3)
    print("sheet:", f"{OUT}/coin_view_sheet.png", "errors:", len(sim.errors), sim.errors[:2])


if __name__ == "__main__":
    main()

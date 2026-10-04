"""Renders the duel scene from the duel camera (intro, the menu shot, a fireball in flight, a strike) for
visual QA.

    python3 toolchain/tests/duel_view.py [trainer]       -> out/duel_view_*.png and a sheet
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import preview3d  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402
from paths import OUT  # noqa: E402

PRE = '''
local LP = game:GetService("Players").LocalPlayer
local DCtl = require(LP.PlayerScripts.Controllers.DuelController)
'''


def cam(sim, player):
    res = run_client_lua(sim, player, PRE + '''
local cf, fov = DCtl.cameraFrame()
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z, lx = cf.LookVector.X, ly = cf.LookVector.Y, lz = cf.LookVector.Z, fov = fov }''')
    r = lua_table_to_py(res.get("R"))
    pos = [r["x"], r["y"], r["z"]]
    return {"pos": pos, "target": [pos[0] + r["lx"] * 40, pos[1] + r["ly"] * 40, pos[2] + r["lz"] * 40], "fov": r["fov"]}


def snap(sim, player, parts_root, label, jobs, paths, labels, i):
    ws = sim.services["Workspace"]
    parts = preview3d.part_records(sim, ws.find_child("DuelStage"))
    c = cam(sim, player)
    scene = preview3d.make_scene(parts, c, fog_density=0.0, shadow_center=[0, 4200, 0], shadow_extent=90)
    path = f"{OUT}/duel_view_{i}.png"
    jobs.append((scene, path, 960, 540))
    paths.append(path)
    labels.append(label)


def main():
    trainer = sys.argv[1] if len(sys.argv) > 1 else "Ranger"
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Viewer", 1001)
    sim.run_for(8, 1 / 30)
    run_client_lua(sim, player, PRE + f'''DCtl.startTrainer("{trainer}") shared.R = {{}}''')
    jobs, paths, labels = [], [], []
    sim.run_for(1.2, 1 / 30)
    snap(sim, player, None, "intro: the camera swoops in", jobs, paths, labels, 0)
    sim.run_for(8.5, 1 / 30)
    snap(sim, player, None, "the menu shot", jobs, paths, labels, 1)
    run_client_lua(sim, player, PRE + '''DCtl.choose("Fire") shared.R = {}''')
    sim.run_for(1.7, 1 / 30)
    snap(sim, player, None, "FIRE in flight", jobs, paths, labels, 2)
    sim.run_for(5.5, 1 / 30)
    run_client_lua(sim, player, PRE + '''DCtl.choose("Strike") shared.R = {}''')
    sim.run_for(2.3, 1 / 30)
    snap(sim, player, None, "STRIKE lunge", jobs, paths, labels, 3)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{OUT}/duel_view_sheet.png", cols=2)
    print("sheet:", f"{OUT}/duel_view_sheet.png", "errors:", len(sim.errors), sim.errors[:2])


if __name__ == "__main__":
    main()

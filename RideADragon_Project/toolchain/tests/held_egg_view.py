"""Renders an R15 block rig carrying an egg (arm pose + egg position QA), plus the
egg in flight towards the nest."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import preview3d  # noqa: E402
import rbx_api  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402
from rbx_types import CFrame  # noqa: E402
from paths import OUT  # noqa: E402


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(4, 1 / 30)
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    # lift the character high above the plaza so nothing else is in the frame
    hrp.props["CFrame"] = CFrame((0, 400, 0))
    sim.run_for(0.3, 1 / 30)
    rig_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "r15rig.lua")).read()
    ctx = sim.server_ctx
    fn = LI.load(rig_src, "rig", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn, char)
    sim.run_for(0.3, 1 / 30)
    types = ["HavenEgg", "RainbowEgg"]
    shots = []
    for t in types:
        fn = LI.load(f'''
local SSS = game:GetService("ServerScriptService")
local PDS = require(SSS.Services.PlayerDataService)
local ES = require(SSS.Services.EggService)
local p = game:GetService("Players"):GetPlayers()[1]
ES.SetHeld(p, nil)
PDS.Set(p, {{ "Eggs" }}, {{ {{ Id = "E_view", Type = "{t}", Found = os.time(), Luck = 3 }} }})
ES.SetHeld(p, "E_view")
shared.R = {{}}
''', "set", sim.script_env(None, ctx))
        sim.in_ctx(ctx, fn)
        sim.run_for(0.4, 1 / 30)
        ws = sim.services["Workspace"]
        parts = preview3d.part_records(sim, char) + preview3d.part_records(sim, ws.find_child("HeldEggs"))
        p = rbx_api.part_cframe(sim, hrp).p
        jobs, outs = [], []
        for i, (yaw, pitch) in enumerate([(180, 8), (145, 10), (215, 10), (90, 6), (270, 6), (0, 6)]):
            cam = preview3d.orbit_camera([p[0] + 0.6, p[1] + 0.5, p[2] - 0.6], 7.5, yaw, pitch, fov=40)
            scene = preview3d.make_scene(parts, cam, fog_density=0.0004, shadow_center=[p[0], p[1], p[2]], shadow_extent=14)
            path = f"{OUT}/heldegg_{t}_{i}.png"
            jobs.append((scene, path, 420, 420))
            outs.append((path, f"{t} yaw={yaw}"))
        preview3d.render_batch(jobs)
        shots += outs
    preview3d.contact_sheet([o[0] for o in shots], [o[1] for o in shots], OUT + "/heldegg_sheet.png", cols=6)
    print("sheet:", OUT + "/heldegg_sheet.png")
    res = run_client_lua(sim, player, '''
local char = game:GetService("Players").LocalPlayer.Character
local s = char:FindFirstChild("RightShoulder", true)
local e = char:FindFirstChild("RightElbow", true)
shared.R = { sh = s and s.C0.Position.Y or -1, el = e and e.C0.Position.Y or -1 }
''')
    print(lua_table_to_py(res.get("R")), "errors", len(sim.errors), sim.errors[:3])


if __name__ == "__main__":
    main()

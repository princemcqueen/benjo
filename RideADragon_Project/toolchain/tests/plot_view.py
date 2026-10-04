"""Renders a sanctuary plot (overview, a perch, the nest) from the simulator for visual QA.

    python3 toolchain/tests/plot_view.py [prefix]       -> <prefix>_{0,1,2}.png and a sheet
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
import preview3d  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402
from paths import OUT  # noqa: E402


def srv(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    head = '''
local SSS = game:GetService("ServerScriptService")
local PDS = require(SSS.Services.PlayerDataService)
local DS = require(SSS.Services.DragonService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, domain, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "" }}
''')
    return lua_table_to_py(res.get("RQ"))


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else f"{OUT}/plot_view"
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Player1", 1001)
    sim.run_for(6, 1 / 30)
    ids = srv(sim, '''
for _, sp in { "FrostDragon", "InfernoDragon", "ForestWyvern" } do DS.Add(p, sp, "None", "Test", true) end
PDS.Set(p, { "Nests", "Unlocked" }, 4)
local ids = {}
for id in d.Dragons do table.insert(ids, id) end
table.sort(ids)
shared.R = ids
''')
    for i, uid in enumerate(ids[1:4]):
        req(sim, player, "Dragon", "Place", f'{{ Id = "{uid}", Slot = {i + 1} }}')
    sim.run_for(4, 1 / 30)
    plot = srv(sim, 'shared.R = { id = p:GetAttribute("PlotId") }')["id"]
    frame = srv(sim, f'''
local WC = require(game:GetService("ReplicatedStorage").Configs.WorldConfig)
local cf = WC.plotFrame({int(plot)})
local nest = WC.perchWorld({int(plot)}, 1)
shared.R = {{ cf.Position.X, cf.Position.Y, cf.Position.Z, math.deg(WC.Plots[{int(plot)}].Facing), nest.Position.X, nest.Position.Y, nest.Position.Z }}
''')
    parts = preview3d.part_records(sim)
    terrain = sim.haven.preview_terrain() if hasattr(sim, "haven") else None
    import math
    yaw0 = frame[3]
    # plot-local nest centre in world space
    ang = math.radians(yaw0)
    # plot frame: CFrame(pos) * Angles(0, facing, 0); local (0,0,-6)
    def to_world(lx, ly, lz):
        c, s = math.cos(ang), math.sin(ang)
        return [frame[0] + c * lx + s * lz, frame[1] + ly, frame[2] - s * lx + c * lz]
    nest_w = to_world(0, 3, -6)
    views = [
        ("plot overview", [frame[0], frame[1] + 4, frame[2]], 120, yaw0 + 180, 38),
        ("perch", [frame[4], frame[5] + 3, frame[6]], 34, yaw0 + 150, 24),
        ("nest", nest_w, 40, yaw0 + 200, 28),
    ]
    jobs, paths, labels = [], [], []
    for i, (label, target, dist, yaw, pitch) in enumerate(views):
        cam = preview3d.orbit_camera(target, dist, yaw, pitch, fov=50)
        sc = preview3d.make_scene(parts, cam, terrain=terrain, fog_density=0.0004, shadow_center=target, shadow_extent=max(60, dist))
        path = f"{prefix}_{i}.png"
        jobs.append((sc, path, 960, 600))
        paths.append(path)
        labels.append(label)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{prefix}_sheet.png", cols=2)
    print("rendered", paths, "errors:", len(sim.errors), sim.errors[:2])


if __name__ == "__main__":
    main()

"""Renders an egg nest with its guardian (what EggController builds near a guarded egg) from a few angles, for
visual QA: the nest of twigs and stones, the egg, the guardian dragon (scaled by the egg's power).

    python3 toolchain/tests/guardian_view.py [EggType] [luck]   -> out/guardian_view_*.png and a sheet
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import preview3d  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, lua_table_to_py, run_client_lua  # noqa: E402
from paths import OUT  # noqa: E402


def srv(sim, src):
    ctx = sim.server_ctx
    fn = LI.load('''
local SSS = game:GetService("ServerScriptService")
local ES = require(SSS.Services.EggService)
local p = game:GetService("Players"):GetPlayers()[1]
''' + src, "gv", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def main():
    egg_type = sys.argv[1] if len(sys.argv) > 1 else "FrostEgg"
    luck = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Viewer", 1001)
    sim.run_for(8, 1 / 30)
    # a guarded egg of the wanted kind (the personal egg list is rewritten: one egg, close to the player)
    info = srv(sim, f'''
local hrp = p.Character.HumanoidRootPart
local EC = require(game:GetService("ReplicatedStorage").Configs.EggConfig)
local active = ES.GetActive(p)
local key, egg
for k, e in active do key, egg = k, e break end
egg.Type = "{egg_type}"
egg.Luck = {luck}
egg.Guard = EC.guardian("{egg_type}", {luck}, 3)
shared.R = {{ key = key, x = egg.Position.X, y = egg.Position.Y, z = egg.Position.Z, species = egg.Guard.Species, power = egg.Guard.Power, mut = egg.Guard.Mutation }}
''')
    print("egg:", info)
    # the client rebuilds it from a resync
    run_client_lua(sim, player, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Egg", "Sync", {})
local EGC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.EggController)
for key in EGC.list() do end
shared.R = { ok = r.ok }''')
    srv(sim, f'''
local hrp = p.Character.HumanoidRootPart
hrp.CFrame = CFrame.new({info["x"] + 30}, {info["y"] + 4}, {info["z"]})
shared.R = {{}}''')
    sim.run_for(1.0, 1 / 30)
    # re-create the egg on the client with the new data (a resync signal does the same)
    run_client_lua(sim, player, f'''
local EGC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.EggController)
shared.R = {{}}''')
    ctx = sim.server_ctx
    fn = LI.load(f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local ES = require(game:GetService("ServerScriptService").Services.EggService)
local p = game:GetService("Players"):GetPlayers()[1]
local list = {{}}
for _, e in ES.GetActive(p) do
	table.insert(list, {{ Key = e.Key, Type = e.Type, Position = e.Position, Area = e.Area, Luck = e.Luck, Guard = e.Guard }})
end
Net.signal(p, "Eggs", {{ List = list }})
shared.R = {{}}''', "resync", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    sim.run_for(5.0, 1 / 30)
    ws = sim.services["Workspace"]
    my = ws.find_child("MyEggs")
    key = info["key"]
    names = [c.props.get("Name") for c in my.children]
    print("models near the egg:", [n for n in names if n.endswith(key)])
    # a ground plate so the picture has a floor
    ctx = sim.server_ctx
    fn = LI.load(f'''
local g = Instance.new("Part")
g.Name = "ViewGround"
g.Anchored = true
g.Size = Vector3.new(160, 1, 160)
g.Position = Vector3.new({info["x"]}, {info["y"] - 3.1}, {info["z"]})
g.Color = Color3.fromRGB(104, 168, 84)
g.Material = Enum.Material.Grass
g.Parent = workspace
shared.R = {{}}''', "ground", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    parts = []
    for c in my.children:
        if str(c.props.get("Name", "")).endswith(key):
            parts += preview3d.part_records(sim, c)
    parts += preview3d.part_records(sim, ws.find_child("ViewGround"))
    print("parts:", len(parts))
    target = [info["x"], info["y"] + 3, info["z"]]
    jobs, paths, labels = [], [], []
    for i, (yaw, pitch, dist) in enumerate([(20, 12, 46), (90, 10, 46), (200, 14, 46), (300, 8, 46), (60, 38, 60), (0, 3, 32)]):
        cam = preview3d.orbit_camera(target, dist, yaw, pitch, fov=38)
        scene = preview3d.make_scene(parts, cam, fog_density=0.0, shadow_center=target, shadow_extent=40)
        path = f"{OUT}/guardian_view_{i}.png"
        jobs.append((scene, path, 460, 380))
        paths.append(path)
        labels.append(f"{egg_type} x{luck}: {info['species']} yaw={yaw} pitch={pitch}")
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{OUT}/guardian_view_sheet.png", cols=3)
    print("sheet:", f"{OUT}/guardian_view_sheet.png", "errors:", len(sim.errors), [str(e)[:200] for e in sim.errors[:3]])


if __name__ == "__main__":
    main()

"""Renders key frames of the hatching cinematic (3D, from the real cinematic camera)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worldgen"))
import luau_interp as LI  # noqa: E402
import preview3d  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402
from paths import OUT  # noqa: E402

EGG = os.environ.get("HATCH_EGG", "FrostEgg")


def cli(sim, player, src):
    head = '''
local LP = game:GetService("Players").LocalPlayer
local HC = require(LP.PlayerScripts.Controllers.HatchController)
'''
    res = run_client_lua(sim, player, head + src)
    return lua_table_to_py(res.get("R"))


STATE = '''
local cam = workspace.CurrentCamera
local cf = cam.CFrame
local look = cf.LookVector
local out = { phase = HC.Phase, pos = { cf.Position.X, cf.Position.Y, cf.Position.Z },
	look = { look.X, look.Y, look.Z }, fov = cam.FieldOfView }
local stage = HC.Stage
if stage then
	local cracks = 0
	for _, d in stage:GetDescendants() do
		if d:IsA("BasePart") and string.sub(d.Name, 1, 5) == "Crack" then cracks += 1 end
	end
	out.cracks = cracks
end
local dg = HC.Dragon
if dg then
	out.root = { dg.Root.Position.X, dg.Root.Position.Y, dg.Root.Position.Z }
	out.roaring = dg.Anim:IsPlaying("Roar")
end
out.card = LP.PlayerGui:FindFirstChild("HatchResult", true) ~= nil
if HC.Framing then out.dist = HC.Framing.Dist out.clear = HC.Framing.Clear end
shared.R = out
'''


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(5, 1 / 30)
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    nest = cli(sim, player, '''
local SC = require(LP.PlayerScripts.Controllers.SanctuaryController)
local cf = SC.nestCFrame()
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z }''')
    hrp.props["CFrame"] = CFrame((nest["x"] + 6, nest["y"] + 3, nest["z"] + 6))
    sim.run_for(1.0, 1 / 30)
    ctx = sim.server_ctx
    fn = LI.load(f'''
local SSS = game:GetService("ServerScriptService")
local PDS = require(SSS.Services.PlayerDataService)
local p = game:GetService("Players"):GetPlayers()[1]
PDS.Set(p, {{ "Incubator", "Slots", "1" }}, {{ Type = "{EGG}", Start = os.time() - 100, Ready = os.time() - 1, Id = "E_v", Luck = 1 }})
shared.R = {{}}''', "put", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    sim.run_for(0.6, 1 / 30)
    cli(sim, player, '''task.spawn(HC.hatch, 1) shared.R = {}''')

    want = ["charge", "walk_a", "walk_b", "roar", "card"]
    shots = {}
    roar_n = 0
    start_root = None
    for _ in range(900):
        sim.run_for(0.1, 1 / 30)
        s = cli(sim, player, STATE)
        ph = s["phase"]
        if ph == "Charge" and "charge" not in shots and s.get("cracks", 0) >= 9:
            shots["charge"] = s
        if ph == "Walk" and s.get("root"):
            if start_root is None:
                start_root = s["root"]
            moved = sum((a - b) ** 2 for a, b in zip(s["root"], start_root)) ** 0.5
            if moved > 4 and "walk_a" not in shots:
                shots["walk_a"] = s
            if moved > 10 and "walk_b" not in shots:
                shots["walk_b"] = s
        if ph == "Roar" and s.get("roaring"):
            roar_n += 1
            if roar_n == 6 and "roar" not in shots:
                shots["roar"] = s
        if ph == "Card" and s["card"] and "card" not in shots:
            shots["card"] = s
        # render immediately when a new shot was taken (the scene is live only now)
        for k in list(shots):
            if "done" not in shots[k]:
                shots[k]["done"] = True
                render_shot(sim, k, shots[k])
        if len(shots) == len(want):
            break
    print("captured:", sorted(shots))
    sheet = [f"{OUT}/hatch_{k}.png" for k in want if k in shots]
    if sheet:
        preview3d.contact_sheet(sheet, [k for k in want if k in shots], f"{OUT}/hatch_sheet.png", cols=3)
        print("sheet:", f"{OUT}/hatch_sheet.png")


def render_shot(sim, name, s):
    terrain = sim.haven.preview_terrain()
    parts = preview3d.part_records(sim)
    pos = s["pos"]
    look = s["look"]
    target = [pos[0] + look[0] * 25, pos[1] + look[1] * 25, pos[2] + look[2] * 25]
    cam = {"pos": pos, "target": target, "fov": s["fov"]}
    scene = preview3d.make_scene(parts, cam, terrain=terrain, fog_density=0.0004, shadow_center=[target[0], target[1], target[2]], shadow_extent=120)
    path = f"{OUT}/hatch_{name}.png"
    preview3d.render_batch([(scene, path, 900, 520)])
    print("rendered", name, s["phase"], "cracks", s.get("cracks"), "dist", s.get("dist"), "clear", s.get("clear"))


if __name__ == "__main__":
    main()

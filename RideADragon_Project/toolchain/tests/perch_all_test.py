"""Every dragon may rest on a perch - the last one too. With nobody out, RIDE (HUD button / R key /
Mount.Ride) brings the strongest resting dragon down and rides it."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402

FAIL = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        FAIL.append(label)


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


def cli(sim, player, src):
    res = run_client_lua(sim, player, src)
    return lua_table_to_py(res.get("R"))


def req(sim, player, domain, action, payload="{}"):
    return cli(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.R = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", data = r.data }}
''')


STATE = '''
local d = nil
local LP = game:GetService("Players").LocalPlayer
local DC = LP.PlayerScripts.Controllers
local data = require(DC.DataController).all()
local free, placed = 0, 0
for _, r in data.Dragons do
	if r.PlacedNestId == "" then free += 1 else placed += 1 end
end
local hud = LP.PlayerGui:FindFirstChild("GameHUD")
local texts = {}
if hud then
	for _, g in hud:GetDescendants() do
		if g:IsA("TextLabel") and g.Text ~= "" then table.insert(texts, g.Text) end
	end
end
shared.R = { equipped = data.EquippedDragon, free = free, placed = placed, riding = LP:GetAttribute("Riding") == true, hud = table.concat(texts, "|") }
'''


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Player1", 1001)
    sim.run_for(6, 1 / 30)
    uid = srv(sim, 'shared.R = { id = d.EquippedDragon }')["id"]

    # 1) the only dragon rests on a perch
    r = req(sim, player, "Dragon", "Place", f'{{ Id = "{uid}" }}')
    sim.run_for(2, 1 / 30)
    s = cli(sim, player, STATE)
    check(r["ok"] and s["placed"] == 1 and s["free"] == 0 and s["equipped"] == "", "the only dragon can be placed on a perch (nothing equipped now)")
    check("No dragon out" in s["hud"], "HUD says no dragon is out")
    n = srv(sim, '''
local dr = workspace:FindFirstChild("Dragons")
local mine = 0
if dr then for _, m in dr:GetChildren() do if string.find(m.Name, tostring(p.UserId)) then mine += 1 end end end
shared.R = { companions = mine }
''')
    check(n["companions"] == 0, "no companion dragon follows you while everything rests")

    # 2) RIDE with nobody out: the strongest comes down and is ridden
    cli(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
require(LP.PlayerScripts.Controllers.DragonController).toggleRide()
task.wait(1.2)
shared.R = {}
''')
    sim.run_for(1.5, 1 / 30)
    s = cli(sim, player, STATE)
    check(s["riding"] and s["equipped"] == uid and s["free"] == 1 and s["placed"] == 0, "RIDE brought the resting dragon down and mounted it")

    # 3) two dragons, both rest, RIDE brings the strongest
    srv(sim, '''
local rec = DS.Add(p, "InfernoDragon", "None", "Test", true)
shared.R = { id = rec.UniqueId }
''')
    cli(sim, player, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
Net.request("Mount", "Dismount")
task.wait(0.5)
shared.R = {}
''')
    sim.run_for(1, 1 / 30)
    ids = srv(sim, '''
local ids = {}
for id in d.Dragons do table.insert(ids, id) end
table.sort(ids)
shared.R = ids
''')
    placed = [req(sim, player, "Dragon", "Place", f'{{ Id = "{i}" }}') for i in ids]
    sim.run_for(1, 1 / 30)
    s = cli(sim, player, STATE)
    check(all(x["ok"] for x in placed) and s["placed"] == 2 and s["free"] == 0 and s["equipped"] == "", "two dragons, both rest on perches")
    r = req(sim, player, "Mount", "Ride")
    sim.run_for(1, 1 / 30)
    best = srv(sim, '''
local DragonStats = require(game:GetService("ReplicatedStorage").Shared.DragonStats)
local best, score = nil, -1
for id, r in d.Dragons do
	local s = DragonStats.score(r)
	if s > score then best, score = id, s end
end
shared.R = { best = best, equipped = d.EquippedDragon, placedOfEquipped = d.Dragons[d.EquippedDragon] and d.Dragons[d.EquippedDragon].PlacedNestId or "?" }
''')
    check(r["ok"] and best["equipped"] == best["best"] and best["placedOfEquipped"] == "", "Mount.Ride with nobody out equips the strongest dragon and takes it off its perch")

    # 4) placing the ridden dragon is refused (dismount first), a resting one can be released
    cli(sim, player, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
Net.request("Mount", "Dismount")
task.wait(0.5)
shared.R = {}
''')
    sim.run_for(1, 1 / 30)
    other = [i for i in ids if i != best["equipped"]][0]
    r = req(sim, player, "Dragon", "Release", f'{{ Id = "{other}" }}')
    s = cli(sim, player, STATE)
    check(r["ok"] and s["placed"] == 0 and s["free"] == 1, "a resting dragon can be released")
    r = req(sim, player, "Dragon", "Release", f'{{ Id = "{best["equipped"]}" }}')
    check(not r["ok"] and r["err"] == "LAST_DRAGON", f"the very last dragon cannot be released ({r['err']})")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

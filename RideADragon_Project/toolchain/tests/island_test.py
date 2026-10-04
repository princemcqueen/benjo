"""The sky islands (World/SkyIslands, IslandService) and eggs that go all over the land AND the islands:
the four islands exist with their plates tagged as egg ground, their egg areas are registered (rare
areas of the right region), roaming eggs land on the land and on every island (inside the plate, on its
surface), a player's own eggs include island areas, Travel puts you on an island, the Teleport window
lists them, and a wild egg keeps away from the previous one."""
import math
import os
import sys
import time

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
local RS = game:GetService("ReplicatedStorage")
local ES = require(SSS.Services.EggService)
local IS = require(SSS.Services.IslandService)
local WC = require(RS.Configs.WorldConfig)
local EC = require(RS.Configs.EggConfig)
local p = game:GetService("Players"):GetPlayers()[1]
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Alice", 7001)
    sim.run_for(16, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ the islands
    r = srv(sim, '''
local folder = workspace.World:FindFirstChild("SkyIslands")
local out = { ready = IS.Ready, n = folder and #folder:GetChildren() or 0, ids = {}, plates = 0, pads = 0, signs = 0, persistent = 0, parts = 0 }
if folder then
	for _, m in folder:GetChildren() do
		table.insert(out.ids, m.Name)
		local surface = m:FindFirstChild("Surface")
		if surface and surface:GetAttribute("EggSurface") == true then out.plates += 1 end
		if m:FindFirstChild("LandingPad", true) then out.pads += 1 end
		if m:FindFirstChild("NameGui", true) then out.signs += 1 end
		for _, d in m:GetDescendants() do if d:IsA("BasePart") then out.parts += 1 end end
	end
end
local areas = {}
local islandAreas = 0
for _, a in ES.Areas() do
	if a.Island then
		islandAreas += 1
		areas[a.Name] = { region = a.Region, rare = EC.RareAreas[a.Name] == true, radius = a.Radius, label = a.Label }
	end
end
out.islandAreas = islandAreas
out.areas = areas
out.fixed = #ES.Areas() - islandAreas
out.travel = {}
for _, isle in WC.SkyIslands do
	local cf = WC.islandArrival(isle)
	out.travel[isle.Id] = { dx = cf.Position.X - isle.Center.X, dy = cf.Position.Y - isle.Center.Y, dz = cf.Position.Z - isle.Center.Z }
end
shared.R = out''')
    print("islands", {k: v for k, v in r.items() if k not in ("areas", "travel")})
    check(r["ready"] and r["n"] == 4, "four sky islands are built")
    check(r["plates"] == 4 and r["pads"] == 4 and r["signs"] == 4, "each has an egg-ground plate, a landing pad and a name sign")
    check(r["parts"] > 600, f"{r['parts']:.0f} parts in all (themed decoration)")
    check(r["islandAreas"] == 4 and r["fixed"] >= 24, f"4 island egg areas next to the {r['fixed']:.0f} fixed areas")
    regions = {k: v["region"] for k, v in r["areas"].items()}
    check(regions == {"CrystalIsle": "Skyreach", "BloomIsle": "Haven", "EmberIsle": "EmberCaldera", "FrostIsle": "Frostpeak"}, f"each island grows the eggs of its region ({regions})")
    check(all(v["rare"] for v in r["areas"].values()), "every island is a rare area (luck rolls twice)")

    # ------------------------------------------------------------------ roaming eggs: land and every island
    r = srv(sim, '''
local total, onIsland, bad, onLand = 140, 0, 0, 0
local counts = {}
local cells = {}
local minToArea = {}
local fixed = {}
for _, a in ES.Areas() do if not a.Island then table.insert(fixed, a.Position) end end
for i = 1, total do
	local spot, area = ES.RandomSpot(nil)
	if spot and area then
		if area.Island then
			onIsland += 1
			counts[area.Name] = (counts[area.Name] or 0) + 1
			local def = WC.SkyIslandById[area.Name]
			local dx, dz = spot.X - def.Center.X, spot.Z - def.Center.Z
			local inside = math.sqrt(dx * dx + dz * dz) <= def.Radius * EC.Spawning.IslandInset + 0.5
			local onPlate = math.abs(spot.Y - (def.Center.Y + 2.6)) < 1.2
			if not inside or not onPlate then bad += 1 end
		else
			onLand += 1
			cells[math.floor(spot.X / 200) .. ":" .. math.floor(spot.Z / 200)] = true
			local best = math.huge
			for _, f in fixed do
				local d = math.sqrt((f.X - spot.X) ^ 2 + (f.Z - spot.Z) ^ 2)
				if d < best then best = d end
			end
			table.insert(minToArea, best)
		end
	end
end
local far = 0
for _, d in minToArea do if d > 90 then far += 1 end end
local nCells = 0
for _ in cells do nCells += 1 end
shared.R = { total = total, onIsland = onIsland, onLand = onLand, bad = bad, counts = counts, cells = nCells, far = far }''')
    print("roaming", r)
    isl = sum(r["counts"].values()) if r["counts"] else 0
    check(r["onIsland"] + r["onLand"] >= 120, f"random spots found: {r['onLand']:.0f} on the land, {r['onIsland']:.0f} on islands")
    check(r["onIsland"] >= 15, f"about a third of the roaming eggs go to the islands ({r['onIsland']:.0f} of {r['total']:.0f})")
    check(len(r["counts"]) == 4, f"every island gets some ({ {k: int(v) for k, v in r['counts'].items()} })")
    check(r["bad"] == 0, "island eggs lie inside the plate (80% of its radius), on its surface")
    check(r["cells"] >= 8, f"land eggs spread over {r['cells']:.0f} different 200-stud squares of the map")
    check(r["far"] >= r["onLand"] * 0.4, f"land eggs are not tied to the fixed areas ({r['far']:.0f} of {r['onLand']:.0f} are more than 90 studs from any)")

    # ------------------------------------------------------------------ the player's own eggs
    r = srv(sim, '''
local act = ES.GetActive(p)
local n, onIsland, regions = 0, 0, {}
for _, e in act do
	n += 1
	local def = WC.SkyIslandById[e.Area]
	if def then onIsland += 1 regions[e.Area] = (regions[e.Area] or 0) + 1 end
end
shared.R = { n = n, onIsland = onIsland, max = EC.Spawning.MaxActive, regions = regions }''')
    print("own eggs", r)
    check(r["n"] >= 10, f"{r['n']:.0f} of the player's own eggs are out in the world (max {r['max']:.0f})")
    check(r["onIsland"] >= 1, f"some of them are on the islands ({r['onIsland']:.0f})")

    # a wild egg keeps away from the previous one
    r = srv(sim, '''
local first = select(1, ES.RandomSpot(nil))
local tooClose = 0
for i = 1, 25 do
	local spot, area = ES.RandomSpot(first)
	if spot and not area.Island then
		local d = math.sqrt((spot.X - first.X) ^ 2 + (spot.Z - first.Z) ^ 2)
		if d < EC.Spawning.RoamMinSeparation then tooClose += 1 end
	end
end
shared.R = { tooClose = tooClose }''')
    check(r["tooClose"] == 0, "a roaming spot keeps its distance from the previous wild egg")

    # ------------------------------------------------------------------ travel + the teleport window
    for isle in ("CrystalIsle", "FrostIsle"):
        res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Travel", "To", {{ Place = "{isle}" }})
shared.R = {{ ok = r.ok, err = r.err or "" }}''', max_steps=1500)
        t = lua_table_to_py(res.get("R"))
        sim.run_for(3.5, 1 / 30)
        pos = srv(sim, f'''
local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
local def = WC.SkyIslandById["{isle}"]
local a = hrp and hrp.Position
shared.R = {{ ok = a ~= nil, dx = a and (a.X - def.Center.X) or 0, dy = a and (a.Y - def.Center.Y) or 0, dz = a and (a.Z - def.Center.Z) or 0, r = def.Radius }}''')
        near = math.hypot(pos["dx"], pos["dz"] - pos["r"] * 0.55) < 12 and -2 < pos["dy"] < 14
        check(t["ok"] and pos["ok"] and near, f"Travel to {isle} puts you on its landing pad (offset {pos['dx']:.0f}, {pos['dy']:.0f}, {pos['dz']:.0f})")
        sim.run_for(2.5, 1 / 30)
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
UIC.Open("Teleport")
task.wait(0.5)
local w = UIC.Windows.Teleport
shared.R = { crystal = w.Buttons.CrystalIsle ~= nil, bloom = w.Buttons.BloomIsle ~= nil, ember = w.Buttons.EmberIsle ~= nil, frost = w.Buttons.FrostIsle ~= nil, race = w.Buttons.RaceIsland ~= nil }''', max_steps=1500)
    w = lua_table_to_py(res.get("R"))
    check(w["crystal"] and w["bloom"] and w["ember"] and w["frost"] and w["race"], "the Teleport window has a card for every island")

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    check(len(sim.errors) == 0, "no script errors")
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")
    print("ALL OK" if not FAIL else "SOME FAILED")


if __name__ == "__main__":
    main()

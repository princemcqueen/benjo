"""Coins on the map: the layout (trails, sky arcs, treasure piles), pickups validated by the server,
cash from the income, the chain, respawn, every player's own coins, and the client (coins built near
the player, taking one, the HUD chain pill, a refused coin coming back)."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
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
local PDS = require(SSS.Services.PlayerDataService)
local CS = require(SSS.Services.CoinService)
local ECO = require(SSS.Services.EconomyService)
local CoinConfig = require(RS.Configs.CoinConfig)
local CoinLayout = require(RS.Shared.CoinLayout)
local WorldConfig = require(RS.Configs.WorldConfig)
local players = game:GetService("Players"):GetPlayers()
local p = players[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src, steps=600):
    head = '''
local LP = game:GetService("Players").LocalPlayer
local CC = require(LP.PlayerScripts.Controllers.CoinController)
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
'''
    res = run_client_lua(sim, player, head + src, max_steps=steps)
    return lua_table_to_py(res.get("R"))


def collect(sim, player, ids):
    r = cli(sim, player, '''
local res = Net.request("Coins", "Collect", { Ids = { %s } })
local took = {}
if res.data then for _, id in res.data.Collected or {} do table.insert(took, id) end end
shared.R = { ok = res.ok, err = res.err or "", n = #took, gained = res.data and res.data.Gained or 0, chain = res.data and res.data.Chain or 0,
	mult = res.data and res.data.Mult or 0, total = res.data and res.data.Total or 0, first = took[1] or 0, last = took[#took] or 0 }''' % ", ".join(str(i) for i in ids))
    return r


def coin_pos(sim, i):
    r = srv(sim, 'local c = CS.List()[%d] shared.R = { x = c.Position.X, y = c.Position.Y, z = c.Position.Z, kind = c.Kind }' % i)
    return r


def stand_at(hrp, x, y, z):
    hrp.props["CFrame"] = CFrame((x, y, z))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 4001)
    sim.run_for(10, 1 / 30)
    ws = sim.services["Workspace"]
    hrp = alice.props.get("Character").find_child("HumanoidRootPart")
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ numbers
    s = srv(sim, '''
shared.R = {
	c0 = CoinConfig.value("Copper", 0), g0 = CoinConfig.value("Gold", 0), j0 = CoinConfig.value("Gem", 0),
	c1k = CoinConfig.value("Copper", 1000), g1k = CoinConfig.value("Gold", 1000), j1k = CoinConfig.value("Gem", 1000),
	m1 = CoinConfig.multiplier(1), m2 = CoinConfig.multiplier(2), m5 = CoinConfig.multiplier(5), m9 = CoinConfig.multiplier(9), m40 = CoinConfig.multiplier(40),
}''')
    check(s["c0"] == 6 and s["g0"] == 20 and s["j0"] == 150, f"new players: coin ${s['c0']:.0f} / sky coin ${s['g0']:.0f} / treasure ${s['j0']:.0f}")
    check(s["c1k"] == 600 and s["g1k"] == 2000 and s["j1k"] == 30000, f"at $1000/s: coin ${s['c1k']:.0f} / sky coin ${s['g1k']:.0f} / treasure ${s['j1k']:.0f}")
    check(s["m1"] == 1 and s["m2"] == 1.25 and s["m5"] == 2 and s["m9"] == 3 and s["m40"] == 3, "chain: x1, x1.25, x2 ... capped at x3")

    # ------------------------------------------------------------------ the layout
    n = srv(sim, '''shared.R = { n = CS.Build() }''')["n"]
    st = srv(sim, '''
local list = CS.List()
local kinds = { Copper = 0, Gold = 0, Gem = 0 }
local ground = RaycastParams.new()
ground.FilterType = Enum.RaycastFilterType.Include
ground.FilterDescendantsInstances = { workspace.Terrain }
local L = CoinConfig.Layout
local hub = WorldConfig.Hub.Center
local liftBad, water, hubClose, skyLow, skyHigh = 0, 0, 0, 1e9, 0
local steps, nearSteps = 0, 0
local prev
for i, c in list do
	kinds[c.Kind] += 1
	local hit = workspace:Raycast(Vector3.new(c.Position.X, 900, c.Position.Z), Vector3.new(0, -1800, 0), ground)
	local gy = hit and hit.Position.Y or 0
	if c.Kind == "Copper" then
		if math.abs(c.Position.Y - gy - L.Lift) > 1.2 then liftBad += 1 end
		if hit and hit.Material == Enum.Material.Water then water += 1 end
		if (Vector3.new(c.Position.X, 0, c.Position.Z) - Vector3.new(hub.X, 0, hub.Z)).Magnitude < L.FromHub - 1 then hubClose += 1 end
		if prev then
			local dist = (c.Position - prev).Magnitude
			steps += 1
			if dist <= L.Spacing * 1.8 then nearSteps += 1 end
		end
		prev = c.Position
	elseif c.Kind == "Gold" then
		skyLow = math.min(skyLow, c.Position.Y - gy)
		skyHigh = math.max(skyHigh, c.Position.Y - gy)
		prev = nil
	else
		prev = nil
	end
end
local packed = CoinLayout.pack(list)
local back = CoinLayout.unpack(packed)
local same = #back == #list
for i, c in list do
	if back[i].Kind ~= c.Kind or (back[i].Position - c.Position).Magnitude > 1.8 then same = false end
end
shared.R = { n = #list, copper = kinds.Copper, gold = kinds.Gold, gem = kinds.Gem, liftBad = liftBad, water = water, hubClose = hubClose,
	skyLow = skyLow, skyHigh = skyHigh, steps = steps, nearSteps = nearSteps, same = same, str = #packed.K }''')
    print("layout", st)
    check(st["n"] == n and st["n"] >= 200, f"{st['n']:.0f} coins on the map")
    check(st["copper"] >= 120 and st["gold"] >= 50 and st["gem"] >= 10, f"{st['copper']:.0f} coins, {st['gold']:.0f} sky coins, {st['gem']:.0f} treasure piles")
    check(st["liftBad"] == 0, "every road coin floats the same height above the ground")
    check(st["water"] == 0 and st["hubClose"] == 0, "no coin in the water, none in the village centre")
    check(st["skyLow"] >= 50 and st["skyHigh"] <= 140, f"sky coins fly {st['skyLow']:.0f}..{st['skyHigh']:.0f} studs above the ground")
    check(st["steps"] > 0 and st["nearSteps"] / st["steps"] >= 0.85, f"the trails are continuous ({st['nearSteps']:.0f} of {st['steps']:.0f} gaps are one coin apart)")
    check(st["same"] and st["str"] == st["n"], "the packed list unpacks to the same coins")

    # ------------------------------------------------------------------ the layout reaches the client
    sim.run_for(4, 1 / 30)
    c = cli(sim, alice, '''shared.R = { n = CC.count(), vis = CC.visibleCount() }''')
    check(c["n"] == st["n"], f"the client has the whole list ({c['n']:.0f} coins)")

    # ------------------------------------------------------------------ picking up (server rules)
    # (the client must not take the coins by itself while the test asks the server directly)
    cli(sim, alice, '''CC.setTouch(false) shared.R = {}''')
    # first copper coin: on a road far from the village
    p1 = coin_pos(sim, 1)
    print("coin 1", p1)
    stand_at(hrp, p1["x"], p1["y"], p1["z"])
    sim.run_for(0.2, 1 / 30)
    cash0 = srv(sim, 'shared.R = { cash = d.Cash, coins = d.Stats.Coins or 0, income = ECO.IncomeRate(p) }')
    r = collect(sim, alice, [1])
    cash1 = srv(sim, 'shared.R = { cash = d.Cash, coins = d.Stats.Coins or 0 }')
    print("collect 1", r, cash0, cash1)
    check(r["ok"] and r["n"] == 1 and r["first"] == 1, "a coin right next to the player is taken")
    check(r["gained"] == max(6, round(cash0["income"] * 0.6)), f"...and pays its value (${r['gained']:.0f})")
    check(cash1["cash"] - cash0["cash"] >= r["gained"] and cash1["coins"] == cash0["coins"] + 1, "the cash and the coin counter went up")
    r = collect(sim, alice, [1])
    check(r["ok"] and r["n"] == 0, "the same coin cannot be taken twice")
    far = srv(sim, '''
local list = CS.List()
local best, bestD = 0, 0
for i, c in list do
	local dd = (c.Position - list[1].Position).Magnitude
	if dd > bestD then best, bestD = i, dd end
end
shared.R = { id = best, dist = bestD }''')
    r = collect(sim, alice, [int(far["id"])])
    check(r["ok"] and r["n"] == 0, f"a coin {far['dist']:.0f} studs away is refused")
    r = collect(sim, alice, [999999, -3, 0])
    check(not r["ok"] or r["n"] == 0, "invalid ids are ignored")
    bad = cli(sim, alice, '''
local res = Net.request("Coins", "Collect", { Ids = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 } })
shared.R = { ok = res.ok, err = res.err or "" }''')
    check(not bad["ok"], f"a batch that is too big is refused ({bad['err']})")

    # ------------------------------------------------------------------ chain
    sim.run_for(4, 1 / 30)  # the chain of the first coin is over
    cash0 = srv(sim, 'shared.R = { cash = d.Cash, income = ECO.IncomeRate(p) }')
    p4 = coin_pos(sim, 4)
    stand_at(hrp, p4["x"], p4["y"], p4["z"])
    sim.run_for(0.2, 1 / 30)
    # five coins of the trail within reach (radius 9 + slack 42) of where she stands
    group = [i for i in (2, 3, 4, 5, 6) if ((coin_pos(sim, i)["x"] - p4["x"]) ** 2 + (coin_pos(sim, i)["z"] - p4["z"]) ** 2) ** 0.5 <= 50]
    print("group", group)
    r = collect(sim, alice, group)
    print("chain", r)
    base = max(6, round(cash0["income"] * 0.6))
    k = len(group)
    expect = sum(int(base * min(3, 1 + 0.25 * i) + 0.5) for i in range(k))
    check(k >= 4 and r["n"] == k and r["chain"] == k, f"{k} coins in one go make a chain of {r['chain']:.0f}")
    check(abs(r["mult"] - min(3, 1 + 0.25 * (k - 1))) < 1e-9 and r["gained"] == expect, f"each coin pays more: ${r['gained']:.0f} for {k} (x{r['mult']})")
    p7 = coin_pos(sim, 7)
    stand_at(hrp, p7["x"], p7["y"], p7["z"])
    sim.run_for(0.2, 1 / 30)
    r2 = collect(sim, alice, [7])
    check(r2["n"] == 1 and r2["chain"] == k + 1, f"the next coin continues the chain ({r2['chain']:.0f})")
    sim.run_for(3.2, 1 / 30)
    p8 = coin_pos(sim, 8)
    stand_at(hrp, p8["x"], p8["y"], p8["z"])
    sim.run_for(0.2, 1 / 30)
    r3 = collect(sim, alice, [8])
    print("after the pause", r3)
    check(r3["n"] == 1 and r3["chain"] == 1 and r3["mult"] == 1, "after a pause the chain starts again")

    # ------------------------------------------------------------------ kinds and income
    srv(sim, '''
PDS.Set(p, { "Dragons", "TESTD" }, { IncomePerSecond = 1000, Name = "Test", SpeciesId = "GreenDrake", Level = 1, Rarity = "Common" })
PDS.Set(p, { "Nests", "Slots", "1" }, "TESTD")
shared.R = {}''')
    sim.run_for(0.3, 1 / 30)
    inc = srv(sim, 'shared.R = { income = ECO.IncomeRate(p) }')["income"]
    check(inc >= 1000, f"income set up (${inc:.0f}/s)")
    kinds = srv(sim, '''
local firstOf, lastOf = {}, {}
for i, c in CS.List() do
	if not firstOf[c.Kind] then firstOf[c.Kind] = i end
	lastOf[c.Kind] = i
end
shared.R = { Copper = lastOf.Copper - 30, Gold = firstOf.Gold, Gem = firstOf.Gem }''')
    sim.run_for(4, 1 / 30)
    for kind, mult_value in (("Gold", 2.0), ("Gem", 30.0), ("Copper", 0.6)):
        pos = coin_pos(sim, int(kinds[kind]))
        stand_at(hrp, pos["x"], pos["y"], pos["z"])
        sim.run_for(0.2, 1 / 30)
        r = collect(sim, alice, [int(kinds[kind])])
        # the income can have grown a little by the time of the request: allow the same second
        check(r["n"] == 1 and abs(r["gained"] - inc * mult_value) <= max(3, inc * mult_value * 0.02), f"{kind}: ${r['gained']:.0f} ({mult_value} s of ${inc:.0f}/s)")
        sim.run_for(3.0, 1 / 30)

    # ------------------------------------------------------------------ respawn and other players
    sim.run_for(80, 0.25)
    pos = coin_pos(sim, 1)
    stand_at(hrp, pos["x"], pos["y"], pos["z"])
    sim.run_for(0.3, 1 / 30)
    r = collect(sim, alice, [1])
    check(r["n"] == 1, "after its respawn time a coin can be taken again")

    bob = sim.add_player("Bob", 4002)
    sim.run_for(0.1, 1 / 30)
    sim.run_for(6, 1 / 30)
    cli(sim, bob, '''CC.setTouch(false) shared.R = {}''')
    bob_hrp = bob.props.get("Character").find_child("HumanoidRootPart")
    stand_at(bob_hrp, pos["x"], pos["y"], pos["z"])
    sim.run_for(0.3, 1 / 30)
    r = collect(sim, bob, [1])
    check(r["n"] == 1, "Bob can take the coin Alice just took (every player has their own coins)")

    # ------------------------------------------------------------------ the client: building, taking, the chain pill
    cli(sim, alice, '''CC.setTouch(true) shared.R = {}''')
    sim.run_for(4, 1 / 30)
    near = srv(sim, '''
-- a copper coin somewhere along the east road that is far from the ones taken so far
local list = CS.List()
local pick = 0
for i = #list, 1, -1 do
	if list[i].Kind == "Copper" then pick = i break end
end
local c = list[pick]
shared.R = { id = pick, x = c.Position.X, y = c.Position.Y, z = c.Position.Z }''')
    cid = int(near["id"])
    stand_at(hrp, near["x"], near["y"] + 12, near["z"])  # near, but not on it
    sim.run_for(1.5, 1 / 30)
    c = cli(sim, alice, '''
local folder = workspace:FindFirstChild("Coins")
shared.R = { vis = CC.visibleCount(), built = folder and #folder:GetChildren() or 0, mine = CC.isVisible(%d) }''' % cid)
    print("client near", c)
    check(c["vis"] >= 10 and c["built"] >= c["vis"], f"coins around the player are built ({c['vis']:.0f})")
    check(c["mine"], "the coin next to the player is there")
    far_vis = cli(sim, alice, '''
local far = 0
local me = LP.Character.HumanoidRootPart.Position
local folder = workspace:FindFirstChild("Coins")
for _, m in folder:GetChildren() do
	if m:IsA("Model") and (m:GetPivot().Position - me).Magnitude > 520 then far += 1 end
end
shared.R = { far = far }''')
    check(far_vis["far"] == 0, "coins far away are not built")
    cash0 = srv(sim, 'shared.R = { cash = d.Cash, coins = d.Stats.Coins or 0 }')
    stand_at(hrp, near["x"], near["y"], near["z"])
    sim.run_for(1.2, 1 / 30)
    c = cli(sim, alice, '''
local hud = LP.PlayerGui:FindFirstChild("Chain", true)
local texts = {}
for _, d in (hud and hud:GetDescendants() or {}) do
	if d:IsA("TextLabel") and d.Text ~= "" then table.insert(texts, d.Text) end
end
shared.R = { mine = CC.isVisible(%d), pill = hud ~= nil and hud.Visible, text = table.concat(texts, " "), total = CC.total(), chain = CC.chain().N }''' % cid)
    cash1 = srv(sim, 'shared.R = { cash = d.Cash, coins = d.Stats.Coins or 0, back = CS.State(p).Back[%d] ~= nil }' % cid)
    print("client taking", c, cash0, cash1)
    check(not c["mine"], "touching a coin takes it (it is gone)")
    check(cash1["back"] and cash1["coins"] > cash0["coins"] and cash1["cash"] > cash0["cash"], "the server counted it and paid")
    check(c["pill"] and "+$" in c["text"], f"the HUD shows the pill under the cash ({c['text']!r})")
    check(c["total"] == cash1["coins"], f"the coin total is known on the client ({c['total']:.0f})")
    sim.run_for(5, 1 / 30)
    c = cli(sim, alice, '''
local hud = LP.PlayerGui:FindFirstChild("Chain", true)
shared.R = { pill = hud ~= nil and hud.Visible }''')
    check(not c["pill"], "the pill goes out when the chain is over")

    # a coin the server refuses comes back
    p2 = coin_pos(sim, 40)
    srv(sim, '''CS.State(p).Back[40] = workspace:GetServerTimeNow() + 500 shared.R = {}''')
    stand_at(hrp, p2["x"], p2["y"] + 12, p2["z"])
    sim.run_for(1.5, 1 / 30)
    seen = cli(sim, alice, '''shared.R = { vis = CC.isVisible(40) }''')
    stand_at(hrp, p2["x"], p2["y"], p2["z"])
    sim.run_for(0.12, 1 / 30)
    gone = cli(sim, alice, '''shared.R = { vis = CC.isVisible(40) }''')
    sim.run_for(1.5, 1 / 30)
    back = cli(sim, alice, '''shared.R = { vis = CC.isVisible(40) }''')
    stand_at(hrp, p2["x"], p2["y"] + 60, p2["z"])
    print("refused coin", seen, gone, back)
    check(seen["vis"] is True, "(the coin was built before)")
    check(back["vis"] is True, "a coin the server did not take is back in the world")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    print("done in %ds" % (time.time() - t0))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

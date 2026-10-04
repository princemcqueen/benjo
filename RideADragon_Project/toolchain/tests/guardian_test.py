"""Egg guardians: every world egg lies in a nest guarded by a dragon (EggConfig.Guardians / EggService /
DuelService "Guardian" / EggController / DuelController). Rules (stronger egg = stronger guardian), the world
(nests, guardians built near you, no pickup by walking), the challenge (range, bag, retry wait), the duel
(win = the egg + XP, loss / forfeit = the egg stays), bonus eggs stay free."""
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
local PDS = require(SSS.Services.PlayerDataService)
local ES = require(SSS.Services.EggService)
local DS = require(SSS.Services.DuelService)
local EC = require(RS.Configs.EggConfig)
local DragonConfig = require(RS.Configs.DragonConfig)
local TreeConfig = require(RS.Configs.TreeConfig)
local players = game:GetService("Players"):GetPlayers()
local p = players[1]
local d = PDS.Get(p)
local function teleport(pos)
	local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	if hrp then hrp.Anchored = false hrp.CFrame = CFrame.new(pos) end
end
local function park(pos)
	local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	if hrp then hrp.Anchored = true hrp.CFrame = CFrame.new(pos) end
end
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src, steps=1200):
    head = '''
local LP = game:GetService("Players").LocalPlayer
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local EGC = require(LP.PlayerScripts.Controllers.EggController)
local DCtl = require(LP.PlayerScripts.Controllers.DuelController)
local ws = game:GetService("Workspace")
'''
    res = run_client_lua(sim, player, head + src, max_steps=steps)
    return lua_table_to_py(res.get("R"))


def request(sim, player, domain, action, payload="{}"):
    return cli(sim, player, f'''
local r = Net.request("{domain}", "{action}", {payload})
local f = r.data and r.data.Fighters
shared.R = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", kind = r.data and r.data.Kind or "", id = r.data and r.data.Id or "",
	eggType = r.data and r.data.Egg and r.data.Egg.Type or "", eggLuck = r.data and r.data.Egg and r.data.Egg.Luck or 0,
	species2 = f and f[2].Species or "", level1 = f and f[1].Level or 0, level2 = f and f[2].Level or 0, owner2 = f and f[2].Owner or "",
	mut2 = f and f[2].Mutation or "" }}''', steps=900)


def eggs_by_distance(sim):
    """All active eggs of the first player as plain rows, nearest to the player first."""
    rows = srv(sim, '''
local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
local here = hrp and hrp.Position or Vector3.zero
local list = {}
for key, e in ES.GetActive(p) do
	table.insert(list, { key = key, type = e.Type, luck = e.Luck, x = e.Position.X, y = e.Position.Y, z = e.Position.Z,
		guard = e.Guard ~= nil, species = e.Guard and e.Guard.Species or "", power = e.Guard and e.Guard.Power or 0,
		bonus = e.Bonus == true, dist = (e.Position - here).Magnitude })
end
table.sort(list, function(a, b) return a.dist < b.dist end)
shared.R = list''')
    if isinstance(rows, dict):
        rows = [rows[k] for k in sorted(rows, key=lambda x: int(x))]
    return rows


def go_to(sim, egg, dx=4.0):
    srv(sim, f'teleport(Vector3.new({egg["x"] + dx}, {egg["y"] + 3}, {egg["z"]})) shared.R = {{}}')
    sim.run_for(1.2, 1 / 30)


def server_state(sim):
    return srv(sim, '''
local n = 0
for _ in d.Eggs do n += 1 end
shared.R = { bag = n, found = d.Stats.EggsFound or 0, guardians = d.Stats.Guardians or 0, duelsWon = d.Stats.DuelsWon or 0,
	xp = d.XP or 0, level = d.Level or 1, held = ES.Held(p) or "", cap = TreeConfig.eggCapacity(d) }''')


def play_duel(sim, player, label, max_turns=14):
    """Plays the running duel scene to its end with STRIKE; returns the DuelEnd payload the client got."""
    for _ in range(400):
        st = cli(sim, player, 'shared.R = DCtl.State()')
        if st.get("Phase") == "Menu":
            cli(sim, player, 'shared.R = { ok = DCtl.choose("Strike") }')
            sim.run_for(0.3, 1 / 30)
        elif st.get("Ended") or not st.get("Active"):
            break
        sim.run_for(0.5, 1 / 30)
    end = cli(sim, player, 'shared.R = shared.END or {}')
    print(f"   [{label}] DuelEnd:", end)
    return end


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 7001)
    sim.run_for(10, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))
    # the client records the end of every duel
    cli(sim, alice, '''
Net.onSignal("DuelEnd", function(p) shared.END = { winner = p.Winner or 0, side = p.Side or 0, retry = p.Reward and p.Reward.Retry or 0,
	eggType = p.Reward and p.Reward.Egg and p.Reward.Egg.Type or "", eggLuck = p.Reward and p.Reward.Egg and p.Reward.Egg.Luck or 0,
	xp = p.Reward and p.Reward.XP or 0, cash = p.Reward and p.Reward.Cash or 0, gone = p.Reward and p.Reward.Gone == true or false } end)
shared.R = {}''')

    # ------------------------------------------------------------------ the rules: stronger egg = stronger guardian
    s = srv(sim, '''
local function rank(g) return DragonConfig.rarityRank(DragonConfig.Species[g.Species].Rarity) end
local haven, grove, frost, aurora, inferno, cele = EC.guardian("HavenEgg", 1, 0), EC.guardian("GroveEgg", 1, 0), EC.guardian("FrostEgg", 1, 0),
	EC.guardian("AuroraEgg", 1, 0), EC.guardian("InfernoEgg", 1, 0), EC.guardian("CelestialEgg", 1, 0)
local top = EC.guardian("CelestialEgg", 1000, 1)
local lucky = EC.guardian("HavenEgg", 100, 2)
local seen, n = {}, 0
for seed = 0, 11 do local g = EC.guardian("HavenEgg", 1, seed) if not seen[g.Species] then seen[g.Species] = true n += 1 end end
local again = EC.guardian("FrostEgg", 5, 7)
local again2 = EC.guardian("FrostEgg", 5, 7)
shared.R = {
	p1 = haven.Power, r1 = rank(haven), r2 = rank(grove), r3 = rank(frost), r4 = rank(aurora), r5 = rank(inferno), r6 = rank(cele), r9 = rank(top),
	m1 = haven.Mutation, mTop = top.Mutation, mLucky = lucky.Mutation, rLucky = rank(lucky), pTop = top.Power,
	d1 = haven.Delta, d3 = frost.Delta, d6 = cele.Delta, dTop = top.Delta, soft1 = haven.Scale, soft2 = grove.Scale, soft3 = frost.Scale,
	variety = n, same = again.Species == again2.Species and again.Mutation == again2.Mutation,
	lvLow = EC.guardianLevel(haven, 1), lvHigh = EC.guardianLevel(top, 45), lvMid = EC.guardianLevel(frost, 20),
	xp1 = EC.guardianXP(1), xp5 = EC.guardianXP(5), xp9 = EC.guardianXP(9),
	golden = rank(EC.guardian("GoldenEgg", 10, 0)), rainbow = rank(EC.guardian("RainbowEgg", 25, 0)),
}''')
    print("rules", s)
    check(s["p1"] == 1 and s["pTop"] == 9, "power = egg tier + log10(luck): a Haven Egg x1 is 1, a Celestial Egg x1000 is 9")
    check([s["r1"], s["r2"], s["r3"], s["r4"], s["r5"], s["r6"]] == [1, 2, 3, 4, 5, 6], "the guardian's rarity follows the egg's tier (Common ... Mythic)")
    check(s["r9"] == 7 and s["mTop"] == "Crystal", "the best egg has a Secret guardian with a Crystal mutation")
    check(s["rLucky"] == 3 and s["mLucky"] == "Golden" and s["m1"] == "None", "luck makes a guardian stronger too (Haven x100: a Rare, Golden guardian)")
    check(s["d1"] == -3 and s["d3"] == 0 and s["d6"] == 5 and s["dTop"] == 9, f"its level over yours grows with the power ({s['d1']:+.0f} / {s['d3']:+.0f} / {s['d6']:+.0f} / {s['dTop']:+.0f})")
    check(s["soft1"] == 0.8 and s["soft2"] == 0.9 and s["soft3"] == 1, "the weakest guardians fight a bit softer (first win is fair)")
    check(s["variety"] >= 4 and s["same"], f"a pool gives variety ({s['variety']:.0f} species in 12 seeds) but the same egg always has the same guardian")
    check(s["lvLow"] == 1 and s["lvHigh"] == 50 and s["lvMid"] == 20, "guardian level stays inside 1..50")
    check(s["xp1"] == 20 and 100 < s["xp5"] < 130 and s["xp9"] > 500, f"XP grows with the egg ({s['xp1']:.0f} / {s['xp5']:.0f} / {s['xp9']:.0f})")
    check(s["golden"] == 6 and s["rainbow"] == 7, "the special eggs (Golden, Rainbow) have Mythic / Secret guardians")

    # ------------------------------------------------------------------ the world: nests and guarded eggs
    eggs = eggs_by_distance(sim)
    print("eggs:", len(eggs), [(e["type"], e["luck"], e["species"]) for e in eggs[:5]])
    check(len(eggs) == 24 and all(e["guard"] for e in eggs), f"all {len(eggs)} world eggs have a guardian")
    check(all(e["power"] >= 1 for e in eggs), "every guardian has a power of 1 or more")
    ws = sim.services["Workspace"]
    my = ws.find_child("MyEggs")
    nests = [c for c in my.children if str(c.props.get("Name", "")).startswith("Nest_")]
    check(len(nests) == len(eggs), f"every egg lies in a nest on the client ({len(nests)} nests)")
    twigs = sum(1 for n in nests for c in n.children if c.props.get("Name") == "Twig")
    check(twigs >= 20 * len(nests) * 0.9, f"a nest is a ring of twigs and stones ({twigs} twigs)")

    # ------------------------------------------------------------------ walking into a guarded egg does nothing
    base = server_state(sim)
    near = eggs[0]
    go_to(sim, near)
    sim.run_for(3.0, 1 / 30)
    after = server_state(sim)
    still = [e for e in eggs_by_distance(sim) if e["key"] == near["key"]]
    check(len(still) == 1 and after["bag"] == base["bag"] and after["found"] == base["found"], "flying through a guarded egg does not take it")
    r = request(sim, alice, "Egg", "Pickup", '{ Key = "%s" }' % near["key"])
    check(not r["ok"] and r["err"] == "GUARDED", f"Egg.Pickup is refused for a guarded egg ({r['err']})")
    key = cli(sim, alice, 'shared.R = { key = EGC.promptKey() or "" }')["key"]
    check(key == near["key"], "the CHALLENGE button shows for the nest you are standing at")
    gui = cli(sim, alice, '''
local pg = game:GetService("Players").LocalPlayer.PlayerGui
local panel = pg:FindFirstChild("GuardianPrompt", true)
shared.R = { found = panel ~= nil, visible = panel ~= nil and panel.Visible or false, title = panel and panel:FindFirstChild("Title") and panel.Title.Text or "" }''')
    print("   prompt:", gui)
    check(gui["found"] and gui["visible"] and gui["title"] != "", f"...with the guardian's name and level ({gui['title']})")
    # the guardian's model is built while you are near
    sim.run_for(2.0, 1 / 30)
    models = [c for c in my.children if str(c.props.get("Name", "")).startswith("Guardian_")]
    check(any(m.props.get("Name") == "Guardian_" + near["key"] for m in models), f"the guardian of this nest stands next to it ({len(models)} guardian model(s) built)")
    check(len(models) <= 5, "never more than five guardian models at once")
    # ...and dropped again when you are far away
    far = eggs[-1]
    go_to(sim, far)
    sim.run_for(3.0, 1 / 30)
    models = [c.props.get("Name") for c in my.children if str(c.props.get("Name", "")).startswith("Guardian_")]
    apart = math.dist((near["x"], near["z"]), (far["x"], far["z"]))
    if apart > 450:
        check("Guardian_" + near["key"] not in models, f"the guardian of the first nest is dropped when you are {apart:.0f} studs away")
    key = cli(sim, alice, 'shared.R = { key = EGC.promptKey() or "" }')["key"]
    check(key == far["key"], "the button follows you to the next nest")
    srv(sim, 'park(Vector3.new(0, 2500, 0)) shared.R = {}')
    sim.run_for(3.0, 1 / 30)
    key = cli(sim, alice, 'shared.R = { key = EGC.promptKey() or "" }')["key"]
    check(key == "", "...and hides when no nest is near")
    models = [c.props.get("Name") for c in my.children if str(c.props.get("Name", "")).startswith("Guardian_")]
    check(len(models) == 0, f"high above the world every guardian model is dropped again ({len(models)} left)")

    # ------------------------------------------------------------------ the challenge: range, bag, retry
    eggs = eggs_by_distance(sim)  # (the player is far from the nest now)
    target = [e for e in eggs if e["dist"] > 150][0]
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % target["key"])
    check(not r["ok"] and r["err"] == "TOO_FAR", f"too far from the nest: {r['err']}")
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "nope" }')
    check(not r["ok"] and r["err"] == "GONE", f"an unknown egg: {r['err']}")
    r = request(sim, alice, "Duel", "Guardian", "{}")
    check(not r["ok"] and r["err"] == "BAD_REQUEST", "a request without a key is refused")
    # a Lucky Egg Call egg has no guardian
    anchor = eggs_by_distance(sim)[0]
    go_to(sim, anchor, 20)
    srv(sim, '''shared.R = { n = ES.SpawnBonusEggs(p, 1, { 25, 25 }, 120) }''')
    sim.run_for(0.5, 1 / 30)
    bonus = [e for e in eggs_by_distance(sim) if e["bonus"]]
    check(len(bonus) == 1 and not bonus[0]["guard"], "a Lucky Egg Call egg has no guardian")
    if bonus:
        r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % bonus[0]["key"])
        check(not r["ok"] and r["err"] == "NOT_GUARDED", f"...so there is nothing to challenge ({r['err']})")
        before = server_state(sim)
        go_to(sim, bonus[0], 1)
        sim.run_for(2.5, 1 / 30)
        after = server_state(sim)
        check(after["bag"] == before["bag"] + 1, "...and you just take it by flying into it")

    # ------------------------------------------------------------------ a duel for an egg: WIN
    eggs = [e for e in eggs_by_distance(sim) if e["guard"]]
    prize = eggs[0]
    go_to(sim, prize)
    # a full bag cannot start (the egg would have no room)
    srv(sim, '''
for _ = #d.Eggs + 1, TreeConfig.eggCapacity(d) do ES.GiveEgg(p, "HavenEgg", 1, true) end
shared.R = {}''')
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % prize["key"])
    check(not r["ok"] and r["err"] == "EGG_STORAGE_FULL", f"a full egg bag cannot start the duel: {r['err']}")
    srv(sim, 'PDS.Set(p, { "Eggs" }, {}) shared.R = {}')
    sim.run_for(0.3, 1 / 30)
    base = server_state(sim)
    ok = cli(sim, alice, '''
local ok, msg = EGC.challenge("%s")
shared.R = { ok = ok, msg = msg or "" }''' % prize["key"], steps=900)
    check(ok["ok"], f"EggController.challenge starts the duel scene ({ok['msg']})")
    m = srv(sim, '''
local m = DS.Match(p)
local f1, f2 = m.Sides[1], m.Sides[2]
shared.R = { kind = m.Kind, species2 = f2.Species, level1 = f1.Level, level2 = f2.Level, owner2 = f2.Owner, hp2 = f2.MaxHP, soft = (m.Egg and m.Egg.Key) or "" }''')
    print("   match:", m)
    check(m["kind"] == "Guardian" and m["species2"] == prize["species"], f"the foe is the nest's guardian ({m['species2']})")
    guard_level = srv(sim, f'shared.R = {{ lv = EC.guardianLevel(ES.GetActive(p)["{prize["key"]}"].Guard, DS.Match(p).Sides[1].Level) }}')["lv"]
    check(m["level2"] == guard_level, f"its level follows yours (Lv {m['level2']:.0f} vs your Lv {m['level1']:.0f})")
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % prize["key"])
    check(not r["ok"] and r["err"] == "IN_DUEL", "a second challenge is refused while the duel runs")
    # the guardian is nearly beaten: the player wins with a few STRIKEs
    srv(sim, '''
local m = DS.Match(p)
m.Sides[2].HP = 1
m.Sides[1].Speed = 1e9
shared.R = {}''')
    end = play_duel(sim, alice, "win")
    check(end.get("winner") == end.get("side") and end.get("winner") != 0, "the player won")
    check(end.get("eggType") == prize["type"] and end.get("eggLuck") == prize["luck"], f"the prize is the guarded egg ({end.get('eggType')} x{end.get('eggLuck'):.0f})")
    check(end.get("xp", 0) > 0 and end.get("cash", 0) == 0, f"...plus XP ({end.get('xp'):.0f}), no cash")
    after = server_state(sim)
    gone = [e for e in eggs_by_distance(sim) if e["key"] == prize["key"]]
    check(after["bag"] == base["bag"] + 1 and after["guardians"] == base["guardians"] + 1 and after["found"] == base["found"] + 1,
          f"the egg is in your bag / hand, EggsFound +1, Guardians +1 ({after['bag']:.0f} eggs)")
    check(after["duelsWon"] == base["duelsWon"], "a guardian win is not counted as a Battle Hall duel")
    check(after["held"] != "", "your hands were free: the egg is in your hand")
    check(len(gone) == 0, "the egg left the world (a new one grows later)")
    check(after["xp"] > base["xp"] or after["level"] > base["level"], "the XP went to your level")
    # the end card, then the world again: the nest and the guardian are gone
    cli(sim, alice, 'shared.R = { ok = DCtl.dismiss() }')
    sim.run_for(3.0, 1 / 30)
    left = cli(sim, alice, '''
local f = ws:FindFirstChild("MyEggs")
local names = {}
for _, c in f:GetChildren() do table.insert(names, c.Name) end
shared.R = { inList = EGC.list()["%s"] ~= nil, active = DCtl.active(), nest = f:FindFirstChild("Nest_%s") ~= nil, egg = f:FindFirstChild("Egg_%s") ~= nil }''' % (prize["key"], prize["key"], prize["key"]))
    check(not left["inList"] and not left["nest"] and not left["egg"] and not left["active"], "after the duel scene the egg, its nest and the guardian are gone from the world")

    # ------------------------------------------------------------------ a duel for an egg: LOSS and the retry wait
    eggs = [e for e in eggs_by_distance(sim) if e["guard"]]
    lost = eggs[0]
    go_to(sim, lost)
    base = server_state(sim)
    cli(sim, alice, 'shared.END = nil shared.R = {}')
    ok = cli(sim, alice, '''
local ok, msg = EGC.challenge("%s")
shared.R = { ok = ok, msg = msg or "" }''' % lost["key"], steps=900)
    check(ok["ok"], "a second duel for another egg starts")
    m = srv(sim, '''
local m = DS.Match(p)
shared.R = { kind = m.Kind, species2 = m.Sides[2].Species, owner2 = m.Sides[2].Owner, eggType = m.Egg.Type, id = m.Id }''')
    check(m["kind"] == "Guardian" and m["eggType"] == lost["type"] and m["owner2"] == "Egg Guardian" and m["species2"] == lost["species"],
          f"the foe is the guardian of that egg ({m['species2']}, {m['eggType']})")
    srv(sim, '''
local m = DS.Match(p)
m.Sides[1].HP = 1
m.Sides[2].Speed = 1e9
m.Sides[2].Damage = 5000
shared.R = {}''')
    end = play_duel(sim, alice, "loss")
    check(end.get("winner") == 2 and end.get("retry", 0) >= 5, f"the guardian won; the retry wait is {end.get('retry'):.0f} s")
    after = server_state(sim)
    still = [e for e in eggs_by_distance(sim) if e["key"] == lost["key"]]
    check(len(still) == 1 and after["bag"] == base["bag"] and after["guardians"] == base["guardians"], "the egg stays in its nest after a loss")
    cli(sim, alice, 'shared.R = { ok = DCtl.dismiss() }')
    sim.run_for(1.5, 1 / 30)
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % lost["key"])
    check(not r["ok"] and r["err"] == "GUARD_ANGRY", f"the same guardian needs a moment: {r['msg']}")
    sim.run_for(7.0, 1 / 30)
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % lost["key"])
    check(r["ok"], "...then it can be challenged again")
    # running away counts as a loss
    f = request(sim, alice, "Duel", "Forfeit", '{ Id = "%s" }' % r["id"])
    sim.run_for(1.0, 1 / 30)
    cli(sim, alice, 'shared.R = { ok = DCtl.dismiss() }')
    sim.run_for(1.5, 1 / 30)
    r = request(sim, alice, "Duel", "Guardian", '{ Key = "%s" }' % lost["key"])
    check(f["ok"] and not r["ok"] and r["err"] == "GUARD_ANGRY", "running away from a guardian starts the wait too")
    sim.run_for(7.0, 1 / 30)

    # ------------------------------------------------------------------ a won egg is never lost (the bag filled up meanwhile)
    eggs = [e for e in eggs_by_distance(sim) if e["guard"]]
    last = eggs[0]
    go_to(sim, last)
    srv(sim, 'PDS.Set(p, { "Eggs" }, {}) shared.R = {}')
    sim.run_for(0.3, 1 / 30)
    cli(sim, alice, 'shared.END = nil shared.R = {}')
    ok = cli(sim, alice, '''
local ok, msg = EGC.challenge("%s")
shared.R = { ok = ok, msg = msg or "" }''' % last["key"], steps=900)
    check(ok["ok"], "a new duel starts with an empty bag")
    srv(sim, '''
for _ = #d.Eggs + 1, TreeConfig.eggCapacity(d) do ES.GiveEgg(p, "HavenEgg", 1, true) end
local m = DS.Match(p)
m.Sides[2].HP = 1
m.Sides[1].Speed = 1e9
shared.R = { n = #d.Eggs }''')
    end = play_duel(sim, alice, "full bag")
    sim.run_for(2.0, 1 / 30)
    full = srv(sim, 'shared.R = { n = #d.Eggs, cap = TreeConfig.eggCapacity(d), inWorld = ES.GetActive(p)["%s"] ~= nil }' % last["key"])
    check(full["n"] == full["cap"] + 1 and not full["inWorld"], f"the bag filled up during the duel, the won egg still came: {full['n']:.0f} / {full['cap']:.0f} + 1")
    cli(sim, alice, 'shared.R = { ok = DCtl.dismiss() }')
    sim.run_for(2.0, 1 / 30)

    # ------------------------------------------------------------------ the server never trusts the client
    r = request(sim, alice, "Duel", "Guardian", '{ Key = 5 }')
    check(not r["ok"] and r["err"] == "BAD_REQUEST", "a key that is not a string is refused")
    errs = [e for e in sim.errors if "Guardian" in str(e) or "EggController" in str(e) or "DuelService" in str(e)]
    check(not errs, f"no errors from the guardian scripts ({len(errs)})")
    print("sim errors:", len(sim.errors), [str(e)[:160] for e in sim.errors[:5]])
    print()
    print("FAILED:" if FAIL else "ALL OK", FAIL if FAIL else "", f"({time.time() - t0:.0f} s)")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

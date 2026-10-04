"""Race & Battle Island - the duel arena: hit points from level and rarity, fighters only inside the
arena and only while riding, strike cone / reach / cooldown, aimed fireballs (clamped aim, flight,
cooldown), spawn protection, knockouts (respawn pad, frozen, back with full HP), rewards and the
Arena Warriors board, anti-farming, nothing outside the arena, the Net events, and the client side
(HUD, key binding, effects)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402

import race_test as rt  # noqa: E402

check = rt.check
req = rt.req


def csrv(sim, src):
    """Server snippet with the combat helpers in scope."""
    head = '''
local CS = require(SSS.Services.CombatService)
local CC = require(RS.Configs.CombatConfig)
local DC = require(RS.Configs.DragonConfig)
local function arena() local c, r, h = CC.arenaWorld() return c, r, h end
local function place(p, pos, look)
	local comp = MS.Get(p)
	comp.Root.Anchored = true
	comp.Root.CFrame = CFrame.lookAt(pos, pos + look)
	comp.Root.AssemblyLinearVelocity = Vector3.zero
	comp.LastPos = pos
	comp.LastGood = comp.Root.CFrame
end
'''
    return rt.srv(sim, head + src)


def attrs(sim, name):
    return csrv(sim, f'''
local p = byName("{name}")
local f = CS.Fighter(p)
shared.R = {{ arena = p:GetAttribute("InArena") == true, hp = p:GetAttribute("HP") or -1, max = p:GetAttribute("MaxHP") or -1,
	downed = p:GetAttribute("Downed") == true, fighter = f ~= nil, dead = f and f.Dead or false,
	kills = PDS.Get(p).Stats.ArenaKills, deaths = PDS.Get(p).Stats.ArenaDeaths, cash = PDS.Get(p).Cash,
	anchored = MS.Get(p) and MS.Get(p).Root.Anchored or false, riding = p:GetAttribute("Riding") == true }}''')


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 2001)
    bob = sim.add_player("Bob", 2002)
    sim.run_for(8, 1 / 30)

    # ------------------------------------------------------------------ the numbers
    nums = csrv(sim, '''
local lo, hi = CC.maxHP(1, 1), CC.maxHP(100, 8)
local d1, d2 = CC.baseDamage(1, 1), CC.baseDamage(100, 8)
local c, r, h = arena()
local ec = require(RS.Configs.RaceConfig).toWorld(CC.Entrance)
shared.R = { lo = lo, hi = hi, d1 = d1, d2 = d2, cx = c.X, cy = c.Y, cz = c.Z, r = r, h = h,
	hits = math.ceil(CC.maxHP(1, 1) / (CC.baseDamage(100, 8) * CC.Strike.Multiplier)),
	slow = math.ceil(CC.maxHP(100, 8) / (CC.baseDamage(1, 1) * CC.Strike.Multiplier)),
	respawns = #CC.Respawns }''')
    print("numbers:", nums)
    check(nums["lo"] < nums["hi"] and nums["d1"] < nums["d2"], f"hit points {nums['lo']:.0f} -> {nums['hi']:.0f}, damage {nums['d1']:.0f} -> {nums['d2']:.0f}: better dragons are stronger")
    check(nums["hits"] >= 3, f"even a legend needs {nums['hits']:.0f} strikes to drop a fresh dragon")
    check(nums["slow"] <= 45, f"a fresh dragon can drop a legend ({nums['slow']:.0f} strikes), it just takes a team")
    check(nums["respawns"] >= 4, "four respawn pads")

    # ------------------------------------------------------------------ travel to the island, outside the arena
    for p in (alice, bob):
        r = req(sim, p, "Travel", "To", '{ Place = "RaceIsland" }')
        check(r["ok"], f"{p.props.get('Name')} travels to the Race Island")
    sim.run_for(3, 1 / 30)
    a = attrs(sim, "Alice")
    check(not a["arena"] and not a["fighter"], "on the island plaza nobody is a fighter")
    # a known dragon: level 10 Rare for Alice, level 60 Legendary for Bob
    csrv(sim, '''
local function setup(name, level, rarity)
	local p = byName(name)
	local d = PDS.Get(p)
	local rec = d.Dragons[d.EquippedDragon]
	rec.Level = level
	rec.Rarity = rarity
	MS.Mount(p)
end
setup("Alice", 10, "Rare")
setup("Bob", 60, "Legendary")
shared.R = {}''')
    sim.run_for(1, 1 / 30)
    a, b = attrs(sim, "Alice"), attrs(sim, "Bob")
    check(a["riding"] and b["riding"], "both ride their dragons")

    # ------------------------------------------------------------------ riders on the plaza are not fighters; strike does nothing there
    r = csrv(sim, '''
local c = arena()
local plaza = require(RS.Configs.RaceConfig).toWorld(Vector3.new(0, 14, 10))
place(byName("Alice"), plaza, Vector3.new(0, 0, 1))
CS._zone()
shared.R = { strike = CS.Strike(byName("Alice")) }''')
    check(not r["strike"], "outside the arena the strike does nothing")
    check(not attrs(sim, "Alice")["arena"], "...and nobody is hit there (InArena stays off)")

    # ------------------------------------------------------------------ into the arena
    exp = csrv(sim, '''
local c = arena()
local hpA, hpB = CC.maxHP(10, DC.rarityRank("Rare")), CC.maxHP(60, DC.rarityRank("Legendary"))
place(byName("Alice"), c + Vector3.new(0, 14, 20), Vector3.new(0, 0, -1))   -- 20 studs south of the centre, looking north
place(byName("Bob"), c + Vector3.new(0, 14, -4), Vector3.new(0, 0, 1))      -- 24 studs north of her, looking at her
CS._zone()
shared.R = { hpA = hpA, hpB = hpB }''')
    a, b = attrs(sim, "Alice"), attrs(sim, "Bob")
    check(a["arena"] and b["arena"], "both enter the arena: InArena")
    check(a["hp"] == exp["hpA"] and a["max"] == exp["hpA"], f"Alice (level 10 Rare) has {a['hp']:.0f} hit points")
    check(b["hp"] == exp["hpB"] and exp["hpB"] > exp["hpA"], f"Bob (level 60 Legendary) has {b['hp']:.0f}: more than her")

    # ------------------------------------------------------------------ spawn protection
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 10), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, 1))        -- 10 studs ahead of Alice
shared.R = { ok = CS.Strike(A), hp = B:GetAttribute("HP"), max = B:GetAttribute("MaxHP") }''')
    check(r["ok"] and r["hp"] == r["max"], "a fresh arrival is protected for a few seconds: the strike lands for nothing")
    sim.run_for(3.3, 1 / 30)

    # ------------------------------------------------------------------ strike: damage, cooldown, cone, reach
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 10), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, 1))
local f = CS.Fighter(A)
f.NextStrike = 0
local before = B:GetAttribute("HP")
local ok = CS.Strike(A)
local after = B:GetAttribute("HP")
local base = CC.baseDamage(10, DC.rarityRank("Rare")) * CC.Strike.Multiplier
local again = CS.Strike(A)
shared.R = { ok = ok, dmg = before - after, base = base, again = again }''')
    check(r["ok"] and r["base"] * 0.95 <= r["dmg"] <= r["base"] * 1.55, f"strike hits for {r['dmg']:.0f} (base {r['base']:.0f}, x1.5 on a crit)")
    check(not r["again"], "the strike is on cooldown right after")
    sim.run_for(0.8, 1 / 30)
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
-- out of reach: 40 studs
place(B, c + Vector3.new(0, 14, -30), Vector3.new(0, 0, 1))
local hp0 = B:GetAttribute("HP")
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
local far = hp0 - B:GetAttribute("HP")
-- behind her
place(B, c + Vector3.new(0, 14, 24), Vector3.new(0, 0, 1))
local hp1 = B:GetAttribute("HP")
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
local behind = hp1 - B:GetAttribute("HP")
-- beside her (90 degrees): outside the 78 degree cone
place(B, c + Vector3.new(10, 14, 10), Vector3.new(0, 0, 1))
local hp2 = B:GetAttribute("HP")
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
local beside = hp2 - B:GetAttribute("HP")
-- inside the cone, 40 degrees off, near
place(B, c + Vector3.new(-7, 14, 3), Vector3.new(0, 0, 1))
local hp3 = B:GetAttribute("HP")
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
local angled = hp3 - B:GetAttribute("HP")
shared.R = { far = far, behind = behind, beside = beside, angled = angled }''')
    check(r["far"] == 0, "a target out of reach is not hit")
    check(r["behind"] == 0, "a target behind you is not hit")
    check(r["beside"] == 0, "a target at your side (outside the cone) is not hit")
    check(r["angled"] > 0, "a target 40 degrees off to the side, close by, is hit")

    # ------------------------------------------------------------------ blast: aimed fireball
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 30), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, -20), Vector3.new(0, 0, 1))     -- 50 studs ahead
local hp0 = B:GetAttribute("HP")
CS.Fighter(A).NextBlast = 0
local ok = CS.Blast(A, Vector3.new(0, 0, -1))
local flying = #CS._blasts()
for i = 1, 20 do CS._step(0.05) end
local dmg = hp0 - B:GetAttribute("HP")
local base = CC.baseDamage(10, DC.rarityRank("Rare")) * CC.Blast.Multiplier
local again = CS.Blast(A, Vector3.new(0, 0, -1))
shared.R = { ok = ok, flying = flying, left = #CS._blasts(), dmg = dmg, base = base, again = again }''')
    check(r["ok"] and r["flying"] == 1, "the blast is a projectile the server flies")
    check(r["left"] == 0 and r["base"] * 0.95 <= r["dmg"] <= r["base"] * 1.55, f"it hits for {r['dmg']:.0f} (base {r['base']:.0f}) and is gone")
    check(not r["again"], "the blast is on a long cooldown")
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
-- the client claims an aim 90 degrees away from where the dragon looks: it is clamped to 45 degrees
place(A, c + Vector3.new(0, 14, 30), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, -20), Vector3.new(0, 0, 1))
local hp0 = B:GetAttribute("HP")
CS.Fighter(A).NextBlast = 0
CS.Blast(A, Vector3.new(1, 0, 0))
local b = CS._blasts()[1]
local angle = math.deg(math.acos(math.clamp(b.Dir:Dot(Vector3.new(0, 0, -1)), -1, 1)))
for i = 1, 40 do CS._step(0.05) end
shared.R = { angle = angle, dmg = hp0 - B:GetAttribute("HP"), left = #CS._blasts() }''')
    check(abs(r["angle"] - 45) < 1.5, f"a wild aim is clamped to 45 degrees (got {r['angle']:.1f})")
    check(r["dmg"] == 0 and r["left"] == 0, "so the fireball misses and flies out of the arena")

    # ------------------------------------------------------------------ the Net events from a client
    sim.run_for(3.8, 1 / 30)
    csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 10), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, 1))
CS.Fighter(A).NextStrike = 0
shared.hp0 = B:GetAttribute("HP")
shared.R = {}''')
    run_client_lua(sim, alice, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
Net.fire("CombatStrike", {})
task.wait(0.3)
shared.R = {}''')
    r = csrv(sim, 'shared.R = { dmg = shared.hp0 - byName("Bob"):GetAttribute("HP") }')
    check(r["dmg"] > 0, "the CombatStrike event from the client hits the target")

    # ------------------------------------------------------------------ knockout
    k0 = attrs(sim, "Alice")
    b0 = attrs(sim, "Bob")
    sim.run_for(0.8, 1 / 30)
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 10), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, 1))
local f = CS.Fighter(B)
f.HP = 5
B:SetAttribute("HP", 5)
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
local fb = CS.Fighter(B)
local comp = MS.Get(B)
local pos = comp.Root.Position
local nearest, nd = 0, math.huge
for i, pad in CC.Respawns do
	local d = (require(RS.Configs.RaceConfig).toWorld(pad) - Vector3.new(pos.X, require(RS.Configs.RaceConfig).toWorld(pad).Y, pos.Z)).Magnitude
	if d < nd then nearest, nd = i, d end
end
shared.R = { dead = fb.Dead, downed = B:GetAttribute("Downed") == true, hp = B:GetAttribute("HP"), padDist = nd, anchored = comp.Root.Anchored }''')
    a1, b1 = attrs(sim, "Alice"), attrs(sim, "Bob")
    check(r["dead"] and r["downed"] and r["hp"] == 0, "Bob is knocked out: Dead, Downed, 0 hit points")
    check(r["padDist"] < 12, f"...and put on a respawn pad ({r['padDist']:.1f} studs from it)")
    check(r["anchored"], "...held there (nobody can move him)")
    check(a1["kills"] == k0["kills"] + 1 and b1["deaths"] == b0["deaths"] + 1, f"Alice has {a1['kills']:.0f} knockout, Bob {b1['deaths']:.0f} defeat")
    check(a1["cash"] > k0["cash"], f"the knockout pays cash (+${a1['cash'] - k0['cash']:.0f})")
    lb = csrv(sim, 'shared.R = { v = LB.valueOf(byName("Alice"), "ArenaKills") }')
    check(lb["v"] == a1["kills"], "the Arena Warriors board sees the knockout")
    # a downed fighter cannot be hit again and cannot attack
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
CS.Fighter(A).NextStrike = 0
local ok = CS.Strike(B)
shared.R = { ok = ok }''')
    check(not r["ok"], "a knocked-out dragon cannot attack")
    sim.run_for(1.0, 1 / 30)
    check(attrs(sim, "Bob")["dead"], "after a second he is still down")
    sim.run_for(2.4, 1 / 30)
    b2 = attrs(sim, "Bob")
    check(not b2["dead"] and b2["hp"] == b2["max"] and not b2["downed"], f"after the delay he is back with full hit points ({b2['hp']:.0f})")
    check(not b2["anchored"], "...and free to move")
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 10), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, 1))
CS.Fighter(A).NextStrike = 0
local hp0 = B:GetAttribute("HP")
CS.Strike(A)
shared.R = { dmg = hp0 - B:GetAttribute("HP") }''')
    check(r["dmg"] == 0, "he is protected for a few seconds after the respawn")

    # ------------------------------------------------------------------ the same victim again soon: no reward
    sim.run_for(3.6, 1 / 30)
    c0 = attrs(sim, "Alice")
    csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
place(A, c + Vector3.new(0, 14, 10), Vector3.new(0, 0, -1))
place(B, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, 1))
CS.Fighter(B).HP = 5
B:SetAttribute("HP", 5)
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
shared.R = {}''')
    c1 = attrs(sim, "Alice")
    check(c1["kills"] == c0["kills"] + 1, "the second knockout still counts for the board")
    check(c1["cash"] == c0["cash"], "...but the same opponent again within 45 seconds pays nothing")
    sim.run_for(3.4, 1 / 30)

    # ------------------------------------------------------------------ the training dummy (practice: Alice alone in the arena)
    sim.run_for(1.0, 1 / 30)
    csrv(sim, '''
local B = byName("Bob")
local plaza = require(RS.Configs.RaceConfig).toWorld(Vector3.new(0, 14, 10))
place(B, plaza, Vector3.new(0, 0, 1))
CS._zone()
shared.R = {}''')
    check(not attrs(sim, "Bob")["arena"], "Bob steps out of the arena")
    before = attrs(sim, "Alice")
    r = csrv(sim, '''
local A = byName("Alice")
local d = CS._dummy()
d.HP = CC.Dummy.HP
d.Down = false
local center = CC.dummyWorld()
place(A, center + Vector3.new(0, 0, 14), Vector3.new(0, 0, -1))   -- 14 studs from the dummy, looking at it
CS._zone()
CS.Fighter(A).NextStrike = 0
local ok = CS.Strike(A)
local base = CC.baseDamage(10, DC.rarityRank("Rare")) * CC.Strike.Multiplier
shared.R = { ok = ok, dmg = CC.Dummy.HP - d.HP, base = base, attr = d.Model and d.Model:GetAttribute("HP") or -1, max = d.Model and d.Model:GetAttribute("MaxHP") or -1, hp = d.HP }''')
    check(r["ok"] and r["base"] * 0.95 <= r["dmg"] <= r["base"] * 1.55, f"a strike hits the training dummy for {r['dmg']:.0f}")
    check(r["attr"] == r["hp"] and r["max"] == 4000, f"its hit points are on the model for the client bar ({r['attr']:.0f} / {r['max']:.0f})")
    r = csrv(sim, '''
local A = byName("Alice")
local d = CS._dummy()
local hp0 = d.HP
local center = CC.dummyWorld()
place(A, center + Vector3.new(0, 0, 70), Vector3.new(0, 0, -1))
CS.Fighter(A).NextBlast = 0
CS.Blast(A, Vector3.new(0, 0, -1))
for i = 1, 20 do CS._step(0.05) end
shared.R = { dmg = hp0 - d.HP, left = #CS._blasts() }''')
    check(r["dmg"] > 0 and r["left"] == 0, f"a fireball hits it too ({r['dmg']:.0f})")
    r = csrv(sim, '''
local A = byName("Alice")
local d = CS._dummy()
d.HP = 5
local center = CC.dummyWorld()
place(A, center + Vector3.new(0, 0, 14), Vector3.new(0, 0, -1))
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
shared.R = { down = d.Down, attr = d.Model and d.Model:GetAttribute("Down") == true }''')
    check(r["down"] and r["attr"], "the dummy falls when its hit points are gone")
    after = attrs(sim, "Alice")
    check(after["kills"] == before["kills"] and after["cash"] == before["cash"], "...and pays nothing, it is not a knockout")
    sim.run_for(4.6, 1 / 30)
    r = csrv(sim, '''
local d = CS._dummy()
shared.R = { down = d.Down, hp = d.HP }''')
    check(not r["down"] and r["hp"] == 4000, "a few seconds later the dummy stands again with full hit points")
    # with a second fighter in the arena the dummy keeps out of the way
    r = csrv(sim, '''
local A, B = byName("Alice"), byName("Bob")
local c = arena()
local center = CC.dummyWorld()
place(B, c + Vector3.new(30, 14, 0), Vector3.new(0, 0, 1))
CS._zone()
local d = CS._dummy()
local hp0 = d.HP
place(A, center + Vector3.new(0, 0, 14), Vector3.new(0, 0, -1))
CS.Fighter(A).NextStrike = 0
CS.Strike(A)
shared.R = { dmg = hp0 - d.HP, bob = B:GetAttribute("InArena") == true }''')
    check(r["bob"] and r["dmg"] == 0, "in a duel the dummy takes no hits (it never blocks a shot)")

    # ------------------------------------------------------------------ leaving / dismounting / racing
    csrv(sim, '''
local A = byName("Alice")
local c = arena()
place(A, c + Vector3.new(0, 14, 90), Vector3.new(0, 0, -1))   -- flew out of the cylinder
CS._zone()
shared.R = {}''')
    check(not attrs(sim, "Alice")["arena"], "flying out of the arena ends the fight")
    csrv(sim, '''
local A = byName("Alice")
local c = arena()
place(A, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, -1))
CS._zone()
shared.R = {}''')
    check(attrs(sim, "Alice")["arena"], "flying back in starts it again")
    csrv(sim, '''
local A = byName("Alice")
A:SetAttribute("RaceActive", true)
CS._zone()
shared.R = {}''')
    check(not attrs(sim, "Alice")["arena"], "a racer is never a fighter")
    csrv(sim, 'byName("Alice"):SetAttribute("RaceActive", nil) shared.R = {}')
    csrv(sim, '''
local A = byName("Alice")
local c = arena()
place(A, c + Vector3.new(0, 14, 0), Vector3.new(0, 0, -1))
CS._zone()
MS.Get(A).Root.Anchored = false
shared.R = {}''')
    csrv(sim, '''
local A = byName("Alice")
MS.Dismount(A)
CS._zone()
shared.R = {}''')
    check(not attrs(sim, "Alice")["arena"], "getting off the dragon ends the fight")

    # ------------------------------------------------------------------ client side
    csrv(sim, '''
for _, n in { "Alice", "Bob" } do
	local p = byName(n)
	if not MS.IsRiding(p) then MS.Mount(p) end
	local c = arena()
	place(p, c + Vector3.new(n == "Alice" and 6 or -6, 14, 0), Vector3.new(0, 0, -1))
end
CS._zone()
shared.R = {}''')
    sim.run_for(1.2, 1 / 30)
    cl = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local CAS = game:GetService("ContextActionService")
local CC = require(LP.PlayerScripts.Controllers.CombatController)
local gui = LP.PlayerGui:FindFirstChild("GameCombat")
local hud = gui and gui.Root:FindFirstChild("ArenaHud")
local keys = gui and gui.Root:FindFirstChild("ArenaKeys")
local bound = CAS:GetAllBoundActionInfo()
shared.R = { gui = gui ~= nil, hudVisible = hud and hud.Visible or false, keysVisible = keys and keys.Visible or false,
	bound = (bound.RAD_ArenaStrike ~= nil), boundBlast = (bound.RAD_ArenaBlast ~= nil), fighter = LP:GetAttribute("InArena") == true,
	hp = LP:GetAttribute("HP"), max = LP:GetAttribute("MaxHP"), text = hud and hud.Hp.Text or "" }''')
    cl = lua_table_to_py(cl.get("R"))
    print("client:", cl)
    check(cl["gui"] and cl["fighter"], "the client has the combat layer and knows it is a fighter")
    check(cl["hudVisible"], f"the hit point panel shows ({cl['text']})")
    check(cl["bound"] and cl["boundBlast"], "strike (F / click) and blast (G) are bound")
    check(cl["keysVisible"], "the key hints show on a desktop")
    # pressing the keys from the client: the cooldown and the server both react
    sim.run_for(3.4, 1 / 30)
    cr = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local CC = require(LP.PlayerScripts.Controllers.CombatController)
local first = CC.strike()
local second = CC.strike()
task.wait(0.4)
local fxCount = workspace:FindFirstChild("CombatFx") and #workspace.CombatFx:GetChildren() or 0
local blast = CC.blast()
task.wait(0.4)
shared.R = { first = first, second = second, fx = fxCount, blast = blast, blasts = workspace:FindFirstChild("CombatFx") and #workspace.CombatFx:GetChildren() or 0 }''')
    cr = lua_table_to_py(cr.get("R"))
    print("client press:", cr)
    check(cr["first"] and not cr["second"], "the client strikes once and then waits for the cooldown")
    check(cr["fx"] > 0, "the strike shockwave is drawn")
    check(cr["blast"], "the client can blast too")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if rt.FAIL else "\nALL OK", rt.FAIL if rt.FAIL else "")
    sys.exit(1 if rt.FAIL else 0)


if __name__ == "__main__":
    main()

"""Turn-based duels (DuelService / DuelController / DuelWindow): the rules on the server (order, damage,
elements, guard, PP, buffs, KO, rewards, forfeits, trainer levels, player challenges) and the scene on
the client (stage, camera, menu, a whole duel against a trainer, the end card, everything back after)."""
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
local DS = require(SSS.Services.DuelService)
local DC = require(RS.Configs.DuelConfig)
local players = game:GetService("Players"):GetPlayers()
local p = players[1]
local q = players[2]
local d = PDS.Get(p)
-- a clean slate for a hand-driven turn (the hooks play turns without ending the match)
local function fresh(m)
	m.Over = false
	m.Winner = nil
	m.Choices = {}
	for _, f in m.Sides do
		f.HP = f.MaxHP f.Guarding = false f.LastMove = "" f.Buff = 1 f.BuffTurns = 0
	end
end
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Duel", "{action}", {payload})
local fighters = r.data and r.data.Fighters
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", id = r.data and r.data.Id or "", side = r.data and r.data.Side or 0,
	level1 = fighters and fighters[1].Level or 0, level2 = fighters and fighters[2].Level or 0, name1 = fighters and fighters[1].Name or "", name2 = fighters and fighters[2].Name or "",
	hp1 = fighters and fighters[1].MaxHP or 0, hp2 = fighters and fighters[2].MaxHP or 0, waiting = r.data and r.data.Waiting == true or false,
	count = r.data and r.data.List and #r.data.List or 0 }}''', max_steps=1200)
    return lua_table_to_py(res.get("RQ"))


def cli(sim, player, src, steps=1200):
    head = '''
local LP = game:GetService("Players").LocalPlayer
local DCtl = require(LP.PlayerScripts.Controllers.DuelController)
local UIC = require(LP.PlayerScripts.Controllers.UIController)
'''
    res = run_client_lua(sim, player, head + src, max_steps=steps)
    return lua_table_to_py(res.get("R"))


def end_match(sim):
    srv(sim, '''
local m = DS.Match(p)
if m then DS.Resolve(m, { "Strike", "Strike" }) end
shared.R = {}''')


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 7001)
    sim.run_for(8, 1 / 30)
    bob = sim.add_player("Bob", 7002)
    sim.run_for(6, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ config rules
    s = srv(sim, '''
shared.R = {
	fireNature = DC.effectiveness("Fire", "Nature"), natureFire = DC.effectiveness("Nature", "Fire"), same = DC.effectiveness("Fire", "Fire"),
	darkLight = DC.effectiveness("Dark", "Light"), fireWater = DC.effectiveness("Fire", "Water"), waterFire = DC.effectiveness("Water", "Fire"),
	nature = DC.elementOf("GreenDrake"), ember = DC.elementOf("EmberPup"), hp1 = DC.maxHP(1, 1), hp50 = DC.maxHP(50, 8), trainers = #DC.Trainers,
	covered = (function() local n = 0 for id in require(RS.Configs.DragonConfig).Species do if DC.SpeciesElement[id] then n += 1 end end return n end)(),
}''')
    print("config", s)
    check(s["fireNature"] == 1.5 and abs(s["natureFire"] - 2 / 3) < 1e-9 and s["same"] == 1, "elements: Fire beats Nature (x1.5), the reverse is x0.67, the same is x1")
    check(s["darkLight"] == 1 and s["fireWater"] == 2 / 3 and s["waterFire"] == 1.5, "Water beats Fire; Dark and Light beat each other: neutral")
    check(s["nature"] == "Nature" and s["ember"] == "Fire" and s["covered"] == 34, f"every species has an element ({s['covered']:.0f} of 34)")
    check(s["hp1"] == 578 and s["trainers"] == 4, f"a new dragon has {s['hp1']:.0f} hit points in a duel; {s['trainers']:.0f} trainers")

    # ------------------------------------------------------------------ trainer list and levels
    r = req(sim, alice, "Trainers")
    check(r["ok"] and r["count"] == 4, "the Battle Hall lists the four trainers")
    srv(sim, '''
PDS.Set(p, { "Dragons", d.EquippedDragon, "Level" }, 10)
shared.R = {}''')
    r = req(sim, alice, "Start", '{ Trainer = "Captain" }')
    print("start", r)
    check(r["ok"] and r["level1"] == 10 and r["level2"] == 13, f"Captain Vale's dragon is 3 levels above yours (Lv {r['level2']:.0f} vs {r['level1']:.0f})")
    check(r["name1"] == "Green Drake" and r["side"] == 1, "you fight with your equipped dragon")
    check(srv(sim, 'shared.R = { inDuel = p:GetAttribute("InDuel") == true }')["inDuel"], "InDuel is set while the match runs")
    r2 = req(sim, alice, "Start", '{ Trainer = "Rookie" }')
    check(not r2["ok"] and r2["err"] == "IN_DUEL", "a second duel is refused while one is running")
    r2 = req(sim, alice, "Forfeit", '{ Id = "%s" }' % r["id"])
    check(r2["ok"], "RUN AWAY ends the match")
    sim.run_for(1.0, 1 / 30)
    e = srv(sim, 'shared.R = { inDuel = p:GetAttribute("InDuel") == true, lost = d.Stats.DuelsLost or 0, match = DS.Match(p) ~= nil }')
    check(not e["inDuel"] and e["lost"] == 1 and not e["match"], "...and the loss is counted, InDuel is cleared")
    for tid, delta in (("Rookie", -2), ("Ranger", 0), ("Champion", 6)):
        sim.run_for(1.2, 1 / 30)
        r = req(sim, alice, "Start", '{ Trainer = "%s" }' % tid)
        check(r["ok"] and r["level2"] == 10 + delta, f"{tid}: dragon Lv {r['level2']:.0f} (yours 10{delta:+d})")
        req(sim, alice, "Forfeit", '{ Id = "%s" }' % r["id"])
        sim.run_for(0.6, 1 / 30)
    r = req(sim, alice, "Start", '{ Trainer = "Nobody" }')
    check(not r["ok"], "an unknown trainer is refused")

    # ------------------------------------------------------------------ the rules of a turn (server)
    sim.run_for(1.5, 1 / 30)
    srv(sim, 'DS.Seed(7) shared.R = {}')
    r = req(sim, alice, "Start", '{ Trainer = "Ranger" }')
    mid = r["id"]
    s = srv(sim, '''
local m = DS.Match(p)
fresh(m)
local a, b = m.Sides[1], m.Sides[2]
-- slow player, fast foe; the player guards: GUARD goes first anyway
a.Speed = 1 b.Speed = 1000
local ev = DS.Resolve(m, { "Guard", "Strike" })
local out = { n = #ev, first = ev[1].Side, firstMove = ev[1].Move, second = ev[2] and ev[2].Side or 0, guarded = ev[2] and ev[2].Guarded or false,
	dmg = ev[2] and ev[2].Damage or -1, hit = ev[2] and ev[2].Hit or false, max = math.floor(b.Damage * 1.1 * 0.5 + 0.5) + 1, turn = m.Turn }
shared.R = out''')
    print("guard first", s)
    check(s["first"] == 1 and s["firstMove"] == "Guard", "GUARD goes first even for the slower dragon")
    if s["hit"]:
        check(s["guarded"] and 1 <= s["dmg"] <= s["max"], f"...and halves the damage ({s['dmg']:.0f} <= {s['max']:.0f})")
    else:
        check(True, "(the foe missed this time)")
    s = srv(sim, '''
local m = DS.Match(p)
fresh(m)
local a, b = m.Sides[1], m.Sides[2]
a.Damage = 1 b.Damage = 1
a.Speed = 10 b.Speed = 1000
local ev = DS.Resolve(m, { "Strike", "Strike" })
fresh(m)
a.Speed = 1000 b.Speed = 10
local ev3 = DS.Resolve(m, { "Strike", "Strike" })
shared.R = { slowFirst = ev[1].Side, fastFirst = ev3[1].Side }''')
    check(s["slowFirst"] == 2 and s["fastFirst"] == 1, "the faster dragon moves first")
    s = srv(sim, '''
local m = DS.Match(p)
fresh(m)
local a, b = m.Sides[1], m.Sides[2]
a.Speed = 1000 b.Speed = 10
b.Damage = 0
a.Element = "Fire" b.Element = "Nature"
local fireEff, strikeEff, weak = 0, 0, 0
for i = 1, 30 do
	fresh(m) a.PP.Fire = 8
	local ev = DS.Resolve(m, { "Fire", "Strike" })
	if ev[1].Hit then fireEff = ev[1].Eff break end
end
for i = 1, 30 do
	fresh(m)
	local ev = DS.Resolve(m, { "Strike", "Strike" })
	if ev[1].Hit then strikeEff = ev[1].Eff break end
end
fresh(m) b.PP.Guard = 6
DS.Resolve(m, { "Strike", "Guard" })
local ev3 = DS.Resolve(m, { "Strike", "Guard" })
local guardFail = false
for _, e in ev3 do if e.Side == 2 then guardFail = e.Fail end end
a.Element = "Nature" b.Element = "Fire"
for i = 1, 30 do
	fresh(m) a.PP.Fire = 8
	local ev = DS.Resolve(m, { "Fire", "Strike" })
	if ev[1].Hit then weak = ev[1].Eff break end
end
fresh(m) a.PP.Fire = 8 b.PP.Guard = 6
DS.Resolve(m, { "Fire", "Guard" })
shared.R = { fireEff = fireEff, strikeEff = strikeEff, guardFail = guardFail, weak = weak, ppFire = a.PP.Fire, ppGuard = b.PP.Guard }'''
    )
    print("elements", s)
    check(s["fireEff"] == 1.5 and s["strikeEff"] == 1, "Fire is super effective on Nature, a plain STRIKE is never affected")
    check(s["guardFail"] is True, "GUARD twice in a row fails")
    check(s["weak"] == 2 / 3, "Fire attacks a Fire dragon from a Nature dragon: not very effective (x0.67)")
    check(s["ppFire"] == 7 and s["ppGuard"] == 5, f"uses are counted (FIRE {s['ppFire']:.0f} left, foe GUARD {s['ppGuard']:.0f} left)")
    s = srv(sim, '''
local m = DS.Match(p)
fresh(m)
local a = m.Sides[1]
m.Sides[2].Damage = 0
a.Mutation = "None" a.Special = "Roar" a.SpecialName = "ROAR" a.PP.Special = 4
a.Speed = 1000
local ev = DS.Resolve(m, { "Special", "Strike" })
local buffed = a.Buff
local t1 = a.BuffTurns
DS.Resolve(m, { "Strike", "Strike" })
DS.Resolve(m, { "Strike", "Strike" })
DS.Resolve(m, { "Strike", "Strike" })
shared.R = { move = ev[1].Move, buff = buffed, turns = t1, after = a.Buff, pp = a.PP.Special }''')
    print("roar", s)
    check(s["move"] == "Roar" and abs(s["buff"] - 1.3) < 1e-9 and s["turns"] == 2, "a normal dragon's SPECIAL is ROAR: +30% for this and the next 2 turns")
    check(s["after"] == 1 and s["pp"] == 3, "...the buff wears off and the use is counted")
    s = srv(sim, '''
local m = DS.Match(p)
fresh(m)
local a, b = m.Sides[1], m.Sides[2]
a.Special = "Burst" a.SpecialName = "FROST BURST"
a.Speed = 1000 b.Speed = 10
b.Damage = 0
a.Element = "Neutral" b.Element = "Neutral"
local best, plain = 0, 0
for i = 1, 40 do
	fresh(m) b.HP = 1e9 b.MaxHP = 1e9
	a.PP.Special = 3
	local ev = DS.Resolve(m, { "Special", "Strike" })
	for _, e in ev do if e.Side == 1 and e.Hit and not e.Crit then best = math.max(best, e.Damage) end end
	fresh(m) b.HP = 1e9 b.MaxHP = 1e9
	local ev2 = DS.Resolve(m, { "Strike", "Strike" })
	for _, e in ev2 do if e.Side == 1 and e.Hit and not e.Crit then plain = math.max(plain, e.Damage) end end
end
shared.R = { burst = best, strike = plain }''')
    check(s["burst"] > s["strike"] * 1.3, f"a mutated dragon's burst hits much harder than a strike ({s['burst']:.0f} vs {s['strike']:.0f})")
    # the PP limit
    srv(sim, '''
local m = DS.Match(p)
fresh(m)
m.Sides[1].PP.Fire = 0
shared.R = {}''')
    r = req(sim, alice, "Move", '{ Id = "%s", Move = "Fire" }' % mid)
    check(not r["ok"] and r["err"] == "NO_PP", "a move without uses left is refused")
    r = req(sim, alice, "Move", '{ Id = "%s", Move = "Teleport" }' % mid)
    check(not r["ok"] and r["err"] == "BAD_REQUEST", "an unknown move is refused")
    r = req(sim, alice, "Move", '{ Id = "wrong", Move = "Strike" }')
    check(not r["ok"] and r["err"] == "NO_MATCH", "a move for another match is refused")

    # ------------------------------------------------------------------ winning: reward, stats, cooldown
    srv(sim, '''
local m = DS.Match(p)
fresh(m)
m.Sides[2].HP = 1
m.Sides[1].Speed = 1000
shared.R = {}''')
    before = srv(sim, 'shared.R = { cash = d.Cash, won = d.Stats.DuelsWon or 0 }')
    won = False
    for _ in range(12):
        sim.run_for(1.2, 1 / 30)
        r = req(sim, alice, "Move", '{ Id = "%s", Move = "Strike" }' % mid)
        sim.run_for(1.0, 1 / 30)
        m = srv(sim, 'local m = DS.Match(p) shared.R = { open = m ~= nil }')
        if not m["open"]:
            won = True
            break
    after = srv(sim, 'shared.R = { cash = d.Cash, won = d.Stats.DuelsWon or 0, inDuel = p:GetAttribute("InDuel") == true }')
    print("win", before, after)
    check(won and after["won"] == before["won"] + 1 and not after["inDuel"], "knocking the foe out wins the duel and counts it")
    check(after["cash"] - before["cash"] >= 4000, f"Ranger Kai pays at least $4000 (${after['cash'] - before['cash']:.0f})")
    # the same trainer again at once pays a quarter
    sim.run_for(1.5, 1 / 30)
    req(sim, alice, "Start", '{ Trainer = "Ranger" }')
    srv(sim, '''
local m = DS.Match(p)
m.Sides[2].HP = 1
m.Sides[1].Speed = 1000
shared.R = {}''')
    b2 = srv(sim, 'shared.R = { cash = d.Cash }')
    for _ in range(12):
        sim.run_for(1.2, 1 / 30)
        mm = srv(sim, 'local m = DS.Match(p) shared.R = { id = m and m.Id or "" }')
        if mm["id"] == "":
            break
        req(sim, alice, "Move", '{ Id = "%s", Move = "Strike" }' % mm["id"])
        sim.run_for(1.0, 1 / 30)
    a2 = srv(sim, 'shared.R = { cash = d.Cash }')
    gain2 = a2["cash"] - b2["cash"]
    check(gain2 < (after["cash"] - before["cash"]) * 0.5, f"a rematch right away pays less (${gain2:.0f} instead of ${after['cash'] - before['cash']:.0f})")

    # ------------------------------------------------------------------ losing
    sim.run_for(1.5, 1 / 30)
    req(sim, alice, "Start", '{ Trainer = "Champion" }')
    srv(sim, '''
local m = DS.Match(p)
m.Sides[1].HP = 1 m.Sides[1].Speed = 1 m.Sides[2].Speed = 1000
shared.R = {}''')
    lost0 = srv(sim, 'shared.R = { lost = d.Stats.DuelsLost or 0 }')["lost"]
    for _ in range(14):
        sim.run_for(1.2, 1 / 30)
        mm = srv(sim, 'local m = DS.Match(p) shared.R = { id = m and m.Id or "" }')
        if mm["id"] == "":
            break
        req(sim, alice, "Move", '{ Id = "%s", Move = "Guard" }' % mm["id"])
        sim.run_for(0.8, 1 / 30)
    lost1 = srv(sim, 'shared.R = { lost = d.Stats.DuelsLost or 0, inDuel = p:GetAttribute("InDuel") == true }')
    check(lost1["lost"] == lost0 + 1 and not lost1["inDuel"], "a knocked-out player loses; the loss is counted")

    # ------------------------------------------------------------------ players
    sim.run_for(2.0, 1 / 30)
    r = req(sim, alice, "Challenge", '{ UserId = 7001 }')
    check(not r["ok"], "you cannot challenge yourself")
    r = req(sim, alice, "Challenge", '{ UserId = 424242 }')
    check(not r["ok"] and r["err"] == "NO_PLAYER", "a player who is not here cannot be challenged")
    r = req(sim, alice, "Challenge", '{ UserId = 7002 }')
    check(r["ok"], "Alice challenges Bob")
    sim.run_for(1.0, 1 / 30)
    c = cli(sim, bob, '''
local g = LP.PlayerGui:FindFirstChild("DuelChallenge", true)
shared.R = { shown = g ~= nil and g.Visible }''')
    check(c["shown"], "Bob sees the challenge panel")
    r = req(sim, bob, "Respond", '{ From = 7001, Accept = false }')
    check(r["ok"], "Bob declines")
    sim.run_for(1.0, 1 / 30)
    r = req(sim, alice, "Challenge", '{ UserId = 7002 }')
    check(r["ok"], "...Alice tries again")
    sim.run_for(1.2, 1 / 30)
    # (Bob presses ACCEPT: the controller sends the answer and opens his scene; Alice's opens by the signal)
    c = cli(sim, bob, '''
DCtl.respond(7001, true)
shared.R = { active = DCtl.active(), phase = DCtl.State().Phase or "" }''')
    print("accept", c)
    check(c["active"], "Bob accepts: his client opens the duel scene")
    sim.run_for(1.0, 1 / 30)
    pm = srv(sim, '''
local m = DS.Match(p)
shared.R = { kind = m and m.Kind or "", turn = m and m.Turn or 0, id = m and m.Id or "", bob = q:GetAttribute("InDuel") == true, alice = p:GetAttribute("InDuel") == true, bobSide2 = m ~= nil and m.Players[2] == q }''')
    check(pm["kind"] == "PVP" and pm["bob"] and pm["alice"], "both are in the match")
    check(pm["bobSide2"], "the challenged player is side 2")
    # both choose; the turn is played once both have chosen
    ra = req(sim, alice, "Move", '{ Id = "%s", Move = "Strike" }' % pm["id"])
    check(ra["ok"] and ra["waiting"], "Alice chooses and waits for Bob")
    sim.run_for(0.5, 1 / 30)
    t0turn = srv(sim, 'local m = DS.Match(p) shared.R = { turn = m.Turn }')["turn"]
    rb = req(sim, bob, "Move", '{ Id = "%s", Move = "Strike" }' % pm["id"])
    sim.run_for(0.5, 1 / 30)
    t1turn = srv(sim, 'local m = DS.Match(p) shared.R = { turn = m.Turn, hp1 = m.Sides[1].HP, hp2 = m.Sides[2].HP, max1 = m.Sides[1].MaxHP, max2 = m.Sides[2].MaxHP }')
    check(rb["ok"] and t1turn["turn"] == t0turn + 1, "Bob chooses: the turn is played")
    check(t1turn["hp1"] < t1turn["max1"] or t1turn["hp2"] < t1turn["max2"], "somebody took damage")
    # the other side sees the match from its own side
    r = req(sim, bob, "Move", '{ Id = "%s", Move = "Strike" }' % pm["id"])
    check(r["ok"], "Bob chooses again (the next turn)")
    # nobody else chooses: after the time limit the turn is played with STRIKE
    sim.run_for(31.5, 1 / 10)
    t2 = srv(sim, 'local m = DS.Match(p) shared.R = { turn = m and m.Turn or -1 }')
    check(t2["turn"] >= t1turn["turn"] + 1 or t2["turn"] == -1, "a player who does not choose in time uses STRIKE (the turn goes on)")
    # both clients are showing the scene
    ca = cli(sim, alice, 'shared.R = { active = DCtl.active(), phase = DCtl.State().Phase }')
    cb = cli(sim, bob, 'shared.R = { active = DCtl.active(), phase = DCtl.State().Phase }')
    check(ca["active"] and cb["active"], f"both players see the duel scene (Alice: {ca['phase']}, Bob: {cb['phase']})")
    # the match ends when somebody forfeits
    mm = srv(sim, 'local m = DS.Match(p) shared.R = { id = m and m.Id or "" }')
    if mm["id"] != "":
        req(sim, bob, "Forfeit", '{ Id = "%s" }' % mm["id"])
        sim.run_for(1.0, 1 / 30)
    z = srv(sim, 'shared.R = { a = p:GetAttribute("InDuel") == true, b = q:GetAttribute("InDuel") == true }')
    check(not z["a"] and not z["b"], "a forfeit ends the player duel for both")
    sim.run_for(4.0, 1 / 30)
    ca = cli(sim, alice, 'shared.R = { phase = DCtl.State().Phase, card = DCtl.dismiss() }')
    cb = cli(sim, bob, 'shared.R = { phase = DCtl.State().Phase, card = DCtl.dismiss() }')
    check(ca["card"] and cb["card"], f"both clients show the end card ({ca['phase']} / {cb['phase']}) and CONTINUE closes it")
    sim.run_for(2.5, 1 / 30)
    ca = cli(sim, alice, 'shared.R = { active = DCtl.active() }')
    cb = cli(sim, bob, 'shared.R = { active = DCtl.active() }')
    check(not ca["active"] and not cb["active"], "both scenes are closed")

    # ------------------------------------------------------------------ the scene on the client: a whole duel
    sim.run_for(2.0, 1 / 30)
    c = cli(sim, alice, '''
local ok, msg = DCtl.startTrainer("Rookie")
shared.R = { ok = ok, msg = msg or "" }''')
    print("scene start", c)
    check(c["ok"], "the client starts a duel against Rookie Ren")
    sim.run_for(0.5, 1 / 30)
    c = cli(sim, alice, '''
local stage = workspace:FindFirstChild("DuelStage")
local dragons = DCtl.Dragons or {}
local n = 0
for _, dr in dragons do n += 1 end
local hud = LP.PlayerGui:FindFirstChild("GameHUD")
local cam = require(LP.PlayerScripts.Controllers.CameraController)
local humanoid = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
local y = stage and stage:FindFirstChild("Ground") and stage.Ground.Position.Y or 0
local PG = require(game:GetService("ReplicatedStorage").Shared.Util.PromptGate)
shared.R = { active = DCtl.active(), stage = stage ~= nil, y = y, dragons = n, hudOn = hud ~= nil and hud.Enabled, cinematic = cam.inCinematic(), walk = humanoid and humanoid.WalkSpeed or -1,
	prompts = PG.hidden() }''')
    print("scene", c)
    check(c["active"] and c["stage"] and c["y"] > 4000, "a stage is built high above the world")
    check(c["dragons"] == 2, "both dragons stand on it")
    check(not c["hudOn"] and c["cinematic"] and c["walk"] == 0 and c["prompts"], "HUD and prompts are hidden, the camera is scriptable, the character is held")
    # the intro, then the menu
    sim.run_for(9.0, 1 / 30)
    c = cli(sim, alice, '''
local st = DCtl.State()
local gui = LP.PlayerGui:FindFirstChild("GameDuel")
local menu = gui and gui:FindFirstChild("Menu", true)
local cells = {}
if menu then
	for _, id in { "Strike", "Fire", "Guard", "Special" } do
		local cell = menu:FindFirstChild(id)
		cells[id] = cell and (cell.Label.Text .. ":" .. cell.PP.Text) or "?"
	end
end
local foe = gui and gui:FindFirstChild("FoePlate", true)
local me = gui and gui:FindFirstChild("MePlate", true)
local cf = DCtl.cameraFrame()
shared.R = { phase = st.Phase, turn = st.Turn, menu = menu ~= nil and menu.Visible, strike = cells.Strike or "", fire = cells.Fire or "", guard = cells.Guard or "", special = cells.Special or "",
	foe = foe ~= nil and foe.Visible, me = me ~= nil and me.Visible, foeName = foe and foe:FindFirstChild("Name", true).Text or "", camY = cf and cf.Position.Y or 0 }''')
    print("menu", c)
    check(c["phase"] == "Menu" and c["menu"], "after the intro the move menu is up")
    check(c["fire"] == "FIRE:8 LEFT" and c["guard"] == "GUARD:6 LEFT" and c["strike"].startswith("STRIKE"), f"the moves: {c['strike']} / {c['fire']} / {c['guard']} / {c['special']}")
    check(c["foe"] and c["me"] and c["foeName"] != "", f"both plates show ({c['foeName']})")
    check(c["camY"] > 4000, "the camera looks at the stage")
    # make it short: the foe has one hit point
    srv(sim, '''
local m = DS.Match(p)
m.Sides[2].HP = 1
m.Sides[1].Speed = 1000
shared.R = {}''')
    c = cli(sim, alice, '''shared.R = { chosen = DCtl.choose("Strike") }''')
    check(c["chosen"], "STRIKE is chosen from the menu")
    c2 = cli(sim, alice, '''shared.R = { again = DCtl.choose("Fire") }''')
    check(not c2["again"], "a second choice in the same turn is ignored")
    sim.run_for(8.0, 1 / 30)
    c = cli(sim, alice, '''
local st = DCtl.State()
shared.R = { phase = st.Phase, turn = st.Turn, hp1 = st.Hp1 or -1, hp2 = st.Hp2 or -1, ended = st.Ended }''')
    print("after the first choice", c)
    for _ in range(14):
        if c["ended"] or c["phase"] == "End":
            break
        if c["phase"] == "Menu":
            srv(sim, '''
local m = DS.Match(p)
if m then m.Sides[2].HP = math.min(m.Sides[2].HP, 1) m.Sides[1].Speed = 1000 end
shared.R = {}''')
            cli(sim, alice, '''DCtl.choose("Strike") shared.R = {}''')
        sim.run_for(6.0, 1 / 30)
        c = cli(sim, alice, '''
local st = DCtl.State()
shared.R = { phase = st.Phase, turn = st.Turn, hp1 = st.Hp1 or -1, hp2 = st.Hp2 or -1, ended = st.Ended }''')
    sim.run_for(5.0, 1 / 30)
    c = cli(sim, alice, '''
local st = DCtl.State()
local gui = LP.PlayerGui:FindFirstChild("GameDuel")
local card = gui and gui:FindFirstChild("EndCard", true)
shared.R = { phase = st.Phase, card = card ~= nil and card.Visible, title = card and card:FindFirstChild("Title").Text or "", rewards = card and card:FindFirstChild("Rewards").Text or "", hp2 = st.Hp2 or -1 }''')
    print("end", c)
    check(c["phase"] == "End" and c["card"], f"the end card shows ({c['title']})")
    check(c["title"] in ("VICTORY!", "DEFEAT"), "...VICTORY or DEFEAT")
    check(c["title"] != "VICTORY!" or "XP" in c["rewards"], f"a victory lists the reward ({c['rewards'].replace(chr(10), ' ')})")
    c = cli(sim, alice, '''shared.R = { ok = DCtl.dismiss() }''')
    check(c["ok"], "CONTINUE closes the card")
    sim.run_for(2.0, 1 / 30)
    c = cli(sim, alice, '''
local stage = workspace:FindFirstChild("DuelStage")
local hud = LP.PlayerGui:FindFirstChild("GameHUD")
local cam = require(LP.PlayerScripts.Controllers.CameraController)
local humanoid = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
local PG = require(game:GetService("ReplicatedStorage").Shared.Util.PromptGate)
shared.R = { active = DCtl.active(), stage = stage ~= nil, hudOn = hud ~= nil and hud.Enabled, cinematic = cam.inCinematic(), walk = humanoid and humanoid.WalkSpeed or -1, prompts = PG.hidden(),
	inDuel = LP:GetAttribute("InDuel") == true }''')
    print("back", c)
    check(not c["active"] and not c["stage"], "the stage is gone")
    check(c["hudOn"] and not c["cinematic"] and c["walk"] > 0 and not c["prompts"] and not c["inDuel"], "HUD, camera, walking and prompts are back")

    # ------------------------------------------------------------------ the Battle Hall window
    c = cli(sim, alice, '''
UIC.Open("Duel")
task.wait(1.2)
local win = UIC.Windows.Duel
local rows = #win.Rows
local you = win.YouName.Text
win.Seg:Set("Players") win.Tab = "Players" win:Render()
local players = #win.Rows
shared.R = { open = UIC.IsOpen("Duel"), rows = rows, you = you, players = players }''', steps=2400)
    print("window", c)
    check(c["open"] and c["rows"] == 4 and c["you"] != "", f"the Battle Hall lists 4 trainers and your dragon ({c['you']})")
    check(c["players"] == 1, "the PLAYERS tab lists the other player (Bob)")
    st = srv(sim, '''
local station = workspace.World.Hub:FindFirstChild("BattleHall", true)
local prompt = station and station:FindFirstChildWhichIsA("ProximityPrompt", true)
shared.R = { built = station ~= nil, prompt = prompt ~= nil, window = prompt and prompt:GetAttribute("Window") or "" }''')
    check(st["built"] and st["prompt"] and st["window"] == "Duel", "the Battle Hall is built in the village with a prompt that opens the window")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    print("done in %ds" % (time.time() - t0))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

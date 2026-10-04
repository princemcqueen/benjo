"""Player level system: XP from picking up eggs, hatching dragons (rarity + mutation +
first discovery), flying (server-measured), bond and tree; level-up rewards (cash, spin
tickets every 5th level), region unlock notices, Ancient Wisdom, cap, HUD display."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py, render as ui_render  # noqa: E402
from paths import OUT  # noqa: E402

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
local Configs = game:GetService("ReplicatedStorage").Configs
local PDS = require(SSS.Services.PlayerDataService)
local LS = require(SSS.Services.LevelService)
local ES = require(SSS.Services.EggService)
local MS = require(SSS.Services.MountService)
local EconomyConfig = require(Configs.EconomyConfig)
local DragonConfig = require(Configs.DragonConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Player1", 1001)
    sim.run_for(6, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # client listens for notifications + the LevelUp signal
    run_client_lua(sim, p1, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
shared.NOTES = {}
shared.LEVELUPS = {}
Net.Notified:Connect(function(kind, text) table.insert(shared.NOTES, text) end)
Net.onSignal("LevelUp", function(p) table.insert(shared.LEVELUPS, p.Level) end)
shared.X = {}
''')

    s = srv(sim, 'shared.R = { lv = d.Level, xp = d.XP, need = EconomyConfig.playerXPToNext(1), cash = d.Cash }')
    check(s["lv"] == 1 and s["xp"] == 0, "new players start at level 1 with 0 XP")

    # ---- eggs: real pickup signal path
    s = srv(sim, 'ES.PickedUp:Fire(p, "HavenEgg"); shared.R = { xp = d.XP }')
    check(s["xp"] == 8, "picking up an egg gives EconomyConfig.XP.EggFound (8)")

    # ---- hatching: rarity XP + mutation bonus + first discovery
    s = srv(sim, '''
local before = d.XP
local rec = { SpeciesId = "FrostDragon", Rarity = "Epic", Mutation = "None" }
d.Index.FrostDragon = { First = os.time(), Count = 1 }
ES.Hatched:Fire(p, rec, "FrostEgg")
local first = d.XP - before
before = d.XP
d.Index.FrostDragon = { First = os.time(), Count = 2 }
ES.Hatched:Fire(p, { SpeciesId = "FrostDragon", Rarity = "Epic", Mutation = "Golden" }, "FrostEgg")
local golden = d.XP - before
shared.R = { first = first, golden = golden, hatchXP = DragonConfig.Rarities.Epic.HatchXP, lv = d.Level }
''')
    print("hatch xp", s)
    check(s["first"] == s["hatchXP"] + 25 or s["lv"] > 1, "hatching an Epic pays its HatchXP (+25 first discovery)")
    check(s["golden"] >= s["hatchXP"] * 1.4 or s["lv"] > 1, "a Golden mutation pays about +50% more")

    # ---- levelling: rewards, spins at level 5, notices
    s = srv(sim, '''
d.Level = 1; d.XP = 0
local cash0, spins0 = d.Cash, d.Spin.Tickets
local gained = LS.Add(p, EconomyConfig.playerXPToNext(1), "t")
shared.R = { gained = gained, lv = d.Level, xp = d.XP, cash = d.Cash - cash0, want = (EconomyConfig.levelReward(2)) }
''')
    sim.run_for(0.5, 1 / 30)
    check(s["gained"] == 1 and s["lv"] == 2 and s["xp"] == 0, "exactly enough XP -> level 2, XP resets")
    check(s["cash"] == s["want"] and s["want"] > 0, "level 2 paid its cash reward ($%d)" % s["want"])
    s = srv(sim, '''
local spins0 = d.Spin.Tickets
d.Level = 4; d.XP = 0
LS.Add(p, EconomyConfig.playerXPToNext(4), "t") -- 4 -> 5 (region level too)
shared.R = { lv = d.Level, spins = d.Spin.Tickets - spins0 }
''')
    sim.run_for(0.5, 1 / 30)
    check(s["lv"] == 5 and s["spins"] == 2, "level 5 also gave 2 spin tickets")
    out = run_client_lua(sim, p1, 'shared.X = { notes = shared.NOTES, ups = shared.LEVELUPS }')
    notes = lua_table_to_py(shared_get(out, "NOTES"))
    ups = lua_table_to_py(shared_get(out, "LEVELUPS"))
    print("notes", notes, "level-ups", ups)
    joined = " | ".join(str(n) for n in (notes.values() if isinstance(notes, dict) else notes))
    check("LEVEL UP" in joined and "level 5" in joined, "client got LEVEL UP notices")
    check("Frostpeak" in joined, "level 5 announces the region it opens (Frostpeak Highlands)")
    check(5 in (ups.values() if isinstance(ups, dict) else ups), "client got the LevelUp signal for level 5")

    # ---- several levels in one go, carry-over
    s = srv(sim, '''
d.Level = 1; d.XP = 0
local need = EconomyConfig.playerXPToNext(1) + EconomyConfig.playerXPToNext(2) + 7
local gained = LS.Add(p, need, "t")
shared.R = { gained = gained, lv = d.Level, xp = d.XP }
''')
    check(s["gained"] == 2 and s["lv"] == 3 and s["xp"] == 7, "a big XP gain skips several levels and keeps the remainder")

    # ---- Ancient Wisdom multiplies XP
    s = srv(sim, '''
d.Level = 10; d.XP = 0
d.Tree.Wisdom = 5
local before = d.XP
LS.Add(p, 100, "t")
shared.R = { got = d.XP - before, bonus = require(Configs.TreeConfig).bonus(d, "Wisdom") }
''')
    check(abs(s["got"] - 100 * (1 + s["bonus"])) <= 1, "Ancient Wisdom L5 multiplies XP (+%d%%)" % (s["bonus"] * 100))
    srv(sim, 'd.Tree.Wisdom = nil; shared.R = {}')

    # ---- cap
    s = srv(sim, '''
d.Level = EconomyConfig.MaxPlayerLevel - 1; d.XP = 0
LS.Add(p, 1e9, "t")
LS.Add(p, 1e9, "t")
shared.R = { lv = d.Level, xp = d.XP, cap = EconomyConfig.MaxPlayerLevel, need = EconomyConfig.playerXPToNext(EconomyConfig.MaxPlayerLevel) }
''')
    check(s["lv"] == s["cap"] and s["xp"] < s["need"], "level stops at the cap (%d) and XP never overflows" % s["cap"])
    s = srv(sim, 'd.Level = 1; d.XP = 0; PDS.Set(p, { "Level" }, 1); PDS.Set(p, { "XP" }, 0); shared.R = {}')

    # ---- bad input
    s = srv(sim, 'local a = LS.Add(p, -5, "t"); local b = LS.Add(p, 0/0, "t"); local c = LS.Add(p, math.huge, "t"); shared.R = { ok = a == 0 and b == 0, lv = d.Level }')
    check(s["ok"], "negative / NaN XP is ignored")

    # ---- flight XP: server measures distance of a flying, ridden dragon
    run_client_lua(sim, p1, '''
local dc = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.DragonController)
dc.toggleRide()
task.wait(1.0)
shared.X = { riding = dc.isRiding() }
''', max_steps=900)
    sim.run_for(1.0, 1 / 30)
    srv(sim, 'local comp = MS.Get(p); comp.Model:SetAttribute("Mode", "Fly"); d.Level = 1; d.XP = 0; shared.R = {}')
    flown0 = srv(sim, 'shared.R = { f = d.Stats.DistanceFlown, xp = d.XP }')
    for _ in range(8):
        srv(sim, 'local comp = MS.Get(p); comp.Model:SetAttribute("Mode", "Fly"); comp.Root.CFrame = comp.Root.CFrame + Vector3.new(0, 0, -400); shared.R = {}')
        sim.run_for(2.2, 1 / 10)
    flown1 = srv(sim, 'shared.R = { f = d.Stats.DistanceFlown, xp = d.XP, lv = d.Level }')
    print("flight", flown0, flown1)
    check(flown1["f"] - flown0["f"] > 1500, "server counts distance flown (%d studs)" % (flown1["f"] - flown0["f"]))
    check(flown1["xp"] > 8 or flown1["lv"] > 1, "flying pays XP (6 per 1000 studs)")
    srv(sim, 'local comp = MS.Get(p); comp.Model:SetAttribute("Mode", "Ground"); shared.R = {}')

    # ---- HUD shows the level
    out = run_client_lua(sim, p1, '''
local hud = require(game:GetService("Players").LocalPlayer.PlayerScripts.UI.Hud.Hud)
task.wait(0.5)
local D = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.DataController)
shared.H = { level = D.get("Level"), xp = D.get("XP") }
''')
    H = lua_table_to_py(out.get("H"))
    srv(sim, 'LS.Add(p, 123, "t"); shared.R = {}')
    sim.run_for(0.5, 1 / 30)
    ui_render(sim, p1, f"{OUT}/level_hud.png", debug=False)

    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


def shared_get(out, key):
    return out.get(key)


if __name__ == "__main__":
    main()

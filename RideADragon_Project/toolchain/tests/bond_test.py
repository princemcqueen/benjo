"""Dragon Bond: points while riding (and only while moving), levels, perks unlocked at
5 / 10 / 20 / 50, server-validated abilities (dash, fire breath with cooldowns, sky dance),
fire burns Burnable things, aura at level 50, Great Tree bond hooks, HUD bond bar + animations."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
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
local BS = require(SSS.Services.BondService)
local MS = require(SSS.Services.MountService)
local BondConfig = require(Configs.BondConfig)
local TreeConfig = require(Configs.TreeConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
local uid = d.EquippedDragon
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def act(sim, player, action):
    run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
Net.fire("BondAction", {{ Action = "{action}" }})
shared.X = {{}}
''')
    sim.run_for(0.4, 1 / 30)


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Player1", 1001)
    sim.run_for(6, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ---- config
    c = srv(sim, '''
shared.R = { l0 = BondConfig.levelFor(0), l5 = BondConfig.levelFor(BondConfig.threshold(5)), l49 = BondConfig.levelFor(BondConfig.threshold(50) - 1),
	l50 = BondConfig.levelFor(1e9), dash = BondConfig.has(BondConfig.threshold(5), "Dash"), notyet = BondConfig.has(BondConfig.threshold(5) - 1, "Dash"),
	fire = BondConfig.PerkById.Fire.Level, dance = BondConfig.PerkById.Flourish.Level, aura = BondConfig.PerkById.Aura.Level }
''')
    check(c["l0"] == 0 and c["l5"] == 5 and c["l49"] == 49 and c["l50"] == 50, "bond levels follow the points (0..50)")
    check(c["dash"] and not c["notyet"], "Wind Dash unlocks exactly at level 5")
    check(c["fire"] == 10 and c["dance"] == 20 and c["aura"] == 50, "perk levels: fire 10, dance 20, aura 50")

    # ---- riding earns bond; standing still does not
    run_client_lua(sim, p1, '''
local dc = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.DragonController)
dc.toggleRide()
task.wait(1.0)
shared.X = { riding = dc.isRiding() }
''', max_steps=900)
    sim.run_for(1.0, 1 / 30)
    r = srv(sim, 'local comp = MS.Get(p); shared.R = { riding = comp ~= nil and comp.Riding, pts = BS.Points(p, uid), uid = uid }')
    check(r["riding"], "player is riding the equipped dragon")
    p0 = r["pts"]
    sim.run_for(12, 1 / 10)  # standing still on the dragon
    r = srv(sim, 'shared.R = { pts = BS.Points(p, uid) }')
    check(r["pts"] == p0, "no bond points while the dragon is not moving (anti-AFK)")
    # move the dragon root between ticks
    for i in range(6):
        srv(sim, 'local comp = MS.Get(p); comp.Root.CFrame = comp.Root.CFrame + Vector3.new(30, 0, 0); shared.R = {}')
        sim.run_for(5.2, 1 / 10)
    r = srv(sim, 'shared.R = { pts = BS.Points(p, uid) }')
    print("points after moving", r)
    check(r["pts"] > p0 + 5, "bond points grow while riding and moving (%.1f)" % r["pts"])

    # ---- level ups notify and unlock
    srv(sim, 'BS.AddPoints(p, uid, BondConfig.threshold(5) - BS.Points(p, uid)); shared.R = {}')
    sim.run_for(0.5, 1 / 30)
    r = srv(sim, 'shared.R = { lvl = BS.Level(p, uid), dash = BS.Has(p, "Dash"), fire = BS.Has(p, "Fire") }')
    check(r["lvl"] == 5 and r["dash"] and not r["fire"], "level 5: dash unlocked, fire not yet")

    # ---- locked abilities are refused by the server
    act(sim, p1, "FireStart")
    r = srv(sim, 'local m = MS.GetModel(p); shared.R = { b = m:GetAttribute("Breathing") }')
    check(r["b"] is False, "fire breath refused below level 10")

    # ---- dash: unlocked, shot replicated, cooldown enforced
    s0 = srv(sim, 'local m = MS.GetModel(p); shared.R = { id = m:GetAttribute("ShotId") or 0 }')["id"]
    act(sim, p1, "Dash")
    s1 = srv(sim, 'local m = MS.GetModel(p); shared.R = { id = m:GetAttribute("ShotId") or 0, shot = m:GetAttribute("Shot") }')
    check(s1["id"] == s0 + 1 and s1["shot"] == "Dash", "Dash replicates as a shot to other players")
    act(sim, p1, "Dash")
    s2 = srv(sim, 'local m = MS.GetModel(p); shared.R = { id = m:GetAttribute("ShotId") or 0 }')
    check(s2["id"] == s1["id"], "second dash during the cooldown is ignored")

    # ---- fire breath (level 10)
    srv(sim, 'BS.AddPoints(p, uid, BondConfig.threshold(10) - BS.Points(p, uid)); shared.R = {}')
    sim.run_for(0.3, 1 / 30)
    # a burnable bramble right in front of the dragon
    srv(sim, '''
local comp = MS.Get(p)
local f = Instance.new("Part")
f.Name = "TestBramble"
f.Anchored = true
f.Size = Vector3.new(6, 6, 6)
f.CFrame = comp.Root.CFrame * CFrame.new(0, 0, -22)
f:SetAttribute("Reward", 250)
f:SetAttribute("RespawnSeconds", 5)
f.Parent = workspace
game:GetService("CollectionService"):AddTag(f, "Burnable")
shared.R = {}
''')
    cash0 = srv(sim, 'shared.R = { c = d.Cash }')["c"]
    act(sim, p1, "FireStart")
    r = srv(sim, 'local m = MS.GetModel(p); shared.R = { b = m:GetAttribute("Breathing") }')
    check(r["b"] is True, "fire breath starts at level 10 (attribute replicates to everyone)")
    sim.run_for(3.0, 1 / 20)
    r = srv(sim, 'local f = workspace.TestBramble; shared.R = { burned = f:GetAttribute("Burning"), tr = f.Transparency, cash = d.Cash }')
    check(r["burned"] and r["tr"] == 1, "the flames burnt the Burnable bramble away")
    check(r["cash"] - cash0 >= 250, "burning it paid its reward (+$250)")
    sim.run_for(3.0, 1 / 20)
    r = srv(sim, 'local m = MS.GetModel(p); shared.R = { b = m:GetAttribute("Breathing") }')
    check(r["b"] is False, "the breath ends on its own after the maximum duration")
    sim.run_for(6.0, 1 / 20)
    r = srv(sim, 'local f = workspace.TestBramble; shared.R = { tr = f.Transparency, burning = f:GetAttribute("Burning") }')
    check(r["tr"] == 0 and not r.get("burning"), "the bramble grows back after its respawn time")

    # ---- sky dance (level 20) and aura (level 50)
    act(sim, p1, "Flourish")
    r = srv(sim, 'local m = MS.GetModel(p); shared.R = { shot = m:GetAttribute("Shot") }')
    check(r["shot"] != "Flourish", "Sky Dance refused below level 20")
    srv(sim, 'BS.AddPoints(p, uid, BondConfig.threshold(20) - BS.Points(p, uid)); shared.R = {}')
    sim.run_for(0.3, 1 / 30)
    act(sim, p1, "Flourish")
    r = srv(sim, 'local m = MS.GetModel(p); shared.R = { shot = m:GetAttribute("Shot"), lvl = m:GetAttribute("BondLevel"), rev = m:GetAttribute("VisualRev") }')
    check(r["shot"] == "Flourish" and r["lvl"] == 20, "Sky Dance unlocked at level 20")
    rev0 = r["rev"]
    srv(sim, 'BS.AddPoints(p, uid, BondConfig.threshold(50) - BS.Points(p, uid)); shared.R = {}')
    sim.run_for(0.5, 1 / 30)
    r = srv(sim, 'local m = MS.GetModel(p); shared.R = { lvl = m:GetAttribute("BondLevel"), rev = m:GetAttribute("VisualRev") }')
    check(r["lvl"] == 50 and r["rev"] == rev0 + 1, "level 50: BondLevel attribute set and the visual rebuilt for the aura")
    aura = run_client_lua(sim, p1, '''
local m = workspace.Dragons:FindFirstChild("Dragon_" .. game:GetService("Players").LocalPlayer.UserId)
task.wait(0.5)
local n, light = 0, false
for _, d in m:GetDescendants() do
	if d.Name == "BondAura" then n += 1 end
	if d.Name == "BondGlow" then light = true end
end
shared.A = { n = n, light = light }
''')
    A = lua_table_to_py(aura.get("A"))
    check(A["n"] >= 3 and A["light"], "Bond Aura: %s emitters + glow on the dragon at level 50" % A["n"])

    # ---- Great Tree bond hooks
    srv(sim, 'PDS.Set(p, { "Cash" }, 1e12); shared.R = {}')
    for _ in range(3):
        run_client_lua(sim, p1, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
Net.request("Tree", "Buy", { Id = "QuickFeathers" })
Net.request("Tree", "Buy", { Id = "Dragonfire" })
shared.X = {}
''')
        sim.run_for(1.5, 1 / 20)
    r = srv(sim, 'shared.R = { qf = TreeConfig.bonus(d, "QuickFeathers"), df = TreeConfig.bonus(d, "Dragonfire") }')
    check(r["qf"] > 0 and r["df"] > 0, "Quick Feathers and Dragonfire bought (-%d%% wait, +%d%% range)" % (r["qf"] * 100, r["df"] * 100))

    # ---- client: info + HUD bond bar
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local bc = require(lp.PlayerScripts.Controllers.BondController)
task.wait(0.6)
local info = bc.info()
local uic = require(lp.PlayerScripts.Controllers.UIController)
local hud = require(lp.PlayerScripts.UI.Hud.Hud)
shared.I = { level = info.Level, dash = info.Unlocked.Dash, fire = info.Unlocked.Fire, dance = info.Unlocked.Flourish, aura = info.Unlocked.Aura,
	hasNext = info.NextPerk ~= nil }
''', max_steps=900)
    I = lua_table_to_py(out.get("I"))
    check(I["level"] == 50 and I["dash"] and I["fire"] and I["dance"] and I["aura"], "client sees bond level 50 with every perk unlocked")
    check(not I["hasNext"], "no next perk after level 50")
    # ---- client input: Dash surges the dragon, Fire shows flames and tells the server
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local ctrl = lp.PlayerScripts.Controllers
local dc = require(ctrl.DragonController)
local input = require(ctrl.InputController)
local BreathFX = require(game:GetService("ReplicatedStorage").Shared.Dragons.BreathFX)
local bc = require(ctrl.BondController)
task.wait(6.5) -- let every cooldown run out
local st = dc.getState()
local before = st.DashLeft or 0
input.Pressed:Fire("Dash")
task.wait(0.05)
local dashing = (dc.getState().DashLeft or 0) > 0
local dashCd = bc.cooldown("Dash") -- (the simulator's os.clock is wall time, so read it right away)
task.wait(1.0)
-- fire: held key
input.setVirtual("Fire", true)
input.Pressed:Fire("Fire")
task.wait(0.4)
local model = dc.getModel()
local flamesOn = BreathFX.isOn(model)
local flames = 0
for _, d in model:GetDescendants() do
	if d:IsA("ParticleEmitter") and d.Parent.Name == "BreathFX" then flames += 1 end
end
local serverFlag = model:GetAttribute("Breathing")
input.setVirtual("Fire", false)
task.wait(0.6)
shared.F = { before = before, dashing = dashing, dashCd = dashCd, flamesOn = flamesOn, flames = flames, serverFlag = serverFlag, stopped = not BreathFX.isOn(model) }
''', max_steps=2400)
    F = lua_table_to_py(out.get("F"))
    print("client input", F)
    check(F["dashing"], "pressing Dash starts a dash in Locomotion")
    check(F["dashCd"] > 0, "dash cooldown is running on the client")
    check(F["flamesOn"] and F["flames"] >= 3, "pressing Fire shows flames (flame, sparks, smoke emitters)")
    check(F["serverFlag"] is True, "the server confirmed the breath (Breathing attribute)")
    check(F["stopped"], "releasing Fire puts the flames out")
    ui_render(sim, p1, f"{OUT}/bond_hud.png", debug=False)

    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()

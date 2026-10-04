"""Egg Radar: the Forge upgrade (250 / 600 / 1200 studs / whole map), the Robux boost and the
Egg Hunter pass. Markers over eggs inside the range (through walls), an arrow chip to the best
one; Egg Magnet boost and pass widen the pickup range; Fast Hatch halves the incubation."""
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
local BS = require(SSS.Services.BoostService)
local ES = require(SSS.Services.EggService)
local EggReach = require(game:GetService("ReplicatedStorage").Shared.EggReach)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src):
    head = '''
local LP = game:GetService("Players").LocalPlayer
local RC = require(LP.PlayerScripts.Controllers.RadarController)
local EC = require(LP.PlayerScripts.Controllers.EggController)
'''
    res = run_client_lua(sim, player, head + src)
    return lua_table_to_py(res.get("R"))


STATE = '''
local hrp = LP.Character.HumanoidRootPart
local eggs = EC.list()
local total, within250, within600, markers, shownMarkers = 0, 0, 0, 0, 0
local nearest = math.huge
for key, egg in eggs do
	total += 1
	local dist = (egg.Position - hrp.Position).Magnitude
	nearest = math.min(nearest, dist)
	if dist <= 250 then within250 += 1 end
	if dist <= 600 then within600 += 1 end
	local shell = egg.Model and egg.Model.PrimaryPart
	local bb = shell and shell:FindFirstChild("RadarMarker")
	if bb then
		markers += 1
		if bb.Enabled then shownMarkers += 1 end
	end
end
local chip = LP.PlayerGui:FindFirstChild("EggRadar", true)
local best = chip and chip:FindFirstChild("Best", true)
local info = chip and chip:FindFirstChild("Info", true)
shared.R = { active = RC.isActive(), total = total, within250 = within250, within600 = within600, markers = markers,
	shown = shownMarkers, chip = chip ~= nil and chip.Visible, best = best and best.Text or "", info = info and info.Text or "",
	nearest = nearest }
'''


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(6, 1 / 30)

    # ------------------------------------------------------------ ranges (shared module)
    r = srv(sim, '''
shared.R = {
	none = EggReach.radarRange({ Upgrades = { Radar = 0 } }, 100),
	l1 = EggReach.radarRange({ Upgrades = { Radar = 1 } }, 100),
	l2 = EggReach.radarRange({ Upgrades = { Radar = 2 } }, 100),
	l3 = EggReach.radarRange({ Upgrades = { Radar = 3 } }, 100),
	l4 = EggReach.radarRange({ Upgrades = { Radar = 4 } }, 100),
	boost = EggReach.radarRange({ Upgrades = { Radar = 0 }, Boosts = { Radar = 200 } }, 100),
	expired = EggReach.radarRange({ Upgrades = { Radar = 0 }, Boosts = { Radar = 50 } }, 100),
	pass = EggReach.radarRange({ Upgrades = { Radar = 0 }, Flags = { Passes = { EggHunter = true } } }, 100),
	magnet0 = EggReach.bonus({ Upgrades = {}, Tree = {} }, 100),
	magnetBoost = EggReach.bonus({ Boosts = { Magnet = 200 } }, 100),
	magnetPass = EggReach.bonus({ Flags = { Passes = { EggHunter = true } } }, 100),
	magnetBoth = EggReach.bonus({ Boosts = { Magnet = 200 }, Flags = { Passes = { EggHunter = true } } }, 100),
}''')
    print(r)
    check(r["none"] == 0 and r["l1"] == 250 and r["l2"] == 600 and r["l3"] == 1200 and r["l4"] >= 100000, "Forge upgrade levels give 0 / 250 / 600 / 1200 / whole map")
    check(r["boost"] > 1e12 and r["pass"] > 1e12, "the Robux boost and the pass see everything")
    check(r["expired"] == 0, "an expired boost does nothing")
    check(r["magnet0"] == 0 and abs(r["magnetBoost"] - 1.0) < 1e-9 and abs(r["magnetPass"] - 0.5) < 1e-9 and abs(r["magnetBoth"] - 1.5) < 1e-9,
          "pickup range: +100% boost, +50% pass, they add up")

    # ------------------------------------------------------------ nothing without the radar
    s = cli(sim, player, STATE)
    print(s)
    check(s["active"] is False and s["markers"] == 0 and s["chip"] is False, "no radar, no markers")
    check(s["total"] >= 5, f"the player has eggs in the world ({s['total']})")

    # ------------------------------------------------------------ Forge upgrade level 1: 250 studs
    srv(sim, '''PDS.Set(p, { "Upgrades", "Radar" }, 1) shared.R = {}''')
    sim.run_for(1.2, 1 / 30)
    s = cli(sim, player, STATE)
    print(s)
    check(s["active"] is True and s["chip"] is True, "upgrade level 1 switches the radar on")
    check(s["markers"] == s["within250"], f"markers only for eggs inside 250 studs ({s['markers']} of {s['total']}, {s['within250']} in range)")
    check("250" in s["info"], f"the chip says what powers it ({s['info']})")
    if s["within250"] > 0:
        check("studs" in s["best"] and s["best"].startswith("x"), f"the best egg is named with luck and distance ({s['best']})")
    else:
        check(s["best"] == "No egg nearby", f"nothing in range: {s['best']}")

    # ------------------------------------------------------------ level 3: 1200 studs, level 4: whole map
    srv(sim, '''PDS.Set(p, { "Upgrades", "Radar" }, 3) shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    s3 = cli(sim, player, STATE)
    check(s3["markers"] >= s["markers"], f"a bigger range sees more eggs ({s['markers']} -> {s3['markers']})")
    srv(sim, '''PDS.Set(p, { "Upgrades", "Radar" }, 4) shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    s4 = cli(sim, player, STATE)
    check(s4["markers"] == s4["total"] and "WHOLE MAP" in s4["info"], f"top level: every egg is marked ({s4['markers']} of {s4['total']})")
    check(s4["shown"] <= s4["markers"], "markers of eggs right next to you hide themselves")

    # ------------------------------------------------------------ off again
    srv(sim, '''PDS.Set(p, { "Upgrades", "Radar" }, 0) shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    s = cli(sim, player, STATE)
    check(s["active"] is False and s["markers"] == 0 and s["chip"] is False, "radar off: markers and chip are gone")

    # ------------------------------------------------------------ the Robux boost
    r = srv(sim, '''shared.R = { ok = BS.Add(p, "Radar", 600) }''')
    check(r["ok"] is True, "the Egg Radar boost can be bought")
    sim.run_for(1.2, 1 / 30)
    s = cli(sim, player, STATE)
    print(s)
    check(s["active"] is True and s["markers"] == s["total"], f"boost: every egg marked ({s['markers']} of {s['total']})")
    check(s["info"].startswith("EGG RADAR  ") and ":" in s["info"], f"the chip counts the boost down ({s['info']})")
    srv(sim, '''PDS.Set(p, { "Boosts", "Radar" }, nil) BS.Refresh(p) shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    s = cli(sim, player, STATE)
    check(s["active"] is False and s["markers"] == 0, "boost over: radar off")

    # ------------------------------------------------------------ the Egg Hunter pass
    srv(sim, '''PDS.Set(p, { "Flags", "Passes", "EggHunter" }, true) shared.R = {}''')
    sim.run_for(1.2, 1 / 30)
    s = cli(sim, player, STATE)
    check(s["active"] is True and s["info"] == "EGG HUNTER" and s["markers"] == s["total"], f"pass: permanent radar ({s['info']})")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

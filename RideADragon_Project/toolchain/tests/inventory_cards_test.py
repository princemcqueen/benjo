"""The 3D previews of the dragon cards (InventoryWindow): every visible card gets its model even while the
cash changes every half second (it used to rebuild and re-bind every card on each cash tick, so the cards
stayed on the grey placeholder icon), models are cloned from a per-look cache, and a relayout keeps them."""
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
local PDS = require(SSS.Services.PlayerDataService)
local DS = require(SSS.Services.DragonService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


CLIENT_COUNT = '''
local LP = game:GetService("Players").LocalPlayer
local UIC = require(LP.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
local bound, built, placeholders = 0, 0, 0
for _, card in w.Cards do
	bound += 1
	if card.Model then built += 1 end
	if card.Placeholder.Visible then placeholders += 1 end
end
shared.R = { bound = bound, built = built, placeholders = placeholders, pool = #w.Pool }
'''


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Alice", 7001)
    sim.run_for(8, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    srv(sim, '''
PDS.Set(p, { "Upgrades", "DragonStorage" }, 2)
local species = { "GreenDrake", "ForestWyvern", "AquaSerpent", "CrystalWyvern", "FrostDragon", "InfernoDragon" }
for i = 1, 24 do DS.Add(p, species[i % 6 + 1], (i % 5 == 0) and "Shiny" or "None", "Test") end
shared.R = {}''')
    run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
UIC.Open("Inventory")
shared.R = {}''')
    # the cash changes twice a second (like the income tick) the whole time
    t_ok = None
    for i in range(24):
        srv(sim, 'PDS.Increment(p, { "Cash" }, 7) shared.R = {}')
        sim.run_for(0.5, 1 / 30)
        c = lua_table_to_py(run_client_lua(sim, player, CLIENT_COUNT).get("R"))
        if c["bound"] > 0 and c["built"] == c["bound"] and t_ok is None:
            t_ok = (i + 1) * 0.5
            break
    print("cards", c, "all built after", t_ok, "s")
    check(c["bound"] >= 8, f"{c['bound']:.0f} cards are on screen")
    check(c["built"] == c["bound"] and c["placeholders"] == 0, f"every visible card shows its 3D model while the cash ticks ({c['built']:.0f} of {c['bound']:.0f}, after {t_ok}s)")

    # the cash keeps ticking and the models stay (no rebuild, no placeholder coming back)
    for _ in range(8):
        srv(sim, 'PDS.Increment(p, { "Cash" }, 7) shared.R = {}')
        sim.run_for(0.5, 1 / 30)
    c2 = lua_table_to_py(run_client_lua(sim, player, CLIENT_COUNT).get("R"))
    check(c2["built"] == c2["bound"] and c2["placeholders"] == 0, f"4 more seconds of cash ticks change nothing ({c2['built']:.0f} / {c2['bound']:.0f} built)")

    # a relayout (window resize) keeps the models
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
local before = {}
for i, card in w.Cards do before[i] = card.Model end
w:Relayout()
local same, total = 0, 0
for i, card in w.Cards do
	total += 1
	if before[i] ~= nil and card.Model == before[i] then same += 1 end
end
shared.R = { same = same, total = total }''')
    r = lua_table_to_py(res.get("R"))
    check(r["total"] > 0 and r["same"] == r["total"], f"a relayout keeps every card's model ({r['same']:.0f} of {r['total']:.0f})")

    # sorting reshuffles the cards: pooled cards that already show a look are reused for it
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
w.Query.Sort = "Name"
w:Rebuild(true)
task.wait(1.5)
local bound, built = 0, 0
for _, card in w.Cards do bound += 1 if card.Model then built += 1 end end
shared.R = { bound = bound, built = built }''')
    r = lua_table_to_py(res.get("R"))
    check(r["bound"] > 0 and r["built"] == r["bound"], f"after a new sort every card has its model again ({r['built']:.0f} of {r['bound']:.0f})")

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    check(len(sim.errors) == 0, "no script errors")
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")
    print("ALL OK" if not FAIL else "SOME FAILED")


if __name__ == "__main__":
    main()

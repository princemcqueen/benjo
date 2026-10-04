"""Dragon Index (collection book): the window (cards for every species, found / missing, mutation
counts, the detail panel), the milestone rewards paid by IndexService and the numbers in IndexConfig."""
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
local BS = require(SSS.Services.BoostService)
local IC = require(RS.Configs.IndexConfig)
local DragonConfig = require(RS.Configs.DragonConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def claim(sim, player, count):
    sim.run_for(1.5, 1 / 30)
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Index", "Claim", {{ Count = {count} }})
shared.RQ = {{ ok = r.ok, err = r.err or "", cash = r.data and r.data.Cash or 0, spins = r.data and r.data.Spins or 0 }}''')
    return lua_table_to_py(res.get("RQ"))


def discover(sim, n):
    """Marks the first n collectable species as found (and gives the first one some mutations)."""
    srv(sim, f'''
local list = IC.collectable()
local idx = {{}}
for i = 1, {n} do idx[list[i]] = {{ First = os.time() - 86400, Count = i }} end
if {n} >= 1 then
	for _, m in {{ "Shiny", "Neon", "Golden" }} do idx[list[1] .. ":" .. m] = {{ First = os.time(), Count = 1 }} end
end
PDS.Set(p, {{ "Index" }}, idx)
shared.R = {{}}''')


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 6001)
    sim.run_for(8, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    s = srv(sim, '''
local m = IC.milestones()
local counts = {}
for _, x in m do table.insert(counts, x.Count) end
shared.R = { total = #IC.collectable(), ex = #IC.exclusives(), muts = #IC.mutations(), all = #DragonConfig.speciesList(), counts = table.concat(counts, ","),
	last = m[#m].Count }''')
    print("config", s)
    check(s["total"] == 30 and s["ex"] == 4 and s["total"] + s["ex"] == s["all"], f"{s['total']:.0f} collectable species + {s['ex']:.0f} Robux exclusives")
    check(s["muts"] == 16, f"{s['muts']:.0f} mutations to collect per species (not Normal, not Omni)")
    check(s["counts"] == "5,10,15,20,25,30" and s["last"] == s["total"], f"milestones {s['counts']}: the last is the whole collection")

    # ---------------------------------------------------------------- no dragons found yet: cannot claim
    srv(sim, '''PDS.Set(p, { "Index" }, {}) shared.R = {}''')
    r = claim(sim, alice, 5)
    check(not r["ok"] and r["err"] == "NOT_ENOUGH", f"nothing found: milestone 5 is refused ({r['err']})")
    r = claim(sim, alice, 7)
    check(not r["ok"] and r["err"] == "NO_SUCH_MILESTONE", "a number that is not a milestone is refused")

    # ---------------------------------------------------------------- 5 found: cash
    discover(sim, 5)
    before = srv(sim, 'shared.R = { cash = d.Cash, spins = d.Spin.Tickets, eggs = #d.Eggs }')
    r = claim(sim, alice, 5)
    after = srv(sim, 'shared.R = { cash = d.Cash, spins = d.Spin.Tickets, eggs = #d.Eggs, claimed = d.IndexClaims["5"] == true }')
    check(r["ok"] and r["cash"] >= 5000 and after["cash"] - before["cash"] >= r["cash"] and after["claimed"], f"5 dragons: ${r['cash']:.0f} paid and recorded")
    r = claim(sim, alice, 5)
    check(not r["ok"] and r["err"] == "ALREADY_CLAIMED", "the same milestone cannot be taken twice")
    r = claim(sim, alice, 10)
    check(not r["ok"] and r["err"] == "NOT_ENOUGH", "10 is not reachable with 5 found")

    # ---------------------------------------------------------------- 10: spins, 15: cash + boost, 20: egg
    discover(sim, 10)
    r = claim(sim, alice, 10)
    after2 = srv(sim, 'shared.R = { spins = d.Spin.Tickets }')
    check(r["ok"] and after2["spins"] == after["spins"] + 5, f"10 dragons: 5 spin tickets ({after['spins']:.0f} -> {after2['spins']:.0f})")
    discover(sim, 15)
    r = claim(sim, alice, 15)
    b = srv(sim, 'shared.R = { luck = BS.Remaining(p, "Luck") }')
    check(r["ok"] and r["cash"] >= 25000 and b["luck"] > 800, f"15 dragons: ${r['cash']:.0f} and a 15 minute luck boost ({b['luck']:.0f} s)")
    discover(sim, 20)
    r = claim(sim, alice, 20)
    e = srv(sim, '''
local n = 0
for _, egg in d.Eggs do if egg.Type == "GoldenEgg" and egg.Luck == 10 then n += 1 end end
shared.R = { golden = n }''')
    check(r["ok"] and e["golden"] == 1, "20 dragons: a Golden Egg (x10 luck) in the bag")
    discover(sim, 30)
    r = claim(sim, alice, 25)
    check(r["ok"] and r["cash"] >= 100000 and r["spins"] == 10, f"25 dragons: ${r['cash']:.0f} and 10 spins")
    r = claim(sim, alice, 30)
    e = srv(sim, '''
local n = 0
for _, egg in d.Eggs do if egg.Type == "RainbowEgg" and egg.Luck == 50 then n += 1 end end
shared.R = { rainbow = n }''')
    check(r["ok"] and e["rainbow"] == 1 and r["cash"] >= 500000, f"the whole collection: ${r['cash']:.0f} and a Rainbow Egg (x50)")

    # ---------------------------------------------------------------- the window
    discover(sim, 12)
    srv(sim, '''PDS.Set(p, { "IndexClaims" }, { ["5"] = true }) shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    c = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
ui.Open("Index")
task.wait(1.5)
local win = ui.Windows.Index
local cards, foundCards, qCards, names = 0, 0, 0, {}
for id, view in win.Cards do
	cards += 1
	if view.Found then foundCards += 1 end
	if view.Mark.Visible then qCards += 1 end
	if view.Found and #names < 3 then table.insert(names, view.Name.Text) end
end
local ready, claimed = 0, 0
for count, view in win.MileCards do
	if view.State.Text == "CLAIMED" then claimed += 1 end
	if view.State.Text == "CLAIM!" then ready += 1 end
end
local previews = 0
for _, view in win.Cards do if view.Viewport then previews += 1 end end
shared.R = { open = ui.IsOpen("Index"), cards = cards, found = foundCards, question = qCards, count = win.CountText.Text, muts = win.MutText.Text,
	ready = ready, claimed = claimed, previews = previews, sample = table.concat(names, ",") }''', max_steps=2400)
    c = lua_table_to_py(c.get("R"))
    print("window", c)
    check(c["open"] and c["cards"] == 34, f"the book opens with a card for every species ({c['cards']:.0f})")
    check(c["found"] == 12 and c["count"] == "12 / 30", f"12 found: '{c['count']}'")
    check(c["question"] >= 18, f"the missing ones are '?' ({c['question']:.0f})")
    check(c["previews"] == 12, f"every found dragon has a 3D preview ({c['previews']:.0f})")
    check(c["claimed"] == 1 and c["ready"] == 1, f"milestones: {c['claimed']:.0f} claimed, {c['ready']:.0f} ready (10 is open, 5 is taken)")
    check("3 MUTATIONS" in c["muts"], f"mutation counter ({c['muts']})")

    # filter and detail
    c = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
local win = ui.Windows.Index
win.Seg:Set("Found") win.Filter = "Found" win:ApplyFilter()
local shown = 0
for _, view in win.Cards do if view.Card.Visible then shown += 1 end end
win.Seg:Set("Missing") win.Filter = "Missing" win:ApplyFilter()
local missing = 0
for _, view in win.Cards do if view.Card.Visible then missing += 1 end end
win.Seg:Set("All") win.Filter = "All" win:ApplyFilter()
local list = require(game:GetService("ReplicatedStorage").Configs.IndexConfig).collectable()
win:OpenDetail(list[1])
task.wait(1.0)
local opened = win.DetailOpen
local title = win.DetailName.Text
local sub = win.DetailSub.Text
local seen = 0
for _, chip in win.MutChips do if chip.Label.Text ~= "???" then seen += 1 end end
local hasView = win.DetailView.Viewport ~= nil
local backClosed = win.OnBack()
win:OpenDetail(list[25])
local missingTitle = win.DetailName.Text
win:CloseDetail()
shared.R = { shown = shown, missing = missing, opened = opened, title = title, sub = sub, seen = seen, hasView = hasView, backClosed = backClosed, afterBack = win.DetailOpen, missingTitle = missingTitle }''', max_steps=2400)
    c = lua_table_to_py(c.get("R"))
    print("filter / detail", c)
    check(c["shown"] == 12 and c["missing"] == 22, f"filters: FOUND shows {c['shown']:.0f}, MISSING shows {c['missing']:.0f} (22 = 18 + 4 exclusives)")
    check(c["opened"] and c["title"] != "???" and "FOUND" in c["sub"], f"the detail of a found dragon: {c['title']} ({c['sub']})")
    check(c["seen"] == 3 and c["hasView"], "its 3 found mutations are named, with a big 3D preview")
    check(c["backClosed"] is True and c["afterBack"] is False, "the back button closes the detail first")
    check(c["missingTitle"] == "???", "a missing dragon shows '???'")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    print("done in %ds" % (time.time() - t0))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

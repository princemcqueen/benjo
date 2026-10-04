"""Great Tree v2: LEGO tree in the plaza (5 pods x 5 fruit orbs + prompt), 20 branches in 5
categories (~190 levels), server-authoritative purchases (order, price, max), the bonuses
applied where they matter (luck, income, flight/run speed, boost, hatch speed, egg bag,
offline, XP, refund...), orbs light up per category, TreeWindow UI with tabs."""
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
local PDS = require(SSS.Services.PlayerDataService)
local BS = require(SSS.Services.BoostService)
local TS = require(SSS.Services.TreeService)
local ES = require(SSS.Services.EconomyService)
local MS = require(SSS.Services.MountService)
local Configs = game:GetService("ReplicatedStorage").Configs
local TreeConfig = require(Configs.TreeConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, domain, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", data = r.data }}
''')
    return lua_table_to_py(res.get("RQ"))


def buy(sim, player, branch):
    """Tree purchase followed by a short pause (the server rate-limits rapid requests)."""
    r = req(sim, player, "Tree", "Buy", '{ Id = "%s" }' % branch)
    sim.run_for(0.5, 1 / 30)
    return r


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Player1", 1001)
    sim.run_for(5, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ---- world: the Great Tree stands in the plaza
    w = srv(sim, '''
local CS = game:GetService("CollectionService")
local tree = workspace.World.Hub:FindFirstChild("GreatTree")
local n = 0
if tree then for _, x in tree:GetDescendants() do if x:IsA("BasePart") then n += 1 end end end
local prompt = tree and tree:FindFirstChild("StationPrompt", true)
local orbs = {}
for _, o in CS:GetTagged("TreeOrb") do orbs[#orbs + 1] = o:GetAttribute("Category") .. o:GetAttribute("Level") end
local pos = tree and tree:GetPivot().Position
shared.R = { built = tree ~= nil, parts = n, window = prompt and prompt:GetAttribute("Window") or "", orbs = #orbs,
	x = pos and pos.X or 0, z = pos and pos.Z or 0 }
''')
    print("tree", w)
    check(w["built"] and w["parts"] > 150, "Great Tree built in the plaza (%s parts)" % w["parts"])
    check(w["window"] == "Tree", "tree prompt opens the Tree window")
    check(w["orbs"] == 25, "25 fruit orbs (5 branches x 5 levels)")
    check(w["x"] > 20 and w["z"] < -5, "tree stands north-east of the statue")

    # ---- purchases are server-authoritative
    r = buy(sim, p1, "RollLuck")
    check(not r["ok"] and r["err"] == "NO_CASH", "cannot buy without cash (%s)" % r["err"])
    r = req(sim, p1, "Tree", "Buy", '{ Id = "Nope" }')
    check(not r["ok"] and r["err"] == "BAD_BRANCH", "unknown branch rejected")
    r = req(sim, p1, "Tree", "Buy", '{ Id = 5 }')
    check(not r["ok"] and r["err"] == "BAD_REQUEST", "bad payload rejected")
    srv(sim, 'PDS.Set(p, { "Cash" }, 1e12); shared.R = {}')
    base = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), coins = BS.Multiplier(p, "Coins"), fly = TS.Bonus(p, "FlySpeed") }')
    check(base["luck"] == 1 and base["coins"] == 1 and base["fly"] == 0, "no bonuses before buying")

    # luck
    r = buy(sim, p1, "RollLuck")
    check(r["ok"] and r["data"]["Level"] == 1, "Roll Luck level 1 bought")
    s = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), attr = p:GetAttribute("Luck"), cash = d.Cash, b = TreeConfig.ById.RollLuck.Levels[1].Bonus }')
    check(abs(s["luck"] - (1 + s["b"])) < 1e-6 and abs(s["attr"] - (1 + s["b"])) < 1e-6, "Roll Luck L1 -> luck x%.3f (HUD attribute too)" % (1 + s["b"]))
    price1 = srv(sim, 'shared.R = { p = TreeConfig.ById.RollLuck.Levels[1].Price }')["p"]
    check(abs(s["cash"] - (1e12 - price1)) < 1, "price taken from TreeConfig ($%d)" % price1)
    for _ in range(11):
        r = buy(sim, p1, "RollLuck")
    s = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), lvl = TS.Level(p, "RollLuck"), n = #TreeConfig.ById.RollLuck.Levels }')
    check(s["lvl"] == 12 == s["n"] and abs(s["luck"] - 3.0) < 1e-6, "Roll Luck maxes at level 12 -> x3.0")
    r = buy(sim, p1, "RollLuck")
    check(not r["ok"] and r["err"] == "MAXED", "no level 13")
    # luck stacks with the Owner pass multiplicatively
    s = srv(sim, 'PDS.Set(p, { "Flags", "OwnerPass" }, true); BS.Refresh(p); shared.R = { luck = BS.LuckMultiplier(p) }')
    check(abs(s["luck"] - 6.0) < 1e-6, "tree luck stacks with the Owner pass (x3 * x2 = x6)")
    srv(sim, 'PDS.Set(p, { "Flags", "OwnerPass" }, false); BS.Refresh(p); shared.R = {}')

    # income
    buy(sim, p1, "Income")
    s = srv(sim, '''
local rec = nil
for _, r in d.Dragons do rec = r break end
shared.R = { coins = BS.Multiplier(p, "Coins"), rate = ES.IncomeRate(p), income = rec and rec.IncomePerSecond or 0 }
''')
    ib = srv(sim, 'shared.R = { b = TreeConfig.ById.Income.Levels[1].Bonus }')["b"]
    check(abs(s["coins"] - (1 + ib)) < 1e-6, "Golden Roots L1 -> income x%.3f" % (1 + ib))

    # fly speed (server attribute for the client + the companion's cruise speed)
    pre = srv(sim, 'local m = MS.GetModel(p); shared.R = { cruise = m and m:GetAttribute("CruiseSpeed") or 0, run = m and m:GetAttribute("RunSpeed") or 0 }')
    r = buy(sim, p1, "FlySpeed")
    r2 = buy(sim, p1, "RunSpeed")
    post = srv(sim, 'local m = MS.GetModel(p); shared.R = { cruise = m and m:GetAttribute("CruiseSpeed") or 0, run = m and m:GetAttribute("RunSpeed") or 0, fly = TreeConfig.ById.FlySpeed.Levels[1].Bonus, rb = TreeConfig.ById.RunSpeed.Levels[1].Bonus }')
    print("speed", pre, post)
    check(r["ok"] and pre["cruise"] > 0 and abs(post["cruise"] / pre["cruise"] - (1 + post["fly"])) < 1e-3, "Wind Wings L1 -> companion cruise speed up right away")
    check(r2["ok"] and abs(post["run"] / pre["run"] - (1 + post["rb"])) < 1e-3, "Swift Paws L1 -> companion run speed up")

    # hatch speed: new eggs are faster, eggs already warming up speed up immediately
    srv(sim, '''
local now = os.time()
PDS.Set(p, { "Incubator", "Slots", "1" }, { Type = "SkyEgg", Start = now, Ready = now + 1000, Id = "T1", Luck = 1 })
shared.R = {}
''')
    r = buy(sim, p1, "HatchSpeed")
    s = srv(sim, 'shared.R = { left = d.Incubator.Slots["1"].Ready - os.time() }')
    print("incubator after Warm Nest L1:", s)
    hb = srv(sim, 'shared.R = { b = TreeConfig.ById.HatchSpeed.Levels[1].Bonus }')["b"]
    check(r["ok"] and abs(s["left"] - 1000 * (1 - hb)) < 25, "Warm Nest L1 shortens an egg already warming (1000s -> ~%ds)" % (1000 * (1 - hb)))

    # mutation luck is a plain bonus read by EggService
    r = buy(sim, p1, "MutationLuck")
    s = srv(sim, 'shared.R = { b = TS.Bonus(p, "MutationLuck") }')
    check(r["ok"] and abs(s["b"] - 0.25) < 1e-9, "Mutation Luck L1 -> +25% (3.0 over 12 levels)")

    # ---- more branches: egg bag, recycler refund, XP (Wisdom), generated level tables
    buy(sim, p1, "EggBag")
    buy(sim, p1, "Recycler")
    buy(sim, p1, "Wisdom")
    s = srv(sim, '''
local base = require(Configs.EconomyConfig).upgradeValue("EggStorage", d.Upgrades.EggStorage or 0)
local LS = require(SSS.Services.LevelService)
local xp0, lv0 = d.XP, d.Level
LS.Add(p, 100, "test")
shared.R = {
	cap = TreeConfig.eggCapacity(d), base = base, bag = TreeConfig.bonus(d, "EggBag"),
	refund = TreeConfig.refundSeconds(d), rb = TreeConfig.bonus(d, "Recycler"),
	wis = TreeConfig.bonus(d, "Wisdom"), gained = (d.XP - xp0) + (d.Level - lv0) * 1e9,
	branches = #TreeConfig.Branches, cats = #TreeConfig.Categories,
}
''')
    print("hooks", s)
    check(s["cap"] == s["base"] + 1 and s["bag"] == 1, "Deep Pockets L1 -> +1 egg slot (client + server formula)")
    check(abs(s["refund"] - 30 * (1 + s["rb"])) < 1e-6, "Gentle Goodbye L1 refunds more")
    check(s["gained"] >= 100 * (1 + s["wis"]) - 1, "Ancient Wisdom multiplies player XP (+%d%%)" % (s["wis"] * 100))
    check(s["branches"] == 20 and s["cats"] == 5, "20 branches in 5 categories")
    lv = srv(sim, 'local n = 0; for _, b in TreeConfig.Branches do n += #b.Levels end; local mono = true; for _, b in TreeConfig.Branches do for i = 2, #b.Levels do if b.Levels[i].Price <= b.Levels[i-1].Price or b.Levels[i].Bonus < b.Levels[i-1].Bonus then mono = false end end end; shared.R = { n = n, mono = mono, top = TreeConfig.ById.MutationLuck.Levels[12].Price }')
    print("levels", lv)
    check(lv["n"] >= 180, "about 190 purchasable levels (%d)" % lv["n"])
    check(lv["mono"], "prices and bonuses strictly grow with the level in every branch")
    check(lv["top"] >= 1e11, "top level prices are endgame-sized ($%.0e)" % lv["top"])

    # ---- client: orbs light up, window works
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local ctrl = lp.PlayerScripts.Controllers
local CS = game:GetService("CollectionService")
task.wait(0.6)
local on, off = 0, 0
for _, o in CS:GetTagged("TreeOrb") do
	if o.Material == Enum.Material.Neon then on += 1 else off += 1 end
end
shared.O = { on = on, off = off }
''')
    O = lua_table_to_py(out.get("O"))
    want = srv(sim, '''
local lit = 0
for _, cat in TreeConfig.Categories do
	lit += math.min(5, math.floor(TreeConfig.categoryProgress(d, cat.Id) * 5 + 1e-6))
end
shared.R = { lit = lit }
''')["lit"]
    print("orbs", O, "expected lit", want)
    check(O["on"] == want and O["on"] + O["off"] == 25, "client lights the fruit by category progress (%d of 25)" % want)

    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local uic = require(lp.PlayerScripts.Controllers.UIController)
uic.Open("Tree")
task.wait(0.8)
local w = uic.Windows.Tree
local rows, nodes, owned, visibleRows = 0, 0, 0, 0
for id, row in w.Rows do
	rows += 1
	if row.Row.Visible then visibleRows += 1 end
	for _, n in row.Nodes do
		nodes += 1
		if n.Check.Visible then owned += 1 end
	end
end
shared.W = { open = w ~= nil and w.Root.Visible, rows = rows, nodes = nodes, owned = owned, visibleRows = visibleRows, cat = w.Category, buy = w.BuyButton.Label.Text, title = w.DetailTitle.Text, cash = w.CashText.Text, total = w.TotalText.Text }
''', max_steps=1500)
    W = lua_table_to_py(out.get("W"))
    print("window", W)
    check(W["open"] and W["rows"] == 20 and W["nodes"] >= 180, "Tree window: 20 branch rows with %d nodes" % W["nodes"])
    check(W["visibleRows"] == 5 and W["cat"] == "Luck", "first tab (Luck) shows its 5 branches")
    check(W["owned"] >= 20, "owned nodes show a check (%d)" % W["owned"])
    ui_render(sim, p1, f"{OUT}/tree_window.png", debug=False)

    # buy through the window (select the Income level 2 node, press BUY)
    srv(sim, 'PDS.Set(p, { "Cash" }, 1e12); shared.R = {}')
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local uic = require(lp.PlayerScripts.Controllers.UIController)
local w = uic.Windows.Tree
w:ShowCategory("Wealth")
task.wait(0.3)
local vis = 0
for _, row in w.Rows do if row.Row.Visible then vis += 1 end end
local lvBefore = require(game:GetService("ReplicatedStorage").Configs.TreeConfig).level(w.Data.all(), "Income")
w:Select("Income", lvBefore + 1)
task.wait(0.3)
local before = w.BuyButton.Label.Text
w:Buy()
task.wait(1.0)
shared.B = { before = before, after = w.BuyButton.Label.Text, sel = w.Selected.Level, vis = vis, level = require(game:GetService("ReplicatedStorage").Configs.TreeConfig).level(w.Data.all(), "Income"), was = lvBefore }
''', max_steps=1500)
    B = lua_table_to_py(out.get("B"))
    print("buy via window", B)
    check(B["vis"] == 4, "Wealth tab shows its 4 branches")
    check(B["level"] == B["was"] + 1 and "BUY" in B["before"], "BUY button purchases the selected next level")
    check(B["sel"] == B["was"] + 2, "selection moves on to the next level")
    ui_render(sim, p1, f"{OUT}/tree_window_after.png", debug=False)

    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()

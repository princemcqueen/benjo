"""Great Tree: LEGO tree built in the plaza (25 fruit orbs + prompt), server-authoritative
purchases (order, price, max), every bonus applied where it matters (luck, income, flight
speed, hatch speed, mutation luck), orbs light up on the client, TreeWindow UI."""
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
for _, o in CS:GetTagged("TreeOrb") do orbs[#orbs + 1] = o:GetAttribute("Branch") .. o:GetAttribute("Level") end
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
    s = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), attr = p:GetAttribute("Luck"), cash = d.Cash }')
    check(abs(s["luck"] - 1.1) < 1e-6 and abs(s["attr"] - 1.1) < 1e-6, "Roll Luck L1 -> luck x1.1 (HUD attribute too)")
    check(abs(s["cash"] - (1e12 - 1000)) < 1, "price taken from TreeConfig ($1000)")
    for _ in range(4):
        r = buy(sim, p1, "RollLuck")
    s = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), lvl = TS.Level(p, "RollLuck") }')
    check(s["lvl"] == 5 and abs(s["luck"] - 2.0) < 1e-6, "Roll Luck maxes at level 5 -> x2.0")
    r = buy(sim, p1, "RollLuck")
    check(not r["ok"] and r["err"] == "MAXED", "no level 6")
    # luck stacks with the Owner pass multiplicatively
    s = srv(sim, 'PDS.Set(p, { "Flags", "OwnerPass" }, true); BS.Refresh(p); shared.R = { luck = BS.LuckMultiplier(p) }')
    check(abs(s["luck"] - 4.0) < 1e-6, "tree luck stacks with the Owner pass (x2 * x2 = x4)")
    srv(sim, 'PDS.Set(p, { "Flags", "OwnerPass" }, false); BS.Refresh(p); shared.R = {}')

    # income
    buy(sim, p1, "Income")
    s = srv(sim, '''
local rec = nil
for _, r in d.Dragons do rec = r break end
shared.R = { coins = BS.Multiplier(p, "Coins"), rate = ES.IncomeRate(p), income = rec and rec.IncomePerSecond or 0 }
''')
    check(abs(s["coins"] - 1.1) < 1e-6, "Golden Roots L1 -> income x1.1")

    # fly speed (server attribute for the client + the companion's cruise speed)
    pre = srv(sim, 'local m = MS.GetModel(p); shared.R = { cruise = m and m:GetAttribute("CruiseSpeed") or 0 }')
    r = buy(sim, p1, "FlySpeed")
    post = srv(sim, 'local m = MS.GetModel(p); shared.R = { cruise = m and m:GetAttribute("CruiseSpeed") or 0, attr = p:GetAttribute("TreeFlySpeed") }')
    print("fly", pre, post)
    check(r["ok"] and abs(post["attr"] - 0.05) < 1e-9, "Wind Wings L1 -> player attribute TreeFlySpeed = 0.05")
    check(pre["cruise"] > 0 and abs(post["cruise"] / pre["cruise"] - 1.05) < 1e-3, "companion cruise speed +5% right away")

    # hatch speed: new eggs are faster, eggs already warming up speed up immediately
    srv(sim, '''
local now = os.time()
PDS.Set(p, { "Incubator", "Slots", "1" }, { Type = "SkyEgg", Start = now, Ready = now + 1000, Id = "T1", Luck = 1 })
shared.R = {}
''')
    r = buy(sim, p1, "HatchSpeed")
    s = srv(sim, 'shared.R = { left = d.Incubator.Slots["1"].Ready - os.time() }')
    print("incubator after Warm Nest L1:", s)
    check(r["ok"] and 880 <= s["left"] <= 920, "Warm Nest L1 shortens an egg already warming (1000s -> ~900s)")

    # mutation luck is a plain bonus read by EggService
    r = buy(sim, p1, "MutationLuck")
    s = srv(sim, 'shared.R = { b = TS.Bonus(p, "MutationLuck") }')
    check(r["ok"] and abs(s["b"] - 0.15) < 1e-9, "Mutation Luck L1 -> +15%")

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
    print("orbs", O)
    # RollLuck 5 + Income 1 + FlySpeed 1 + HatchSpeed 1 + MutationLuck 1 = 9
    check(O["on"] == 9 and O["off"] == 16, "client lights the bought fruit (9 on, 16 off)")

    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local uic = require(lp.PlayerScripts.Controllers.UIController)
uic.Open("Tree")
task.wait(0.8)
local w = uic.Windows.Tree
local rows, nodes, owned = 0, 0, 0
for id, row in w.Rows do
	rows += 1
	for _, n in row.Nodes do
		nodes += 1
		if n.Check.Visible then owned += 1 end
	end
end
shared.W = { open = w ~= nil and w.Root.Visible, rows = rows, nodes = nodes, owned = owned, buy = w.BuyButton.Label.Text, title = w.DetailTitle.Text, cash = w.CashText.Text }
''', max_steps=1500)
    W = lua_table_to_py(out.get("W"))
    print("window", W)
    check(W["open"] and W["rows"] == 5 and W["nodes"] == 25, "Tree window: 5 branches x 5 nodes")
    check(W["owned"] == 9, "owned nodes show a check (9)")
    ui_render(sim, p1, f"{OUT}/tree_window.png", debug=False)

    # buy through the window (select the Income level 2 node, press BUY)
    srv(sim, 'PDS.Set(p, { "Cash" }, 1e12); shared.R = {}')
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local uic = require(lp.PlayerScripts.Controllers.UIController)
local w = uic.Windows.Tree
w:Select("Income", 2)
task.wait(0.3)
local before = w.BuyButton.Label.Text
w:Buy()
task.wait(1.0)
shared.B = { before = before, after = w.BuyButton.Label.Text, sel = w.Selected.Level, levels = require(lp.PlayerScripts.Controllers.TreeController).levels().Income }
''', max_steps=1500)
    B = lua_table_to_py(out.get("B"))
    print("buy via window", B)
    check(B["levels"] == 2 and "BUY" in B["before"], "BUY button purchases the selected next level")
    check(B["sel"] == 3, "selection moves on to the next level")
    ui_render(sim, p1, f"{OUT}/tree_window_after.png", debug=False)

    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()

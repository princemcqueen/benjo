"""Robux shop: Owner Dragon pass (test purchase), potions, cash packs, level and
mutation potions, cash upgrades, luck multiplier applied to hatching (+ odds)."""
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
local DS = require(SSS.Services.DragonService)
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


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Player1", 1001)
    sim.run_for(5, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # open the shop (robux tab) and render
    run_client_lua(sim, p1, '''
local uic = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
uic.Open("Shop")
task.wait(0.8)
shared.X = { ok = true }
''')
    sim.run_for(0.5, 1 / 30)
    ui_render(sim, p1, f"{OUT}/shop_robux.png", debug=False)

    s0 = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), cash = d.Cash, n = 0 }')
    r = req(sim, p1, "Shop", "TestBuy", '{ Item = "OwnerDragon" }')
    sim.run_for(0.5, 1 / 30)
    s1 = srv(sim, '''
local has = false
for _, rec in d.Dragons do if rec.SpeciesId == "OwnerDragon" then has = true end end
shared.R = { luck = BS.LuckMultiplier(p), owner = d.Flags.OwnerPass, has = has, attr = p:GetAttribute("Luck") }
''')
    print("owner", r, s0, s1)
    check(r["ok"], "test purchase of the Owner Dragon succeeds")
    check(s1["owner"] and s1["has"], "Owner pass flag + Owner Dragon in the collection")
    check(s1["luck"] == 2 and s1["attr"] == 2, "luck multiplier x2 from the Owner pass")
    r = req(sim, p1, "Shop", "TestBuy", '{ Item = "LuckPotion" }')
    s2 = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p), left = BS.Remaining(p, "Luck") }')
    print("potion", r, s2)
    check(s2["luck"] == 4 and s2["left"] > 890, "Luck Potion stacks to x4 for 15 minutes")
    cash0 = srv(sim, 'shared.R = { cash = d.Cash }')["cash"]
    r = req(sim, p1, "Shop", "TestBuy", '{ Item = "CashPackSmall" }')
    cash1 = srv(sim, 'shared.R = { cash = d.Cash }')["cash"]
    check(cash1 - cash0 >= 5000, "cash pack pays at least $5K (%s)" % (cash1 - cash0))
    lv = srv(sim, 'local r = d.Dragons[d.EquippedDragon]; shared.R = { lv = r and r.Level or 0, mut = r and r.Mutation or "", id = d.EquippedDragon }')
    req(sim, p1, "Shop", "TestBuy", '{ Item = "LevelPotion" }')
    req(sim, p1, "Shop", "TestBuy", '{ Item = "MutationPotion" }')
    lv2 = srv(sim, 'local r = d.Dragons[d.EquippedDragon]; shared.R = { lv = r and r.Level or 0, mut = r and r.Mutation or "", id = d.EquippedDragon }')
    print("potions", lv, lv2)
    check(lv2["lv"] == lv["lv"] + 5, "Level Potion: +5 levels on the equipped dragon")
    check(lv2["mut"] != lv["mut"], "Mutation Potion: better mutation (%s -> %s)" % (lv["mut"], lv2["mut"]))
    srv(sim, 'PDS.Set(p, { "Cash" }, 100000); shared.R = {}')
    r = req(sim, p1, "Shop", "BuyUpgrade", '{ Id = "EggStorage" }')
    up = srv(sim, 'shared.R = { lvl = d.Upgrades.EggStorage, cash = d.Cash }')
    print("upgrade", r, up)
    check(r["ok"] and up["lvl"] == 1 and up["cash"] == 100000 - 300, "Egg Storage upgrade bought with cash")
    # hatch with luck: record gets "1 in N" odds
    h = srv(sim, '''
local now = os.time()
PDS.Set(p, { "Incubator", "Slots", "1" }, { Type = "SkyEgg", Start = now - 1000, Ready = now - 1 })
shared.R = {}
''')
    r = req(sim, p1, "Egg", "Hatch", '{ Slot = 1 }')
    print("hatch", r)
    d = r.get("data") or {}
    rec = d.get("Dragon") or {}
    check(r["ok"] and (rec.get("Odds") or 0) >= 1, "hatched dragon carries its odds (1 in %s)" % rec.get("Odds"))
    sim.run_for(2, 1 / 30)

    # ---------------------------------------------------------------- LEGENDARY M0NICA (11999 R$, 50T base, x20 luck)
    mon0 = srv(sim, 'shared.R = { luck = BS.LuckMultiplier(p) }')
    r = req(sim, p1, "Shop", "TestBuy", '{ Item = "MonicaDragon" }')
    sim.run_for(0.5, 1 / 30)
    mon = srv(sim, '''
local rec
for _, r in d.Dragons do if r.SpeciesId == "M0nicaDragon" then rec = r end end
local MC = require(game:GetService("ReplicatedStorage").Configs.MonetizationConfig)
shared.R = { has = rec ~= nil, mutation = rec and rec.Mutation or "", income = rec and rec.IncomePerSecond or 0, rarity = rec and rec.Rarity or "",
	luck = BS.LuckMultiplier(p), attr = p:GetAttribute("Luck"), owns = MC.ownsPass(d, "MonicaDragon"), price = MC.GamePasses.MonicaDragon.Price,
	name = rec and rec.Name or "" }
''')
    print("monica", r, mon0, mon)
    check(r["ok"], "test purchase of LEGENDARY M0NICA succeeds")
    check(mon["has"] and mon["owns"] and mon["price"] == 11999, "M0NICA dragon granted, pass owned, price 11999 R$")
    check(mon["mutation"] == "Omni", "M0NICA comes with every mutation (Omni)")
    check(mon["income"] == 50e12 * 25, f"M0NICA income: 50T base x25 Omni = $1.25Qa/s ({mon['income']:.3g})")
    check(abs(mon["luck"] / mon0["luck"] - 20) < 1e-9 and mon["attr"] == mon["luck"], f"permanent x20 luck stacks on top ({mon0['luck']} -> {mon['luck']})")
    ui = run_client_lua(sim, p1, '''
local uic = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
uic.Close()
task.wait(0.4)
uic.Open("Shop")
task.wait(0.6)
local pg = game:GetService("Players").LocalPlayer.PlayerGui
local card = pg:FindFirstChild("MonicaDragon", true)
local texts = {}
if card then
	for _, d in card:GetDescendants() do
		if d:IsA("TextLabel") and d.Text ~= "" then table.insert(texts, d.Text) end
	end
end
shared.R = { found = card ~= nil, texts = table.concat(texts, " | ") }
''')
    cardinfo = lua_table_to_py(ui.get("R"))
    print("card", cardinfo)
    check(cardinfo["found"] and "LEGENDARY M0NICA DRAGON" in cardinfo["texts"].upper(), "shop card is titled LEGENDARY M0NICA DRAGON")
    check("11,999" in cardinfo["texts"] or "OWNED" in cardinfo["texts"], "shop card shows the price (R$ 11,999) / OWNED")
    check("X20 LUCK" in cardinfo["texts"].upper(), "card advertises x20 LUCK")
    run_client_lua(sim, p1, '''
local uic = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
uic.Close()
task.wait(0.5)
uic.Open("Shop", { Tab = "Upgrades" })
task.wait(0.6)
shared.X = { ok = true }
''')
    ui_render(sim, p1, f"{OUT}/shop_upgrades.png", debug=False)
    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()

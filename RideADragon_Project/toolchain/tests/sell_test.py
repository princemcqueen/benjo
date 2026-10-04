"""Selling dragons (DragonService Sell / SellBulk, DragonStats.sellValue) and the inventory window around it:
the price (base income x mutation x 300 s, never the level), the refusals (locked, exclusive, ridden, the only
dragon), the bulk sale (keeps locked / equipped / resting dragons), feeding never raises the price, the Gentle
Goodbye tree bonus, the SELL button with its price and SELL SHOWN with its confirmation."""
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
local DS = require(SSS.Services.DragonService)
local DragonStats = require(RS.Shared.DragonStats)
local TreeConfig = require(RS.Configs.TreeConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
local function add(species, mutation, force)
	local rec = DS.Add(p, species, mutation or "None", "Test", force)
	return rec and rec.UniqueId or "?"
end
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Dragon", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", refund = r.data and r.data.Refund or 0, sold = r.data and r.data.Sold or 0,
	cash = r.data and r.data.Cash or 0, skipped = r.data and r.data.Skipped or 0 }}
''', max_steps=1200)
    return lua_table_to_py(res.get("RQ"))


def cash(sim):
    return srv(sim, 'shared.R = { cash = d.Cash, count = (function() local n = 0 for _ in d.Dragons do n += 1 end return n end)(), released = d.Stats.Released }')


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Alice", 7001)
    sim.run_for(8, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ the price
    r = srv(sim, '''
PDS.Set(p, { "Upgrades", "DragonStorage" }, 2)
PDS.Set(p, { "Cash" }, 0)
local a = add("GreenDrake", "None")
local shiny = add("ForestWyvern", "Shiny")
local lv = add("GreenDrake", "None")
PDS.Set(p, { "Dragons", lv, "Level" }, 30)
local rec = d.Dragons[lv]
local copy = table.clone(rec) DragonStats.refresh(copy) PDS.Set(p, { "Dragons", lv }, copy)
local prince = add("PrinceDragon", "None", true)
shared.R = {
	a = a, shiny = shiny, lv = lv, prince = prince,
	priceA = DragonStats.sellValue(d.Dragons[a], d), priceShiny = DragonStats.sellValue(d.Dragons[shiny], d), priceLv = DragonStats.sellValue(d.Dragons[lv], d),
	incomeLv = d.Dragons[lv].IncomePerSecond, seconds = TreeConfig.refundSeconds(d),
	canGreen = DragonStats.canSellSpecies("GreenDrake"), canPrince = DragonStats.canSellSpecies("PrinceDragon"), canMonica = DragonStats.canSellSpecies("M0nicaDragon"),
}''')
    print("prices", r)
    check(r["priceA"] == 600, f"a Green Drake sells for 300 s of its income: ${r['priceA']:.0f}")
    check(r["priceShiny"] == 4050, f"a Shiny Forest Wyvern: 9 x 1.5 x 300 = ${r['priceShiny']:.0f}")
    check(r["priceLv"] == 600 and r["incomeLv"] > 4, f"the level does not count: a level 30 drake still sells for ${r['priceLv']:.0f} (it earns ${r['incomeLv']:.1f}/s)")
    check(r["canGreen"] and not r["canPrince"] and not r["canMonica"], "exclusive (Robux) dragons are not for sale")
    ids = r

    # ------------------------------------------------------------------ one sale
    before = cash(sim)
    res = req(sim, player, "Sell", f'{{ Id = "{ids["a"]}" }}')
    after = cash(sim)
    check(res["ok"] and res["refund"] == 600 and after["cash"] - before["cash"] == 600, f"Sell pays the price (+${after['cash'] - before['cash']:.0f})")
    check(after["count"] == before["count"] - 1 and after["released"] == before["released"] + 1, "the dragon is gone and counted")
    res = req(sim, player, "Sell", f'{{ Id = "{ids["a"]}" }}')
    check(not res["ok"] and res["err"] == "NOT_FOUND", "selling the same dragon twice is refused")
    res = req(sim, player, "Sell", f'{{ Id = "{ids["prince"]}" }}')
    check(not res["ok"] and res["err"] == "EXCLUSIVE", f"an exclusive dragon cannot be sold ({res['err']})")
    req(sim, player, "Lock", f'{{ Id = "{ids["shiny"]}", Locked = true }}')
    res = req(sim, player, "Sell", f'{{ Id = "{ids["shiny"]}" }}')
    check(not res["ok"] and res["err"] == "LOCKED", "a locked dragon cannot be sold")
    req(sim, player, "Lock", f'{{ Id = "{ids["shiny"]}", Locked = false }}')
    res = req(sim, player, "Release", f'{{ Id = "{ids["shiny"]}" }}')
    check(res["ok"] and res["refund"] == 4050, "the old action name Release still sells")

    # ------------------------------------------------------------------ the Gentle Goodbye tree bonus
    r = srv(sim, '''
local c = add("EmberPup", "None")
PDS.Set(p, { "Tree", "Recycler" }, 3)
shared.R = { c = c, price = DragonStats.sellValue(d.Dragons[c], d), seconds = TreeConfig.refundSeconds(d), bonus = TreeConfig.bonus(d, "Recycler") }''')
    check(abs(r["seconds"] - 300 * (1 + r["bonus"])) < 1e-6 and r["price"] > 900, f"Gentle Goodbye raises the price (${r['price']:.0f} instead of $900)")
    srv(sim, 'PDS.Set(p, { "Tree", "Recycler" }, 0) shared.R = {}')

    # ------------------------------------------------------------------ bulk sale
    r = srv(sim, '''
local keep = d.EquippedDragon
local sell1 = add("GreenDrake", "None")
local locked = add("PebbleDrake", "None")
PDS.Set(p, { "Dragons", locked, "Locked" }, true)
local sell2 = add("CoralGlider", "Shiny")
local sell3 = add("AquaSerpent", "None")
local resting = add("StormHawk", "None")
shared.R = { keep = keep, sell1 = sell1, locked = locked, sell2 = sell2, sell3 = sell3, resting = resting }''')
    bulk = r
    res = req(sim, player, "Place", f'{{ Id = "{bulk["resting"]}" }}')
    check(res["ok"], "one dragon rests on a perch")
    expect = srv(sim, f'''
local total = 0
for _, id in {{ "{bulk["sell1"]}", "{bulk["sell2"]}", "{bulk["sell3"]}" }} do total += DragonStats.sellValue(d.Dragons[id], d) end
shared.R = {{ total = total, equipped = d.EquippedDragon }}''')
    before = cash(sim)
    ids_lua = ", ".join(f'"{x}"' for x in [bulk["sell1"], bulk["locked"], bulk["sell2"], bulk["sell3"], bulk["resting"], bulk["keep"], ids["prince"], "bogus", bulk["sell1"]])
    res = req(sim, player, "SellBulk", f"{{ Ids = {{ {ids_lua} }} }}")
    after = cash(sim)
    print("bulk", res, expect, before, after)
    check(res["ok"] and res["sold"] == 3, f"SellBulk sold the three plain dragons ({res['sold']:.0f})")
    check(res["skipped"] == 5, f"...and kept the locked, resting, equipped, exclusive and unknown ones ({res['skipped']:.0f} skipped)")
    check(res["cash"] == expect["total"] and after["cash"] - before["cash"] == expect["total"], f"the bulk sale pays the sum (+${after['cash'] - before['cash']:.0f})")
    kept = srv(sim, f'''
shared.R = {{ locked = d.Dragons["{bulk["locked"]}"] ~= nil, resting = d.Dragons["{bulk["resting"]}"] ~= nil, prince = d.Dragons["{ids["prince"]}"] ~= nil, keep = d.Dragons["{bulk["keep"]}"] ~= nil }}''')
    check(all(kept.values()), "locked, resting, exclusive and equipped dragons are all still there")
    res = req(sim, player, "SellBulk", '{ Ids = {} }')
    check(not res["ok"] and res["err"] == "BAD_REQUEST", "an empty list is refused")
    res = req(sim, player, "SellBulk", '{ Ids = 5 }')
    check(not res["ok"] and res["err"] == "BAD_REQUEST", "a list that is not a list is refused")

    # one dragon always stays
    srv(sim, '''
for uid, rec in table.clone(d.Dragons) do
	if uid ~= d.EquippedDragon then PDS.Set(p, { "Dragons", uid, "Locked" }, false) end
end
shared.R = {}''')
    r = srv(sim, '''
local ids = {}
for uid in d.Dragons do table.insert(ids, uid) end
shared.R = { n = #ids }''')
    # unequip, then try to sell everything that is not exclusive / resting: one must stay
    req(sim, player, "Unequip")
    allids = srv(sim, '''
local out = {}
for uid, rec in d.Dragons do if rec.PlacedNestId == "" then table.insert(out, uid) end end
shared.R = { list = out }''')
    # take the resting dragon and the prince out of the picture by locking them
    srv(sim, '''
for uid, rec in d.Dragons do
	if rec.SpeciesId == "PrinceDragon" or rec.PlacedNestId ~= "" then PDS.Set(p, { "Dragons", uid, "Locked" }, true) end
end
shared.R = {}''')
    r = srv(sim, '''
local out = {}
for uid, rec in d.Dragons do if not rec.Locked then table.insert(out, uid) end end
shared.R = { list = out, n = #out }''')
    ids_lua = ", ".join(f'"{x}"' for x in r["list"].values()) if isinstance(r["list"], dict) else ", ".join(f'"{x}"' for x in r["list"])
    res = req(sim, player, "SellBulk", f"{{ Ids = {{ {ids_lua} }} }}")
    left = cash(sim)
    check(res["ok"] and left["count"] >= 1, f"a bulk sale never sells the last dragon ({left['count']:.0f} left)")

    # ------------------------------------------------------------------ the window
    srv(sim, '''
for uid, rec in table.clone(d.Dragons) do PDS.Set(p, { "Dragons", uid, "Locked" }, false) end
for i = 1, 8 do add("GreenDrake", "None") end
add("FrostDragon", "None")
shared.R = {}''')
    res = run_client_lua(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local UIC = require(LP.PlayerScripts.Controllers.UIController)
local DragonStats = require(game:GetService("ReplicatedStorage").Shared.DragonStats)
UIC.Open("Inventory")
task.wait(0.8)
local w = UIC.Windows.Inventory
local data = w.Data.all()
local prince, plain
for _, uid in w.List do
	local rec = data.Dragons[uid]
	if rec.SpeciesId == "PrinceDragon" then prince = uid end
	if rec.SpeciesId == "GreenDrake" and not plain then plain = uid end
end
w:Select(prince, true)
task.wait(0.2)
local labelPrince = w.ReleaseBtn.Label and w.ReleaseBtn.Label.Text or ""
w:Select(plain, true)
task.wait(0.2)
local label1 = w.ReleaseBtn.Label and w.ReleaseBtn.Label.Text or ""
local ids, total, rare = w:SellableShown()
shared.W1 = { sell = label1, prince = labelPrince, shown = #ids, total = total, rare = rare, enabled = w.SellShown.Instance.Visible, list = #w.List }''')
    w1 = lua_table_to_py(res.get("W1"))
    print("window", w1)
    check("SELL" in w1["sell"] and "$" in w1["sell"], f"the details show the SELL button with its price ({w1['sell']})")
    check(w1["prince"] == "NOT FOR SALE", f"an exclusive dragon shows NOT FOR SALE ({w1['prince']})")
    check(w1["shown"] >= 8 and w1["total"] > 0 and w1["enabled"], f"SELL SHOWN counts the sellable dragons of the list ({w1['shown']:.0f}, ${w1['total']:.0f})")
    res = run_client_lua(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local UIC = require(LP.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
local asked = {}
local realConfirm = UIC.Confirm
UIC.Confirm = function(opts) table.insert(asked, opts.Title .. " | " .. opts.Body) return true end
w.Query.Filter = "Common"
w:Rebuild(true)
local ids, total = w:SellableShown()
w:DoSellShown()
task.wait(2.0)
UIC.Confirm = realConfirm
local n = 0
for uid, rec in w.Data.all().Dragons do if rec.Rarity == "Common" then n += 1 end end
shared.W2 = { asked = asked[1] or "", sellable = #ids, total = total, commonLeft = n }''')
    w2 = lua_table_to_py(res.get("W2"))
    print("sell shown", w2)
    check("Sell" in w2["asked"] and "dragons for" in w2["asked"], f"SELL SHOWN asks once and names the count and the total ({w2['asked'][:70]})")
    check(w2["commonLeft"] <= 8, f"the Common dragons of the list were sold ({w2['commonLeft']:.0f} Common left)")

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    check(len(sim.errors) == 0, "no script errors")
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")
    print("ALL OK" if not FAIL else "SOME FAILED")


if __name__ == "__main__":
    main()

"""Egg hunting items (Robux): the shop sections, Egg Radar / Egg Magnet / Fast Hatch potions, the
Lucky Egg Call, the Mythic Bundle and the Egg Hunter pass (radar forever, +50% pickup range, +3 bag
slots) - the server effects, the shop cards and the HUD pill.  (The radar markers themselves are in
radar_test.py.)"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
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
local ES = require(SSS.Services.EggService)
local EggReach = require(RS.Shared.EggReach)
local MC = require(RS.Configs.MonetizationConfig)
local TreeConfig = require(RS.Configs.TreeConfig)
local EggConfig = require(RS.Configs.EggConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src, steps=600):
    head = '''
local Players = game:GetService("Players")
local LP = Players.LocalPlayer
local Controllers = LP.PlayerScripts.Controllers
local EC = require(Controllers.EggController)
local SC = require(Controllers.SanctuaryController)
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
'''
    res = run_client_lua(sim, player, head + src, max_steps=steps)
    return lua_table_to_py(res.get("R"))


def req(sim, player, domain, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", data = r.data }}
''')
    return lua_table_to_py(res.get("RQ"))


def buy(sim, player, item):
    r = req(sim, player, "Shop", "TestBuy", '{ Item = "%s" }' % item)
    sim.run_for(0.6, 1 / 30)
    return r


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Hunter", 1001)
    sim.run_for(6, 1 / 30)
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------ the shop sections (config)
    s = srv(sim, '''
local per, total, orphan, ordered = {}, 0, 0, #MC.ProductOrder
for _, sec in MC.Sections do
	per[sec.Id] = #MC.sectionProducts(sec.Id)
	total += per[sec.Id]
end
local count = 0
for id, def in MC.Products do
	count += 1
	local found = false
	for _, sec in MC.Sections do
		if def.Section == sec.Id then found = true end
	end
	if not found then orphan += 1 end
end
shared.R = { potions = per.Potions, hunt = per.Hunt, packs = per.Packs, total = total, count = count, orphan = orphan, ordered = ordered }''')
    print("sections", s)
    check(s["hunt"] == 5 and s["potions"] == 5 and s["packs"] == 5, f"three sections: potions {s['potions']}, egg hunting {s['hunt']}, cash & spins {s['packs']}")
    check(s["total"] == s["count"] == s["ordered"] and s["orphan"] == 0, f"every product sits in exactly one section ({s['count']} products)")

    # ------------------------------------------------------------ Egg Radar potion
    base = srv(sim, '''PDS.Set(p, { "Upgrades", "Radar" }, 0) shared.R = { range = EggReach.radarRange(d, os.time()), magnet = EggReach.bonus(d, os.time()), hatch = EggReach.hatchFactor(d, os.time()), cap = TreeConfig.eggCapacity(d), eggs = #d.Eggs, luck = BS.LuckMultiplier(p) }''')
    print("base", base)
    check(base["range"] == 0 and base["hatch"] == 1, "before any purchase: no radar, normal hatching")
    r = buy(sim, player, "EggRadar")
    s = srv(sim, '''shared.R = { range = EggReach.radarRange(d, os.time()), left = BS.Remaining(p, "Radar"), secs = EggReach.radarSeconds(d, os.time()) }''')
    print("radar", r, s)
    check(r["ok"], "the Egg Radar potion can be bought")
    check(s["range"] > 1e12, "the radar sees the whole map")
    check(1700 < s["left"] <= 1800, f"...for 30 minutes ({s['left']:.0f} s left)")

    # ------------------------------------------------------------ Lucky Egg Call (before the Magnet: with the magnet eggs 22+ studs away
    # are picked up by themselves)
    srv(sim, '''ES.SetHeld(p, nil) PDS.Set(p, { "Eggs" }, {}) shared.R = {}''')
    before = cli(sim, player, '''
local n = 0
for key in EC.list() do if string.sub(key, 1, 1) == "b" then n += 1 end end
shared.R = { n = n }''')
    r = buy(sim, player, "LuckyEggCall")
    sim.run_for(1.0, 1 / 30)
    s = cli(sim, player, '''
local hrp = LP.Character.HumanoidRootPart
local list = {}
for key, egg in EC.list() do
	if string.sub(key, 1, 1) == "b" then
		local off = egg.Position - hrp.Position
		table.insert(list, { key = key, luck = egg.Luck, dist = Vector3.new(off.X, 0, off.Z).Magnitude })
	end
end
local minLuck, maxLuck, minDist, maxDist = math.huge, 0, math.huge, 0
for _, e in list do
	minLuck = math.min(minLuck, e.luck) maxLuck = math.max(maxLuck, e.luck)
	minDist = math.min(minDist, e.dist) maxDist = math.max(maxDist, e.dist)
end
shared.R = { n = #list, minLuck = minLuck, maxLuck = maxLuck, minDist = minDist, maxDist = maxDist, key = list[1] and list[1].key or "" }''')
    print("lucky call", r, s)
    check(r["ok"], "the Lucky Egg Call can be bought")
    if s["n"] != 3:
        print("  client eggs:", cli(sim, player, '''
local hrp = LP.Character.HumanoidRootPart
local out = {}
for key, egg in EC.list() do
	table.insert(out, key .. "@" .. math.floor((egg.Position - hrp.Position).Magnitude) .. " x" .. egg.Luck)
end
local data = require(Controllers.DataController).all()
shared.R = { list = table.concat(out, ", "), bag = data and data.Eggs and #data.Eggs or -1 }'''))
    # (a spot is searched with 14 random tries per egg: on rough ground one may not be found)
    check(s["n"] >= 2 and before["n"] == 0, f"lucky eggs appear around the player ({s['n']:.0f} of 3)")
    check(25 <= s["minLuck"] and s["maxLuck"] <= 100, f"each with x25..x100 luck ({s['minLuck']}..{s['maxLuck']})")
    check(s["minDist"] >= 15 and s["maxDist"] <= 90, f"...within walking distance ({s['minDist']:.0f}..{s['maxDist']:.0f} studs)")
    # pick one up: it lands in the bag with its luck
    if s["key"]:
        eggs_before = srv(sim, '''shared.R = { n = #d.Eggs }''')["n"]
        pos = cli(sim, player, '''
local e = EC.list()["%s"]
shared.R = { x = e.Position.X, y = e.Position.Y, z = e.Position.Z, luck = e.Luck }''' % s["key"])
        hrp.props["CFrame"] = CFrame((pos["x"] + 2, pos["y"] + 1, pos["z"]))
        sim.run_for(1.5, 1 / 30)
        got = srv(sim, '''
local n, has, list = #d.Eggs, false, {}
for _, e in d.Eggs do
	table.insert(list, e.Type .. "/" .. tostring(e.Luck))
	if e.Luck == %d then has = true end
end
shared.R = { n = n, has = has, list = table.concat(list, ", ") }''' % pos["luck"])
        print("pickup", eggs_before, got)
        check(got["n"] >= eggs_before + 1 and got["has"], f"walking up to a lucky egg picks it up (x{pos['luck']:.0f} luck in the bag)")
    # they vanish after their time: ask the server for short-lived ones (their own keys are watched:
    # other lucky eggs may be picked up by the companion meanwhile)
    KEYS = '''
local keys = {}
for key in EC.list() do if string.sub(key, 1, 1) == "b" then table.insert(keys, key) end end
table.sort(keys)
shared.R = { keys = table.concat(keys, ",") }'''
    old_keys = set(filter(None, cli(sim, player, KEYS)["keys"].split(",")))
    srv(sim, '''shared.R = { n = ES.SpawnBonusEggs(p, 2, { 30, 40 }, 5) }''')
    sim.run_for(1.0, 1 / 30)
    mid_keys = set(filter(None, cli(sim, player, KEYS)["keys"].split(",")))
    new_keys = mid_keys - old_keys
    sim.run_for(6.0, 1 / 30)
    late_keys = set(filter(None, cli(sim, player, KEYS)["keys"].split(",")))
    # (the companion may pick one of the two up in the first second: one is enough to see them vanish)
    check(len(new_keys) >= 1 and not (new_keys & late_keys), f"lucky eggs vanish after their time ({len(new_keys)} new, {len(new_keys & late_keys)} left)")

    # ------------------------------------------------------------ Egg Magnet potion
    r = buy(sim, player, "EggMagnet")
    s = srv(sim, '''shared.R = { bonus = EggReach.bonus(d, os.time()), left = BS.Remaining(p, "Magnet"), range = EggReach.range(d, 20, os.time()) }''')
    print("magnet", r, s)
    check(r["ok"], "the Egg Magnet potion can be bought")
    check(abs(s["bonus"] - base["magnet"] - 1.0) < 1e-9, f"pickup range +100% (x{1 + s['bonus']:.2f})")
    check(abs(s["range"] - 20 * (1 + s["bonus"])) < 1e-6, f"a 20-stud reach becomes {s['range']:.0f} studs")
    check(800 < s["left"] <= 900, f"...for 15 minutes ({s['left']:.0f} s left)")

    # ------------------------------------------------------------ Fast Hatch potion: the nest takes half the time
    r = srv(sim, '''
ES.SetHeld(p, nil)
PDS.Set(p, { "Eggs" }, {})
local ok, id1 = ES.GiveEgg(p, "CelestialEgg", 1)
local ok2, id2 = ES.GiveEgg(p, "CelestialEgg", 1)
PDS.Set(p, { "Incubator", "Unlocked" }, 3)
PDS.Set(p, { "Boosts", "Hatch" }, nil)
BS.Refresh(p)
shared.R = { ok = ok and ok2, id1 = id1, id2 = id2, time = EggConfig.Eggs.CelestialEgg.HatchTime, tree = TreeConfig.bonus(d, "HatchSpeed") }''')
    egg1, egg2, base_time = r["id1"], r["id2"], r["time"]
    check(r["ok"] and r["tree"] == 0, f"two Celestial Eggs in the bag (incubation {base_time} s)")
    pos = cli(sim, player, '''
local cf = SC.nestCFrame()
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z }''')
    hrp.props["CFrame"] = CFrame((pos["x"] + 5, pos["y"] + 3, pos["z"] + 5))
    sim.run_for(1.0, 1 / 30)
    r = req(sim, player, "Egg", "Place", '{ Id = "%s", Slot = 1 }' % egg1)
    check(r["ok"], f"egg 1 goes into nest spot 1 ({r['err']})")
    s = srv(sim, '''local s = d.Incubator.Slots["1"] shared.R = { span = s and (s.Ready - s.Start) or -1 }''')
    check(s["span"] == base_time, f"without the potion it takes the normal {base_time} s ({s['span']})")
    r = buy(sim, player, "HatchBoost")
    s = srv(sim, '''shared.R = { factor = EggReach.hatchFactor(d, os.time()), left = BS.Remaining(p, "Hatch") }''')
    print("hatch", r, s)
    check(r["ok"] and s["factor"] == 0.5, f"the Fast Hatch potion halves the incubation (factor {s['factor']})")
    check(1700 < s["left"] <= 1800, f"...for 30 minutes ({s['left']:.0f} s left)")
    r = req(sim, player, "Egg", "Place", '{ Id = "%s", Slot = 2 }' % egg2)
    check(r["ok"], f"egg 2 goes into nest spot 2 ({r['err']})")
    s = srv(sim, '''local s = d.Incubator.Slots["2"] shared.R = { span = s and (s.Ready - s.Start) or -1 }''')
    check(abs(s["span"] - base_time / 2) <= 1, f"with the potion it takes half: {s['span']} s instead of {base_time} s")

    # ------------------------------------------------------------ the HUD pill
    pill = cli(sim, player, '''
local pill = LP.PlayerGui:FindFirstChild("Hunt", true)
local txt = pill and pill:FindFirstChildWhichIsA("TextLabel", true)
shared.R = { found = pill ~= nil, visible = pill ~= nil and pill.Visible, text = txt and txt.Text or "" }''')
    print("pill", pill)
    check(pill["found"] and pill["visible"], "the HUD shows an egg hunting pill while a potion runs")
    check("MAGNET" in pill["text"] and "FAST HATCH" in pill["text"] and ":" in pill["text"], f"...saying what runs and for how long ({pill['text']})")

    # ------------------------------------------------------------ Mythic Bundle: even into a full bag
    r = srv(sim, '''
PDS.Set(p, { "Eggs" }, {})
local cap = TreeConfig.eggCapacity(d)
local given = 0
for _ = 1, cap + 5 do
	local ok = ES.GiveEgg(p, "HavenEgg", 1)
	if ok then given += 1 end
end
shared.R = { cap = cap, given = given, n = #d.Eggs }''')
    print("full bag", r)
    check(r["n"] == r["cap"] and r["given"] == r["cap"], f"the bag is full ({r['n']} / {r['cap']}); a normal pickup is refused")
    cap0 = r["cap"]
    out = buy(sim, player, "MythicBundle")
    s = srv(sim, '''
local cel, luck = 0, 0
for _, e in d.Eggs do
	if e.Type == "CelestialEgg" and e.Luck == 50 then cel += 1 end
end
shared.R = { n = #d.Eggs, cel = cel }''')
    print("bundle", out, s)
    check(out["ok"], "the Mythic Bundle can be bought")
    check(s["cel"] == 3 and s["n"] == cap0 + 3, f"3 Celestial Eggs with x50 luck are added even to a full bag ({s['n']} eggs, {s['cel']} Celestial)")

    # ------------------------------------------------------------ Egg Hunter pass
    srv(sim, '''
PDS.Set(p, { "Boosts" }, {})
PDS.Set(p, { "Upgrades", "Radar" }, 0)
BS.Refresh(p)
shared.R = {}''')
    sim.run_for(0.5, 1 / 30)
    b = srv(sim, '''shared.R = { range = EggReach.radarRange(d, os.time()), bonus = EggReach.bonus(d, os.time()), cap = TreeConfig.eggCapacity(d), luck = BS.LuckMultiplier(p), owned = MC.ownsPass(d, "EggHunter") }''')
    check(b["range"] == 0 and not b["owned"], "without the pass and without potions there is no radar")
    r = buy(sim, player, "EggHunter")
    s = srv(sim, '''shared.R = { range = EggReach.radarRange(d, os.time()), bonus = EggReach.bonus(d, os.time()), cap = TreeConfig.eggCapacity(d), luck = BS.LuckMultiplier(p),
	owned = MC.ownsPass(d, "EggHunter"), slots = MC.passSlots(d), price = MC.GamePasses.EggHunter.Price, flag = d.Flags.Passes and d.Flags.Passes.EggHunter == true,
	dragons = #(function() local t = {} for _, rec in d.Dragons do if rec.SpeciesId == "EggHunter" then table.insert(t, rec) end end return t end)() }''')
    print("pass", r, s)
    check(r["ok"] and s["owned"] and s["flag"], "the Egg Hunter pass can be bought and is saved with the player")
    check(s["range"] > 1e12, "permanent radar: it sees every egg, with no upgrade and no potion")
    check(abs(s["bonus"] - b["bonus"] - 0.5) < 1e-9, f"pickup range +50% (x{1 + s['bonus']:.2f})")
    check(s["slots"] == 3 and s["cap"] == b["cap"] + 3, f"the egg bag has 3 more slots ({b['cap']} -> {s['cap']})")
    check(s["luck"] == b["luck"] and s["dragons"] == 0, "it gives no dragon and no luck: it is a toolkit")
    check(s["price"] == 1299, f"price {s['price']} R$")
    r = srv(sim, '''
PDS.Set(p, { "Eggs" }, {})
local given = 0
for _ = 1, TreeConfig.eggCapacity(d) + 5 do
	if ES.GiveEgg(p, "HavenEgg", 1) then given += 1 end
end
shared.R = { given = given, cap = TreeConfig.eggCapacity(d) }''')
    check(r["given"] == r["cap"] == b["cap"] + 3, f"...and the bag really takes {r['given']} eggs")
    sim.run_for(0.8, 1 / 30)
    pill = cli(sim, player, '''
local pill = LP.PlayerGui:FindFirstChild("Hunt", true)
local txt = pill and pill:FindFirstChildWhichIsA("TextLabel", true)
shared.R = { visible = pill ~= nil and pill.Visible, text = txt and txt.Text or "" }''')
    print("pill with pass", pill)
    check(pill["visible"] and pill["text"].startswith("HUNTER"), f"the HUD pill shows HUNTER ({pill['text']})")

    # ------------------------------------------------------------ the shop window
    ui = cli(sim, player, '''
local uic = require(Controllers.UIController)
uic.Close()
task.wait(0.4)
uic.Open("Shop")
task.wait(0.8)
local pg = LP.PlayerGui
local function texts(inst)
	local out = {}
	for _, d in inst:GetDescendants() do
		if d:IsA("TextLabel") and d.Text ~= "" then table.insert(out, d.Text) end
		if d:IsA("TextButton") and d.Text ~= "" then table.insert(out, d.Text) end
	end
	return table.concat(out, " | ")
end
local function card(id)
	for _, d in pg:GetDescendants() do
		if d.Name == id and d:FindFirstChild("Buy", true) then return d end
	end
	return nil
end
local cards = {}
for _, id in { "EggRadar", "EggMagnet", "HatchBoost", "LuckyEggCall", "MythicBundle", "LuckPotion", "CashPackSmall" } do
	local c = card(id)
	cards[id] = c and texts(c) or ""
end
local headers = {}
for _, id in { "Potions", "Hunt", "Packs" } do
	local h = pg:FindFirstChild(id .. "Header", true)
	headers[id] = h and h.Text or ""
end
local pass = card("EggHunter")
local preview = pass and pass:FindFirstChild("Preview", true)
shared.R = { radar = cards.EggRadar, magnet = cards.EggMagnet, hatch = cards.HatchBoost, lucky = cards.LuckyEggCall, bundle = cards.MythicBundle,
	potion = cards.LuckPotion, cash = cards.CashPackSmall, hPotions = headers.Potions, hHunt = headers.Hunt, hPacks = headers.Packs,
	pass = pass and texts(pass) or "", hasPass = pass ~= nil, hasPreview = preview ~= nil }''')
    print("shop", ui)
    check(ui["hPotions"] == "POTIONS" and ui["hHunt"] == "EGG HUNTING" and ui["hPacks"] == "CASH & SPINS", f"section headers: {ui['hPotions']} / {ui['hHunt']} / {ui['hPacks']}")
    # (the prices are the owner's: read them from MonetizationConfig instead of hard-coding them)
    prices = srv(sim, 'shared.R = { radar = MC.Products.EggRadar.Price, magnet = MC.Products.EggMagnet.Price, hatch = MC.Products.HatchBoost.Price, lucky = MC.Products.LuckyEggCall.Price, bundle = MC.Products.MythicBundle.Price }')
    for key, name in (("radar", "EGG RADAR"), ("magnet", "EGG MAGNET"), ("hatch", "FAST HATCH"), ("lucky", "LUCKY EGG CALL"), ("bundle", "MYTHIC BUNDLE")):
        price = str(int(prices[key]))
        check(name in ui[key].upper() and price in ui[key], f"shop card {name}: R$ {price}")
    check(ui["potion"] != "" and ui["cash"] != "", "the old potion and cash cards are still in the shop")
    check(ui["hasPass"] and ui["hasPreview"], "the Egg Hunter pass has a card with an egg preview")
    check("EGG HUNTER" in ui["pass"].upper() and "PERMANENT" in ui["pass"].upper(), "...named EGG HUNTER with a PERMANENT badge")
    check("OWNED" in ui["pass"].upper(), "...and it reads OWNED once bought")
    check("DRAGON" not in ui["pass"].upper().replace("NO DRAGON", ""), "...without 'DRAGON' in its title (it is a toolkit)")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    print("done in %ds" % (time.time() - t0))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

"""Phase 5 end-to-end: dragon collection (virtualized window), details and
every action - Equip (hot swap), Ride, Feed, Mutate, Lock, Release, Place /
Take back / Auto place / Buy perch on sanctuary perches - plus the replicated
perch state and the client perch dragons. Renders the window and the plot."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_api  # noqa: E402
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
local PDS = require(SSS.Services.PlayerDataService)
local DS = require(SSS.Services.DragonService)
local MS = require(SSS.Services.MountService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, action, payload="{}", domain="Dragon"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", data = r.data }}
''')
    return lua_table_to_py(res.get("RQ"))


def state(sim):
    return srv(sim, '''
local n, placed = 0, {}
for uid, r in d.Dragons do
	n += 1
	if r.PlacedNestId ~= "" then placed[r.PlacedNestId] = uid end
end
local slots = {}
for k, v in d.Nests.Slots do slots[k] = v end
shared.R = { Count = n, Cash = d.Cash, Equipped = d.EquippedDragon, Unlocked = d.Nests.Unlocked, Slots = slots, Placed = placed }
''')


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(5, 1 / 30)
    ws = sim.services["Workspace"]
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ---------------------------------------------------------------- grant a collection
    r = srv(sim, '''
PDS.Set(p, { "Upgrades", "DragonStorage" }, 2)
PDS.Set(p, { "Cash" }, 50000000)
local ids = {}
local function add(s, m) local rec = DS.Add(p, s, m, "Test"); table.insert(ids, rec and rec.UniqueId or "?") end
add("ForestWyvern", "None"); add("AquaSerpent", "Shiny"); add("CrystalWyvern", "None"); add("FrostDragon", "Golden")
add("InfernoDragon", "None"); add("ThunderDragon", "Shadow")
local species = { "GreenDrake", "ForestWyvern", "AquaSerpent", "CrystalWyvern" }
for i = 1, 34 do add(species[i % 4 + 1], (i % 7 == 0) and "Shiny" or "None") end
shared.R = { Ids = ids }
''')
    ids = r["Ids"]
    st = state(sim)
    print("collection:", st["Count"], "dragons; equipped", st["Equipped"])
    check(st["Count"] == 41, "41 dragons in the collection (starter + 40)")
    sim.run_for(0.5, 1 / 30)

    # ---------------------------------------------------------------- window + virtualization
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
UIC.Open("Inventory")
task.wait(0.6)
local w = UIC.Windows.Inventory
local n = 0
for _ in w.Cards do n += 1 end
shared.INV = { list = #w.List, cards = n, cols = w.Cols, selected = w.SelectedId or "", canvas = w.Grid.CanvasSize.Y.Offset }
''')
    inv = lua_table_to_py(res.get("INV"))
    print("window:", inv)
    check(inv["list"] == 41, "list shows all 41 dragons")
    check(0 < inv["cards"] < 41, f"virtualized: only {inv['cards']} card instances for 41 dragons")
    check(inv["selected"] != "", "first dragon auto-selected (desktop)")
    sim.run_for(1.0, 1 / 30)
    ui_render(sim, player, f"{OUT}/inv_window.png", debug=False)
    # scroll to the bottom: cards are re-bound, not created
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
local before = #w.Pool
for _ in w.Cards do before += 1 end
w.Grid.CanvasPosition = Vector2.new(0, 100000)
task.wait(0.2)
local after = #w.Pool
local lastBound = false
for i, c in w.Cards do after += 1; if i == #w.List then lastBound = true end end
shared.SCR = { before = before, after = after, last = lastBound }
''')
    scr = lua_table_to_py(res.get("SCR"))
    print("scroll:", scr)
    check(scr["last"], "last dragon bound after scrolling to the bottom")
    check(scr["after"] <= scr["before"] + 12, "scrolling recycles pooled cards")
    # search + filter
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
w.Query.Search = "frost"
w:Rebuild(true)
local a = #w.List
w.Query.Search = ""
w.Query.Filter = "Legendary"
w:Rebuild(true)
local b = #w.List
w.Query.Filter = "All"
w.Query.Sort = "Income"
w:Rebuild(true)
shared.Q = { frost = a, legendary = b, top = w.List[1] }
''')
    q = lua_table_to_py(res.get("Q"))
    print("query:", q)
    check(q["frost"] == 1 and q["legendary"] == 1, "search 'frost' -> 1, filter Legendary -> 1")
    check(q["top"] == ids[4] or q["top"] == ids[5] or q["top"] == ids[3], "income sort puts a top earner first")

    # ---------------------------------------------------------------- equip (hot swap)
    model = ws.find_child("Dragons").find_child(f"Dragon_{player.user_id}") if hasattr(player, "user_id") else None
    dragons = ws.find_child("Dragons")
    comp = dragons.children[0] if dragons and dragons.children else None
    rev0 = comp.attrs.get("VisualRev") if comp else None
    r = req(sim, player, "Equip", f'{{ Id = "{ids[0]}" }}')
    sim.run_for(0.5, 1 / 30)
    st = state(sim)
    check(r["ok"] and st["Equipped"] == ids[0], "equip Forest Wyvern")
    comp2 = dragons.children[0] if dragons and dragons.children else None
    check(comp2 is comp and comp2.attrs.get("VisualRev") == (rev0 or 0) + 1 and comp2.attrs.get("SpeciesId") == "ForestWyvern",
          "companion hot-swapped on the same root (VisualRev+1)")

    # ---------------------------------------------------------------- feed
    cash0 = st["Cash"]
    levels = []
    for _ in range(3):
        r = req(sim, player, "Feed", f'{{ Id = "{ids[0]}" }}')
        levels.append((r["ok"], (r.get("data") or {}).get("Level")))
    st = state(sim)
    print("feed:", levels, "cash", cash0, "->", st["Cash"])
    check(all(x[0] for x in levels) and levels[-1][1] == 2, "three meals = one level (Lv 2)")
    check(st["Cash"] < cash0, "feeding costs cash")

    # ---------------------------------------------------------------- mutate
    outcomes = []
    for _ in range(6):
        r = req(sim, player, "Mutate", f'{{ Id = "{ids[2]}" }}')
        d = r.get("data") or {}
        outcomes.append((r["ok"], d.get("Improved"), d.get("Mutation")))
        if d.get("Improved"):
            break
    print("mutate:", outcomes)
    check(all(o[0] for o in outcomes), "mutate attempts accepted and paid")
    r = srv(sim, f'shared.R = {{ m = d.Dragons["{ids[1]}"].Mutation }}')
    # rainbow max check via a forced record
    srv(sim, f'local rec = table.clone(d.Dragons["{ids[1]}"]); rec.Mutation = "Void"; PDS.Set(p, {{"Dragons", "{ids[1]}"}}, rec); shared.R = {{}}')
    r = req(sim, player, "Mutate", f'{{ Id = "{ids[1]}" }}')
    check(not r["ok"] and r["err"] == "MAX_MUTATION", "void dragon (max rank) cannot mutate further")

    # ---------------------------------------------------------------- lock / release
    r = req(sim, player, "Lock", f'{{ Id = "{ids[6]}", Locked = true }}')
    r2 = req(sim, player, "Release", f'{{ Id = "{ids[6]}" }}')
    check(r["ok"] and not r2["ok"] and r2["err"] == "LOCKED", "locked dragon cannot be released")
    req(sim, player, "Lock", f'{{ Id = "{ids[6]}", Locked = false }}')
    cash1 = state(sim)["Cash"]
    r = req(sim, player, "Release", f'{{ Id = "{ids[6]}" }}')
    st = state(sim)
    check(r["ok"] and st["Count"] == 40 and st["Cash"] >= cash1, "release removes the dragon and refunds")

    # ---------------------------------------------------------------- perches
    plot = player.attrs.get("PlotId")
    print("plot", plot)
    r1 = req(sim, player, "Place", f'{{ Id = "{ids[3]}" }}')
    r2 = req(sim, player, "Place", f'{{ Id = "{ids[4]}" }}')
    r3 = req(sim, player, "Place", f'{{ Id = "{ids[5]}" }}')
    print("place:", r1.get("data"), r2.get("data"), r3["err"])
    check(r1["ok"] and r2["ok"] and not r3["ok"] and r3["err"] == "PERCHES_FULL", "two free perches, third refused")
    r = req(sim, player, "BuyPerch")
    r3 = req(sim, player, "Place", f'{{ Id = "{ids[5]}" }}')
    st = state(sim)
    check(r["ok"] and r3["ok"] and st["Unlocked"] == 3 and len(st["Slots"]) == 3, "buy perch 3 and place a third dragon")
    # placing the equipped dragon moves equip to another free dragon
    r = req(sim, player, "Place", f'{{ Id = "{ids[0]}", Slot = 3 }}')
    st = state(sim)
    check(r["ok"] and (r.get("data") or {}).get("Swapped") == ids[5] and st["Equipped"] != ids[0],
          "place equipped dragon on an occupied perch: swap + re-equip")
    sstate = sim.services["ReplicatedStorage"].find_child("SanctuaryState").find_child(f"Plot{int(plot)}")
    perch_attrs = {i: sstate.attrs.get(f"Perch{i}") for i in range(1, 9)}
    print("replicated perches:", perch_attrs, "unlocked", sstate.attrs.get("PerchesUnlocked"))
    check(bool(perch_attrs[1]) and bool(perch_attrs[3]) and not perch_attrs[4], "perch state replicated")
    # client perch dragons + markers
    sim.run_for(3, 1 / 30)
    pd = ws.find_child("PerchDragons")
    mine = [m for m in (pd.children if pd else []) if m.attrs.get("PlotId") == plot]
    built = [m for m in mine if m.find_child("Visual") is not None]
    print("perch dragons on my plot:", len(mine), "with visuals:", len(built))
    check(len(mine) == 3 and len(built) == 3, "three resting dragons built on my perches")
    mp = ws.find_child("MyPerches")
    names = sorted(c.props.get("Name") for c in (mp.children if mp else []))
    print("my perch markers:", names)
    check("PerchAnchor4" in names and any(n.startswith("PerchAnchor") for n in names), "perch prompts/markers on my plot")
    # take back
    r = req(sim, player, "TakeBack", f'{{ Id = "{ids[3]}" }}')
    sim.run_for(0.5, 1 / 30)
    check(r["ok"] and not sstate.attrs.get("Perch1"), "take back clears the perch")
    # auto place fills perches with the best free dragons
    r = req(sim, player, "AutoPlace")
    st = state(sim)
    print("autoplace:", r.get("data"), st["Slots"])
    check(r["ok"] and len(st["Slots"]) == 3 and st["Equipped"] not in st["Slots"].values(), "auto place fills free perches, never the equipped dragon")

    # keep one free: a tiny collection cannot place its last free dragon
    r = srv(sim, '''
local keep = d.EquippedDragon
for uid, rec in table.clone(d.Dragons) do
	if uid ~= keep and rec.PlacedNestId == "" then DS.Remove(p, uid) end
end
local n = 0
for _, rec in d.Dragons do if rec.PlacedNestId == "" then n += 1 end end
shared.R = { free = n, keep = keep }
''')
    print("free dragons:", r)
    rr = req(sim, player, "BuyPerch")
    rr = req(sim, player, "Place", f'{{ Id = "{r["keep"]}" }}')
    check(not rr["ok"] and rr["err"] in ("KEEP_ONE",), f"last free dragon stays out ({rr['err']})")

    # ---------------------------------------------------------------- ride from the window
    res = run_client_lua(sim, player, '''
local UIC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
local w = UIC.Windows.Inventory
UIC.Open("Inventory", { SelectId = w.List[1] })
task.wait(0.3)
w:Select(w.List[1], true)
w:DoRide()
task.wait(1.0)
shared.RIDE = { riding = game:GetService("Players").LocalPlayer:GetAttribute("Riding") == true, open = UIC.Current or "" }
''')
    rd = lua_table_to_py(res.get("RIDE"))
    print("ride:", rd)
    check(rd["riding"] and rd["open"] == "", "RIDE equips, mounts and closes the window")
    # hot swap while riding: equip a placed dragon's neighbour (take back first)
    st = state(sim)
    other = list(st["Slots"].values())[0]
    req(sim, player, "TakeBack", f'{{ Id = "{other}" }}')
    r = req(sim, player, "Equip", f'{{ Id = "{other}" }}')
    sim.run_for(0.5, 1 / 30)
    riding = player.attrs.get("Riding")
    comp3 = dragons.children[0] if dragons.children else None
    joint = comp3.find_child("Root").find_child("RiderJoint") if comp3 and comp3.find_child("Root") else None
    check(r["ok"] and riding and joint is not None, "equip while riding swaps the dragon and keeps the rider seated")
    r = req(sim, player, "Release", f'{{ Id = "{other}" }}')
    check(not r["ok"] and r["err"] in ("RIDING", "LAST_DRAGON", "KEEP_ONE"), f"cannot release the ridden dragon ({r['err']})")

    # ---------------------------------------------------------------- render the plot (perch dragons)
    try:
        import preview3d
        from sim_runner import _haven_cache
        frame = srv(sim, f'''
local WC = require(game:GetService("ReplicatedStorage").Configs.WorldConfig)
local cf = WC.plotFrame({int(plot)})
shared.R = {{ cf.Position.X, cf.Position.Y, cf.Position.Z, math.deg(WC.Plots[{int(plot)}].Facing) }}
''')
        parts = preview3d.part_records(sim)
        terrain = sim.haven.preview_terrain() if hasattr(sim, "haven") else None
        jobs, paths = [], []
        for i, (yaw, pitch, dist) in enumerate([(frame[3] + 180, 38, 95), (frame[3] + 140, 22, 60)]):
            cam = preview3d.orbit_camera([frame[0], frame[1] + 4, frame[2]], dist, yaw, pitch, fov=50)
            sc = preview3d.make_scene(parts, cam, terrain=terrain, fog_density=0.0006, shadow_center=[frame[0], frame[1], frame[2]], shadow_extent=90)
            pth = f"{OUT}/inv_plot_{i}.png"
            jobs.append((sc, pth, 960, 560))
            paths.append(pth)
        preview3d.render_batch(jobs)
        preview3d.contact_sheet(paths, ["plot overview", "perches"], f"{OUT}/inv_plot_sheet.png", cols=2)
    except Exception as ex:
        print("plot render skipped:", ex)

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:12]:
        print("  ", e)
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()

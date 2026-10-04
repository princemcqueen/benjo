"""Phase 4 end-to-end: personal egg spawns, pickup (walk into an egg), bag
capacity, nest placement, incubation timer, hatch cinematic + result card,
dragon added to the inventory. Renders key moments."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import rbx_api  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
from sim_runner import boot, client_of, run_client_lua, lua_table_to_py, render as ui_render  # noqa: E402

from paths import OUT  # noqa: E402


def data_of(sim, player):
    ctx = client_of(player)
    return None


def server_data(sim, player):
    import luau_interp as LI
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    src = '''
local PDS = require(game:GetService("ServerScriptService").Services.PlayerDataService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
local n = 0
for _ in d.Dragons do n += 1 end
local slots = {}
for k, v in d.Incubator.Slots do slots[k] = v.Type end
shared.SD = { Eggs = #d.Eggs, Dragons = n, Hatched = d.Stats.Hatched, Found = d.Stats.EggsFound, Slots = slots, Unlocked = d.Incubator.Unlocked }
'''
    fn = LI.load(src, "sd", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("SD"))


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(5, 1 / 30)
    ws = sim.services["Workspace"]
    my = ws.find_child("MyEggs")
    eggs = [c for c in my.children] if my else []
    print("client eggs:", len(eggs), [e.props.get("Name") for e in eggs][:8])
    sd = server_data(sim, player)
    print("server data:", sd)
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    # walk into three eggs (teleport next to them)
    picked = 0
    for e in eggs[:3]:
        shell = e.find_child("Shell")
        if shell is None or e.parent is None:
            print("   egg gone before visit:", e.props.get("Name"))
            continue
        cf = rbx_api.part_cframe(sim, shell)
        hrp.props["CFrame"] = CFrame((cf.p[0] + 3, cf.p[1] + 1, cf.p[2]))
        sim.run_for(1.0, 1 / 30)
        hp = rbx_api.part_cframe(sim, hrp).p
        print(f"   visited {e.props.get('Name')} at {tuple(round(v, 1) for v in cf.p)}; hrp now {tuple(round(v, 1) for v in hp)}; "
              f"still there: {e.parent is not None}; data {server_data(sim, player)['Eggs']}")
        picked += 1
    sd = server_data(sim, player)
    print("after pickups:", sd)
    # go to the nest
    plot = player.attrs.get("PlotId")
    print("plot", plot)
    res = run_client_lua(sim, player, '''
local SC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.SanctuaryController)
local cf = SC.nestCFrame()
shared.NEST = { cf.Position.X, cf.Position.Y, cf.Position.Z }
''')
    nest = lua_table_to_py(res.get("NEST"))
    hrp.props["CFrame"] = CFrame((nest[0] + 6, nest[1] + 3, nest[2] + 6))
    sim.run_for(1.0, 1 / 30)
    res = run_client_lua(sim, player, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r1 = Net.request("Egg", "Place", {})
local r2 = Net.request("Egg", "Place", {})
local r3 = Net.request("Egg", "Place", {})
shared.PLACE = { r1.ok, r2.ok, r3.ok, r3.err or "" }
''')
    print("place:", lua_table_to_py(res.get("PLACE")))
    sd = server_data(sim, player)
    print("after place:", sd)
    ms = ws.find_child("MySanctuary")
    print("sanctuary visuals:", sorted(c.props.get("Name") for c in ms.children) if ms else None)
    # too early
    res = run_client_lua(sim, player, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Egg", "Hatch", { Slot = 1 })
shared.EARLY = { r.ok, r.err or "" }
''')
    print("early hatch:", lua_table_to_py(res.get("EARLY")))
    # wait out incubation (sim time drives os.time via wall epoch + clock)
    sim.run_for(42, 1 / 10)
    # render the nest with eggs
    try:
        ui_render(sim, player, f"{OUT}/egg_nest_ui.png", debug=False)
    except Exception as ex:
        print("ui render skipped:", ex)
    # hatch via the controller (runs the cinematic); press AWESOME! after the card shows
    run_client_lua(sim, player, '''
local HC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.HatchController)
task.spawn(HC.hatch, 1)
''')
    t0 = time.time()
    card = None
    for i in range(400):
        sim.step(1 / 30)
        pg = player.find_child("PlayerGui")
        for d in pg.descendants() if pg else []:
            if d.props.get("Name") == "HatchResult":
                card = d
                break
        if card is not None:
            break
    print("result card shown:", card is not None, "after", round(i / 30, 1), "s sim")
    if card is not None:
        try:
            ui_render(sim, player, f"{OUT}/egg_hatch_card.png", debug=False)
        except Exception as ex:
            print("card render skipped:", ex)
        # click "AWESOME!"
        btn = None
        for d in card.descendants():
            if d.props.get("Name") == "Continue":
                btn = d
        import rbx_api as A
        if btn is not None:
            A.fire_signal(sim, btn, "Activated") if hasattr(A, "fire_signal") else None
    sim.run_for(3, 1 / 30)
    sd = server_data(sim, player)
    print("after hatch:", sd)
    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    return sim, player


if __name__ == "__main__":
    main()

"""Egg in hand: a picked-up egg is carried in the hand (replicated through player
attributes, drawn on the character), the HUD chip shows it, and you place it into the
nest spot of your choice (the egg flies from the hand into the spot)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_api  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py, NO_GUARDIANS  # noqa: E402

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
local ES = require(SSS.Services.EggService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src):
    head = '''
local Players = game:GetService("Players")
local LP = Players.LocalPlayer
local Controllers = LP.PlayerScripts.Controllers
local HC = require(Controllers.HeldEggController)
local SC = require(Controllers.SanctuaryController)
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
'''
    res = run_client_lua(sim, player, head + src)
    return lua_table_to_py(res.get("R"))


def press(sim, player, path_lua, seconds=0.45):
    """Holds a ProximityPrompt (found by the Lua expression `path_lua`) like a player would."""
    run_client_lua(sim, player, f'''
local prompt = {path_lua}
prompt:InputHoldBegin()
shared.R = {{}}
''')
    sim.run_for(seconds, 1 / 30)
    run_client_lua(sim, player, f'''
local prompt = {path_lua}
prompt:InputHoldEnd()
shared.R = {{}}
''')


def main():
    sim = boot(extra_server=[NO_GUARDIANS])
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(5, 1 / 30)
    ws = sim.services["Workspace"]
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")

    # ---------------------------------------------------------------- empty hand
    r = srv(sim, '''shared.R = { held = ES.Held(p) or "", type = p:GetAttribute("HeldEggType") or "" }''')
    check(r["held"] == "" and r["type"] == "", "hand is empty before the first pickup")
    r = cli(sim, player, '''
local hud = LP.PlayerGui:FindFirstChild("HeldEgg", true)
shared.R = { chip = hud ~= nil and hud.Visible, id = HC.id() or "" }''')
    check(r["chip"] is False and r["id"] == "", "HUD chip hidden with an empty hand")

    # ---------------------------------------------------------------- pickup -> hand
    def visit(index):
        my = ws.find_child("MyEggs")
        eggs = [c for c in my.children if c.find_child("Shell") is not None]
        e = eggs[index]
        cf = rbx_api.part_cframe(sim, e.find_child("Shell"))
        hrp.props["CFrame"] = CFrame((cf.p[0] + 3, cf.p[1] + 1, cf.p[2]))
        sim.run_for(1.2, 1 / 30)

    visit(0)
    r = srv(sim, '''
local eggs = d.Eggs
shared.R = { n = #eggs, id = eggs[1] and eggs[1].Id or "", held = ES.Held(p) or "", type = p:GetAttribute("HeldEggType") or "",
	luck = p:GetAttribute("HeldEggLuck") or 0, eggType = eggs[1] and eggs[1].Type or "" }''')
    first = r["id"]
    check(r["n"] == 1 and first != "", "egg picked up into the bag")
    check(r["held"] == first, f"the picked egg is in the hand ({r['held']})")
    check(r["type"] == r["eggType"] and r["luck"] >= 1, f"hand carries its type/luck ({r['type']} x{r['luck']})")

    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
local model = folder and folder:FindFirstChild("HeldEgg_" .. LP.UserId)
local hrp = LP.Character.HumanoidRootPart
local dist = -1
if model then dist = (model:GetPivot().Position - hrp.Position).Magnitude end
local hud = LP.PlayerGui:FindFirstChild("HeldEgg", true)
local name = hud and hud:FindFirstChild("Name", true)
shared.R = {
	id = HC.id() or "", hasModel = model ~= nil, dist = dist,
	chip = hud ~= nil and hud.Visible, chipText = name and name.Text or "",
	flights = folder and #folder:GetChildren() or 0,
	prompt = SC.holding(),
}''')
    check(r["id"] == first and r["hasModel"], "client draws the egg in the hand")
    check(0 < r["dist"] < 5, f"held egg sits at the character ({r['dist']:.1f} studs from the root)")
    check(r["chip"] is True and r["chipText"] != "", f"HUD chip shows the egg ({r['chipText']})")
    check(r["prompt"] is True, "sanctuary knows the hand is full")

    # ---------------------------------------------------------------- second egg goes to the bag
    visit(1)
    r = srv(sim, '''shared.R = { n = #d.Eggs, held = ES.Held(p) or "" }''')
    check(r["n"] == 2 and r["held"] == first, "second egg goes to the bag, hand keeps the first")

    # ---------------------------------------------------------------- hold / put away requests
    r = cli(sim, player, '''
local second
for _, e in require(Controllers.DataController).get("Eggs") do
	if e.Id ~= HC.id() then second = e.Id end
end
local bad = Net.request("Egg", "Hold", { Id = "E_nope" })
local away = Net.request("Egg", "Hold", {})
local afterAway = HC.id() or ""
local take = Net.request("Egg", "Hold", { Id = second })
local afterTake = HC.id() or ""
local best = Net.request("Egg", "Hold", { Best = true })
shared.R = { second = second, bad = bad.ok, badErr = bad.err or "", away = away.ok, afterAway = afterAway,
	take = take.ok, afterTake = afterTake, best = best.ok, afterBest = HC.id() or "" }''')
    sim.run_for(0.5, 1 / 30)
    check(r["bad"] is False and r["badErr"] == "NOT_FOUND", "holding an egg you do not have is refused")
    check(r["away"] is True, "putting the egg away works")
    r2 = srv(sim, '''shared.R = { held = ES.Held(p) or "" }''')
    check(r2["held"] != "", "a held egg exists after the Best request")
    best = r2["held"]

    # ---------------------------------------------------------------- nest: too far
    r = cli(sim, player, '''
local res = Net.request("Egg", "Place", { Id = HC.id(), Slot = 1 })
shared.R = { ok = res.ok, err = res.err or "" }''')
    check(r["ok"] is False and r["err"] == "TOO_FAR", f"cannot place far from the nest ({r['err']})")
    r = srv(sim, '''shared.R = { held = ES.Held(p) or "", n = #d.Eggs }''')
    check(r["held"] == best and r["n"] == 2, "failed placing keeps the egg in hand")

    # ---------------------------------------------------------------- walk to the nest, choose slot 2
    r = cli(sim, player, '''
local cf2 = SC.slotCFrame(2)
local cf = SC.nestCFrame()
shared.R = { sx = cf2.Position.X, sy = cf2.Position.Y, sz = cf2.Position.Z, nx = cf.Position.X, ny = cf.Position.Y, nz = cf.Position.Z }''')
    hrp.props["CFrame"] = CFrame((r["sx"] + 1.5, r["sy"] + 2, r["sz"] + 1.5))
    sim.run_for(1.0, 1 / 30)
    r = cli(sim, player, '''
local prompts = {}
local free = workspace:FindFirstChild("MySanctuary")
for _, d in (free and free:GetDescendants() or {}) do
	if d:IsA("ProximityPrompt") and d.Name == "PlaceHerePrompt" then
		table.insert(prompts, d.Enabled)
	end
end
local allOn = #prompts > 0
for _, e in prompts do allOn = allOn and e end
shared.R = { n = #prompts, allOn = allOn, center = workspace.MySanctuary.NestAnchor.PlaceEggPrompt.ActionText }''')
    check(r["n"] >= 2 and r["allOn"], f"every free nest spot offers 'Place Egg' while holding ({r['n']} spots)")
    check(r["center"] == "Place Egg", "the nest prompt places the egg in hand")

    press(sim, player, 'workspace.MySanctuary.PlaceSpot2.PlaceHerePrompt', 0.3)
    sim.run_for(0.2, 1 / 30)
    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
local flying = 0
for _, c in (folder and folder:GetChildren() or {}) do if c.Name == "FlyingEgg" then flying += 1 end end
shared.R = { flying = flying, nest2 = workspace.MySanctuary:FindFirstChild("NestEgg2") ~= nil }''')
    check(r["flying"] >= 1, "the egg flies from the hand towards the nest spot")
    check(r["nest2"] is False, "...and appears in the spot only when it lands")
    sim.run_for(1.0, 1 / 30)
    r = srv(sim, '''
local slots = {}
for k, v in d.Incubator.Slots do slots[k] = v.Id end
shared.R = { slot2 = slots["2"] or "", slot1 = slots["1"] or "", n = #d.Eggs, held = ES.Held(p) or "" }''')
    check(r["slot2"] == best and r["slot1"] == "", "egg sits in the chosen spot (2), spot 1 stays free")
    check(r["n"] == 1, "bag lost exactly that egg")
    check(r["held"] != "" and r["held"] != best, "next egg of the bag is taken in hand (free spots remain)")
    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
local flying = 0
for _, c in (folder and folder:GetChildren() or {}) do if c.Name == "FlyingEgg" then flying += 1 end end
shared.R = { flying = flying, nest2 = workspace.MySanctuary:FindFirstChild("NestEgg2") ~= nil,
	ring2 = workspace.MySanctuary:FindFirstChild("FreeSlot2") ~= nil }''')
    check(r["flying"] == 0 and r["nest2"] is True, "the landed egg is now part of the nest")
    check(r["ring2"] is False, "free-spot marker of spot 2 is gone")

    # ---------------------------------------------------------------- busy slot, then the nest prompt (first free)
    r = cli(sim, player, '''
local res = Net.request("Egg", "Place", { Id = HC.id(), Slot = 2 })
shared.R = { ok = res.ok, err = res.err or "" }''')
    check(r["ok"] is False and r["err"] == "SLOT_BUSY", "an occupied spot is refused")
    r = cli(sim, player, '''
local cf = SC.nestCFrame()
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z }''')
    hrp.props["CFrame"] = CFrame((r["x"] + 3, r["y"] + 3, r["z"] + 3))
    sim.run_for(0.6, 1 / 30)
    press(sim, player, 'workspace.MySanctuary.NestAnchor.PlaceEggPrompt', 0.5)
    sim.run_for(1.5, 1 / 30)
    r = srv(sim, '''
local slots = {}
for k, v in d.Incubator.Slots do slots[k] = v.Id end
shared.R = { slot1 = slots["1"] or "", n = #d.Eggs, held = ES.Held(p) or "" }''')
    check(r["slot1"] != "" and r["n"] == 0, "nest prompt puts the egg in the first free spot")
    check(r["held"] == "", "hand is empty when the bag is empty")
    r = cli(sim, player, '''
local hud = LP.PlayerGui:FindFirstChild("HeldEgg", true)
local folder = workspace:FindFirstChild("HeldEggs")
local model = folder and folder:FindFirstChild("HeldEgg_" .. LP.UserId)
local prompts = true
for _, d in workspace.MySanctuary:GetDescendants() do
	if d:IsA("ProximityPrompt") and d.Name == "PlaceHerePrompt" and d.Enabled then prompts = false end
end
shared.R = { chip = hud.Visible, model = model ~= nil, prompts = prompts }''')
    check(r["chip"] is False and r["model"] is False, "HUD chip and hand visual vanish with an empty hand")
    check(r["prompts"] is True, "per-spot prompts switch off with an empty hand")

    # ---------------------------------------------------------------- take an egg out of the bag at the nest
    visit_back = srv(sim, '''
local before = #d.Eggs
shared.R = { before = before }''')
    # pick another egg in the world (teleports away from the nest), then come back
    visit(2)
    r = srv(sim, '''shared.R = { n = #d.Eggs, held = ES.Held(p) or "" }''')
    check(r["n"] == 1 and r["held"] != "", "a new pickup is held again")
    cli(sim, player, '''HC.putAway() shared.R = {}''')
    sim.run_for(0.5, 1 / 30)
    r = srv(sim, '''shared.R = { held = ES.Held(p) or "", n = #d.Eggs }''')
    check(r["held"] == "" and r["n"] == 1, "PUT AWAY returns the egg to the bag")
    r = cli(sim, player, '''
local cf = SC.nestCFrame()
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z }''')
    hrp.props["CFrame"] = CFrame((r["x"] + 5, r["y"] + 3, r["z"] + 5))
    sim.run_for(1.0, 1 / 30)
    srv(sim, '''PDS.Set(p, { "Incubator", "Unlocked" }, 4) shared.R = {}''')
    sim.run_for(0.6, 1 / 30)
    r = cli(sim, player, '''
local prompt = workspace.MySanctuary.NestAnchor.PlaceEggPrompt
shared.R = { action = prompt.ActionText, enabled = prompt.Enabled }''')
    check(r["action"] == "Take Egg" and r["enabled"] is True, "empty hand + eggs in the bag: the nest offers 'Take Egg'")
    press(sim, player, 'workspace.MySanctuary.NestAnchor.PlaceEggPrompt', 0.5)
    sim.run_for(0.5, 1 / 30)
    r = srv(sim, '''shared.R = { held = ES.Held(p) or "" }''')
    check(r["held"] != "", "pressing 'Take Egg' takes the egg out of the bag into the hand")

    # ---------------------------------------------------------------- reconcile + riding + respawn
    sim.run_for(0.5, 1 / 30)
    srv(sim, '''p:SetAttribute("Riding", true) shared.R = {}''')
    sim.run_for(0.3, 1 / 30)
    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
local model = folder and folder:FindFirstChild("HeldEgg_" .. LP.UserId)
local hud = LP.PlayerGui:FindFirstChild("HeldEgg", true)
shared.R = { model = model ~= nil, id = HC.id() or "" }''')
    check(r["id"] != "" and r["model"] is False, "the egg in hand is hidden while riding a dragon")
    srv(sim, '''p:SetAttribute("Riding", false) shared.R = {}''')
    sim.run_for(0.3, 1 / 30)
    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
shared.R = { model = folder and folder:FindFirstChild("HeldEgg_" .. LP.UserId) ~= nil }''')
    check(r["model"] is True, "...and back in the hand after dismounting")

    rbx_api.spawn_character(sim, player)
    sim.run_for(1.0, 1 / 30)
    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
shared.R = { model = folder and folder:FindFirstChild("HeldEgg_" .. LP.UserId) ~= nil, held = HC.id() or "" }''')
    check(r["model"] is True and r["held"] != "", "the egg survives a respawn (visual rebuilt for the new character)")

    # the egg leaves the bag some other way -> the hand empties by itself
    srv(sim, '''
PDS.Set(p, { "Eggs" }, {})
shared.R = {}''')
    sim.run_for(2.5, 1 / 30)
    r = srv(sim, '''shared.R = { held = ES.Held(p) or "" }''')
    check(r["held"] == "", "a held egg that left the bag is dropped from the hand")
    r = cli(sim, player, '''
local folder = workspace:FindFirstChild("HeldEggs")
shared.R = { model = folder and folder:FindFirstChild("HeldEgg_" .. LP.UserId) ~= nil }''')
    check(r["model"] is False, "...and its visual disappears")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    del visit_back
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

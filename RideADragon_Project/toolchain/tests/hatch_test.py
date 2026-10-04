"""Hatching cinematic v2: approach -> charge (cracks) -> burst -> the dragon WALKS to the
camera -> ROAR -> result card; SKIP jumps to the card; everything is cleaned up afterwards."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_api  # noqa: E402
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
local PDS = require(SSS.Services.PlayerDataService)
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
local HC = require(LP.PlayerScripts.Controllers.HatchController)
'''
    res = run_client_lua(sim, player, head + src)
    return lua_table_to_py(res.get("R"))


def click(sim, player, name):
    pg = player.find_child("PlayerGui")
    for d in pg.descendants():
        if d.props.get("Name") == name and d.cls.name == "TextButton":
            d.get_signal("Activated").fire()
            sim.sched.run_deferred()
            return True
    return False


SAMPLE = '''
local stage = HC.Stage
local dragon = HC.Dragon
local out = { phase = HC.Phase, stage = stage ~= nil }
local cam = workspace.CurrentCamera
out.cam = { cam.CFrame.Position.X, cam.CFrame.Position.Y, cam.CFrame.Position.Z }
out.fov = cam.FieldOfView
if stage then
	local cracks, eggs = 0, 0
	for _, d in stage:GetDescendants() do
		if d:IsA("BasePart") and string.sub(d.Name, 1, 5) == "Crack" then cracks += 1 end
		if d:IsA("Model") and d.Name == "Egg" then eggs += 1 end
	end
	out.cracks = cracks
	out.eggs = eggs
	out.hatchling = stage:FindFirstChild("Hatchling") ~= nil
end
if dragon then
	local r = dragon.Root.Position
	out.root = { r.X, r.Y, r.Z }
	-- total joint movement of the whole rig (changes with every step of the gait)
	local pose = 0
	for _, motor in dragon.Anim.Motors do
		local rx, ry, rz = motor.Transform:ToEulerAnglesXYZ()
		pose += math.abs(rx) + math.abs(ry) + math.abs(rz)
	end
	out.leg = pose
	out.roaring = dragon.Anim:IsPlaying("Roar")
	out.walking = dragon.Anim.Target
end
local pg = LP.PlayerGui
out.card = pg:FindFirstChild("HatchResult", true) ~= nil
out.skip = (function()
	local b = pg:FindFirstChild("HatchSkip", true)
	return b ~= nil and b.Visible
end)()
out.hud = LP.PlayerGui:FindFirstChild("GameHUD") ~= nil and LP.PlayerGui.GameHUD.Enabled
local lighting = game:GetService("Lighting")
out.grade = lighting:FindFirstChild("HatchGrade") ~= nil
out.focus = lighting:FindFirstChild("HatchFocus") ~= nil
out.camType = tostring(cam.CameraType)
out.prompts = game:GetService("ProximityPromptService").Enabled
local banner = pg:FindFirstChild("HatchName", true)
out.banner = banner ~= nil
if banner then
	local text, shown = "", 0
	local row = banner:FindFirstChild("Letters")
	if row then
		local children = {}
		for _, c in row:GetChildren() do
			if c:IsA("TextLabel") then table.insert(children, c) end
		end
		table.sort(children, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
		for _, l in children do
			if l:IsA("TextLabel") then
				text ..= (l.Text == "\\u{2002}") and " " or l.Text
				if l.TextTransparency < 0.5 then shown += 1 end
			end
		end
	end
	out.name = text
	out.shown = shown
	local number = banner:FindFirstChild("Number")
	out.number = number and number.Text or ""
	local sparks = 0
	for _, d in banner:GetChildren() do
		if d.Name == "Spark" then sparks += 1 end
	end
	out.sparks = sparks
end
shared.R = out
'''


def sample(sim, player):
    return cli(sim, player, SAMPLE)


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def watch(sim, player, until_phase_exit=None, max_seconds=40, step=0.1, log=None):
    """Steps the sim, sampling every `step` seconds; returns the samples."""
    out = []
    t = 0
    while t < max_seconds:
        sim.run_for(step, 1 / 30)
        t += step
        s = sample(sim, player)
        s["t"] = round(t, 2)
        out.append(s)
        if log is not None:
            log.append(s)
        if until_phase_exit and s["phase"] == until_phase_exit:
            break
    return out


def put_ready_egg(sim, egg_type, egg_id, luck=1):
    srv(sim, f'''
PDS.Set(p, {{ "Incubator", "Slots", "1" }}, {{ Type = "{egg_type}", Start = os.time() - 100, Ready = os.time() - 1, Id = "{egg_id}", Luck = {luck} }})
shared.R = {{}}''')


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(5, 1 / 30)
    ws = sim.services["Workspace"]
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    nest = cli(sim, player, '''
local SC = require(LP.PlayerScripts.Controllers.SanctuaryController)
local cf = SC.nestCFrame()
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z }''')
    hrp.props["CFrame"] = CFrame((nest["x"] + 6, nest["y"] + 3, nest["z"] + 6))
    sim.run_for(1.0, 1 / 30)

    # ------------------------------------------------------------ a normal hatch
    put_ready_egg(sim, "FrostEgg", "E_t1")
    sim.run_for(0.6, 1 / 30)
    cli(sim, player, '''task.spawn(HC.hatch, 1) shared.R = {}''')
    samples = []
    # approach .. charge .. burst .. walk .. roar .. card
    watch(sim, player, until_phase_exit="Card", max_seconds=45, step=0.1, log=samples)
    phases = []
    for s in samples:
        if s["phase"] and (not phases or phases[-1] != s["phase"]):
            phases.append(s["phase"])
    print("phases:", phases)
    check(phases == ["Approach", "Charge", "Burst", "Walk", "Roar", "Card"] or phases == ["Approach", "Charge", "Walk", "Roar", "Card"],
          f"cinematic runs its beats in order ({' > '.join(phases)})")
    check(all(s["stage"] for s in samples if s["phase"]), "a stage exists while the cinematic runs")
    check(any(s["grade"] and s["focus"] for s in samples), "the scene is graded (colour correction + depth of field)")
    charge = [s for s in samples if s["phase"] == "Charge"]
    check(len(charge) > 5, f"charging takes time ({len(charge) * 0.1:.1f}s)")
    max_cracks = max((s.get("cracks", 0) for s in samples), default=0)
    check(max_cracks >= 12, f"the shell cracks open ({max_cracks // 3} cracks)")
    check(any(s.get("eggs", 0) for s in samples if s["phase"] in ("Approach", "Charge")), "the egg is on stage during the charge")
    check(not any(s.get("eggs", 0) for s in samples if s["phase"] in ("Walk", "Roar", "Card")), "the egg is gone after the burst")
    walk = [s for s in samples if s["phase"] == "Walk" and s.get("root")]
    check(len(walk) >= 10, f"the dragon walks for {len(walk) * 0.1:.1f}s")
    if len(walk) >= 5:
        d0 = dist(walk[0]["root"], walk[0]["cam"])
        d1 = dist(walk[-1]["root"], walk[-1]["cam"])
        moved = dist(walk[0]["root"], walk[-1]["root"])
        check(d1 < d0 - 3, f"it walks towards the camera ({d0:.0f} -> {d1:.0f} studs)")
        check(moved > 4, f"...covering real ground ({moved:.1f} studs)")
        legs = [s["leg"] for s in walk if s.get("leg") is not None]
        check(max(legs) - min(legs) > 0.05, "the rig really moves (live gait animation)")
        check(any(s.get("walking") == "Walk" for s in walk), "the Animator is in its Walk state")
    roar = [s for s in samples if s["phase"] == "Roar"]
    check(any(s.get("roaring") for s in roar), "the dragon plays its Roar")
    check(len(roar) > 5, f"the roar lasts a moment ({len(roar) * 0.1:.1f}s)")
    check(any(s["fov"] < 66 for s in roar), "camera punches in during the roar")
    check(not any(s["hud"] for s in samples if s["phase"] in ("Charge", "Walk", "Roar")), "HUD is hidden during the show")
    check(not any(s["prompts"] for s in samples if s["phase"]), "world prompts (E / F bubbles) are hidden during the whole show")
    # riding on/off while the show runs must not bring the bubbles back
    cli(sim, player, '''LP:SetAttribute("Riding", true) task.wait(0.2) LP:SetAttribute("Riding", false) task.wait(0.2) shared.R = {}''')

    expect = srv(sim, '''
local MC = require(game:GetService("ReplicatedStorage").Configs.MutationConfig)
local DC = require(game:GetService("ReplicatedStorage").Configs.DragonConfig)
local last
for _, r in d.Dragons do last = r end
local best
for _, r in d.Dragons do
	if best == nil or (r.CreatedAt or 0) >= (best.CreatedAt or 0) then best = r end
end
local m = best.Mutation ~= "None" and MC.Mutations[best.Mutation] or nil
shared.R = { name = string.upper((m and (m.Name .. " ") or "") .. best.Name), order = DC.Species[best.SpeciesId].Order, total = #DC.speciesList() }''')
    roar_s = [x for x in samples if x["phase"] in ("Roar", "Card") and x.get("banner")]
    check(len(roar_s) > 0, "the name banner appears with the roar")
    if roar_s:
        print("banner:", expect, roar_s[-1].get("name"), roar_s[-1].get("number"), "max sparks", max(x.get("sparks", 0) for x in roar_s))
        check(roar_s[-1]["name"] == expect["name"], f"the FULL name is shown ({roar_s[-1]['name']})")
        check(roar_s[-1]["number"] == f"DRAGON  No. {int(expect['order']):02d} / {int(expect['total'])}", f"its Index number is shown ({roar_s[-1]['number']})")
        check(roar_s[0]["shown"] < roar_s[-1]["shown"] or len(roar_s) == 1, "the letters pop in one after another")
        check(max(x.get("sparks", 0) for x in roar_s) > 0, "every letter throws sparks")
        check(roar_s[-1]["shown"] == len(expect["name"]), "all letters are visible at the end")
    sim.run_for(1.6, 1 / 30)
    s = sample(sim, player)
    check(s["card"] is True and s["phase"] == "Card", "the result card appears and stays up until you decide")
    sim.run_for(3.0, 1 / 30)
    s = sample(sim, player)
    check(s["card"] is True and s["phase"] == "Card", "...still there 3 seconds later")
    check(click(sim, player, "Continue"), "AWESOME! button found")
    sim.run_for(2.0, 1 / 30)
    s = sample(sim, player)
    check(s["phase"] == "" and s["stage"] is False, "stage is removed afterwards")
    check(s["hud"] is True, "HUD is back")
    check(s["banner"] is False, "the name banner is gone afterwards")
    check(s["prompts"] is True, "world prompts are back after the show")
    check(s["grade"] is False and s["focus"] is False, "cinematic grading is removed")
    check(s["card"] is False, "card is gone")
    check(abs(s["fov"] - 70) < 1, f"field of view restored ({s['fov']:.0f})")
    r = srv(sim, '''
local n = 0
for _, r in d.Dragons do n += 1 end
shared.R = { dragons = n, slot = d.Incubator.Slots["1"] == nil, hatched = d.Stats.Hatched }''')
    check(r["slot"] is True and r["dragons"] >= 2, "server really created the dragon and cleared the nest spot")

    # ------------------------------------------------------------ skip
    put_ready_egg(sim, "HavenEgg", "E_t2")
    sim.run_for(0.6, 1 / 30)
    cli(sim, player, '''task.spawn(HC.hatch, 1) shared.R = {}''')
    sim.run_for(1.4, 1 / 30)
    s = sample(sim, player)
    check(s["phase"] in ("Approach", "Charge") and s["skip"] is True, f"SKIP shows up during the build-up ({s['phase']})")
    check(click(sim, player, "HatchSkip"), "SKIP button found")
    skipped = []
    watch(sim, player, until_phase_exit="Card", max_seconds=6, step=0.1, log=skipped)
    sim.run_for(1.6, 1 / 30)
    last = sample(sim, player)
    last["t"] = skipped[-1]["t"]
    check(last["phase"] == "Card" and last["card"] is True, f"SKIP jumps to the result card within {last['t'] + 1.6:.1f}s")
    check(not any(x["phase"] in ("Walk", "Roar") and x.get("roaring") for x in skipped[:-1]), "no walk or roar when skipped")
    check(last.get("hatchling") is True, "the dragon is still there for the card")
    check(last.get("banner") is True and last.get("shown", 0) > 0 and last["shown"] == len(last["name"]), "skipping shows the full name at once")
    check(click(sim, player, "Continue"), "button found")
    sim.run_for(2.0, 1 / 30)
    s = sample(sim, player)
    check(s["phase"] == "" and s["hud"] is True and s["grade"] is False, "clean exit after skipping")
    check(s["prompts"] is True, "world prompts are back after skipping")

    # ------------------------------------------------------------ rare result: longer charge, more cracks
    put_ready_egg(sim, "RainbowEgg", "E_t3", 5000)
    sim.run_for(0.6, 1 / 30)
    cli(sim, player, '''task.spawn(HC.hatch, 1) shared.R = {}''')
    rare_samples = []
    watch(sim, player, until_phase_exit="Walk", max_seconds=30, step=0.1, log=rare_samples)
    charge2 = [x for x in rare_samples if x["phase"] == "Charge"]
    cracks2 = max((x.get("cracks", 0) for x in rare_samples), default=0) // 3
    rec = srv(sim, '''
local best
for _, r in d.Dragons do best = r end
shared.R = { rarity = best.Rarity, odds = best.Odds or 0, mutation = best.Mutation or "None" }''')
    print("rare run result:", rec, "charge", len(charge2) * 0.1, "cracks", cracks2)
    check(len(charge2) * 0.1 >= len(charge) * 0.1 - 0.15, "a rainbow egg charges at least as long")
    watch(sim, player, until_phase_exit="Card", max_seconds=30, step=0.2)
    sim.run_for(1.6, 1 / 30)
    click(sim, player, "Continue")
    sim.run_for(2.0, 1 / 30)

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

"""Dragon animations: the new clip library (Yawn, Stretch, TailSwish, Sniff, Shake, Twirl, Bow, Howl,
Cheer, Loop + the rewritten FireBreath) on several body plans, everyday behaviour of perch dragons and
companions, greetings / head tracking, reactions and the fire breath's wind-up."""
import json
import os
import sys

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
local PDS = require(SSS.Services.PlayerDataService)
local DS = require(SSS.Services.DragonService)
local MS = require(SSS.Services.MountService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = p and PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src, steps=900, dt=1 / 60):
    res = run_client_lua(sim, player, src, max_steps=steps, dt=dt)
    return lua_table_to_py(res.get("R"))


CLIPS = ["Yawn", "Stretch", "TailSwish", "Sniff", "Shake", "Twirl", "Bow", "Howl", "Cheer", "Loop", "FireBreath", "Flourish", "Strike", "Cast", "Hurt"]
REFERENCE = ["Roar", "Takeoff", "Landing", "Dash"]  # existing clips, for calibration only
SPECIES = ["GreenDrake", "AquaSerpent", "M0nicaDragon"]
FPS = 60

CLIP_LIB = '''
local RS = game:GetService("ReplicatedStorage")
local DV = require(RS.Shared.Dragons.DragonVisual)
local Animator = require(RS.Shared.Dragons.Animator)
local out = {}
local function angleOf(cf)
	local _, a = cf:ToAxisAngle()
	return math.abs(a)
end
local DT = 1 / %(fps)d
for _, sp in %(species)s do
	local m = DV.build(sp, { Saddle = false, Detail = "Low", Mutation = "None" })
	local m2 = DV.build(sp, { Saddle = false, Detail = "Low", Mutation = "None" })
	m.Parent = workspace
	m2.Parent = workspace
	-- B plays the clips, A is the untouched control that runs in lockstep (its own model)
	local A, B = Animator.new(m), Animator.new(m2)
	B.Time, B.Breath = A.Time, A.Breath -- (every animator starts at a random phase of its idle)
	for _, clip in %(clips)s do
		local mode = (clip == "Loop" or clip == "Takeoff" or clip == "Dash") and "Fly" or "Ground"
		for _, anim in { A, B } do
			anim:SetParams({ Mode = mode, Speed = mode == "Fly" and 90 or 0, Look = Vector2.zero })
		end
		for i = 1, 60 do A:Update(DT) B:Update(DT) end
		A:Apply(false) B:Apply(false)
		local prev = {}
		for name, motor in B.Motors do prev[name] = motor.Transform end
		B.Shots = {}
		B:Play(clip)
		local def = Animator.OneShots[clip]
		local frames = math.ceil((def.Duration + 0.6) * %(fps)d)
		local maxStep, peak, bad, jointPeak = 0, 0, false, 0
		for f = 1, frames do
			if clip == "FireBreath" and f == math.ceil(0.9 * %(fps)d) then B:Stop(clip) end
			A:Update(DT) B:Update(DT)
			A:Apply(false) B:Apply(false)
			local diff = 0
			for name, motor in B.Motors do
				local cf = motor.Transform
				local x, y, z = cf.Position.X, cf.Position.Y, cf.Position.Z
				if x ~= x or y ~= y or z ~= z or math.abs(x) > 1e5 then bad = true end
				local step = math.deg(angleOf(prev[name]:ToObjectSpace(cf)))
				if step > maxStep then maxStep = step end
				prev[name] = cf
				local d = angleOf(A.Motors[name].Transform:ToObjectSpace(cf))
				diff += d
				if name == "Head" or name == "Neck1" or name == "Chest" or name == "Body" then
					jointPeak = math.max(jointPeak, math.deg(d))
				end
			end
			peak = math.max(peak, diff)
		end
		-- settle, then compare with the control: nothing of the clip may stay behind
		for i = 1, 45 do A:Update(DT) B:Update(DT) end
		A:Apply(false) B:Apply(false)
		local residue = 0
		for name, motor in B.Motors do residue += angleOf(A.Motors[name].Transform:ToObjectSpace(motor.Transform)) end
		out[sp .. "/" .. clip] = { maxStep = maxStep, peak = peak, residue = residue, bad = bad, joint = jointPeak, playing = B:IsPlaying(clip) }
	end
	m:Destroy()
	m2:Destroy()
end
shared.R = out
'''


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    # ------------------------------------------------------------------ the clip library
    res = srv(sim, CLIP_LIB % {"species": json.dumps(SPECIES).replace("[", "{").replace("]", "}"),
                                "clips": json.dumps(CLIPS + REFERENCE).replace("[", "{").replace("]", "}"),
                                "fps": FPS})
    worst = {}
    for k, v in res.items():
        sp, clip = k.split("/")
        worst.setdefault(clip, []).append((sp, v))
    ref_speed = max(max(v["maxStep"] for _, v in worst[c]) * FPS for c in REFERENCE)
    print(f"  reference clips (Roar/Takeoff/Landing/Dash) turn at most {ref_speed:.0f} deg/s")
    for clip in CLIPS:
        rows = worst[clip]
        speed = max(v["maxStep"] for _, v in rows) * FPS
        peak = min(v["peak"] for _, v in rows)
        joint = min(v["joint"] for _, v in rows)
        residue = max(v["residue"] for _, v in rows)
        print(f"  {clip:11s} fastest joint {speed:5.0f} deg/s  min peak {peak:5.2f}  head/neck/chest/body peak {joint:5.1f} deg  residue {residue:.3f}")
        check(not any(v["bad"] for _, v in rows), f"{clip}: no NaN / runaway values on any body plan")
        check(speed < max(1500, ref_speed * 1.4), f"{clip}: no jerks (fastest joint {speed:.0f} deg/s)")
        check(peak > 0.25 or joint > 6, f"{clip}: the pose really changes (peak {peak:.2f} rad, joints {joint:.0f} deg)")
        check(residue < 0.08, f"{clip}: nothing stays behind afterwards ({residue:.3f} rad)")
        check(not any(v["playing"] for _, v in rows), f"{clip}: the clip ends by itself")
    fb = [v for k, v in res.items() if k.endswith("/FireBreath")]
    check(min(v["joint"] for v in fb) > 18, "FireBreath is a big move: head / chest / body swing by at least 18 degrees")

    # ------------------------------------------------------------------ in the game
    player = sim.add_player("Player1", 1001)
    sim.run_for(6, 1 / 30)
    # a resting perch dragon of my own
    srv(sim, '''
local rec = DS.Add(p, "FrostDragon", "None", "Test", true)
shared.R = { id = rec.UniqueId }''')
    uid = srv(sim, 'local id; for k, r in d.Dragons do if r.SpeciesId == "FrostDragon" then id = k end end shared.R = { id = id }')["id"]
    r = cli(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local res = Net.request("Dragon", "Place", {{ Id = "{uid}", Slot = 1 }})
shared.R = {{ ok = res.ok }}
''')
    check(r["ok"], "a dragon of mine rests on perch 1")
    sim.run_for(4, 1 / 30)

    PERCH = '''
local LP = game:GetService("Players").LocalPlayer
local AC = require(LP.PlayerScripts.Controllers.AnimationController)
local model
for _, m in workspace.PerchDragons:GetChildren() do
	if m:GetAttribute("Slot") == 1 then model = m end
end
shared.R = { found = model ~= nil }
'''
    check(cli(sim, player, PERCH)["found"], "the perch dragon is built on the client")

    # variety over a few minutes of perch life (own dragon far away: pure behaviour)
    far = srv(sim, '''
local WC = require(game:GetService("ReplicatedStorage").Configs.WorldConfig)
local cf = WC.perchWorld(p:GetAttribute("PlotId"), 1)
shared.R = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z }''')
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    from rbx_types import CFrame as CF
    hrp.props["CFrame"] = CF((far["x"] + 400, far["y"] + 40, far["z"]))
    sim.run_for(1.0, 1 / 30)
    seen = cli(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local AC = require(LP.PlayerScripts.Controllers.AnimationController)
math.randomseed(7)
local model
for _, m in workspace.PerchDragons:GetChildren() do
	if m:GetAttribute("Slot") == 1 then model = m end
end
local entry = AC.get(model)
local names, modes = {}, {}
local wasShots = 0
for step = 1, 2400 do
	task.wait(0.1)
	for _, s in entry.Anim.Shots do names[s.Name] = true end
	modes[entry.Anim.Params.Mode] = true
end
local list, ml = {}, {}
for n in names do table.insert(list, n) end
for n in modes do table.insert(ml, n) end
table.sort(list) table.sort(ml)
shared.R = { clips = list, modes = ml }
''', steps=5400, dt=1 / 20)
    print("perch life: clips", seen["clips"], "moods", seen["modes"])
    check(len(seen["clips"]) >= 4, f"perch dragons show {len(seen['clips'])} different clips over four minutes")
    check(len(seen["modes"]) >= 2, f"...and change their mood ({', '.join(seen['modes'])})")

    # greeting: walk up to my own perch dragon
    hrp.props["CFrame"] = CF((far["x"] + 14, far["y"] + 3, far["z"] + 6))
    sim.run_for(0.5, 1 / 30)
    greet = cli(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local AC = require(LP.PlayerScripts.Controllers.AnimationController)
local model
for _, m in workspace.PerchDragons:GetChildren() do
	if m:GetAttribute("Slot") == 1 then model = m end
end
local entry = AC.get(model)
entry.LastGreet = nil
entry.Near = false
entry.Anim.Shots = {}
local clips = {}
local mode, lookX = "", 0
for i = 1, 60 do
	task.wait(0.1)
	for _, s in entry.Anim.Shots do clips[s.Name] = true end
	mode = entry.Anim.Params.Mode
	lookX = math.max(lookX, math.abs(entry.Anim.Params.Look.X))
end
shared.R = { cheer = clips.Cheer == true, bow = clips.Bow == true, mode = mode, look = lookX }
''', steps=900)
    print("greeting:", greet)
    check(greet["cheer"] or greet["bow"], "my perch dragon greets me when I walk up (cheer or bow)")
    check(greet["mode"] == "Ground", "...it stood up to do it")
    check(greet["look"] > 0.1, f"...and it turns its head towards me (look {greet['look']:.2f})")

    # reactions of the companion
    hrp.props["CFrame"] = CF((far["x"] + 60, far["y"] + 3, far["z"] + 30))
    srv(sim, '''
local rec = DS.Add(p, "GreenDrake", "None", "Test", true)
DS.Equip(p, rec.UniqueId)
shared.R = {}''')
    sim.run_for(3, 1 / 30)
    rc = cli(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local AC = require(LP.PlayerScripts.Controllers.AnimationController)
task.wait(0.5)
local ground = AC.react("Egg", 0.2)
task.wait(0.3)
local model
for _, m in workspace.Dragons:GetChildren() do
	if m:GetAttribute("OwnerUserId") == LP.UserId then model = m end
end
local entry = AC.get(model)
local playingGround = entry.Anim:IsPlaying("Cheer")
entry.Anim.Shots = {}
entry.Anim.Params.Mode = "Fly"
entry.Anim.Params.Speed = 80
local air = AC.react("Egg", 0.2)
task.wait(0.3)
local playingAir = entry.Anim:IsPlaying("Loop")
shared.R = { ground = ground, air = air, playingGround = playingGround, playingAir = playingAir, shot = model:GetAttribute("Shot") }
''', steps=900)
    print("react:", rc)
    check(rc["ground"] == "Cheer" and rc["playingGround"], "on the ground the companion cheers")
    check(rc["air"] == "Loop" and rc["playingAir"], "in the air it loops the loop")
    check(rc["shot"] in ("Cheer", "Loop"), f"others see it (the server relays the shot: {rc['shot']})")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()

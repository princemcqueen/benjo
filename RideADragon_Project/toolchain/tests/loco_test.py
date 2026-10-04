"""Offline tests for Locomotion: scripted inputs over a fake world at several
frame rates; checks framerate independence, mode transitions and stability."""
import sys, os, math
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from sim_runner import boot
import luau_interp as LI

LUA = r'''
local RS = game:GetService("ReplicatedStorage")
local Loco = require(RS.Shared.Dragons.Locomotion)
local FPS = ...
local dt = 1 / FPS

-- fake world: flat ground y=0, a hill (raised plateau with ramp) and a wall
local function groundHeight(x, z)
	-- ramp up between z=-200 and z=-260 to y=20 plateau
	if z < -200 and z > -260 then
		return (-200 - z) / 60 * 20
	elseif z <= -260 and z > -400 then
		return 20
	end
	return 0
end
local world = {}
function world.ground(pos, maxDown)
	local y = groundHeight(pos.X, pos.Z)
	if pos.Y - y <= maxDown and pos.Y >= y - 2 then
		return true, y, Vector3.yAxis, false
	end
	return false
end
function world.sweep(origin, delta, radius)
	-- wall plane at x = 120 (normal -X)
	local x0 = origin.X + radius
	local x1 = origin.X + delta.X + radius
	if x1 > 120 and delta.X > 0 then
		local f = math.clamp((120 - x0) / delta.X, 0, 1)
		return true, f, Vector3.new(-1, 0, 0)
	end
	return false
end

local stats = { RunSpeed = 40, CruiseSpeed = 77, Scale = 1, HipHeight = 4.8, BodyRadius = 4.2, Turn = 1, Accel = 1, Agility = 1 }
local s = Loco.new(stats, Vector3.new(0, 4.8, 0), 0)

-- scripted input timeline (seconds)
local function inputAt(t)
	local i = { Move = Vector3.zero, MoveFlat = Vector3.zero, JumpPressed = false, JumpHeld = false, Ascend = false, Descend = false, Sprint = false }
	if t < 3 then
		i.MoveFlat = Vector3.new(0, 0, -1) -- run forward
	elseif t < 4 then
		i.MoveFlat = Vector3.new(1, 0, -1).Unit -- veer right toward the wall
		i.Sprint = true
	elseif t < 4.6 then
		i.MoveFlat = Vector3.new(1, 0, 0)
		i.JumpHeld = true -- hold space: jump then take off
	elseif t < 8 then
		i.Move = Vector3.new(0, 0.25, -1).Unit -- fly forward, climbing
		i.MoveFlat = Vector3.new(0, 0, -1)
		i.Sprint = t > 6
	elseif t < 10 then
		i.Move = Vector3.new(-1, -0.2, -0.3).Unit -- banked left turn, slight descent
		i.MoveFlat = Vector3.new(-1, 0, -0.3).Unit
	elseif t < 11 then
		-- release: decelerate
	elseif t < 16 then
		i.Descend = true -- descend and land
	end
	return i
end

local trace = {}
local modes = {}
local lastMode = s.Mode
local t = 0
local nextSample = 0
local pos = s.Position
local maxRollStep, maxYawRateStep = 0, 0
local prevRoll, prevYawRate = 0, 0
while t < 16 do
	local inp = inputAt(t)
	-- edge detection for JumpPressed
	if inp.JumpHeld and not _G.__held then inp.JumpPressed = true end
	_G.__held = inp.JumpHeld
	s.Position = pos
	Loco.step(s, inp, dt, world)
	pos = pos + s.Velocity * dt
	t += dt
	if s.Mode ~= lastMode then
		table.insert(modes, string.format("%.2f:%s", t, s.Mode))
		lastMode = s.Mode
	end
	maxRollStep = math.max(maxRollStep, math.abs(s.Roll - prevRoll) / dt)
	maxYawRateStep = math.max(maxYawRateStep, math.abs(s.YawRate - prevYawRate) / dt)
	prevRoll, prevYawRate = s.Roll, s.YawRate
	if t >= nextSample then
		table.insert(trace, { t, pos.X, pos.Y, pos.Z, s.Speed, s.Roll, s.Pitch, s.Mode })
		nextSample += 0.5
	end
end
return trace, modes, maxRollStep, maxYawRateStep, pos
'''

def run(fps):
    from sim_runner import lua_table_to_py
    sim = boot()
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    fn = LI.load(LUA, "loco", env)
    res = sim.in_ctx(ctx, fn, fps)
    if sim.errors:
        print("ERR", sim.errors)
    trace, modes, mr, my, pos = res
    return lua_table_to_py(trace), lua_table_to_py(modes), mr, my, pos


if __name__ == "__main__":
    results = {}
    for fps in (30, 60, 144):
        results[fps] = run(fps)
    for fps, (trace, modes, mr, my, pos) in results.items():
        print(f"--- {fps} fps  final={pos}  maxRollRate={mr:.2f} maxYawAccel={my:.2f}")
        print("   modes:", modes)
    # framerate independence: compare sampled positions
    base = results[144][0]
    for fps in (30, 60):
        tr = results[fps][0]
        worst = 0
        for a, b in zip(tr, base):
            d = ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2 + (a[3] - b[3]) ** 2) ** 0.5
            worst = max(worst, d)
        print(f"max deviation {fps} vs 144 fps: {worst:.2f} studs")
    print("trace @60:")
    for row in results[60][0]:
        print("  t=%5.2f pos=(%7.1f %6.1f %7.1f) speed=%6.1f roll=%5.2f pitch=%5.2f %s" % tuple(row))

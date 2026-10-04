--[[
	Locomotion
	Pure, deterministic dragon movement model (no instance access). The
	client feeds it input + world queries every frame and applies the result
	to physics constraints (LinearVelocity / AlignOrientation), so movement
	is simulated by the engine at its own rate and replicates smoothly.

	Modes:
	  Ground   walking/running on terrain, ground-following spring, slopes
	  Air      ballistic (jump / falling), limited air control
	  Takeoff  crouch + leap + powerful wing beats into flight
	  Fly      3D flight: speed dynamics, rate-limited turning, dive/climb,
	           boost meter, banking, hover
	  Landing  flare + controlled descent + touchdown

	Conventions: Yaw 0 faces -Z, +Yaw turns left. Pitch + = nose up.
	Roll + = rolling left (left wing down). All smoothing is exponential in
	dt and every rate is limited per second, so results are frame-rate
	independent.

	world = {
	  ground = function(pos: Vector3, maxDown: number) -> (hit, y, normal, isWater)
	  sweep  = function(origin: Vector3, delta: Vector3, radius: number) -> (hit, fraction, normal)
	}
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("GameConfig"))

local Locomotion = {}

local R = GameConfig.Riding
local M = GameConfig.Movement
local TAU = math.pi * 2
local clamp, exp, abs, sqrt, atan2, sin, cos, min, max = math.clamp, math.exp, math.abs, math.sqrt, math.atan2, math.sin, math.cos, math.min, math.max

local function wrap(a: number): number
	return (a + math.pi) % TAU - math.pi
end

local function approach(current: number, target: number, rate: number, dt: number): number
	-- exponential approach (frame-rate independent)
	return current + (target - current) * (1 - exp(-rate * dt))
end

local function moveToward(current: number, target: number, maxDelta: number): number
	if current < target then
		return min(current + maxDelta, target)
	end
	return max(current - maxDelta, target)
end

local function yawOf(v: Vector3): number
	return atan2(-v.X, -v.Z)
end

local function flatForward(yaw: number): Vector3
	return Vector3.new(-sin(yaw), 0, -cos(yaw))
end

local function dirFrom(yaw: number, pitch: number): Vector3
	local c = cos(pitch)
	return Vector3.new(-sin(yaw) * c, sin(pitch), -cos(yaw) * c)
end
Locomotion.dirFrom = dirFrom
Locomotion.yawOf = yawOf

--[[
	stats = {
	  RunSpeed, CruiseSpeed   studs/s (from the dragon's stats)
	  Scale, HipHeight, BodyRadius
	  Turn, Accel, Agility    species handling multipliers
	}
]]
function Locomotion.new(stats: { [string]: number }, position: Vector3, yaw: number?)
	return {
		Mode = "Ground",
		ModeTime = 0,
		Position = position,
		Velocity = Vector3.zero,
		Yaw = yaw or 0,
		YawRate = 0,
		Pitch = 0,
		Roll = 0,
		Speed = 0, -- forward speed scalar
		FlightPitch = 0, -- direction-of-travel pitch in flight
		Boost = 1,
		Boosting = false,
		BoostLock = false,
		Grounded = true,
		GroundY = position.Y - (stats.HipHeight or 4.8),
		GroundNormal = Vector3.yAxis,
		OnWater = false,
		AirTime = 0,
		JumpHeldTime = 0,
		JumpConsumed = false,
		CoyoteTime = 0,
		LandingFrom = 0,
		Stats = stats,
		Events = {},
	}
end

function Locomotion.setStats(s, stats)
	s.Stats = stats
end

local function setMode(s, mode: string)
	if s.Mode ~= mode then
		s.Mode = mode
		s.ModeTime = 0
		table.insert(s.Events, { Kind = "Mode", Mode = mode })
	end
end
Locomotion.setMode = setMode

local function event(s, kind: string, data: any?)
	table.insert(s.Events, { Kind = kind, Data = data })
end

-- Desired yaw rate toward a target heading, smoothed (turns accelerate and
-- settle instead of snapping).
local function steerYaw(s, targetYaw: number, maxRate: number, response: number, dt: number, gain: number?)
	local diff = wrap(targetYaw - s.Yaw)
	local desired = clamp(diff * (gain or 4), -maxRate, maxRate)
	s.YawRate = approach(s.YawRate, desired, response, dt)
	s.Yaw = wrap(s.Yaw + s.YawRate * dt)
	return diff
end

local function hip(s): number
	return s.Stats.HipHeight or 4.8
end

-- Sample ground under the dragon (center + slope along heading).
local function probeGround(s, world, maxDown: number)
	local hit, y, normal, water = world.ground(s.Position, maxDown)
	if hit then
		s.GroundY = y
		s.GroundNormal = normal
		s.OnWater = water == true
	end
	return hit, y, normal, water
end

local function slopePitch(s, world): number
	local L = (s.Stats.BodyRadius or 4.2) * 1.1
	local f = flatForward(s.Yaw)
	local hitF, yF = world.ground(s.Position + f * L, hip(s) + 8)
	local hitB, yB = world.ground(s.Position - f * L, hip(s) + 8)
	if hitF and hitB then
		return clamp(atan2(yF - yB, 2 * L), -0.6, 0.6)
	end
	return 0
end

local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and abs(v.X) < 1e6 and abs(v.Y) < 1e6 and abs(v.Z) < 1e6
end

-- Slides a velocity along obstacles found by a sphere sweep. Walls are
-- anticipated with a small look-ahead margin (smooth slides); floor-like
-- hits only stop real penetration, since each mode follows the ground itself.
local function collide(s, world, vel: Vector3, dt: number, radius: number): Vector3
	for _ = 1, 2 do
		local speed = vel.Magnitude
		if speed < 0.01 then
			break
		end
		local dir = vel / speed
		local travel = speed * dt
		local margin = radius * 0.35
		local hit, frac, normal = world.sweep(s.Position, dir * (travel + margin), radius)
		if not hit or not finite(normal) or normal.Magnitude < 0.5 then
			break
		end
		local into = vel:Dot(normal)
		if into >= 0 then
			break
		end
		local contact = frac * (travel + margin)
		if normal.Y > 0.7 and contact >= travel then
			break
		end
		vel = vel - normal * into
		vel *= (1 - 0.25 * clamp(-into / max(1, vel.Magnitude + abs(into)), 0, 1))
		if frac < 0.05 then
			-- already touching: push out gently
			vel += normal * 6
		end
		event(s, "Bump", -into)
	end
	return vel
end

-- ============================================================== ground
local function stepGround(s, input, dt: number, world)
	local st = s.Stats
	local h = hip(s)
	local hit, gy, _, water = probeGround(s, world, h + 3.5)
	if not hit or s.Position.Y - (gy + h) > 2.6 then
		-- stepped off a ledge: start falling (coyote time keeps jumps fair)
		s.CoyoteTime = 0.15
		setMode(s, "Air")
		return
	end

	local move = input.MoveFlat or Vector3.zero
	local mag = min(1, move.Magnitude)
	local sprint = input.Sprint and 1.32 or 1
	local runSpeed = st.RunSpeed * (water and 0.65 or 1)
	local targetSpeed = 0
	if mag > 0.08 then
		local desiredYaw = yawOf(move)
		local speedK = clamp(abs(s.Speed) / max(1, runSpeed), 0, 1)
		local maxRate = (R.GroundTurnRate + (R.GroundTurnRateFast - R.GroundTurnRate) * speedK) * (st.Turn or 1)
		local diff = steerYaw(s, desiredYaw, maxRate, R.GroundTurnResponse, dt)
		-- slow down while turning hard (big creature)
		local align = clamp(cos(diff), 0, 1)
		targetSpeed = runSpeed * mag * sprint * (0.35 + 0.65 * align)
	else
		s.YawRate = approach(s.YawRate, 0, R.GroundTurnResponse, dt)
		s.Yaw = wrap(s.Yaw + s.YawRate * dt)
	end
	local accel = (targetSpeed > s.Speed and R.GroundAccel * (st.Accel or 1) or R.GroundDecel)
	s.Speed = moveToward(s.Speed, targetSpeed, accel * dt)

	local horiz = flatForward(s.Yaw) * s.Speed
	horiz = collide(s, world, horiz, dt, (st.BodyRadius or 4.2) * 0.8)
	horiz = Vector3.new(horiz.X, 0, horiz.Z)
	s.Speed = min(s.Speed, horiz.Magnitude + 0.01)

	-- ground-following spring (critically damped toward hip height)
	local targetY = gy + h * (water and 0.6 or 1)
	local err = targetY - s.Position.Y
	local vy = clamp(err * 14, -70, 55)
	s.Velocity = Vector3.new(horiz.X, vy, horiz.Z)

	-- body attitude: follow slope, lean slightly into turns
	s.Pitch = approach(s.Pitch, slopePitch(s, world), R.SlopeAlignRate, dt)
	local lean = clamp(s.YawRate * s.Speed * 0.0035, -0.14, 0.14)
	s.Roll = approach(s.Roll, lean, 6, dt)
	s.FlightPitch = 0
	s.Grounded = true
	s.AirTime = 0

	-- jump
	if input.JumpPressed then
		s.JumpConsumed = true
		s.JumpHeldTime = 0
		s.Velocity = Vector3.new(s.Velocity.X, R.JumpVelocity * sqrt(max(0.6, st.Scale or 1)), s.Velocity.Z)
		s.Grounded = false
		setMode(s, "Air")
		event(s, "Jump")
	end

	-- boost regenerates on the ground
	s.Boosting = false
	s.Boost = min(1, s.Boost + R.BoostRegenPerSecond * dt)
end

-- ============================================================== air (ballistic)
local function stepAir(s, input, dt: number, world)
	local st = s.Stats
	local h = hip(s)
	s.AirTime += dt
	s.CoyoteTime = max(0, s.CoyoteTime - dt)
	s.Grounded = false

	-- air control
	local move = input.MoveFlat or Vector3.zero
	local mag = min(1, move.Magnitude)
	if mag > 0.08 then
		steerYaw(s, yawOf(move), R.GroundTurnRateFast * 0.8 * (st.Turn or 1), R.GroundTurnResponse * 0.6, dt)
		s.Speed = moveToward(s.Speed, st.RunSpeed * mag, R.GroundAccel * 0.5 * dt)
	else
		s.YawRate = approach(s.YawRate, 0, 4, dt)
		s.Yaw = wrap(s.Yaw + s.YawRate * dt)
	end
	local vy = s.Velocity.Y - R.Gravity * dt
	local horiz = flatForward(s.Yaw) * s.Speed
	local vel = collide(s, world, Vector3.new(horiz.X, vy, horiz.Z), dt, (st.BodyRadius or 4.2) * 0.8)
	s.Velocity = vel
	s.Speed = Vector3.new(vel.X, 0, vel.Z).Magnitude

	s.Pitch = approach(s.Pitch, clamp(vel.Y / 120, -0.25, 0.2), 4, dt)
	s.Roll = approach(s.Roll, 0, 5, dt)

	-- hold jump through the leap, or press again, to take off
	if input.JumpHeld and s.JumpConsumed then
		s.JumpHeldTime += dt
	end
	local pressedAgain = input.JumpPressed and (s.AirTime > 0.05 or s.CoyoteTime <= 0)
	if s.CoyoteTime > 0 and input.JumpPressed and s.JumpConsumed == false then
		-- late jump right after stepping off a ledge
		s.JumpConsumed = true
		s.Velocity = Vector3.new(vel.X, R.JumpVelocity, vel.Z)
		event(s, "Jump")
		return
	end
	if pressedAgain or s.JumpHeldTime >= R.TakeoffHoldTime + 0.12 or input.FlyToggle then
		setMode(s, "Takeoff")
		event(s, "Takeoff")
		return
	end
	-- falling fast: the dragon catches itself and starts flying
	if vel.Y < -55 and s.AirTime > 0.5 then
		setMode(s, "Fly")
		s.FlightPitch = -0.3
		event(s, "CatchFall")
		return
	end

	-- touchdown
	if vel.Y <= 0 then
		local hit, gy = probeGround(s, world, h + max(2, -vel.Y * dt * 2))
		if hit and s.Position.Y - (gy + h) <= 0.6 then
			local impact = -vel.Y
			s.JumpConsumed = false
			s.JumpHeldTime = 0
			setMode(s, "Ground")
			s.Velocity = Vector3.new(vel.X, 0, vel.Z)
			event(s, "Land", impact)
		end
	end
end

-- ============================================================== takeoff
local function stepTakeoff(s, input, dt: number, world)
	local st = s.Stats
	local t = s.ModeTime
	local horiz = Vector3.new(s.Velocity.X, 0, s.Velocity.Z)
	local cap = st.CruiseSpeed * 0.55
	if horiz.Magnitude > cap then
		horiz = horiz.Unit * cap
	end
	local vy
	if t < R.CrouchTime and s.Grounded then
		-- gather: settle down before the leap
		vy = -6
		horiz *= (1 - min(1, dt * 4))
	else
		local k = clamp((t - R.CrouchTime) / max(0.01, R.TakeoffDuration - R.CrouchTime), 0, 1)
		-- strong initial lift that eases out
		vy = R.TakeoffLiftVelocity * (1 - k * k * 0.75)
		s.Grounded = false
	end
	-- allow steering during the climb
	local move = input.MoveFlat or Vector3.zero
	if move.Magnitude > 0.08 then
		steerYaw(s, yawOf(move), R.AirMaxYawRate * (st.Turn or 1), R.AirTurnResponse, dt)
	else
		s.YawRate = approach(s.YawRate, 0, 4, dt)
		s.Yaw = wrap(s.Yaw + s.YawRate * dt)
	end
	local fwd = flatForward(s.Yaw)
	local hs = horiz.Magnitude
	horiz = fwd * hs
	s.Velocity = collide(s, world, Vector3.new(horiz.X, vy, horiz.Z), dt, st.BodyRadius or 4.2)
	s.Speed = hs
	s.Pitch = approach(s.Pitch, t < R.CrouchTime and -0.08 or 0.32, 7, dt)
	s.Roll = approach(s.Roll, 0, 6, dt)
	if t >= R.TakeoffDuration then
		s.FlightPitch = atan2(s.Velocity.Y, max(1, hs)) * 0.6
		setMode(s, "Fly")
	end
end

-- ============================================================== flight
local function stepFly(s, input, dt: number, world)
	local st = s.Stats
	local h = hip(s)
	s.Grounded = false
	local agility = st.Agility or 1
	local turn = st.Turn or 1

	local move = input.Move or Vector3.zero
	local mag = min(1, move.Magnitude)
	local vIn = (input.Ascend and 1 or 0) - (input.Descend and 1 or 0)

	-- boost meter
	local wantBoost = input.Sprint and mag > 0.2
	if wantBoost and not s.Boosting and s.Boost >= R.BoostMinToStart and not s.BoostLock then
		s.Boosting = true
		event(s, "BoostStart")
	end
	if s.Boosting then
		s.Boost = max(0, s.Boost - dt / R.BoostDuration)
		if not wantBoost or s.Boost <= 0 then
			s.Boosting = false
			s.BoostLock = s.Boost <= 0 -- must release before boosting again
			event(s, "BoostEnd")
		end
	else
		if not input.Sprint then
			s.BoostLock = false
		end
		s.Boost = min(1, s.Boost + R.BoostRegenPerSecond * dt)
	end

	-- desired direction and speed
	local cruise = st.CruiseSpeed
	local desiredSpeed = 0
	local desiredDir: Vector3
	if mag > 0.05 then
		desiredDir = move.Unit + Vector3.new(0, vIn * 0.85, 0)
		desiredDir = desiredDir.Unit
		desiredSpeed = cruise * mag * (s.Boosting and M.BoostMultiplier or 1)
	else
		desiredDir = dirFrom(s.Yaw, 0)
	end
	if input.Brake then
		-- pulling back: air brake (turning still allowed with strafe input)
		desiredSpeed = 0
	end
	local desiredPitch = clamp(math.asin(clamp(desiredDir.Y, -1, 1)), -R.MaxPitch, R.MaxPitch)

	-- dive gains speed, climbing costs speed
	local travelPitch = s.FlightPitch
	local speedCap = desiredSpeed
	if desiredSpeed > 0 then
		if travelPitch < -0.2 then
			speedCap *= 1 + (-travelPitch - 0.2) * 0.9
		elseif travelPitch > 0.2 then
			speedCap *= 1 - (travelPitch - 0.2) * R.ClimbPenalty
		end
	end
	local accel
	if speedCap > s.Speed then
		accel = R.AirAccel * (st.Accel or 1)
		if travelPitch < -0.2 then
			accel += R.DiveAccel * (-travelPitch)
		end
		if s.Boosting then
			accel *= 1.8
		end
	else
		accel = (mag < 0.05 or input.Brake) and R.AirBrake or R.AirBrake * 0.6
	end
	s.Speed = moveToward(s.Speed, speedCap, accel * dt)

	-- heading: rate-limited, smoothed yaw; travel pitch follows desired pitch
	local hovering = s.Speed < 14 and mag < 0.05
	if mag > 0.05 then
		local maxRate = R.AirMaxYawRate * turn * (s.Boosting and 0.8 or 1)
		steerYaw(s, yawOf(desiredDir), maxRate, R.AirTurnResponse * agility, dt, 3)
	elseif hovering and input.CamYaw then
		-- hovering: slowly face where the camera looks
		steerYaw(s, input.CamYaw, 0.9, 2.5, dt, 2)
	else
		s.YawRate = approach(s.YawRate, 0, 3, dt)
		s.Yaw = wrap(s.Yaw + s.YawRate * dt)
	end
	if mag > 0.05 then
		s.FlightPitch = approach(s.FlightPitch, desiredPitch, R.PitchResponse * agility, dt)
	else
		s.FlightPitch = approach(s.FlightPitch, 0, 3, dt)
	end

	-- velocity: travel direction * speed + direct vertical control when slow
	local dir = dirFrom(s.Yaw, s.FlightPitch)
	local vel = dir * s.Speed
	local slow = clamp(1 - s.Speed / 30, 0, 1)
	local vy = vel.Y + vIn * R.VerticalSpeed * (slow * 0.9 + 0.1)
	if hovering then
		vy = approach(s.Velocity.Y, vIn * R.VerticalSpeed, R.VerticalAccel, dt)
	end
	-- soft ceiling
	local over = s.Position.Y - (R.Ceiling - R.SoftCeilingBand)
	if over > 0 and vy > 0 then
		vy *= clamp(1 - over / R.SoftCeilingBand, 0, 1)
	end
	vel = Vector3.new(vel.X, vy, vel.Z)

	-- ground: never sink into terrain while flying; auto-land when settling down
	local hit, gy, _, water = probeGround(s, world, h + 40)
	if hit then
		local height = s.Position.Y - (gy + h)
		if height < 1.5 and vel.Y < 0 then
			vel = Vector3.new(vel.X, max(vel.Y, (1.5 - height) * 8), vel.Z)
		end
		local settling = vIn < 0 or (mag < 0.05 and vel.Y <= 0.5)
		if settling and height < R.LandingStartHeight * (st.Scale or 1) and s.Speed < R.AutoLandMaxSpeed and not water then
			s.LandingFrom = height
			setMode(s, "Landing")
			event(s, "LandingStart")
		end
	end

	vel = collide(s, world, vel, dt, st.BodyRadius or 4.2)
	s.Velocity = vel

	-- visual attitude: pitch follows travel, bank follows turn rate
	local visualPitch = clamp(s.FlightPitch * 0.9, -R.MaxPitch, R.MaxPitch)
	if hovering then
		visualPitch = 0.08
	end
	s.Pitch = approach(s.Pitch, visualPitch, R.PitchResponse, dt)
	local bankTarget = clamp(s.YawRate * (14 + s.Speed) * 0.011 * agility, -R.MaxBank, R.MaxBank)
	s.Roll = approach(s.Roll, bankTarget, R.BankResponse, dt)
end

-- ============================================================== landing
local function stepLanding(s, input, dt: number, world)
	local st = s.Stats
	local h = hip(s)
	local hit, gy = probeGround(s, world, h + R.LandingStartHeight * 2 + 10)
	if not hit then
		setMode(s, "Fly")
		return
	end
	-- abort if the rider climbs or pushes forward hard
	if input.Ascend or (input.Move and input.Move.Magnitude > 0.5 and input.Sprint) then
		setMode(s, "Fly")
		return
	end
	local height = s.Position.Y - (gy + h)
	-- critically damped descent toward touchdown height
	local vy = clamp(-height * 3.2 - 4, -45, 2)
	local horiz = Vector3.new(s.Velocity.X, 0, s.Velocity.Z)
	horiz *= exp(-2.6 * dt)
	local move = input.MoveFlat or Vector3.zero
	if move.Magnitude > 0.08 then
		steerYaw(s, yawOf(move), 1.2 * (st.Turn or 1), 4, dt)
		horiz = flatForward(s.Yaw) * horiz.Magnitude
	else
		s.YawRate = approach(s.YawRate, 0, 5, dt)
		s.Yaw = wrap(s.Yaw + s.YawRate * dt)
	end
	s.Velocity = collide(s, world, Vector3.new(horiz.X, vy, horiz.Z), dt, st.BodyRadius or 4.2)
	s.Speed = horiz.Magnitude
	s.FlightPitch = 0
	-- flare: nose up while braking, level on touchdown
	s.Pitch = approach(s.Pitch, height > 2 and 0.22 or 0, 6, dt)
	s.Roll = approach(s.Roll, 0, 6, dt)
	if height <= R.TouchdownHeight then
		s.JumpConsumed = false
		s.JumpHeldTime = 0
		setMode(s, "Ground")
		event(s, "Touchdown", -vy)
	end
end

local STEP = {
	Ground = stepGround,
	Air = stepAir,
	Takeoff = stepTakeoff,
	Fly = stepFly,
	Landing = stepLanding,
}

--[[
	input = {
	  Move: Vector3        camera-relative desired direction (flight: includes pitch)
	  MoveFlat: Vector3    same, flattened to the ground plane
	  JumpPressed, JumpHeld, Ascend, Descend, Sprint, FlyToggle, Brake: boolean
	  CamYaw: number?      camera yaw (hover facing)
	}
	Returns the state; s.Events lists what happened this step.
]]
function Locomotion.step(s, input, dt: number, world)
	table.clear(s.Events)
	if dt <= 0 then
		return s
	end
	dt = min(dt, 1 / 15)
	s.ModeTime += dt
	if input.FlyToggle and s.Mode == "Ground" then
		setMode(s, "Takeoff")
		event(s, "Takeoff")
	elseif input.FlyToggle and s.Mode == "Fly" then
		input.Descend = true
	end
	local fn = STEP[s.Mode] or stepGround
	fn(s, input, dt, world)
	if not input.JumpHeld then
		s.JumpHeldTime = 0
	end
	-- safety net: never hand a non-finite value to physics
	if not finite(s.Velocity) or s.Yaw ~= s.Yaw or s.Pitch ~= s.Pitch or s.Roll ~= s.Roll or s.Speed ~= s.Speed then
		s.Velocity = Vector3.zero
		s.Speed = 0
		s.Yaw = s.Yaw == s.Yaw and s.Yaw or 0
		s.Pitch, s.Roll, s.YawRate, s.FlightPitch = 0, 0, 0, 0
		event(s, "Recovered")
	end
	return s
end

-- Orientation (rotation only) for AlignOrientation.
function Locomotion.orientation(s): CFrame
	return CFrame.Angles(0, s.Yaw, 0) * CFrame.Angles(s.Pitch, 0, 0) * CFrame.Angles(0, 0, s.Roll)
end

-- Animator parameters derived from the state.
function Locomotion.animParams(s)
	local v = s.Velocity
	local horiz = Vector3.new(v.X, 0, v.Z).Magnitude
	local mode = s.Mode
	local animMode
	if mode == "Ground" then
		animMode = "Ground"
	elseif mode == "Air" then
		animMode = "Air"
	else
		animMode = "Fly"
	end
	return {
		Speed = mode == "Fly" and s.Speed or horiz,
		Vertical = v.Y,
		TurnRate = s.YawRate,
		Bank = s.Roll,
		Pitch = s.Pitch,
		Mode = animMode,
		Boost = s.Boosting,
		RunSpeed = s.Stats.RunSpeed,
		WalkSpeed = M.WalkSpeed,
	}
end

return Locomotion

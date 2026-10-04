--[[
	MathUtil
	Frame-rate independent smoothing helpers. Every function that blends
	toward a target takes dt so behaviour is identical at 30, 60 or 240 FPS.
]]

local MathUtil = {}

local TAU = math.pi * 2

-- Alpha for exponential smoothing: fraction of the remaining distance
-- covered this frame. rate = 1/time-constant.
function MathUtil.expAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

function MathUtil.expDecay(current: number, target: number, rate: number, dt: number): number
	return target + (current - target) * math.exp(-rate * dt)
end

function MathUtil.expDecayVec(current: Vector3, target: Vector3, rate: number, dt: number): Vector3
	return target + (current - target) * math.exp(-rate * dt)
end

function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.inverseLerp(a: number, b: number, v: number): number
	if a == b then
		return 0
	end
	return math.clamp((v - a) / (b - a), 0, 1)
end

function MathUtil.remap(v: number, a0: number, a1: number, b0: number, b1: number): number
	return b0 + (b1 - b0) * MathUtil.inverseLerp(a0, a1, v)
end

-- Wrap an angle to (-pi, pi].
function MathUtil.wrapAngle(a: number): number
	a = (a + math.pi) % TAU
	if a <= 0 then
		a += TAU
	end
	return a - math.pi
end

function MathUtil.angleDelta(from: number, to: number): number
	return MathUtil.wrapAngle(to - from)
end

function MathUtil.expDecayAngle(current: number, target: number, rate: number, dt: number): number
	local delta = MathUtil.angleDelta(current, target)
	return MathUtil.wrapAngle(current + delta * MathUtil.expAlpha(rate, dt))
end

-- Moves current toward target by at most maxDelta.
function MathUtil.approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

function MathUtil.approachAngle(current: number, target: number, maxDelta: number): number
	local delta = MathUtil.angleDelta(current, target)
	if math.abs(delta) <= maxDelta then
		return MathUtil.wrapAngle(target)
	end
	return MathUtil.wrapAngle(current + math.sign(delta) * maxDelta)
end

function MathUtil.smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function MathUtil.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function MathUtil.safeUnit(v: Vector3, fallback: Vector3?): Vector3
	local m = v.Magnitude
	if m < 1e-6 then
		return fallback or Vector3.zero
	end
	return v / m
end

-- Yaw (radians) of a horizontal direction; 0 = facing -Z (Roblox forward).
function MathUtil.yawOf(dir: Vector3): number
	return math.atan2(-dir.X, -dir.Z)
end

function MathUtil.dirFromYaw(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

function MathUtil.round(v: number, step: number?): number
	local s = step or 1
	return math.floor(v / s + 0.5) * s
end

return MathUtil

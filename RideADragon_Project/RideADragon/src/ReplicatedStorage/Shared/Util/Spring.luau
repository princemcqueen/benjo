--[[
	Spring
	Critically damped spring solved analytically, so it is exactly frame-rate
	independent (no integration error, no jitter at uneven frame times).
	Works for numbers and Vector3.

	frequency: response speed in Hz. ~1.5 = soft, ~4 = responsive, ~10 = snappy.
]]

local Spring = {}
Spring.__index = Spring

function Spring.new(initial: any, frequency: number)
	return setmetatable({
		Position = initial,
		Velocity = initial * 0,
		Target = initial,
		Omega = 2 * math.pi * frequency,
	}, Spring)
end

function Spring:SetFrequency(frequency: number)
	self.Omega = 2 * math.pi * frequency
end

function Spring:Reset(value: any)
	self.Position = value
	self.Target = value
	self.Velocity = value * 0
end

function Spring:Impulse(velocity: any)
	self.Velocity += velocity
end

function Spring:Update(dt: number)
	local w = self.Omega
	local x0 = self.Position - self.Target
	local v0 = self.Velocity
	local e = math.exp(-w * dt)
	local c2 = v0 + x0 * w
	self.Position = self.Target + (x0 + c2 * dt) * e
	self.Velocity = (v0 - c2 * (w * dt)) * e
	return self.Position
end

return Spring

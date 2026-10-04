--[[
	EggReach
	How far an egg can be grabbed from, whether the Egg Radar is on and how fast the nest
	hatches. The server (pickup / incubation) and the client (when to ask, what to show) use
	the same numbers.

	Pickup range bonus (fraction, 0.5 = +50%) =
	      Great Tree "Egg Magnet" branch
	    + every running boost with a Magnet value   (Egg Magnet potion)
	    + every owned pass with a Magnet value      (Egg Hunter)
	Egg Radar range (studs) = the Forge upgrade "Egg Radar" (250 / 600 / 1200 / whole map),
	unlimited while a Radar boost runs or with a pass that has Radar = true.  0 = no radar.
	Hatch factor = product of the HatchFactor of every running boost (Fast Hatch: 0.5).

	Boosts live in data.Boosts[id] = expiry (os.time); `now` is os.time() on the server and
	Workspace:GetServerTimeNow() on the client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))

local EggReach = {}

local function boostLeft(data, boostId: string, now: number): number
	local boosts = data and data.Boosts
	local t = boosts and tonumber(boosts[boostId]) or 0
	return math.max(0, t - now)
end

-- Seconds left of the boost with the longest time among the ones that have `flag`.
local function flagLeft(data, flag: string, now: number): number
	local best = 0
	for id, def in MonetizationConfig.Boosts do
		if def[flag] then
			best = math.max(best, boostLeft(data, id, now))
		end
	end
	return best
end

local function passWith(data, flag: string): boolean
	for id, pass in MonetizationConfig.GamePasses do
		if pass[flag] and MonetizationConfig.ownsPass(data, id) then
			return true
		end
	end
	return false
end

-- Extra pickup range as a fraction (0.5 = +50%).
function EggReach.bonus(data, now: number?): number
	local t = now or os.time()
	local b = TreeConfig.bonus(data, "EggMagnet")
	for id, def in MonetizationConfig.Boosts do
		if def.Magnet and boostLeft(data, id, t) > 0 then
			b += def.Magnet
		end
	end
	for id, pass in MonetizationConfig.GamePasses do
		if pass.Magnet and MonetizationConfig.ownsPass(data, id) then
			b += pass.Magnet
		end
	end
	return b
end

-- Pickup range in studs for a base range.
function EggReach.range(data, base: number, now: number?): number
	return base * (1 + EggReach.bonus(data, now))
end

-- How far the radar sees (0 = off, math.huge = everything).
function EggReach.radarRange(data, now: number?): number
	local t = now or os.time()
	if flagLeft(data, "Radar", t) > 0 or passWith(data, "Radar") then
		return math.huge
	end
	local level = data and data.Upgrades and tonumber(data.Upgrades.Radar) or 0
	return EconomyConfig.upgradeValue("Radar", level)
end

function EggReach.radarActive(data, now: number?): boolean
	return EggReach.radarRange(data, now) > 0
end

-- Seconds of the Egg Radar BOOST left (math.huge with a radar pass, 0 otherwise).
function EggReach.radarSeconds(data, now: number?): number
	if passWith(data, "Radar") then
		return math.huge
	end
	return flagLeft(data, "Radar", now or os.time())
end

-- Incubation time factor (1 = normal, 0.5 = twice as fast).
function EggReach.hatchFactor(data, now: number?): number
	local t = now or os.time()
	local f = 1
	for id, def in MonetizationConfig.Boosts do
		if def.HatchFactor and boostLeft(data, id, t) > 0 then
			f *= def.HatchFactor
		end
	end
	return f
end

return EggReach

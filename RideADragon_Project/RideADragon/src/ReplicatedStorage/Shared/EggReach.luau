--[[
	EggReach
	How far an egg can be grabbed from, and whether the Egg Radar is on. The server (pickup
	validation) and the client (when to ask) use the same numbers.

	Range bonus = Great Tree "Egg Magnet" branch
	            + Egg Magnet boost (Robux product, timed)
	            + Egg Hunter pass (permanent)
	Egg Radar range (studs) = the Forge upgrade "Egg Radar" (250 / 600 / 1200 / whole map),
	unlimited while the Egg Radar boost runs or with the Egg Hunter pass. 0 = no radar.
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

-- Extra pickup range as a fraction (0.5 = +50%).
function EggReach.bonus(data, now: number?): number
	local t = now or os.time()
	local b = TreeConfig.bonus(data, "EggMagnet")
	if boostLeft(data, "Magnet", t) > 0 then
		b += MonetizationConfig.Boosts.Magnet.Magnet
	end
	if MonetizationConfig.ownsPass(data, "EggHunter") then
		b += MonetizationConfig.GamePasses.EggHunter.Magnet
	end
	return b
end

-- How far the radar sees (0 = off, math.huge = everything).
function EggReach.radarRange(data, now: number?): number
	local t = now or os.time()
	if boostLeft(data, "Radar", t) > 0 or MonetizationConfig.ownsPass(data, "EggHunter") then
		return math.huge
	end
	local level = data and data.Upgrades and tonumber(data.Upgrades.Radar) or 0
	return EconomyConfig.upgradeValue("Radar", level)
end

function EggReach.radarActive(data, now: number?): boolean
	return EggReach.radarRange(data, now) > 0
end

-- Seconds of the Egg Radar BOOST left (math.huge with the pass, 0 otherwise).
function EggReach.radarSeconds(data, now: number?): number
	if MonetizationConfig.ownsPass(data, "EggHunter") then
		return math.huge
	end
	return boostLeft(data, "Radar", now or os.time())
end

return EggReach

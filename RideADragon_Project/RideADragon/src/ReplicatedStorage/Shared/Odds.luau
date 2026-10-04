--[[
	Odds
	"1 in N" rarity titles (RNG style).

	A hatched dragon stores its true odds in record.Odds (egg table x luck x
	mutation chance at the moment it hatched). Dragons from other sources
	(starter, rewards, tests) get the base odds: species from its best egg x
	the mutation's hatch chance.

	Odds.format(n)  -> "1 in 12,500,000,000"
	Odds.color(n)   -> title colour by magnitude (white -> green -> blue ->
	                   purple -> orange -> pink -> red -> cyan)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))

local Odds = {}

local speciesCache: { [string]: number } = {}

-- P(species) from one egg's table (no luck).
function Odds.speciesChanceInEgg(eggType: string, speciesId: string): number
	local egg = EggConfig.Eggs[eggType]
	if not egg then
		return 0
	end
	local total, w = 0, 0
	for _, e in egg.Hatch do
		total += e.Weight
		if e.Id == speciesId then
			w += e.Weight
		end
	end
	return total > 0 and w / total or 0
end

-- Best chance of a species across all eggs (0 for exclusives).
function Odds.speciesChance(speciesId: string): number
	local cached = speciesCache[speciesId]
	if cached then
		return cached
	end
	local best = 0
	for eggType in EggConfig.Eggs do
		best = math.max(best, Odds.speciesChanceInEgg(eggType, speciesId))
	end
	speciesCache[speciesId] = best
	return best
end

function Odds.mutationChance(mutation: string?): number
	if mutation == nil or mutation == "None" then
		local miss = 1
		for i = 2, #MutationConfig.Order do
			local m = MutationConfig.Mutations[MutationConfig.Order[i]]
			miss *= 1 - (m.HatchChance or 0)
		end
		return miss
	end
	local m = MutationConfig.Mutations[mutation]
	return m and m.HatchChance or 1
end

local function oneIn(p: number): number
	if p <= 0 then
		return 0
	end
	return math.max(1, math.floor(1 / p + 0.5))
end
Odds.oneIn = oneIn

-- Base odds of a species + mutation (0 = not obtainable by rolling).
function Odds.base(speciesId: string, mutation: string?): number
	return oneIn(Odds.speciesChance(speciesId) * Odds.mutationChance(mutation))
end

-- Odds of one roll from a given egg (used by the roll animation).
function Odds.fromEgg(eggType: string, speciesId: string, mutation: string?): number
	return oneIn(Odds.speciesChanceInEgg(eggType, speciesId) * Odds.mutationChance(mutation))
end

function Odds.ofRecord(record): number
	if not record then
		return 0
	end
	local stored = tonumber(record.Odds)
	if stored and stored >= 1 then
		return stored
	end
	return Odds.base(record.SpeciesId, record.Mutation)
end

local function commas(n: number): string
	local s = string.format("%.0f", n)
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

local SUFFIX = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

-- "1 in 12,500,000,000"; numbers beyond 15 digits are shortened ("1 in 2.5Qi").
function Odds.format(n: number, exclusive: boolean?): string
	if exclusive then
		return "EXCLUSIVE"
	end
	if not n or n <= 0 then
		return "1 in ???"
	end
	if n < 1e15 then
		return "1 in " .. commas(n)
	end
	local i = 0
	local v = n
	while v >= 1000 and i < #SUFFIX do
		v /= 1000
		i += 1
	end
	return "1 in " .. string.format("%.2f", v):gsub("%.?0+$", "") .. SUFFIX[i]
end

-- Title colour by how rare the roll is.
local TIERS = {
	{ 10, Color3.fromRGB(235, 235, 235) },
	{ 100, Color3.fromRGB(140, 230, 120) },
	{ 1000, Color3.fromRGB(90, 180, 255) },
	{ 10000, Color3.fromRGB(190, 120, 255) },
	{ 100000, Color3.fromRGB(255, 170, 50) },
	{ 1000000, Color3.fromRGB(255, 100, 190) },
	{ 1000000000, Color3.fromRGB(255, 70, 70) },
	{ math.huge, Color3.fromRGB(80, 255, 230) },
}

function Odds.color(n: number): Color3
	for _, t in TIERS do
		if (n or 0) < t[1] then
			return t[2]
		end
	end
	return TIERS[#TIERS][2]
end

-- 0..7 tier index (bigger = rarer), used for effects intensity.
function Odds.tier(n: number): number
	for i, t in TIERS do
		if (n or 0) < t[1] then
			return i - 1
		end
	end
	return #TIERS - 1
end

function Odds.isExclusive(speciesId: string): boolean
	local sp = DragonConfig.Species[speciesId]
	return sp ~= nil and sp.Exclusive == true
end

-- Display text for a record (handles exclusives).
function Odds.title(record): string
	if not record then
		return ""
	end
	if Odds.isExclusive(record.SpeciesId) then
		return "EXCLUSIVE"
	end
	return Odds.format(Odds.ofRecord(record))
end

return Odds

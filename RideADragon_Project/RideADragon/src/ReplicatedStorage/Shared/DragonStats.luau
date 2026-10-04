--[[
	DragonStats
	Pure stat math shared by server (authoritative) and client (previews).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local DragonStats = {}

function DragonStats.compute(speciesId: string, level: number, mutation: string?)
	local species = DragonConfig.Species[speciesId]
	assert(species, "Unknown species " .. tostring(speciesId))
	local lm = DragonConfig.levelMultiplier(level)
	local mm = MutationConfig.multiplier(mutation)
	return {
		Speed = math.floor(species.Speed * lm * mm + 0.5),
		FlightSpeed = math.floor(species.FlightSpeed * lm * mm + 0.5),
		IncomePerSecond = math.floor(species.Income * lm * mm * 100 + 0.5) / 100,
	}
end

-- What a dragon sells for: EconomyConfig.SellSeconds (+ the Gentle Goodbye tree bonus) of its BASE
-- income - species income x mutation, NOT the level. Feeding therefore never raises the price and
-- feed + sell can never make money. `data` = the seller's player data (for the tree bonus), may be nil.
function DragonStats.sellValue(record, data): number
	local species = DragonConfig.Species[record.SpeciesId]
	local base = species and species.Income or record.IncomePerSecond or 0
	local seconds = TreeConfig.refundSeconds(data or {})
	return math.max(1, math.floor(base * MutationConfig.multiplier(record.Mutation) * seconds + 0.5))
end

-- Exclusive (Robux) dragons are not for sale.
function DragonStats.canSellSpecies(speciesId: string): boolean
	local species = DragonConfig.Species[speciesId]
	return species ~= nil and species.Exclusive ~= true and species.Rarity ~= "Exclusive"
end

function DragonStats.newRecord(uid: string, speciesId: string, mutation: string?, now: number)
	local species = DragonConfig.Species[speciesId]
	local stats = DragonStats.compute(speciesId, 1, mutation)
	return {
		UniqueId = uid,
		SpeciesId = speciesId,
		Name = species.Name,
		Rarity = species.Rarity,
		Level = 1,
		XP = 0,
		Mutation = mutation or "None",
		Speed = stats.Speed,
		FlightSpeed = stats.FlightSpeed,
		IncomePerSecond = stats.IncomePerSecond,
		Locked = false,
		PlacedNestId = "",
		CreatedAt = now,
	}
end

-- Recomputes derived fields from species/level/mutation (keeps saves in sync
-- with balance changes and prevents stale or tampered stats).
function DragonStats.refresh(record)
	local species = DragonConfig.Species[record.SpeciesId]
	if not species then
		return false
	end
	record.Level = math.clamp(math.floor(tonumber(record.Level) or 1), 1, DragonConfig.MaxLevel)
	record.XP = math.max(0, math.floor(tonumber(record.XP) or 0))
	if record.Mutation == nil or MutationConfig.Mutations[record.Mutation] == nil then
		record.Mutation = "None"
	end
	local stats = DragonStats.compute(record.SpeciesId, record.Level, record.Mutation)
	record.Rarity = species.Rarity
	record.Speed = stats.Speed
	record.FlightSpeed = stats.FlightSpeed
	record.IncomePerSecond = stats.IncomePerSecond
	if type(record.Name) ~= "string" or #record.Name == 0 or #record.Name > 40 then
		record.Name = species.Name
	end
	record.Locked = record.Locked == true
	if type(record.PlacedNestId) ~= "string" then
		record.PlacedNestId = ""
	end
	if type(record.CreatedAt) ~= "number" then
		record.CreatedAt = 0
	end
	return true
end

-- "BEST" ranking: income dominates, flight speed breaks ties, rarity as backup.
function DragonStats.score(record): number
	return record.IncomePerSecond * 1000 + record.FlightSpeed * 0.01 + DragonConfig.rarityRank(record.Rarity)
end

-- flyBonus: Great Tree "Wind Wings" (fraction, 0.1 = +10% cruise speed)
function DragonStats.cruiseSpeed(record, flyBonus: number?): number
	return GameConfig.flightCruiseSpeed(record.FlightSpeed) * (1 + math.max(0, flyBonus or 0))
end

-- runBonus: Great Tree "Swift Paws" (fraction, 0.1 = +10% run speed)
function DragonStats.runSpeed(record, runBonus: number?): number
	return GameConfig.groundRunSpeed(record.Speed) * (1 + math.max(0, runBonus or 0))
end

-- Applies XP and returns number of levels gained.
function DragonStats.addXP(record, amount: number): number
	local gained = 0
	record.XP += math.max(0, math.floor(amount))
	while record.Level < DragonConfig.MaxLevel do
		local need = DragonConfig.xpToNext(record.Level)
		if record.XP < need then
			break
		end
		record.XP -= need
		record.Level += 1
		gained += 1
	end
	if record.Level >= DragonConfig.MaxLevel then
		record.XP = 0
	end
	DragonStats.refresh(record)
	return gained
end

return DragonStats

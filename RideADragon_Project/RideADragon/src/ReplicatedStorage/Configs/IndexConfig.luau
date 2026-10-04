--[[
	IndexConfig
	The Dragon Index (collection book): which species a player has found (data.Index, filled by
	DragonService when a dragon is added) and the rewards for collecting them (IndexService).

	data.Index = { [speciesId] = { First, Count }, ["speciesId:Mutation"] = { First, Count } }
	data.IndexClaims = { [tostring(count)] = true }   milestones already paid

	Robux exclusives (DragonConfig Exclusive = true) are shown in the book but not counted: the
	book can be completed by hatching alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))

local IndexConfig = {}

-- Count = species found; a reward is any of Cash { Seconds, Min }, Spins, Boost { Id, Seconds }, Egg { Type, Luck }.
IndexConfig.Milestones = {
	{ Count = 5, Cash = { Seconds = 300, Min = 5000 } },
	{ Count = 10, Spins = 5 },
	{ Count = 15, Cash = { Seconds = 900, Min = 25000 }, Boost = { Id = "Luck", Seconds = 900 } },
	{ Count = 20, Egg = { Type = "GoldenEgg", Luck = 10 } },
	{ Count = 25, Cash = { Seconds = 3600, Min = 100000 }, Spins = 10 },
	{ Count = 30, Cash = { Seconds = 14400, Min = 500000 }, Egg = { Type = "RainbowEgg", Luck = 50 } },
}

-- Species that count for the collection, in book order.
function IndexConfig.collectable(): { string }
	local list = {}
	for _, id in DragonConfig.speciesList() do
		if not DragonConfig.Species[id].Exclusive then
			table.insert(list, id)
		end
	end
	return list
end

-- Exclusives, shown after the collection.
function IndexConfig.exclusives(): { string }
	local list = {}
	for _, id in DragonConfig.speciesList() do
		if DragonConfig.Species[id].Exclusive then
			table.insert(list, id)
		end
	end
	return list
end

-- Mutations that can be collected per species (everything except "None"; Omni is Robux-only).
function IndexConfig.mutations(): { string }
	local list = {}
	for _, id in MutationConfig.Order do
		if id ~= "None" and id ~= "Omni" then
			table.insert(list, id)
		end
	end
	return list
end

-- How many collectable species the index holds.
function IndexConfig.found(index): number
	local n = 0
	for _, id in IndexConfig.collectable() do
		if index and index[id] then
			n += 1
		end
	end
	return n
end

-- Mutations found for one species.
function IndexConfig.mutationsFound(index, speciesId: string): number
	local n = 0
	for _, m in IndexConfig.mutations() do
		if index and index[speciesId .. ":" .. m] then
			n += 1
		end
	end
	return n
end

-- All different mutated dragons found.
function IndexConfig.totalMutations(index): number
	local n = 0
	for _, id in IndexConfig.collectable() do
		n += IndexConfig.mutationsFound(index, id)
	end
	return n
end

-- The milestone table with the last one tied to the real size of the collection.
function IndexConfig.milestones()
	local total = #IndexConfig.collectable()
	local list = {}
	for _, m in IndexConfig.Milestones do
		if m.Count <= total then
			table.insert(list, m)
		end
	end
	return list
end

return IndexConfig

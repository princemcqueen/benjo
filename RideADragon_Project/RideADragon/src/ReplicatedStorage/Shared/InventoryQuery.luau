--[[
	InventoryQuery
	Search / filter / sort over the player's actual dragon records.
	Pure function: same input -> same ordered list of UniqueIds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local DragonStats = require(script.Parent:WaitForChild("DragonStats"))

local InventoryQuery = {}

InventoryQuery.Filters = { "All", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Exclusive" }
InventoryQuery.Sorts = { "Best", "Speed", "Income", "Level", "Rarity", "Newest" }

local function lower(s: string): string
	return string.lower(s)
end

local function matchesSearch(record, terms: { string }): boolean
	if #terms == 0 then
		return true
	end
	local species = DragonConfig.Species[record.SpeciesId]
	local mutation = MutationConfig.Mutations[record.Mutation]
	local haystack = lower(table.concat({
		record.Name or "",
		species and species.Name or "",
		record.Rarity or "",
		mutation and mutation.Name or "",
		record.Mutation or "",
	}, " "))
	for _, term in terms do
		if not string.find(haystack, term, 1, true) then
			return false
		end
	end
	return true
end

local comparators = {
	Best = function(a, b)
		return DragonStats.score(a), DragonStats.score(b)
	end,
	Speed = function(a, b)
		return a.FlightSpeed, b.FlightSpeed
	end,
	Income = function(a, b)
		return a.IncomePerSecond, b.IncomePerSecond
	end,
	Level = function(a, b)
		return a.Level + a.XP * 1e-9, b.Level + b.XP * 1e-9
	end,
	Rarity = function(a, b)
		return DragonConfig.rarityRank(a.Rarity) * 1e15 + a.IncomePerSecond,
			DragonConfig.rarityRank(b.Rarity) * 1e15 + b.IncomePerSecond
	end,
	Newest = function(a, b)
		return a.CreatedAt, b.CreatedAt
	end,
}

function InventoryQuery.splitTerms(search: string?): { string }
	local terms = {}
	if search then
		for term in string.gmatch(lower(search), "%S+") do
			table.insert(terms, term)
		end
	end
	return terms
end

-- dragons: { [uid]: DragonRecord }
-- opts: { Search: string?, Filter: string?, Sort: string? }
function InventoryQuery.run(dragons: { [string]: any }, opts: { Search: string?, Filter: string?, Sort: string? }): { string }
	local filter = opts.Filter or "All"
	local sortKey = opts.Sort or "Best"
	local terms = InventoryQuery.splitTerms(opts.Search)
	local list = {}
	for _, record in dragons do
		if (filter == "All" or record.Rarity == filter) and matchesSearch(record, terms) then
			table.insert(list, record)
		end
	end
	local cmp = comparators[sortKey] or comparators.Best
	table.sort(list, function(a, b)
		local va, vb = cmp(a, b)
		if va ~= vb then
			return va > vb
		end
		return a.UniqueId < b.UniqueId
	end)
	local out = table.create(#list)
	for i, record in list do
		out[i] = record.UniqueId
	end
	return out
end

return InventoryQuery

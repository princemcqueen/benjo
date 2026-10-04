--[[
	IndexService
	Pays the Dragon Index milestones (IndexConfig): 5, 10, 15, 20, 25 and all 30 species found.

	Net (domain "Index"):
	  Claim { Count } -> { Count, Cash?, Spins?, Boost?, Egg? }
	Errors: BAD_REQUEST, NOT_LOADED, NO_SUCH_MILESTONE, NOT_ENOUGH, ALREADY_CLAIMED
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local IndexConfig = require(Configs:WaitForChild("IndexConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))

local IndexService = {}

local Data
local Services

local function handleClaim(player: Player, p)
	if not Net.check.int(p.Count, 1, 1000) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local milestone
	for _, m in IndexConfig.milestones() do
		if m.Count == p.Count then
			milestone = m
		end
	end
	if not milestone then
		return false, "NO_SUCH_MILESTONE"
	end
	if IndexConfig.found(data.Index) < milestone.Count then
		return false, "NOT_ENOUGH", "Find more dragons first."
	end
	local key = tostring(milestone.Count)
	if data.IndexClaims and data.IndexClaims[key] then
		return false, "ALREADY_CLAIMED", "You already took this reward."
	end
	Data.Set(player, { "IndexClaims", key }, true)
	local out = { Count = milestone.Count }
	local parts = {}
	if milestone.Cash then
		local income = Services.EconomyService.IncomeRate(player)
		out.Cash = math.floor(math.max(milestone.Cash.Min, income * milestone.Cash.Seconds) + 0.5)
		Services.EconomyService.Earn(player, out.Cash, "Index")
		table.insert(parts, Format.cash(out.Cash))
	end
	if milestone.Spins then
		Services.SpinService.AddTickets(player, milestone.Spins)
		out.Spins = milestone.Spins
		table.insert(parts, string.format("%d spins", milestone.Spins))
	end
	if milestone.Boost then
		Services.BoostService.Add(player, milestone.Boost.Id, milestone.Boost.Seconds)
		out.Boost = milestone.Boost
		table.insert(parts, string.format("%d min boost", milestone.Boost.Seconds // 60))
	end
	if milestone.Egg then
		local ok = Services.EggService.GiveEgg(player, milestone.Egg.Type, milestone.Egg.Luck, true)
		local def = EggConfig.Eggs[milestone.Egg.Type]
		if ok then
			out.Egg = milestone.Egg
			table.insert(parts, string.format("%s x%d", def and def.Name or "egg", milestone.Egg.Luck))
		end
	end
	Net.notify(player, "rare", string.format("COLLECTION %d DRAGONS!  %s", milestone.Count, table.concat(parts, "  +  ")))
	return true, out
end

function IndexService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Index", "Claim", handleClaim, { Burst = 4, PerSecond = 1 })
end

return IndexService

--[[
	DevService
	Studio-only test helpers for playtesting (UI Lab "TEST" buttons).
	Nothing is registered on live servers: every handler is behind
	RunService:IsStudio(), so clients can never reach these in a real game.

	Net (domain "Dev"): Cash, Dragons, Eggs, HatchNow
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))

local MutationConfig = require(Configs:WaitForChild("MutationConfig"))

local DevService = {}

local RATE = { Burst = 4, PerSecond = 1 }

function DevService.Init(services)
	if not RunService:IsStudio() then
		return
	end
	local Data = services.PlayerDataService
	local rng = Random.new()

	Net.handle("Dev", "Cash", function(player)
		services.EconomyService.Earn(player, 1000000, "Dev")
		return true
	end, RATE)

	Net.handle("Dev", "Dragons", function(player)
		-- one of every species, cycling through every mutation (test kit)
		local data = Data.Get(player)
		if not data then
			return false, "NOT_LOADED"
		end
		local maxLevel = #EconomyConfig.Upgrades.DragonStorage.Levels - 1
		if (data.Upgrades.DragonStorage or 0) < maxLevel then
			Data.Set(player, { "Upgrades", "DragonStorage" }, maxLevel)
		end
		local list = DragonConfig.speciesList()
		local muts = MutationConfig.Order
		local added = 0
		local i = 0
		for _, species in list do
			if not DragonConfig.Species[species].Exclusive then
				i += 1
				local mutation = muts[((i - 1) % #muts) + 1]
				if services.DragonService.Add(player, species, mutation, "Dev") then
					added += 1
				end
			end
		end
		if added == 0 then
			return false, "STORAGE_FULL", "Your dragon storage is full."
		end
		return true, { Added = added }
	end, RATE)

	Net.handle("Dev", "Eggs", function(player)
		local data = Data.Get(player)
		if not data then
			return false, "NOT_LOADED"
		end
		local cap = EconomyConfig.upgradeValue("EggStorage", data.Upgrades.EggStorage or 0)
		local types = {}
		for id in EggConfig.Eggs do
			table.insert(types, id)
		end
		table.sort(types)
		local eggs = table.clone(data.Eggs)
		while #eggs < cap do
			local id = Data.NextId(player, "EggSerial", "E")
			local eggType = types[rng:NextInteger(1, #types)]
			table.insert(eggs, { Id = id, Type = eggType, Found = os.time(), Luck = EggConfig.rollLuck(eggType, rng, true) })
		end
		Data.Set(player, { "Eggs" }, eggs)
		return true
	end, RATE)

	Net.handle("Dev", "HatchNow", function(player)
		local data = Data.Get(player)
		if not data then
			return false, "NOT_LOADED"
		end
		local t = os.time()
		for key, slot in data.Incubator.Slots do
			local copy = table.clone(slot)
			copy.Ready = math.min(copy.Ready, t)
			copy.Start = math.min(copy.Start, t - 1)
			Data.Set(player, { "Incubator", "Slots", key }, copy)
		end
		return true
	end, RATE)

	ReplicatedStorage:SetAttribute("DevTools", true)
end

return DevService

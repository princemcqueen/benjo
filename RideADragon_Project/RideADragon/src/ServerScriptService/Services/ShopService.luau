--[[
	ShopService
	Cash upgrades (Forge / Shop "Upgrades" tab): Egg Storage, Dragon Storage,
	Hatch Luck, Egg Radar. Prices come only from EconomyConfig.

	Net (domain "Shop"): BuyUpgrade { Id } -> { Id, Level }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))

local ShopService = {}

local Services
local Data

local function buyUpgrade(player: Player, p)
	if not Net.check.str(p.Id, 32) then
		return false, "BAD_REQUEST"
	end
	local def = EconomyConfig.Upgrades[p.Id]
	local data = Data.Get(player)
	if not def or not data then
		return false, "BAD_UPGRADE"
	end
	local level = tonumber(data.Upgrades[p.Id]) or 0
	local nextEntry = def.Levels[level + 2]
	if not nextEntry then
		return false, "MAXED", def.Name .. " is fully upgraded."
	end
	if not Services.EconomyService.Spend(player, nextEntry.Price, "Upgrade") then
		return false, "NO_CASH", "Not enough cash."
	end
	Data.Set(player, { "Upgrades", p.Id }, level + 1)
	return true, { Id = p.Id, Level = level + 1 }
end

function ShopService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Shop", "BuyUpgrade", buyUpgrade, { Burst = 6, PerSecond = 3 })
end

return ShopService

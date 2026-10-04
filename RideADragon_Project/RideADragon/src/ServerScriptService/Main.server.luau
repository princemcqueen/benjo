--[[
	Server bootstrap. Requires every service in dependency order, runs Init
	(synchronous wiring) for all of them, opens the network layer, then Start
	(loops and listeners).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local ServicesFolder = script.Parent:WaitForChild("Services")

local ORDER = {
	"PlayerDataService",
	"SettingsService",
	"PhysicsGroups",
	"WorldService",
	"DragonAssetService",
	"EconomyService",
	"DragonService",
	"MountService",
	"SanctuaryService",
	"TravelService",
	"BoostService",
	"EggService",
	"ShopService",
	"MonetizationService",
	"QuestService",
	"DailyService",
	"RegionService",
	"LeaderstatsService",
	"LeaderboardService",
	"SpinService",
	"DevService",
}

local services = {}
for _, name in ORDER do
	local module = ServicesFolder:FindFirstChild(name)
	if module then
		services[name] = require(module)
	end
end

for _, name in ORDER do
	local service = services[name]
	if service and service.Init then
		service.Init(services)
	end
end

Net.start()

for _, name in ORDER do
	local service = services[name]
	if service and service.Start then
		task.spawn(service.Start)
	end
end

ReplicatedStorage:SetAttribute("ServerReady", true)

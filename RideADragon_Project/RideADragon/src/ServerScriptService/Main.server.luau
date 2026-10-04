--[[
	Server bootstrap. Requires every service in dependency order, runs Init
	(synchronous wiring) for all of them, opens the network layer, then Start
	(loops and listeners).

	Every step runs in its own protected call: a service that fails is reported (Output, and
	in Studio the ReplicatedStorage attributes ServerBootErrors / ServerErrors that the client's
	Diagnostics panel shows) and the other services keep running.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
	"TreeService",
	"BondService",
	"EggService",
	"WildEggService",
	"CoinService",
	"ShopService",
	"MonetizationService",
	"QuestService",
	"DailyService",
	"IndexService",
	"RegionService",
	"LevelService",
	"LeaderstatsService",
	"LeaderboardService",
	"RaceService",
	"CombatService",
	"DuelService",
	"SpinService",
	"DevService",
}

-- ============================================================== failures
local bootErrors: { string } = {}

local function try(stage: string, name: string, fn: any, ...: any): (boolean, any)
	local ok, result = xpcall(fn, function(e)
		return tostring(e) .. "\n" .. debug.traceback("", 2)
	end, ...)
	if not ok then
		local text = string.format("%s %s: %s", stage, name, tostring(result))
		table.insert(bootErrors, text)
		warn("[Boot] " .. text)
		return false, nil
	end
	return true, result
end

local services = {}
for _, name in ORDER do
	local module = ServicesFolder:FindFirstChild(name)
	if module then
		local ok, service = try("require", name, require, module)
		if ok then
			services[name] = service
		end
	end
end

for _, name in ORDER do
	local service = services[name]
	if service and service.Init then
		try("Init", name, service.Init, services)
	end
end

try("start", "Net", Net.start)

for _, name in ORDER do
	local service = services[name]
	if service and service.Start then
		task.spawn(try, "Start", name, service.Start)
	end
end

-- Studio: publish the errors so the client can show them on screen (see Diagnostics)
if RunService:IsStudio() then
	if #bootErrors > 0 then
		ReplicatedStorage:SetAttribute("ServerBootErrors", table.concat(bootErrors, "\n---\n"))
	end
	local okContext, scriptContext = pcall(function()
		return game:GetService("ScriptContext")
	end)
	if okContext and scriptContext then
		local seen: { [string]: boolean } = {}
		local list: { string } = {}
		local lastPublish = 0
		pcall(function()
			scriptContext.Error:Connect(function(message, _trace, source)
				local text = (source and (source.Name .. ": ") or "") .. tostring(message)
				local key = string.match(text, "^[^\n]*") or text
				if seen[key] then
					return
				end
				seen[key] = true
				table.insert(list, text)
				if #list > 8 then
					table.remove(list, 1)
				end
				if os.clock() - lastPublish > 1 or #list <= 2 then
					lastPublish = os.clock()
					ReplicatedStorage:SetAttribute("ServerErrors", table.concat(list, "\n---\n"))
				end
			end)
		end)
	end
end

ReplicatedStorage:SetAttribute("ServerReady", true)

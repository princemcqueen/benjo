--[[
	IslandService
	Builds the floating sky islands (WorldConfig.SkyIslands, World/SkyIslands) into Workspace.World and
	registers an egg area for each with EggService (a rare area: its luck rolls twice). Eggs then grow on
	the islands like anywhere else: the personal egg cycle picks island areas, a share of the roaming
	eggs and every other wild egg may appear on one (EggConfig.Spawning.IslandShare).

	API: IslandService.Ready (bool), IslandService.Models() -> { [id] = Model }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local WorldConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("WorldConfig"))

local IslandService = {}
IslandService.Ready = false

local Services
local models: { [string]: Model } = {}

function IslandService.Models()
	return models
end

function IslandService.Init(services)
	Services = services
end

function IslandService.Start()
	task.spawn(function()
		local world = Workspace:WaitForChild("World", 180)
		if not world then
			warn("[Islands] no World folder: the sky islands are not built")
			return
		end
		local ok, SkyIslands = pcall(function()
			return require(ServerScriptService:WaitForChild("World"):WaitForChild("SkyIslands"))
		end)
		if not ok then
			warn("[Islands] SkyIslands module failed: " .. tostring(SkyIslands))
			return
		end
		local folder = Instance.new("Folder")
		folder.Name = "SkyIslands"
		folder.Parent = world
		local eggs = Services and Services.EggService
		for _, def in WorldConfig.SkyIslands do
			local built, model = pcall(SkyIslands.build, folder, def)
			if built then
				models[def.Id] = model
				if eggs and eggs.AddArea then
					eggs.AddArea({
						Name = def.Id,
						Label = def.Name,
						Position = def.Center + Vector3.new(0, 2.5, 0),
						Region = def.Region,
						Radius = def.Radius * 0.78,
						Island = true,
					})
				end
			else
				warn("[Islands] " .. def.Id .. " failed: " .. tostring(model))
			end
		end
		IslandService.Ready = true
	end)
end

return IslandService

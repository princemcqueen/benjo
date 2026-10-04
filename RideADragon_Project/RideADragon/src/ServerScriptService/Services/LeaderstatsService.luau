--[[
	LeaderstatsService
	Roblox player-list leaderboard (leaderstats): Cash (abbreviated), Dragons,
	Hatched. Updated from the data mirror, at most a few times per second.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Format"))

local LeaderstatsService = {}

local Data
local stats: { [Player]: { [string]: ValueBase } } = {}

local function build(player: Player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local cash = Instance.new("StringValue")
	cash.Name = "Cash"
	cash.Value = "$0"
	cash.Parent = folder
	local dragons = Instance.new("IntValue")
	dragons.Name = "Dragons"
	dragons.Parent = folder
	local hatched = Instance.new("IntValue")
	hatched.Name = "Hatched"
	hatched.Parent = folder
	folder.Parent = player
	stats[player] = { Cash = cash, Dragons = dragons, Hatched = hatched }
end

local function refresh(player: Player)
	local s = stats[player]
	local data = Data.Get(player)
	if not s or not data then
		return
	end
	local cash = Format.cash(data.Cash or 0)
	if (s.Cash :: StringValue).Value ~= cash then
		(s.Cash :: StringValue).Value = cash
	end
	local n = 0
	for _ in data.Dragons do
		n += 1
	end
	(s.Dragons :: IntValue).Value = n;
	(s.Hatched :: IntValue).Value = data.Stats and data.Stats.Hatched or 0
end

function LeaderstatsService.Init(services)
	Data = services.PlayerDataService
end

function LeaderstatsService.Start()
	Data.Loaded:Connect(function(player)
		if not stats[player] then
			build(player)
		end
		refresh(player)
	end)
	for _, player in Players:GetPlayers() do
		if Data.Get(player) and not stats[player] then
			build(player)
			refresh(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		stats[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			for player in stats do
				if player.Parent == Players then
					refresh(player)
				end
			end
		end
	end)
end

return LeaderstatsService

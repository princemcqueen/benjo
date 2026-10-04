--[[
	TreeService
	The Great Tree: permanent upgrades bought with cash (TreeConfig).
	Five branches (RollLuck, MutationLuck, Income, FlySpeed, HatchSpeed), five
	levels each, bought strictly in order. Server authority: the price, the
	level order and every bonus come from TreeConfig - the client only asks to
	buy "the next level" of a branch.

	data.Tree = { [branchId] = level }  (replicated to the client)

	API:
	  TreeService.Bonus(player, id) -> total bonus of that branch (0 if not bought)
	Net (domain "Tree"):
	  Buy { Id } -> { Id, Level, Bonus }
	Clients read data.Tree (replicated) through TreeConfig.bonus; the server applies
	the bonuses where they matter (see the TreeConfig header).
	Signal: Bought(player, id, level)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local TreeService = {}
TreeService.Bought = Signal.new() -- (player, branchId, level)

local Data
local Services

function TreeService.Bonus(player: Player, id: string): number
	return TreeConfig.bonus(Data.Get(player), id)
end

function TreeService.Level(player: Player, id: string): number
	return TreeConfig.level(Data.Get(player), id)
end

-- Re-reads everything derived from the tree (luck attribute, companion stats).
function TreeService.Refresh(player: Player)
	local boosts = Services.BoostService
	if boosts then
		boosts.Refresh(player)
	end
	local mount = Services.MountService
	if mount and mount.RefreshStats then
		mount.RefreshStats(player)
	end
end

-- Eggs already warming up get faster the moment Warm Nest is upgraded.
local function speedUpIncubator(player: Player, oldBonus: number, newBonus: number)
	local data = Data.Get(player)
	if not data or newBonus <= oldBonus then
		return
	end
	local t = os.time()
	local ratio = (1 - newBonus) / (1 - oldBonus)
	for key, slot in data.Incubator.Slots do
		local ready = tonumber(slot.Ready) or 0
		if ready > t then
			local newReady = t + math.max(1, math.floor((ready - t) * ratio + 0.5))
			Data.Set(player, { "Incubator", "Slots", key, "Ready" }, newReady)
		end
	end
end

local function handleBuy(player: Player, p)
	if not Net.check.str(p.Id, 24) then
		return false, "BAD_REQUEST"
	end
	local branch = TreeConfig.ById[p.Id]
	local data = Data.Get(player)
	if not branch or not data then
		return false, "BAD_BRANCH"
	end
	local level = TreeConfig.level(data, p.Id)
	local entry = branch.Levels[level + 1]
	if not entry then
		return false, "MAXED", branch.Name .. " is fully grown."
	end
	local oldBonus = TreeConfig.bonus(data, p.Id)
	if not Services.EconomyService.Spend(player, entry.Price, "Tree") then
		return false, "NO_CASH", "Not enough cash."
	end
	Data.Set(player, { "Tree", p.Id }, level + 1)
	if p.Id == "HatchSpeed" then
		speedUpIncubator(player, oldBonus, entry.Bonus)
	end
	TreeService.Refresh(player)
	TreeService.Bought:Fire(player, p.Id, level + 1)
	return true, { Id = p.Id, Level = level + 1, Bonus = entry.Bonus }
end

function TreeService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Tree", "Buy", handleBuy, { Burst = 6, PerSecond = 3 })
end

function TreeService.Start()
	Data.Loaded:Connect(function(player)
		TreeService.Refresh(player)
	end)
	for _, player in Players:GetPlayers() do
		if Data.Get(player) then
			TreeService.Refresh(player)
		end
	end
end

return TreeService

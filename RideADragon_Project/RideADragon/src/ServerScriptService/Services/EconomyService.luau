--[[
	EconomyService
	The only place cash changes hands. Every price is read from configs on the
	server; clients never send amounts.

	Passive income: every dragon resting on a sanctuary perch earns its
	IncomePerSecond. Online income is paid into cash once per second; while
	the player is away, a share of it accumulates (capped) and is paid with a
	"welcome back" message on the next join.

	API (server):
	  EconomyService.CanAfford(player, amount) -> boolean
	  EconomyService.Spend(player, amount, reason) -> boolean
	  EconomyService.Earn(player, amount, reason)
	  EconomyService.IncomeRate(player) -> number (per second, boosts included)
	  EconomyService.Multiplier(player) -> number (income multiplier)
	Signals: Spent(player, amount, reason), Earned(player, amount, reason)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local Net = require(Shared:WaitForChild("Net"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local EconomyService = {}
EconomyService.Spent = Signal.new()
EconomyService.Earned = Signal.new()

local Data
local Services
local carry: { [Player]: number } = {} -- fractional income not yet paid

local function valid(amount: any): boolean
	return type(amount) == "number" and amount == amount and amount >= 0 and amount < math.huge
end

function EconomyService.CanAfford(player: Player, amount: number): boolean
	local data = Data.Get(player)
	return data ~= nil and valid(amount) and data.Cash >= amount
end

function EconomyService.Spend(player: Player, amount: number, reason: string?): boolean
	if not valid(amount) then
		return false
	end
	amount = math.floor(amount + 0.5)
	local data = Data.Get(player)
	if not data or data.Cash < amount then
		return false
	end
	if amount > 0 then
		Data.Increment(player, { "Cash" }, -amount)
		EconomyService.Spent:Fire(player, amount, reason or "")
	end
	return true
end

function EconomyService.Earn(player: Player, amount: number, reason: string?)
	if not valid(amount) then
		return
	end
	amount = math.floor(amount + 0.5)
	if amount <= 0 or not Data.Get(player) then
		return
	end
	Data.Increment(player, { "Cash" }, amount)
	Data.Increment(player, { "TotalEarned" }, amount)
	EconomyService.Earned:Fire(player, amount, reason or "")
end

-- Income multiplier from active boosts (Coins potion etc.).
function EconomyService.Multiplier(player: Player): number
	local boosts = Services.BoostService
	if boosts and boosts.Multiplier then
		return boosts.Multiplier(player, "Coins")
	end
	return 1
end

-- Base income per second of every dragon resting on a perch.
local function baseRate(data): number
	local total = 0
	for _, uid in data.Nests.Slots do
		local record = data.Dragons[uid]
		if record then
			total += record.IncomePerSecond
		end
	end
	return total
end

function EconomyService.IncomeRate(player: Player): number
	local data = Data.Get(player)
	if not data then
		return 0
	end
	return baseRate(data) * EconomyService.Multiplier(player)
end

local function payTick(dt: number)
	for _, player in Players:GetPlayers() do
		local data = Data.Get(player)
		if data then
			local amount = (carry[player] or 0) + baseRate(data) * EconomyService.Multiplier(player) * dt
			local whole = math.floor(amount)
			if whole >= 1 then
				EconomyService.Earn(player, whole, "Income")
				Data.Increment(player, { "Stats", "Collected" }, whole)
			end
			carry[player] = amount - whole
		end
	end
end

-- Offline earnings: a share of the perch income since the last session.
local function onLoaded(player: Player, data)
	local last = tonumber(data.LastLogout) or 0
	if last <= 0 or Data.IsTemporary() then
		return
	end
	-- Great Tree "Dream Dens": longer cap and a better rate while you are away
	local dens = TreeConfig.bonus(data, "Offline")
	local away = math.clamp(os.time() - last, 0, EconomyConfig.OfflineCapSeconds * (1 + dens))
	if away < 60 then
		return
	end
	local amount = math.floor(baseRate(data) * away * math.min(1, EconomyConfig.OfflineRate * (1 + dens)))
	if amount > 0 then
		EconomyService.Earn(player, amount, "Offline")
		task.delay(4, function()
			if player.Parent == Players then
				Net.notify(player, "rare", string.format("Welcome back! Your dragons earned %s while you were away.", Format.cash(amount)))
			end
		end)
	end
end

function EconomyService.Init(services)
	Services = services
	Data = services.PlayerDataService
end

function EconomyService.Start()
	Data.Loaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		carry[player] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 1 then
			local step = math.min(acc, 5)
			acc = 0
			payTick(step)
		end
	end)
end

return EconomyService

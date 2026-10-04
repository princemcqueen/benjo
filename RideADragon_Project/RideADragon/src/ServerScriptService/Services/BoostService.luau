--[[
	BoostService
	Timed boosts (potions) and permanent perks (Owner Dragon pass).

	data.Boosts = { [boostId] = expiresAt (os.time) }   -- replicated to the client
	data.Flags.OwnerPass = true                          -- Owner Dragon pass perk

	LuckMultiplier(player): multiplies every roll's luck (egg hatches,
	mutations, Spin Wheel). Multiplier(player, "Coins"): sanctuary income.
	The player attribute "Luck" mirrors the current luck multiplier for the HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Configs = ReplicatedStorage:WaitForChild("Configs")
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))

local BoostService = {}

local Data

local function now(): number
	return os.time()
end

function BoostService.Add(player: Player, boostId: string, seconds: number): boolean
	if not MonetizationConfig.Boosts[boostId] or seconds <= 0 then
		return false
	end
	local data = Data.Get(player)
	if not data then
		return false
	end
	local current = tonumber(data.Boosts and data.Boosts[boostId]) or 0
	local base = math.max(now(), current) -- buying again extends the timer
	Data.Set(player, { "Boosts", boostId }, base + math.floor(seconds))
	BoostService.Refresh(player)
	return true
end

function BoostService.Remaining(player: Player, boostId: string): number
	local data = Data.Get(player)
	local t = data and data.Boosts and tonumber(data.Boosts[boostId]) or 0
	return math.max(0, t - now())
end

function BoostService.HasOwnerPass(player: Player): boolean
	local data = Data.Get(player)
	return data ~= nil and data.Flags ~= nil and data.Flags.OwnerPass == true
end

function BoostService.LuckMultiplier(player: Player): number
	local m = 1
	m *= MonetizationConfig.passLuck(Data.Get(player))
	for id, def in MonetizationConfig.Boosts do
		if def.Luck and BoostService.Remaining(player, id) > 0 then
			m *= def.Luck
		end
	end
	return m
end

-- EconomyService hook: kind "Coins" = sanctuary income multiplier.
function BoostService.Multiplier(player: Player, kind: string): number
	if kind ~= "Coins" then
		return 1
	end
	local m = 1
	for id, def in MonetizationConfig.Boosts do
		if def.Cash and BoostService.Remaining(player, id) > 0 then
			m *= def.Cash
		end
	end
	return m
end

function BoostService.Refresh(player: Player)
	player:SetAttribute("Luck", BoostService.LuckMultiplier(player))
	player:SetAttribute("CashBoost", BoostService.Multiplier(player, "Coins"))
end

local function sweep()
	for _, player in Players:GetPlayers() do
		local data = Data.Get(player)
		if data and data.Boosts then
			for id, t in data.Boosts do
				if (tonumber(t) or 0) <= now() then
					Data.Set(player, { "Boosts", id }, nil)
				end
			end
			BoostService.Refresh(player)
		end
	end
end

function BoostService.Init(services)
	Data = services.PlayerDataService
end

function BoostService.Start()
	Data.Loaded:Connect(function(player)
		BoostService.Refresh(player)
	end)
	for _, player in Players:GetPlayers() do
		if Data.Get(player) then
			BoostService.Refresh(player)
		end
	end
	task.spawn(function()
		while true do
			task.wait(5)
			pcall(sweep)
		end
	end)
end

return BoostService

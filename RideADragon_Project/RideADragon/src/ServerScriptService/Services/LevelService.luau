--[[
	LevelService
	The player level (data.Level / data.XP, shown in the HUD). Awards XP for what
	players actually do and pays a reward on every level up:

	  egg picked up            EconomyConfig.XP.EggFound
	  dragon hatched           DragonConfig.Rarities[rarity].HatchXP (+ mutation bonus)
	  new species discovered   EconomyConfig.XP.FirstPlace
	  distance flown           EconomyConfig.XP.FlyPer1000 per 1000 studs (server-measured)
	  dragon bond level up     EconomyConfig.XP.BondLevel + 4 per level
	  Great Tree level bought  EconomyConfig.XP.TreeLevel + 5 per level
	  anything else            LevelService.Add(player, amount, reason)

	The Great Tree branch "Ancient Wisdom" multiplies all XP. Reaching level N
	needs EconomyConfig.playerXPToNext(N - 1) XP; the cap is MaxPlayerLevel.
	Regions (RegionConfig.RequiredLevel) unlock by level.

	Net signal "LevelUp" { Level, Cash, Spins, Unlocks = { region names } }
	Signal: LevelUp(player, level)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local RegionConfig = require(Configs:WaitForChild("RegionConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local LevelService = {}
LevelService.LevelUp = Signal.new() -- (player, level)

local Data
local Services

local lastFlyPos: { [Player]: Vector3 } = {}
local flyCarry: { [Player]: number } = {} -- distance not yet turned into XP

local FLY_TICK = 2

function LevelService.Level(player: Player): number
	local data = Data.Get(player)
	return data and data.Level or 1
end

local function levelUpRewards(player: Player, level: number)
	local cash, spins = EconomyConfig.levelReward(level)
	if cash > 0 then
		Services.EconomyService.Earn(player, cash, "LevelUp")
	end
	if spins > 0 and Services.SpinService and Services.SpinService.AddTickets then
		Services.SpinService.AddTickets(player, spins)
	end
	local unlocks = {}
	for _, id in RegionConfig.Order do
		local region = RegionConfig.Regions[id]
		if region.RequiredLevel == level and level > 1 then
			table.insert(unlocks, region.Name)
		end
	end
	Net.signal(player, "LevelUp", { Level = level, Cash = cash, Spins = spins, Unlocks = unlocks })
	local text = string.format("LEVEL UP! You reached level %d  (+$%d)", level, cash)
	if spins > 0 then
		text ..= string.format(" +%d spins", spins)
	end
	Net.notify(player, "rare", text)
	for _, name in unlocks do
		Net.notify(player, "success", name .. " is now open to you!")
	end
end

-- Adds player XP (Ancient Wisdom applies). Returns the number of levels gained.
function LevelService.Add(player: Player, amount: number, reason: string?): number
	local data = Data.Get(player)
	if not data or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	local gain = math.max(1, math.floor(amount * (1 + TreeConfig.bonus(data, "Wisdom")) + 0.5))
	local level = math.clamp(math.floor(tonumber(data.Level) or 1), 1, EconomyConfig.MaxPlayerLevel)
	local xp = math.max(0, math.floor(tonumber(data.XP) or 0)) + gain
	local gained = 0
	while level < EconomyConfig.MaxPlayerLevel do
		local need = EconomyConfig.playerXPToNext(level)
		if xp < need then
			break
		end
		xp -= need
		level += 1
		gained += 1
	end
	if level >= EconomyConfig.MaxPlayerLevel then
		xp = math.min(xp, EconomyConfig.playerXPToNext(level) - 1)
	end
	Data.Set(player, { "XP" }, xp)
	if gained > 0 then
		local first = data.Level + 1
		Data.Set(player, { "Level" }, level)
		for lv = first, level do
			levelUpRewards(player, lv)
		end
		LevelService.LevelUp:Fire(player, level)
	end
	local _ = reason
	return gained
end

-- ============================================================== sources
local function onHatched(player: Player, record, _eggType)
	local rarity = DragonConfig.Rarities[record.Rarity]
	local xp = rarity and rarity.HatchXP or 0
	xp *= 1 + MutationConfig.rank(record.Mutation) * EconomyConfig.XP.MutationRank
	local data = Data.Get(player)
	local entry = data and data.Index and data.Index[record.SpeciesId]
	if entry and (tonumber(entry.Count) or 0) <= 1 then
		xp += EconomyConfig.XP.FirstPlace
	end
	LevelService.Add(player, xp, "Hatch")
end

local function flyTick()
	local mount = Services.MountService
	for _, player in Players:GetPlayers() do
		local comp = mount and mount.Get(player)
		if comp and comp.Riding and comp.Model.Parent and comp.Model:GetAttribute("Mode") == "Fly" then
			local pos = comp.Root.Position
			local prev = lastFlyPos[player]
			lastFlyPos[player] = pos
			if prev then
				local moved = math.min((pos - prev).Magnitude, 900) -- teleports/snap-backs do not count
				if moved > 1 then
					Data.Increment(player, { "Stats", "DistanceFlown" }, moved)
					local carry = (flyCarry[player] or 0) + moved
					local per = 1000 / EconomyConfig.XP.FlyPer1000
					local xp = math.floor(carry / per)
					flyCarry[player] = carry - xp * per
					if xp > 0 then
						LevelService.Add(player, xp, "Flight")
					end
				end
			end
		else
			lastFlyPos[player] = nil
		end
	end
end

function LevelService.Init(services)
	Services = services
	Data = services.PlayerDataService
end

function LevelService.Start()
	Services.EggService.PickedUp:Connect(function(player)
		LevelService.Add(player, EconomyConfig.XP.EggFound, "Egg")
	end)
	Services.EggService.Hatched:Connect(onHatched)
	local bond = Services.BondService
	if bond and bond.LevelUp then
		bond.LevelUp:Connect(function(player, _uid, level)
			LevelService.Add(player, EconomyConfig.XP.BondLevel + level * 4, "Bond")
		end)
	end
	local tree = Services.TreeService
	if tree and tree.Bought then
		tree.Bought:Connect(function(player, _id, level)
			LevelService.Add(player, EconomyConfig.XP.TreeLevel + level * 5, "Tree")
		end)
	end
	task.spawn(function()
		while true do
			task.wait(FLY_TICK)
			pcall(flyTick)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastFlyPos[player] = nil
		flyCarry[player] = nil
	end)
end

return LevelService

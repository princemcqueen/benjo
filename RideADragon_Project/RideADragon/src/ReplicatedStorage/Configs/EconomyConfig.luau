--[[
	EconomyConfig
	Prices, upgrade ladders, nests, player levels, daily rewards.
	The server reads prices ONLY from here; clients never send prices.
]]

local EconomyConfig = {}

EconomyConfig.Upgrades = {
	EggStorage = {
		Name = "Egg Storage",
		Description = "Carry more eggs before returning home.",
		Icon = "Egg",
		Format = "Count",
		Levels = {
			{ Value = 5, Price = 0 },
			{ Value = 8, Price = 300 },
			{ Value = 12, Price = 4000 },
			{ Value = 18, Price = 60000 },
			{ Value = 25, Price = 900000 },
			{ Value = 35, Price = 15000000 },
		},
	},
	DragonStorage = {
		Name = "Dragon Storage",
		Description = "Keep more dragons in your collection.",
		Icon = "Chest",
		Format = "Count",
		Levels = {
			{ Value = 30, Price = 0 },
			{ Value = 50, Price = 1500 },
			{ Value = 80, Price = 25000 },
			{ Value = 120, Price = 400000 },
			{ Value = 175, Price = 6000000 },
			{ Value = 250, Price = 90000000 },
		},
	},
	HatchLuck = {
		Name = "Hatch Luck",
		Description = "Boosts the chance of Rare and better dragons.",
		Icon = "Clover",
		Format = "Percent",
		Levels = {
			{ Value = 0, Price = 0 },
			{ Value = 0.15, Price = 2500 },
			{ Value = 0.35, Price = 40000 },
			{ Value = 0.6, Price = 600000 },
			{ Value = 1.0, Price = 9000000 },
			{ Value = 1.5, Price = 150000000 },
		},
	},
	Radar = {
		Name = "Egg Radar",
		Description = "Reveals nearby eggs on your screen.",
		Icon = "Radar",
		Format = "Range",
		Levels = {
			{ Value = 0, Price = 0 },
			{ Value = 250, Price = 500 },
			{ Value = 600, Price = 8000 },
			{ Value = 1200, Price = 150000 },
			{ Value = 100000, Price = 3000000 },
		},
	},
}

EconomyConfig.UpgradeOrder = { "EggStorage", "DragonStorage", "HatchLuck", "Radar" }

function EconomyConfig.upgradeValue(id: string, level: number): number
	local def = EconomyConfig.Upgrades[id]
	local entry = def.Levels[math.clamp(level + 1, 1, #def.Levels)]
	return entry.Value
end

-- Nests: index -> unlock price (0 = unlocked from the start).
EconomyConfig.NestPrices = { 0, 0, 750, 6000, 45000, 300000, 2000000, 15000000 }
EconomyConfig.StartingNests = 2

-- Passive income: perch dragons pay into cash every second while online;
-- while offline a share accumulates for up to OfflineCapSeconds.
EconomyConfig.OfflineCapSeconds = 2 * 3600
EconomyConfig.OfflineRate = 0.5

-- SELLING a dragon pays this many seconds of its BASE income (species income x mutation - the level
-- does not count, so feeding a dragon and selling it can never make money). The Gentle Goodbye branch
-- of the Great Tree adds to it. Exclusive (Robux) dragons cannot be sold.
EconomyConfig.SellSeconds = 300
EconomyConfig.ReleaseRefundSeconds = EconomyConfig.SellSeconds -- (old name)

-- Purchases at/above this fraction of current cash ask for confirmation.
EconomyConfig.ConfirmFraction = 0.4
EconomyConfig.ConfirmMinimum = 25000

-- Feeding: every meal gives a fixed share of the XP the dragon needs for its
-- next level (three meals per level at any level); the price grows instead. One level costs 3 meals
-- = 12 x base income x level^1.15 and adds 8% of the base income per second: it pays itself back in
-- about 150 x level^1.15 seconds (2.5 minutes at level 1, ~35 minutes at level 10, ~3.5 hours at 49).
EconomyConfig.FeedFraction = 0.34
EconomyConfig.FeedExponent = 1.15
function EconomyConfig.feedCost(baseCost: number, level: number): number
	return math.floor(baseCost * level ^ EconomyConfig.FeedExponent + 0.5)
end
function EconomyConfig.feedXP(xpToNext: number): number
	return math.max(1, math.ceil(xpToNext * EconomyConfig.FeedFraction))
end

-- Player level
EconomyConfig.MaxPlayerLevel = 100
function EconomyConfig.playerXPToNext(level: number): number
	return math.floor(120 * level ^ 1.5 + 0.5)
end
-- XP sources (LevelService). Hatching pays DragonConfig.Rarities[rarity].HatchXP.
EconomyConfig.XP = {
	EggFound = 8, -- picking up an egg in the world
	FirstPlace = 25, -- discovering a species for the first time
	QuestBase = 40,
	FlyPer1000 = 6, -- per 1000 studs flown
	MutationRank = 0.25, -- hatch XP bonus per mutation rank (Shiny +25%, Golden +50%...)
	BondLevel = 20, -- + 4 per bond level reached
	TreeLevel = 20, -- + 5 per tree level bought (per branch level)
}

-- Reward for reaching a player level: cash (scales with the level) and, every 5th
-- level, spin tickets.
function EconomyConfig.levelReward(level: number): (number, number)
	local cash = math.floor(250 * level ^ 1.5 / 10 + 0.5) * 10
	local spins = (level % 5 == 0) and 2 or 0
	return cash, spins
end

-- Daily rewards (7-day streak). Cash scales with player level.
EconomyConfig.Daily = {
	{ Kind = "Cash", Amount = 500 },
	{ Kind = "Cash", Amount = 1500 },
	{ Kind = "Egg", Egg = "HavenEgg" },
	{ Kind = "Cash", Amount = 6000 },
	{ Kind = "Egg", Egg = "GroveEgg" },
	{ Kind = "Cash", Amount = 20000 },
	{ Kind = "Egg", Egg = "GroveEgg", Count = 2 },
}
EconomyConfig.DailyCooldown = 20 * 3600
EconomyConfig.DailyStreakWindow = 48 * 3600

function EconomyConfig.dailyCashScale(level: number): number
	return 1 + (math.max(1, level) - 1) * 0.35
end

return table.freeze(EconomyConfig)

--[[
	MonetizationConfig
	Robux items. Create each one on create.roblox.com (your experience ->
	Monetization -> Passes / Developer Products) with the same price, then
	paste its ID here. Id = 0 means "not created yet": in Studio the BUY
	button then grants the item as a free TEST purchase so everything can be
	tried; in a live game it shows "coming soon".

	GamePasses: bought once, owned forever.
	Products:   consumables (potions, cash packs), bought any number of times.

	Egg hunting items (the "Hunt" section of the shop):
	  Egg Radar     boost   every egg of yours is marked on screen, through walls
	  Egg Magnet    boost   +100% egg pickup range
	  Fast Hatch    boost   eggs you put in the nest hatch twice as fast
	  Lucky Egg Call        3 very lucky eggs appear around you for a few minutes
	  Mythic Bundle         3 Celestial Eggs with x50 luck go straight into the bag
	  Egg Hunter    pass    permanent radar, +50% pickup range, +3 egg bag slots
]]

local MonetizationConfig = {}

MonetizationConfig.GamePasses = {
	MonicaDragon = {
		Id = 2006499253,
		Price = 11999,
		Name = "LEGENDARY M0NICA",
		Description = "The strongest dragon of all: 50T per second, every mutation at once and x20 LUCK forever.",
		Icon = "Sparkle",
		Grants = "M0nicaDragon",
		Mutation = "Omni",
		Luck = 20,
		Badges = { "LEGENDARY" },
		Perks = { "x20 LUCK on every roll, forever", "ALL MUTATIONS at once (Omni x25)", "$50T/s, $1.25Qa/s with Omni", "Crown, halo and blazing aura" },
		Featured = true,
		Order = 0,
	},
	OwnerDragon = {
		Id = 2005641208,
		Price = 3000,
		Name = "Owner Dragon",
		Description = "The strongest dragon in the game + x2 LUCK forever on every roll (eggs and the Spin Wheel).",
		Icon = "Dragon",
		Grants = "OwnerDragon", -- species added to the collection
		Luck = 2, -- permanent luck multiplier while owned
		Perks = { "x2 LUCK on every roll, forever", "Fastest & strongest dragon", "EXCLUSIVE rarity + golden aura", "$1B per second on a perch" },
		Featured = true,
		Order = 3,
	},
	PrinceDragon = {
		Id = 2005203251,
		Price = 8999,
		Name = "PRINCE",
		Description = "The strongest dragon in the game: every mutation at once and x3 LUCK forever.",
		Icon = "Trophy",
		Grants = "PrinceDragon",
		Mutation = "Omni",
		Luck = 3,
		Perks = { "x3 LUCK on every roll, forever", "ALL MUTATIONS at once (Omni x25)", "$10T/s, $250T/s with Omni", "Royal halo, crown and golden aura" },
		Featured = true,
		Order = 1,
	},
	N2RC1SDragon = {
		Id = 2005911224,
		Price = 8999,
		Name = "N2RC1S",
		Description = "The strongest dragon in the game: every mutation at once and x3 LUCK forever.",
		Icon = "Star",
		Grants = "N2RC1SDragon",
		Mutation = "Omni",
		Luck = 3,
		Perks = { "x3 LUCK on every roll, forever", "ALL MUTATIONS at once (Omni x25)", "$10T/s, $250T/s with Omni", "Crystal crown, stars and neon aura" },
		Featured = true,
		Order = 2,
	},
}

MonetizationConfig.GamePasses.EggHunter = {
	Id = 2006433199,
	Price = 1299,
	Name = "Egg Hunter",
	Description = "Find more eggs, faster: a permanent radar, a wider pickup range and a bigger bag.",
	Icon = "Radar",
	Kind = "Tool", -- no dragon: shown with an egg instead of a dragon
	Radar = true, -- the egg radar is always on
	Magnet = 0.5, -- +50% egg pickup range
	Slots = 3, -- +3 egg bag slots
	Egg = "CelestialEgg", -- the egg shown on the card
	Accent = Color3.fromRGB(255, 140, 60),
	UnlockText = "EGG HUNTER unlocked! Permanent egg radar, wider pickup range and +3 bag slots.",
	Perks = { "Egg radar on forever", "+50% egg pickup range", "+3 egg bag slots", "Stacks with potions" },
	Order = 4,
}

-- Featured passes in shop order.
function MonetizationConfig.passOrder(): { string }
	local list = {}
	for id in MonetizationConfig.GamePasses do
		table.insert(list, id)
	end
	table.sort(list, function(a, b)
		return (MonetizationConfig.GamePasses[a].Order or 99) < (MonetizationConfig.GamePasses[b].Order or 99)
	end)
	return list
end

-- Is a pass owned according to replicated/saved data?
function MonetizationConfig.ownsPass(data, itemId: string): boolean
	local flags = data and data.Flags
	if not flags then
		return false
	end
	if itemId == "OwnerDragon" and flags.OwnerPass == true then
		return true
	end
	return type(flags.Passes) == "table" and flags.Passes[itemId] == true
end

-- Product of the luck multipliers of every owned pass.
function MonetizationConfig.passLuck(data): number
	local m = 1
	for id, pass in MonetizationConfig.GamePasses do
		if pass.Luck and MonetizationConfig.ownsPass(data, id) then
			m *= pass.Luck
		end
	end
	return m
end

-- Extra egg bag slots from owned passes.
function MonetizationConfig.passSlots(data): number
	local n = 0
	for id, pass in MonetizationConfig.GamePasses do
		if pass.Slots and MonetizationConfig.ownsPass(data, id) then
			n += pass.Slots
		end
	end
	return n
end

MonetizationConfig.Products = {
	LuckPotion = {
		Id = 3716499841,
		Price = 49,
		Name = "Luck Potion",
		Description = "x2 luck on egg rolls for 15 minutes.",
		Icon = "Clover",
		Kind = "Boost",
		Boost = "Luck",
		Seconds = 15 * 60,
		Color = Color3.fromRGB(110, 208, 104),
	},
	SuperLuckPotion = {
		Id = 3716499964,
		Price = 149,
		Name = "Super Luck Potion",
		Description = "x3 luck on egg rolls for 30 minutes.",
		Icon = "Star",
		Kind = "Boost",
		Boost = "SuperLuck",
		Seconds = 30 * 60,
		Color = Color3.fromRGB(64, 236, 214),
	},
	CashPotion = {
		Id = 0,
		Price = 49,
		Name = "Cash Potion",
		Description = "x2 income from your sanctuary for 15 minutes.",
		Icon = "Coin",
		Kind = "Boost",
		Boost = "Cash",
		Seconds = 15 * 60,
		Color = Color3.fromRGB(255, 196, 48),
	},
	LevelPotion = {
		Id = 3716500145,
		Price = 39,
		Name = "Level Potion",
		Description = "+5 levels for the dragon you have equipped.",
		Icon = "Ascend",
		Kind = "DragonLevel",
		Levels = 5,
		Color = Color3.fromRGB(77, 163, 255),
	},
	MutationPotion = {
		Id = 3716500220,
		Price = 389,
		Name = "Mutation Potion",
		Description = "Upgrades the mutation of your equipped dragon (always better).",
		Icon = "Sparkle",
		Kind = "DragonMutation",
		Color = Color3.fromRGB(190, 120, 255),
	},
	SpinPack = {
		Id = 3716498464,
		Price = 49,
		Name = "5 Spins",
		Description = "+5 spins for the wheel on Spin Island.",
		Icon = "Star",
		Kind = "Spins",
		Count = 5,
		Color = Color3.fromRGB(255, 110, 190),
	},
	SpinPackBig = {
		Id = 3716498584,
		Price = 199,
		Name = "25 Spins",
		Description = "+25 spins for the wheel on Spin Island.",
		Icon = "Gift",
		Kind = "Spins",
		Count = 25,
		Color = Color3.fromRGB(255, 70, 150),
	},
	CashPackSmall = {
		Id = 3716498676,
		Price = 25,
		Name = "Pouch of Cash",
		Description = "30 minutes of your income (at least $5K).",
		Icon = "Coin",
		Kind = "Cash",
		IncomeSeconds = 30 * 60,
		Minimum = 5000,
		Color = Color3.fromRGB(255, 196, 48),
	},
	CashPackMedium = {
		Id = 3716498963,
		Price = 299,
		Name = "Chest of Cash",
		Description = "3 hours of your income (at least $50K).",
		Icon = "Chest",
		Kind = "Cash",
		IncomeSeconds = 3 * 3600,
		Minimum = 50000,
		Color = Color3.fromRGB(255, 160, 40),
	},
	CashPackLarge = {
		Id = 3716499082,
		Price = 249,
		Name = "Vault of Cash",
		Description = "12 hours of your income (at least $250K).",
		Icon = "Trophy",
		Kind = "Cash",
		IncomeSeconds = 12 * 3600,
		Minimum = 250000,
		Color = Color3.fromRGB(255, 120, 40),
	},

	-- egg hunting
	EggRadar = {
		Id = 3716499249,
		Price = 49,
		Name = "Egg Radar",
		Description = "Marks every egg on the map, even through walls, for 30 minutes.",
		Icon = "Radar",
		Kind = "Boost",
		Boost = "Radar",
		Seconds = 30 * 60,
		Color = Color3.fromRGB(255, 140, 60),
	},
	EggMagnet = {
		Id = 3716499468,
		Price = 49,
		Name = "Egg Magnet",
		Description = "Pick eggs up from twice as far away for 15 minutes.",
		Icon = "Magnet",
		Kind = "Boost",
		Boost = "Magnet",
		Seconds = 15 * 60,
		Color = Color3.fromRGB(255, 90, 120),
	},
	HatchBoost = {
		Id = 3716499582,
		Price = 59,
		Name = "Fast Hatch",
		Description = "Eggs you put in your nest hatch twice as fast for 30 minutes.",
		Icon = "Clock",
		Kind = "Boost",
		Boost = "Hatch",
		Seconds = 30 * 60,
		Color = Color3.fromRGB(255, 205, 60),
	},
	LuckyEggCall = {
		Id = 3716499681,
		Price = 99,
		Name = "Lucky Egg Call",
		Description = "3 rare eggs with x25 to x100 luck appear around you for 5 minutes.",
		Icon = "Sparkle",
		Kind = "LuckyEggs",
		Count = 3,
		Luck = { 25, 100 },
		Lifetime = 5 * 60,
		Color = Color3.fromRGB(190, 120, 255),
	},
	MythicBundle = {
		Id = 3716499744,
		Price = 249,
		Name = "Mythic Bundle",
		Description = "3 Celestial Eggs with x50 luck, straight into your egg bag.",
		Icon = "Gift",
		Kind = "Eggs",
		Egg = "CelestialEgg",
		Count = 3,
		Luck = 50,
		Color = Color3.fromRGB(255, 80, 160),
	},
}

-- Shop sections (ROBUX tab): products list their Section, ProductOrder their order.
MonetizationConfig.Sections = {
	{ Id = "Potions", Title = "POTIONS" },
	{ Id = "Hunt", Title = "EGG HUNTING" },
	{ Id = "Packs", Title = "CASH & SPINS" },
}
local SECTION_OF = {
	LuckPotion = "Potions",
	SuperLuckPotion = "Potions",
	CashPotion = "Potions",
	LevelPotion = "Potions",
	MutationPotion = "Potions",
	EggRadar = "Hunt",
	EggMagnet = "Hunt",
	HatchBoost = "Hunt",
	LuckyEggCall = "Hunt",
	MythicBundle = "Hunt",
	SpinPack = "Packs",
	SpinPackBig = "Packs",
	CashPackSmall = "Packs",
	CashPackMedium = "Packs",
	CashPackLarge = "Packs",
}
for id, product in MonetizationConfig.Products do
	product.Section = SECTION_OF[id] or "Packs"
end

-- Shop order (ROBUX tab)
MonetizationConfig.ProductOrder = {
	"LuckPotion",
	"SuperLuckPotion",
	"CashPotion",
	"LevelPotion",
	"MutationPotion",
	"EggRadar",
	"EggMagnet",
	"HatchBoost",
	"LuckyEggCall",
	"MythicBundle",
	"SpinPack",
	"SpinPackBig",
	"CashPackSmall",
	"CashPackMedium",
	"CashPackLarge",
}

-- Product ids of one section, in shop order.
function MonetizationConfig.sectionProducts(sectionId: string): { string }
	local list = {}
	for _, id in MonetizationConfig.ProductOrder do
		if MonetizationConfig.Products[id].Section == sectionId then
			table.insert(list, id)
		end
	end
	return list
end

-- Boosts (timed): luck multipliers stack by multiplying.
MonetizationConfig.Boosts = {
	Luck = { Name = "x2 LUCK", Luck = 2, Color = Color3.fromRGB(110, 208, 104), Icon = "Clover" },
	SuperLuck = { Name = "x3 LUCK", Luck = 3, Color = Color3.fromRGB(64, 236, 214), Icon = "Star" },
	Cash = { Name = "x2 CASH", Cash = 2, Color = Color3.fromRGB(255, 196, 48), Icon = "Coin" },
	-- egg hunting: Radar = radar on, Magnet = extra pickup range (+100%), HatchFactor = incubation time factor
	Radar = { Name = "EGG RADAR", Radar = true, Color = Color3.fromRGB(255, 140, 60), Icon = "Radar" },
	Magnet = { Name = "EGG MAGNET", Magnet = 1.0, Color = Color3.fromRGB(255, 90, 120), Icon = "Magnet" },
	Hatch = { Name = "FAST HATCH", HatchFactor = 0.5, Color = Color3.fromRGB(255, 205, 60), Icon = "Clock" },
}

function MonetizationConfig.find(itemId: string)
	local pass = MonetizationConfig.GamePasses[itemId]
	if pass then
		return pass, "Pass"
	end
	local product = MonetizationConfig.Products[itemId]
	if product then
		return product, "Product"
	end
	return nil, nil
end

-- itemId for a developer product id / game pass id (receipts, prompts)
function MonetizationConfig.byProductId(id: number): string?
	if id == 0 then
		return nil
	end
	for itemId, p in MonetizationConfig.Products do
		if p.Id == id then
			return itemId
		end
	end
	return nil
end

function MonetizationConfig.byPassId(id: number): string?
	if id == 0 then
		return nil
	end
	for itemId, p in MonetizationConfig.GamePasses do
		if p.Id == id then
			return itemId
		end
	end
	return nil
end

return MonetizationConfig

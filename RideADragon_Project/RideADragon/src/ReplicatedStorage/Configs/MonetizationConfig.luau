--[[
	MonetizationConfig
	Robux items. Create each one on create.roblox.com (your experience ->
	Monetization -> Passes / Developer Products) with the same price, then
	paste its ID here. Id = 0 means "not created yet": in Studio the BUY
	button then grants the item as a free TEST purchase so everything can be
	tried; in a live game it shows "coming soon".

	GamePasses: bought once, owned forever.
	Products:   consumables (potions, cash packs), bought any number of times.
]]

local MonetizationConfig = {}

MonetizationConfig.GamePasses = {
	OwnerDragon = {
		Id = 0,
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
		Id = 0,
		Price = 8999,
		Name = "PRINCE",
		Description = "The strongest dragon in the game: every mutation at once and x3 LUCK forever.",
		Icon = "Trophy",
		Grants = "PrinceDragon",
		Mutation = "Omni",
		Luck = 3,
		Perks = { "x3 LUCK on every roll, forever", "ALL MUTATIONS at once (Omni x25)", "$10T per second on a perch", "Royal halo, crown and golden aura" },
		Featured = true,
		Order = 1,
	},
	N2RC1SDragon = {
		Id = 0,
		Price = 8999,
		Name = "N2RC1S",
		Description = "The strongest dragon in the game: every mutation at once and x3 LUCK forever.",
		Icon = "Star",
		Grants = "N2RC1SDragon",
		Mutation = "Omni",
		Luck = 3,
		Perks = { "x3 LUCK on every roll, forever", "ALL MUTATIONS at once (Omni x25)", "$10T per second on a perch", "Crystal crown, stars and neon aura" },
		Featured = true,
		Order = 2,
	},
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

MonetizationConfig.Products = {
	LuckPotion = {
		Id = 0,
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
		Id = 0,
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
		Id = 0,
		Price = 39,
		Name = "Level Potion",
		Description = "+5 levels for the dragon you have equipped.",
		Icon = "Ascend",
		Kind = "DragonLevel",
		Levels = 5,
		Color = Color3.fromRGB(77, 163, 255),
	},
	MutationPotion = {
		Id = 0,
		Price = 99,
		Name = "Mutation Potion",
		Description = "Upgrades the mutation of your equipped dragon (always better).",
		Icon = "Sparkle",
		Kind = "DragonMutation",
		Color = Color3.fromRGB(190, 120, 255),
	},
	SpinPack = {
		Id = 0,
		Price = 49,
		Name = "5 Spins",
		Description = "+5 spins for the wheel on Spin Island.",
		Icon = "Star",
		Kind = "Spins",
		Count = 5,
		Color = Color3.fromRGB(255, 110, 190),
	},
	SpinPackBig = {
		Id = 0,
		Price = 199,
		Name = "25 Spins",
		Description = "+25 spins for the wheel on Spin Island.",
		Icon = "Gift",
		Kind = "Spins",
		Count = 25,
		Color = Color3.fromRGB(255, 70, 150),
	},
	CashPackSmall = {
		Id = 0,
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
		Id = 0,
		Price = 99,
		Name = "Chest of Cash",
		Description = "3 hours of your income (at least $50K).",
		Icon = "Chest",
		Kind = "Cash",
		IncomeSeconds = 3 * 3600,
		Minimum = 50000,
		Color = Color3.fromRGB(255, 160, 40),
	},
	CashPackLarge = {
		Id = 0,
		Price = 249,
		Name = "Vault of Cash",
		Description = "12 hours of your income (at least $250K).",
		Icon = "Trophy",
		Kind = "Cash",
		IncomeSeconds = 12 * 3600,
		Minimum = 250000,
		Color = Color3.fromRGB(255, 120, 40),
	},
}

-- Shop order (ROBUX tab)
MonetizationConfig.ProductOrder = {
	"LuckPotion",
	"SuperLuckPotion",
	"CashPotion",
	"LevelPotion",
	"MutationPotion",
	"SpinPack",
	"SpinPackBig",
	"CashPackSmall",
	"CashPackMedium",
	"CashPackLarge",
}

-- Boosts (timed): luck multipliers stack by multiplying.
MonetizationConfig.Boosts = {
	Luck = { Name = "x2 LUCK", Luck = 2, Color = Color3.fromRGB(110, 208, 104), Icon = "Clover" },
	SuperLuck = { Name = "x3 LUCK", Luck = 3, Color = Color3.fromRGB(64, 236, 214), Icon = "Star" },
	Cash = { Name = "x2 CASH", Cash = 2, Color = Color3.fromRGB(255, 196, 48), Icon = "Coin" },
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

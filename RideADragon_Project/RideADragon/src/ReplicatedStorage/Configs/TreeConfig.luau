--[[
	TreeConfig
	The Great Tree in the plaza: permanent upgrades bought with cash.
	20 branches in 5 categories, 8-12 levels each (about 190 levels). A level
	needs the one below it. Level.Bonus is the TOTAL bonus at that level (not
	added per level); Level.Price is the price of that level.

	Levels are generated from a few numbers per branch (how many, the bonus at
	the last level, the price of the first and last level; prices grow
	geometrically), so balancing is a matter of editing one line.

	Where each bonus is applied (server unless noted):
	  RollLuck       x(1+b) luck on every egg roll                BoostService.LuckMultiplier
	  MutationLuck   x(1+b) mutation chance when hatching         EggService.Hatch
	  FindLuck       x(1+b) luck of eggs found in the world       EggService (spawn)
	  SpinLuck       x(1+b) luck on the Spin Wheel rare prizes    SpinService
	  SpinSpeed      free spin comes back b faster                SpinService
	  Income         x(1+b) perch income                          BoostService.Multiplier("Coins")
	  Offline        x(1+b) offline earning rate and cap          EconomyService
	  Wisdom         x(1+b) player XP                             LevelService
	  Recycler       x(1+b) cash refunded when releasing          DragonService.Release
	  FlySpeed       x(1+b) cruise speed                          MountService / DragonController
	  BoostLong      x(1+b) boost duration                        Locomotion (client stats)
	  BoostRegen     x(1+b) boost refill speed                    Locomotion (client stats)
	  RunSpeed       x(1+b) ground run speed                      MountService / DragonController
	  HatchSpeed     eggs incubate b faster                       EggService.Place
	  EggBag         +b egg bag slots                             EggService (+ UI)  (Egg Hunter pass: +3 more)
	  EggMagnet      x(1+b) egg pickup range                      EggReach.bonus (+ boost + pass)
	  EggRespawn     new eggs appear b faster                     EggService
	  BondGrowth     x(1+b) bond points                           BondService
	  QuickFeathers  bond ability cooldowns -b                    BondService / BondController
	  Dragonfire     x(1+b) fire breath range                     BondService
]]

local EconomyConfig = require(script.Parent:WaitForChild("EconomyConfig"))
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))

local TreeConfig = {}

local C3 = Color3.fromRGB

TreeConfig.Categories = {
	{ Id = "Luck", Name = "Luck", Icon = "Clover", Color = C3(110, 208, 104) },
	{ Id = "Wealth", Name = "Wealth", Icon = "Coin", Color = C3(255, 196, 48) },
	{ Id = "Flight", Name = "Flight", Icon = "Wind", Color = C3(77, 163, 255) },
	{ Id = "Nest", Name = "Nest", Icon = "Egg", Color = C3(255, 140, 60) },
	{ Id = "Bond", Name = "Bond", Icon = "Flame", Color = C3(255, 96, 96) },
}

-- 2 significant digits: 25200 -> 25000
local function nice(x: number): number
	if x < 100 then
		return math.floor(x + 0.5)
	end
	local e = math.floor(math.log10(x))
	local m = 10 ^ (e - 1)
	return math.floor(x / m + 0.5) * m
end

-- Def: Levels (count), Max (bonus at the last level), Curve (1 = linear),
-- Price = { first, last }, Integer (whole-number bonuses)
local function generate(def)
	local n = def.Levels
	local levels = {}
	for k = 1, n do
		local t = (k - 1) / math.max(1, n - 1)
		local price = nice(def.Price[1] * (def.Price[2] / def.Price[1]) ^ t)
		local raw = def.Max * (k / n) ^ (def.Curve or 1)
		local bonus = def.Integer and math.ceil(raw - 1e-9) or math.floor(raw * 1000 + 0.5) / 1000
		levels[k] = { Bonus = bonus, Price = price }
	end
	return levels
end

-- Id, Name, Icon, Color, Description, Format ("Luck" xN | "Percent" +N% | "Faster" N% faster |
-- "Slots" +N | "Range" +N% range | "Less" -N%)
local DEFS = {
	-- LUCK
	{ Cat = "Luck", Id = "RollLuck", Name = "Roll Luck", Icon = "Clover", Color = C3(110, 208, 104), Description = "More luck on every egg roll.", Format = "Luck", Levels = 12, Max = 2.0, Price = { 6e3, 6e10 } },
	{ Cat = "Luck", Id = "MutationLuck", Name = "Mutation Luck", Icon = "Sparkle", Color = C3(190, 120, 255), Description = "Mutations appear more often when hatching.", Format = "Luck", Levels = 12, Max = 3.0, Price = { 1.2e4, 1.2e11 } },
	{ Cat = "Luck", Id = "FindLuck", Name = "Lucky Finds", Icon = "Star", Color = C3(255, 220, 90), Description = "Eggs you find in the world carry more luck.", Format = "Luck", Levels = 10, Max = 1.5, Price = { 1e4, 2e10 } },
	{ Cat = "Luck", Id = "SpinLuck", Name = "Lucky Wheel", Icon = "Gift", Color = C3(255, 120, 170), Description = "Better odds for the rare Spin Wheel prizes.", Format = "Luck", Levels = 8, Max = 1.0, Price = { 1.5e4, 5e9 } },
	{ Cat = "Luck", Id = "SpinSpeed", Name = "Quick Spin", Icon = "Speed", Color = C3(120, 220, 220), Description = "Your free spin comes back sooner.", Format = "Faster", Levels = 8, Max = 0.6, Price = { 2e4, 8e9 } },
	-- WEALTH
	{ Cat = "Wealth", Id = "Income", Name = "Golden Roots", Icon = "Coin", Color = C3(255, 196, 48), Description = "More income from every perch.", Format = "Percent", Levels = 12, Max = 2.0, Price = { 8e3, 8e10 } },
	{ Cat = "Wealth", Id = "Offline", Name = "Dream Dens", Icon = "Home", Color = C3(170, 140, 255), Description = "Your dragons earn more while you are away.", Format = "Percent", Levels = 10, Max = 1.0, Price = { 2.5e4, 3e10 } },
	{ Cat = "Wealth", Id = "Wisdom", Name = "Ancient Wisdom", Icon = "Book", Color = C3(120, 190, 255), Description = "You earn player XP faster.", Format = "Percent", Levels = 10, Max = 1.0, Price = { 1.5e4, 1.5e10 } },
	{ Cat = "Wealth", Id = "Recycler", Name = "Gentle Goodbye", Icon = "Release", Color = C3(150, 230, 170), Description = "Releasing a dragon refunds more cash.", Format = "Percent", Levels = 8, Max = 4.0, Price = { 5e3, 2e9 } },
	-- FLIGHT
	{ Cat = "Flight", Id = "FlySpeed", Name = "Wind Wings", Icon = "Wind", Color = C3(77, 163, 255), Description = "Your dragons fly faster.", Format = "Percent", Levels = 12, Max = 0.5, Price = { 6e3, 4e10 } },
	{ Cat = "Flight", Id = "BoostLong", Name = "Deep Breath", Icon = "Speed", Color = C3(255, 150, 70), Description = "Your boost lasts longer.", Format = "Percent", Levels = 10, Max = 1.5, Price = { 1e4, 1.2e10 } },
	{ Cat = "Flight", Id = "BoostRegen", Name = "Second Wind", Icon = "Ascend", Color = C3(100, 230, 200), Description = "The boost meter refills faster.", Format = "Percent", Levels = 10, Max = 1.5, Price = { 1e4, 1.2e10 } },
	{ Cat = "Flight", Id = "RunSpeed", Name = "Swift Paws", Icon = "Dragon", Color = C3(230, 200, 120), Description = "Your dragons run faster on the ground.", Format = "Percent", Levels = 8, Max = 0.4, Price = { 5e3, 3e9 } },
	-- NEST
	{ Cat = "Nest", Id = "HatchSpeed", Name = "Warm Nest", Icon = "Egg", Color = C3(255, 140, 60), Description = "Eggs hatch faster in your nest.", Format = "Faster", Levels = 12, Max = 0.6, Price = { 5e3, 3e10 } },
	{ Cat = "Nest", Id = "EggBag", Name = "Deep Pockets", Icon = "Bag", Color = C3(200, 160, 110), Description = "Carry more eggs in your bag.", Format = "Slots", Levels = 10, Max = 10, Integer = true, Price = { 8e3, 1e10 } },
	{ Cat = "Nest", Id = "EggMagnet", Name = "Egg Magnet", Icon = "Radar", Color = C3(255, 90, 120), Description = "Pick up eggs from farther away.", Format = "Range", Levels = 8, Max = 1.0, Price = { 6e3, 2e9 } },
	{ Cat = "Nest", Id = "EggRespawn", Name = "Fertile Soil", Icon = "Plus", Color = C3(140, 220, 110), Description = "New eggs appear sooner.", Format = "Faster", Levels = 8, Max = 0.6, Price = { 8e3, 3e9 } },
	-- BOND
	{ Cat = "Bond", Id = "BondGrowth", Name = "Soul Bond", Icon = "Dragon", Color = C3(255, 96, 96), Description = "Dragon Bond grows faster while you ride.", Format = "Percent", Levels = 10, Max = 2.0, Price = { 1e4, 1.5e10 } },
	{ Cat = "Bond", Id = "QuickFeathers", Name = "Quick Feathers", Icon = "Wing", Color = C3(130, 200, 255), Description = "Dash, fire and dance recharge sooner.", Format = "Less", Levels = 8, Max = 0.5, Price = { 1.2e4, 8e9 } },
	{ Cat = "Bond", Id = "Dragonfire", Name = "Dragonfire", Icon = "Flame", Color = C3(255, 120, 40), Description = "Your fire breath reaches farther.", Format = "Range", Levels = 8, Max = 0.8, Price = { 1.5e4, 6e9 } },
}

TreeConfig.Branches = {}
TreeConfig.ById = {}
TreeConfig.CategoryById = {}
for _, cat in TreeConfig.Categories do
	cat.Branches = {}
	TreeConfig.CategoryById[cat.Id] = cat
end
for _, def in DEFS do
	local branch = {
		Id = def.Id,
		Name = def.Name,
		Icon = def.Icon,
		Color = def.Color,
		Description = def.Description,
		Format = def.Format,
		Category = def.Cat,
		Levels = generate(def),
	}
	table.insert(TreeConfig.Branches, branch)
	TreeConfig.ById[branch.Id] = branch
	table.insert(TreeConfig.CategoryById[def.Cat].Branches, branch)
end

function TreeConfig.level(data, id: string): number
	local t = data and data.Tree
	return t and math.max(0, math.floor(tonumber(t[id]) or 0)) or 0
end

-- Total bonus (0 when not bought).
function TreeConfig.bonus(data, id: string): number
	local branch = TreeConfig.ById[id]
	local lvl = TreeConfig.level(data, id)
	if not branch or lvl <= 0 then
		return 0
	end
	return branch.Levels[math.min(lvl, #branch.Levels)].Bonus
end

-- Egg bag capacity: Egg Storage upgrade + Deep Pockets + pass slots (Egg Hunter) - the one
-- formula everybody uses.
function TreeConfig.eggCapacity(data): number
	local level = data and data.Upgrades and tonumber(data.Upgrades.EggStorage) or 0
	return EconomyConfig.upgradeValue("EggStorage", level)
		+ math.floor(TreeConfig.bonus(data, "EggBag") + 0.5)
		+ MonetizationConfig.passSlots(data)
end

-- Seconds of the dragon's income refunded when it is released (Gentle Goodbye).
function TreeConfig.refundSeconds(data): number
	return EconomyConfig.ReleaseRefundSeconds * (1 + TreeConfig.bonus(data, "Recycler"))
end

-- Levels bought / levels available inside a category (0..1).
function TreeConfig.categoryProgress(data, categoryId: string): number
	local cat = TreeConfig.CategoryById[categoryId]
	if not cat then
		return 0
	end
	local have, total = 0, 0
	for _, branch in cat.Branches do
		have += math.min(TreeConfig.level(data, branch.Id), #branch.Levels)
		total += #branch.Levels
	end
	return total > 0 and have / total or 0
end

-- Levels bought in total, and available in total.
function TreeConfig.totals(data): (number, number)
	local have, total = 0, 0
	for _, branch in TreeConfig.Branches do
		have += math.min(TreeConfig.level(data, branch.Id), #branch.Levels)
		total += #branch.Levels
	end
	return have, total
end

local function pct(x: number): number
	return math.floor(x * 100 + 0.5)
end

function TreeConfig.formatBonus(branch, bonus: number): string
	local f = branch.Format
	if f == "Luck" then
		return "x" .. tostring(math.floor((1 + bonus) * 100 + 0.5) / 100)
	elseif f == "Faster" then
		return pct(bonus) .. "% faster"
	elseif f == "Slots" then
		return "+" .. tostring(math.floor(bonus + 0.5)) .. " slots"
	elseif f == "Range" then
		return "+" .. pct(bonus) .. "% range"
	elseif f == "Less" then
		return "-" .. pct(bonus) .. "% wait"
	end
	return "+" .. pct(bonus) .. "%"
end

-- Great Tree position (plaza, north-east of the statue).
TreeConfig.WorldAngle = 62 -- degrees from north, clockwise
TreeConfig.WorldRing = 46

return table.freeze(TreeConfig)

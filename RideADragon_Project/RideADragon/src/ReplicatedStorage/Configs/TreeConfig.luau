--[[
	TreeConfig
	The Great Tree in the plaza: permanent upgrades bought with cash.
	Five branches, five levels each (a level needs the one below it).
	Level.Bonus is the TOTAL bonus at that level (not added per level).

	RollLuck      x(1 + bonus) luck on every egg roll and Spin Wheel spin
	MutationLuck  x(1 + bonus) mutation chance when hatching
	Income        x(1 + bonus) sanctuary income
	FlySpeed      x(1 + bonus) flight cruise speed
	HatchSpeed    eggs incubate (bonus * 100)% faster
]]

local TreeConfig = {}

TreeConfig.Branches = {
	{
		Id = "RollLuck",
		Name = "Roll Luck",
		Icon = "Clover",
		Color = Color3.fromRGB(110, 208, 104),
		Description = "More luck on every egg roll and spin.",
		Format = "Luck",
		Levels = {
			{ Bonus = 0.1, Price = 1000 },
			{ Bonus = 0.25, Price = 15000 },
			{ Bonus = 0.5, Price = 200000 },
			{ Bonus = 0.75, Price = 3000000 },
			{ Bonus = 1.0, Price = 50000000 },
		},
	},
	{
		Id = "MutationLuck",
		Name = "Mutation Luck",
		Icon = "Sparkle",
		Color = Color3.fromRGB(190, 120, 255),
		Description = "Mutations appear more often when hatching.",
		Format = "Luck",
		Levels = {
			{ Bonus = 0.15, Price = 2500 },
			{ Bonus = 0.35, Price = 40000 },
			{ Bonus = 0.6, Price = 600000 },
			{ Bonus = 1.0, Price = 9000000 },
			{ Bonus = 1.5, Price = 150000000 },
		},
	},
	{
		Id = "Income",
		Name = "Golden Roots",
		Icon = "Coin",
		Color = Color3.fromRGB(255, 196, 48),
		Description = "More income from every perch.",
		Format = "Percent",
		Levels = {
			{ Bonus = 0.1, Price = 2000 },
			{ Bonus = 0.2, Price = 30000 },
			{ Bonus = 0.35, Price = 400000 },
			{ Bonus = 0.5, Price = 6000000 },
			{ Bonus = 0.75, Price = 100000000 },
		},
	},
	{
		Id = "FlySpeed",
		Name = "Wind Wings",
		Icon = "Wind",
		Color = Color3.fromRGB(77, 163, 255),
		Description = "Your dragons fly faster.",
		Format = "Percent",
		Levels = {
			{ Bonus = 0.05, Price = 1500 },
			{ Bonus = 0.1, Price = 25000 },
			{ Bonus = 0.15, Price = 350000 },
			{ Bonus = 0.2, Price = 5000000 },
			{ Bonus = 0.3, Price = 80000000 },
		},
	},
	{
		Id = "HatchSpeed",
		Name = "Warm Nest",
		Icon = "Egg",
		Color = Color3.fromRGB(255, 140, 60),
		Description = "Eggs hatch faster in your nest.",
		Format = "Faster",
		Levels = {
			{ Bonus = 0.1, Price = 1200 },
			{ Bonus = 0.2, Price = 20000 },
			{ Bonus = 0.3, Price = 300000 },
			{ Bonus = 0.4, Price = 4000000 },
			{ Bonus = 0.5, Price = 60000000 },
		},
	},
}

TreeConfig.ById = {}
for _, b in TreeConfig.Branches do
	TreeConfig.ById[b.Id] = b
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

function TreeConfig.formatBonus(branch, bonus: number): string
	if branch.Format == "Luck" then
		return "x" .. tostring(math.floor((1 + bonus) * 100 + 0.5) / 100)
	elseif branch.Format == "Faster" then
		return math.floor(bonus * 100 + 0.5) .. "% faster"
	end
	return "+" .. math.floor(bonus * 100 + 0.5) .. "%"
end

-- Great Tree position (plaza, north-east of the statue).
TreeConfig.WorldAngle = 62 -- degrees from north, clockwise
TreeConfig.WorldRing = 46

return table.freeze(TreeConfig)

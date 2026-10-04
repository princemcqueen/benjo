--[[
	MutationConfig
	Mutations multiply Speed/FlightSpeed/Income and change the dragon's look.
]]

local MutationConfig = {}

MutationConfig.Order = { "None", "Shiny", "Golden", "Frost", "Toxic", "Lava", "Shadow", "Diamond", "Galaxy", "Rainbow", "Void", "Omni" }

-- Rank: higher = rarer/better. HatchChance: per hatch (rarest rolled first),
-- shown to players as "1 in N" titles (Shiny 1 in 20 ... Void 1 in 2,500,000).
-- Fx: visual effect family used by BrickBuilder (sparkle, glow, fire, smoke...).
MutationConfig.Mutations = {
	None = { Rank = 0, Name = "Normal", Multiplier = 1, Color = Color3.fromRGB(150, 146, 136), HatchChance = 0 },
	Shiny = { Rank = 1, Name = "Shiny", Multiplier = 1.5, Color = Color3.fromRGB(150, 230, 255), HatchChance = 0.05, Fx = "Sparkle" },
	Golden = { Rank = 2, Name = "Golden", Multiplier = 2, Color = Color3.fromRGB(255, 205, 80), HatchChance = 1 / 75, Fx = "Gold" },
	Frost = { Rank = 3, Name = "Frost", Multiplier = 2.5, Color = Color3.fromRGB(150, 220, 255), HatchChance = 1 / 200, Fx = "Snow" },
	Toxic = { Rank = 4, Name = "Toxic", Multiplier = 3, Color = Color3.fromRGB(150, 255, 80), HatchChance = 1 / 500, Fx = "Toxic" },
	Lava = { Rank = 5, Name = "Lava", Multiplier = 4, Color = Color3.fromRGB(255, 120, 30), HatchChance = 1 / 1500, Fx = "Fire" },
	Shadow = { Rank = 6, Name = "Shadow", Multiplier = 5, Color = Color3.fromRGB(170, 90, 255), HatchChance = 1 / 5000, Fx = "Smoke" },
	Diamond = { Rank = 7, Name = "Diamond", Multiplier = 6.5, Color = Color3.fromRGB(200, 245, 255), HatchChance = 1 / 20000, Fx = "Diamond" },
	Galaxy = { Rank = 8, Name = "Galaxy", Multiplier = 8, Color = Color3.fromRGB(120, 140, 255), HatchChance = 1 / 100000, Fx = "Stars" },
	Rainbow = { Rank = 9, Name = "Rainbow", Multiplier = 10, Color = Color3.fromRGB(255, 120, 200), HatchChance = 1 / 500000, Fx = "Rainbow" },
	Void = { Rank = 10, Name = "Void", Multiplier = 15, Color = Color3.fromRGB(190, 120, 255), HatchChance = 1 / 2500000, Fx = "Void" },
	-- every mutation at once: only on the Robux exclusives (N2RC1S, PRINCE)
	Omni = { Rank = 11, Name = "Omni", Multiplier = 25, Color = Color3.fromRGB(255, 130, 230), HatchChance = 0, Fx = "Omni" },
}

-- Weights used by the MUTATE action (a roll that can only improve the dragon).
MutationConfig.MutateWeights = {
	{ Id = "Shiny", Weight = 40 },
	{ Id = "Golden", Weight = 24 },
	{ Id = "Frost", Weight = 14 },
	{ Id = "Toxic", Weight = 9 },
	{ Id = "Lava", Weight = 6 },
	{ Id = "Shadow", Weight = 3.5 },
	{ Id = "Diamond", Weight = 2 },
	{ Id = "Galaxy", Weight = 1 },
	{ Id = "Rainbow", Weight = 0.4 },
	{ Id = "Void", Weight = 0.1 },
}

-- Cost of one mutation attempt: minutes of the dragon's own base income, scaled.
MutationConfig.CostIncomeMinutes = 12
MutationConfig.CostRankFactor = 0.6 -- each mutation rank already owned makes the next try pricier
MutationConfig.MinCost = 750
MutationConfig.MaxRank = 10

function MutationConfig.rank(id: string?): number
	local m = MutationConfig.Mutations[id or "None"]
	return m and m.Rank or 0
end

function MutationConfig.multiplier(id: string?): number
	local m = MutationConfig.Mutations[id or "None"]
	return m and m.Multiplier or 1
end

-- Price of one MUTATE attempt for a species base income and current mutation.
function MutationConfig.cost(baseIncome: number, current: string?): number
	local rank = MutationConfig.rank(current)
	local c = baseIncome * 60 * MutationConfig.CostIncomeMinutes * (1 + rank * MutationConfig.CostRankFactor)
	return math.max(MutationConfig.MinCost, math.floor(c + 0.5))
end

-- Chance that one attempt improves a dragon that currently has `current`.
function MutationConfig.improveChance(current: string?): number
	local rank = MutationConfig.rank(current)
	local total, better = 0, 0
	for _, e in MutationConfig.MutateWeights do
		total += e.Weight
		if MutationConfig.rank(e.Id) > rank then
			better += e.Weight
		end
	end
	return total > 0 and better / total or 0
end

return table.freeze(MutationConfig)

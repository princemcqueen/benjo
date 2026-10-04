--[[
	MutationConfig
	Mutations multiply Speed/FlightSpeed/Income and really change how the dragon looks
	(palette, materials, particles, light, trails, halo - see BrickBuilder.MutationFx).

	Order is from common to rare; the rank of a mutation is its position in Order, so
	"better" always means "later". Rolling at hatch time goes through the list from the
	rarest down (EggService.rollMutation), the MUTATE action only ever improves.
]]

local MutationConfig = {}

MutationConfig.Order = {
	"None", "Shiny", "Neon", "Golden", "Frost", "Toxic", "Lava", "Infernal", "Shadow", "Corrupted",
	"Diamond", "Crystal", "Lightning", "Angelic", "Galaxy", "Rainbow", "Void", "Omni",
}

-- HatchChance: per hatch (rarest rolled first), shown to players as "1 in N" titles
-- (Shiny 1 in 20 ... Void 1 in 2,500,000). Multiplier: speed / flight speed / income.
-- Fx: visual effect family used by BrickBuilder (sparkle, glow, fire, smoke...).
-- Blurb: one line for the Index / inventory.
MutationConfig.Mutations = {
	None = { Rank = 0, Name = "Normal", Multiplier = 1, Color = Color3.fromRGB(150, 146, 136), HatchChance = 0, Blurb = "A dragon just as nature made it." },
	Shiny = { Rank = 1, Name = "Shiny", Multiplier = 1.5, Color = Color3.fromRGB(150, 230, 255), HatchChance = 0.05, Fx = "Sparkle", Blurb = "Sparkles all over." },
	Neon = { Rank = 2, Name = "Neon", Multiplier = 1.75, Color = Color3.fromRGB(80, 255, 230), HatchChance = 1 / 45, Fx = "Neon", Blurb = "Glows in electric colours and leaves a light trail." },
	Golden = { Rank = 3, Name = "Golden", Multiplier = 2, Color = Color3.fromRGB(255, 205, 80), HatchChance = 1 / 75, Fx = "Gold", Blurb = "Scales of shining gold." },
	Frost = { Rank = 4, Name = "Frost", Multiplier = 2.5, Color = Color3.fromRGB(150, 220, 255), HatchChance = 1 / 200, Fx = "Snow", Blurb = "Ice-blue skin and a swirl of snowflakes." },
	Toxic = { Rank = 5, Name = "Toxic", Multiplier = 3, Color = Color3.fromRGB(150, 255, 80), HatchChance = 1 / 500, Fx = "Toxic", Blurb = "Glowing green venom bubbles around it." },
	Lava = { Rank = 6, Name = "Lava", Multiplier = 4, Color = Color3.fromRGB(255, 120, 30), HatchChance = 1 / 1500, Fx = "Fire", Blurb = "Dark stone skin with molten cracks." },
	Infernal = { Rank = 7, Name = "Infernal", Multiplier = 4.5, Color = Color3.fromRGB(255, 70, 40), HatchChance = 1 / 3000, Fx = "Infernal", Blurb = "Burning red, shedding embers and hellfire." },
	Shadow = { Rank = 8, Name = "Shadow", Multiplier = 5, Color = Color3.fromRGB(170, 90, 255), HatchChance = 1 / 5000, Fx = "Smoke", Blurb = "Wrapped in violet shadow smoke." },
	Corrupted = { Rank = 9, Name = "Corrupted", Multiplier = 5.75, Color = Color3.fromRGB(255, 40, 140), HatchChance = 1 / 9000, Fx = "Glitch", Blurb = "Something is wrong with it: it flickers and glitches." },
	Diamond = { Rank = 10, Name = "Diamond", Multiplier = 6.5, Color = Color3.fromRGB(200, 245, 255), HatchChance = 1 / 20000, Fx = "Diamond", Blurb = "Brilliant white, hard as a diamond." },
	Crystal = { Rank = 11, Name = "Crystal", Multiplier = 7, Color = Color3.fromRGB(190, 140, 255), HatchChance = 1 / 35000, Fx = "Crystal", Blurb = "A body of living amethyst with crystal spikes." },
	Lightning = { Rank = 12, Name = "Lightning", Multiplier = 7.4, Color = Color3.fromRGB(255, 240, 90), HatchChance = 1 / 50000, Fx = "Zap", Blurb = "Crackling with electricity, wings trailing sparks." },
	Angelic = { Rank = 13, Name = "Angelic", Multiplier = 7.7, Color = Color3.fromRGB(255, 240, 200), HatchChance = 1 / 70000, Fx = "Holy", Blurb = "A glowing halo, white feathers and wings of light." },
	Galaxy = { Rank = 14, Name = "Galaxy", Multiplier = 8, Color = Color3.fromRGB(120, 140, 255), HatchChance = 1 / 100000, Fx = "Stars", Blurb = "A night sky wrapped around a dragon." },
	Rainbow = { Rank = 15, Name = "Rainbow", Multiplier = 10, Color = Color3.fromRGB(255, 120, 200), HatchChance = 1 / 500000, Fx = "Rainbow", Blurb = "Every colour at once." },
	Void = { Rank = 16, Name = "Void", Multiplier = 15, Color = Color3.fromRGB(190, 120, 255), HatchChance = 1 / 2500000, Fx = "Void", Blurb = "A hole in the world shaped like a dragon." },
	-- every mutation at once: only on the Robux exclusives (N2RC1S, PRINCE)
	Omni = { Rank = 17, Name = "Omni", Multiplier = 25, Color = Color3.fromRGB(255, 130, 230), HatchChance = 0, Fx = "Omni", Blurb = "All mutations at once." },
}

-- Weights used by the MUTATE action (a roll that can only improve the dragon).
MutationConfig.MutateWeights = {
	{ Id = "Shiny", Weight = 40 },
	{ Id = "Neon", Weight = 30 },
	{ Id = "Golden", Weight = 24 },
	{ Id = "Frost", Weight = 14 },
	{ Id = "Toxic", Weight = 9 },
	{ Id = "Lava", Weight = 6 },
	{ Id = "Infernal", Weight = 4.5 },
	{ Id = "Shadow", Weight = 3.5 },
	{ Id = "Corrupted", Weight = 2.6 },
	{ Id = "Diamond", Weight = 2 },
	{ Id = "Crystal", Weight = 1.5 },
	{ Id = "Lightning", Weight = 1.2 },
	{ Id = "Angelic", Weight = 1 },
	{ Id = "Galaxy", Weight = 0.8 },
	{ Id = "Rainbow", Weight = 0.4 },
	{ Id = "Void", Weight = 0.1 },
}

-- Cost of one mutation attempt: minutes of the dragon's own base income, scaled.
MutationConfig.CostIncomeMinutes = 12
MutationConfig.CostRankFactor = 0.6 -- each mutation rank already owned makes the next try pricier
MutationConfig.MinCost = 750
MutationConfig.MaxRank = MutationConfig.Mutations.Void.Rank -- the best mutation a roll / the MUTATE action can give

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

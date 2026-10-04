--[[
	EggConfig
	Egg types, hatch tables and spawn tuning. Hatch tables are weighted;
	HatchLuck multiplies the weight of Rare-and-better results.
]]

local EggConfig = {}

EggConfig.Eggs = {
	HavenEgg = {
		HatchTime = 12, -- seconds of incubation in the sanctuary nest
		Name = "Haven Egg",
		Region = "Haven",
		Tier = 1,
		Shell = Color3.fromRGB(196, 222, 150),
		Spots = Color3.fromRGB(92, 140, 70),
		Glow = Color3.fromRGB(190, 255, 160),
		Pattern = "Spots",
		Hatch = {
			{ Id = "GreenDrake", Weight = 30 },
			{ Id = "PebbleDrake", Weight = 18 },
			{ Id = "EmberPup", Weight = 15 },
			{ Id = "SproutDrake", Weight = 13 },
			{ Id = "PuddleWyrm", Weight = 10 },
			{ Id = "SandScuttler", Weight = 8 },
			{ Id = "ForestWyvern", Weight = 2.5 },
			{ Id = "CoralGlider", Weight = 1.8 },
			{ Id = "Thornback", Weight = 1.2 },
			{ Id = "AquaSerpent", Weight = 0.35 },
			{ Id = "CrystalWyvern", Weight = 0.15 },
		},
	},
	GroveEgg = {
		HatchTime = 40, -- seconds of incubation in the sanctuary nest
		Name = "Grove Egg",
		Region = "Haven",
		Tier = 2,
		Shell = Color3.fromRGB(122, 160, 120),
		Spots = Color3.fromRGB(226, 200, 120),
		Glow = Color3.fromRGB(140, 255, 200),
		Pattern = "Spots",
		Hatch = {
			{ Id = "ForestWyvern", Weight = 18 },
			{ Id = "CoralGlider", Weight = 16 },
			{ Id = "Thornback", Weight = 14 },
			{ Id = "Frostling", Weight = 12 },
			{ Id = "SunbeamDrake", Weight = 10 },
			{ Id = "NightWyvern", Weight = 8 },
			{ Id = "AquaSerpent", Weight = 6 },
			{ Id = "CrystalWyvern", Weight = 5 },
			{ Id = "StormHawk", Weight = 4 },
			{ Id = "MagmaBrute", Weight = 3 },
			{ Id = "JadeSerpent", Weight = 2 },
			{ Id = "FrostDragon", Weight = 1.2 },
			{ Id = "ThunderDragon", Weight = 0.6 },
			{ Id = "InfernoDragon", Weight = 0.15 },
			{ Id = "GoldenEmperor", Weight = 0.05 },
		},
	},
	BloomEgg = {
		HatchTime = 45, -- seconds of incubation in the sanctuary nest
		Name = "Bloom Egg",
		Region = "Haven",
		Tier = 2,
		Shell = Color3.fromRGB(255, 214, 232),
		Spots = Color3.fromRGB(255, 120, 170),
		Glow = Color3.fromRGB(255, 170, 210),
		Pattern = "Flowers",
		Hatch = {
			{ Id = "SproutDrake", Weight = 30 },
			{ Id = "CoralGlider", Weight = 22 },
			{ Id = "SunbeamDrake", Weight = 18 },
			{ Id = "PuddleWyrm", Weight = 12 },
			{ Id = "JadeSerpent", Weight = 9 },
			{ Id = "AquaSerpent", Weight = 5 },
			{ Id = "SakuraSpirit", Weight = 3.5 },
			{ Id = "CelestialDragon", Weight = 0.5 },
		},
	},
	FrostEgg = {
		HatchTime = 120, -- seconds of incubation in the sanctuary nest
		Name = "Frost Egg",
		Region = "Frostpeak",
		Tier = 3,
		Shell = Color3.fromRGB(200, 232, 255),
		Spots = Color3.fromRGB(110, 170, 230),
		Glow = Color3.fromRGB(170, 230, 255),
		Pattern = "Spots",
		Hatch = {
			{ Id = "Frostling", Weight = 20 },
			{ Id = "NightWyvern", Weight = 12 },
			{ Id = "AquaSerpent", Weight = 16 },
			{ Id = "CrystalWyvern", Weight = 14 },
			{ Id = "StormHawk", Weight = 12 },
			{ Id = "JadeSerpent", Weight = 8 },
			{ Id = "FrostDragon", Weight = 9 },
			{ Id = "ThunderDragon", Weight = 5 },
			{ Id = "SakuraSpirit", Weight = 3 },
			{ Id = "AbyssLeviathan", Weight = 0.7 },
			{ Id = "GoldenEmperor", Weight = 0.25 },
			{ Id = "CelestialDragon", Weight = 0.05 },
		},
	},
	GlacierEgg = {
		HatchTime = 150, -- seconds of incubation in the sanctuary nest
		Name = "Glacier Egg",
		Region = "Frostpeak",
		Tier = 3,
		Shell = Color3.fromRGB(226, 246, 255),
		Spots = Color3.fromRGB(120, 200, 240),
		Glow = Color3.fromRGB(190, 240, 255),
		Pattern = "Crystal",
		Hatch = {
			{ Id = "Frostling", Weight = 26 },
			{ Id = "CrystalWyvern", Weight = 22 },
			{ Id = "AquaSerpent", Weight = 18 },
			{ Id = "FrostDragon", Weight = 16 },
			{ Id = "NightWyvern", Weight = 10 },
			{ Id = "AbyssLeviathan", Weight = 5 },
			{ Id = "CelestialDragon", Weight = 2.5 },
			{ Id = "GalaxyDragon", Weight = 0.5 },
		},
	},
	AuroraEgg = {
		HatchTime = 240, -- seconds of incubation in the sanctuary nest
		Name = "Aurora Egg",
		Region = "Frostpeak",
		Tier = 4,
		Shell = Color3.fromRGB(60, 80, 140),
		Spots = Color3.fromRGB(90, 255, 200),
		Glow = Color3.fromRGB(150, 120, 255),
		Pattern = "Stripes",
		Hatch = {
			{ Id = "NightWyvern", Weight = 24 },
			{ Id = "CrystalWyvern", Weight = 20 },
			{ Id = "FrostDragon", Weight = 18 },
			{ Id = "SakuraSpirit", Weight = 14 },
			{ Id = "AbyssLeviathan", Weight = 12 },
			{ Id = "CelestialDragon", Weight = 7 },
			{ Id = "GalaxyDragon", Weight = 4 },
			{ Id = "VoidDragon", Weight = 0.8 },
			{ Id = "EternalDragon", Weight = 0.2 },
		},
	},
	EmberEgg = {
		HatchTime = 300, -- seconds of incubation in the sanctuary nest
		Name = "Ember Egg",
		Region = "EmberCaldera",
		Tier = 4,
		Shell = Color3.fromRGB(58, 40, 36),
		Spots = Color3.fromRGB(255, 120, 40),
		Glow = Color3.fromRGB(255, 150, 70),
		Pattern = "Spots",
		Hatch = {
			{ Id = "MagmaBrute", Weight = 30 },
			{ Id = "StormHawk", Weight = 10 },
			{ Id = "ToxicWyrm", Weight = 18 },
			{ Id = "BloodmoonDrake", Weight = 16 },
			{ Id = "ThunderDragon", Weight = 12 },
			{ Id = "FrostDragon", Weight = 8 },
			{ Id = "InfernoDragon", Weight = 3.5 },
			{ Id = "PhoenixDrake", Weight = 1.5 },
			{ Id = "GoldenEmperor", Weight = 0.8 },
			{ Id = "GalaxyDragon", Weight = 0.15 },
			{ Id = "CelestialDragon", Weight = 0.05 },
		},
	},
	MagmaEgg = {
		HatchTime = 330, -- seconds of incubation in the sanctuary nest
		Name = "Magma Egg",
		Region = "EmberCaldera",
		Tier = 4,
		Shell = Color3.fromRGB(30, 24, 24),
		Spots = Color3.fromRGB(255, 90, 20),
		Glow = Color3.fromRGB(255, 120, 40),
		Pattern = "Cracks",
		Hatch = {
			{ Id = "MagmaBrute", Weight = 30 },
			{ Id = "ToxicWyrm", Weight = 20 },
			{ Id = "BloodmoonDrake", Weight = 20 },
			{ Id = "InfernoDragon", Weight = 14 },
			{ Id = "PhoenixDrake", Weight = 9 },
			{ Id = "GoldenEmperor", Weight = 5 },
			{ Id = "GalaxyDragon", Weight = 1.6 },
			{ Id = "VoidDragon", Weight = 0.4 },
		},
	},
	InfernoEgg = {
		HatchTime = 600, -- seconds of incubation in the sanctuary nest
		Name = "Inferno Egg",
		Region = "EmberCaldera",
		Tier = 5,
		Shell = Color3.fromRGB(196, 40, 27),
		Spots = Color3.fromRGB(255, 205, 47),
		Glow = Color3.fromRGB(255, 160, 60),
		Pattern = "Stripes",
		Hatch = {
			{ Id = "BloodmoonDrake", Weight = 26 },
			{ Id = "InfernoDragon", Weight = 24 },
			{ Id = "PhoenixDrake", Weight = 20 },
			{ Id = "GoldenEmperor", Weight = 14 },
			{ Id = "AbyssLeviathan", Weight = 9 },
			{ Id = "GalaxyDragon", Weight = 4.5 },
			{ Id = "CelestialDragon", Weight = 2 },
			{ Id = "VoidDragon", Weight = 0.4 },
			{ Id = "EternalDragon", Weight = 0.1 },
		},
	},
	SkyEgg = {
		HatchTime = 900, -- seconds of incubation in the sanctuary nest
		Name = "Sky Egg",
		Region = "Skyreach",
		Tier = 5,
		Shell = Color3.fromRGB(250, 246, 232),
		Spots = Color3.fromRGB(240, 196, 90),
		Glow = Color3.fromRGB(255, 240, 190),
		Pattern = "Spots",
		Hatch = {
			{ Id = "SakuraSpirit", Weight = 28.088 },
			{ Id = "BloodmoonDrake", Weight = 20 },
			{ Id = "ToxicWyrm", Weight = 16 },
			{ Id = "PhoenixDrake", Weight = 12 },
			{ Id = "GoldenEmperor", Weight = 10 },
			{ Id = "InfernoDragon", Weight = 7 },
			{ Id = "AbyssLeviathan", Weight = 5 },
			{ Id = "CelestialDragon", Weight = 1.3 },
			{ Id = "GalaxyDragon", Weight = 0.6 },
			{ Id = "VoidDragon", Weight = 0.01 },
			{ Id = "EternalDragon", Weight = 0.002 },
		},
	},
	StormEgg = {
		HatchTime = 900, -- seconds of incubation in the sanctuary nest
		Name = "Storm Egg",
		Region = "Skyreach",
		Tier = 5,
		Shell = Color3.fromRGB(110, 114, 130),
		Spots = Color3.fromRGB(255, 226, 70),
		Glow = Color3.fromRGB(200, 220, 255),
		Pattern = "Stripes",
		Hatch = {
			{ Id = "StormHawk", Weight = 25 },
			{ Id = "ThunderDragon", Weight = 25 },
			{ Id = "PhoenixDrake", Weight = 15 },
			{ Id = "GoldenEmperor", Weight = 15 },
			{ Id = "AbyssLeviathan", Weight = 10 },
			{ Id = "CelestialDragon", Weight = 6 },
			{ Id = "GalaxyDragon", Weight = 3 },
			{ Id = "VoidDragon", Weight = 0.8 },
			{ Id = "EternalDragon", Weight = 0.2 },
		},
	},
	CelestialEgg = {
		HatchTime = 1500, -- seconds of incubation in the sanctuary nest
		Name = "Celestial Egg",
		Region = "Skyreach",
		Tier = 6,
		Shell = Color3.fromRGB(255, 252, 240),
		Spots = Color3.fromRGB(255, 215, 90),
		Glow = Color3.fromRGB(255, 250, 210),
		Pattern = "Stars",
		Hatch = {
			{ Id = "GoldenEmperor", Weight = 25 },
			{ Id = "PhoenixDrake", Weight = 20 },
			{ Id = "AbyssLeviathan", Weight = 18 },
			{ Id = "CelestialDragon", Weight = 18 },
			{ Id = "GalaxyDragon", Weight = 12 },
			{ Id = "VoidDragon", Weight = 5 },
			{ Id = "EternalDragon", Weight = 2 },
		},
	},
	GoldenEgg = {
		HatchTime = 300, -- seconds of incubation in the sanctuary nest
		Name = "Golden Egg",
		Region = "Any",
		Tier = 5,
		Shell = Color3.fromRGB(245, 200, 60),
		Spots = Color3.fromRGB(255, 240, 170),
		Glow = Color3.fromRGB(255, 220, 110),
		Pattern = "Gold",
		MinLuck = 10,
		Hatch = {
			{ Id = "GoldenEmperor", Weight = 30 },
			{ Id = "InfernoDragon", Weight = 20 },
			{ Id = "PhoenixDrake", Weight = 18 },
			{ Id = "AbyssLeviathan", Weight = 14 },
			{ Id = "CelestialDragon", Weight = 10 },
			{ Id = "GalaxyDragon", Weight = 6 },
			{ Id = "VoidDragon", Weight = 1.6 },
			{ Id = "EternalDragon", Weight = 0.4 },
		},
	},
	RainbowEgg = {
		HatchTime = 600, -- seconds of incubation in the sanctuary nest
		Name = "Rainbow Egg",
		Region = "Any",
		Tier = 6,
		Shell = Color3.fromRGB(255, 255, 255),
		Spots = Color3.fromRGB(255, 120, 200),
		Glow = Color3.fromRGB(255, 170, 230),
		Pattern = "Rainbow",
		MinLuck = 25,
		GuaranteedMutation = true,
		Hatch = {
			{ Id = "CelestialDragon", Weight = 30 },
			{ Id = "GalaxyDragon", Weight = 28 },
			{ Id = "AbyssLeviathan", Weight = 20 },
			{ Id = "VoidDragon", Weight = 14 },
			{ Id = "EternalDragon", Weight = 8 },
		},
	},
}

EggConfig.Order = { "HavenEgg", "GroveEgg", "BloomEgg", "FrostEgg", "GlacierEgg", "AuroraEgg", "EmberEgg", "MagmaEgg", "InfernoEgg", "SkyEgg", "StormEgg", "CelestialEgg", "GoldenEgg", "RainbowEgg" }

-- Incubator (sanctuary nest) slots: index -> unlock price.
EggConfig.IncubatorPrices = { 0, 0, 1500, 20000, 250000, 3000000 }
EggConfig.IncubatorStart = 2

-- Spawn areas that roll their luck twice (keep the best).
EggConfig.RareAreas = { Ruins = true, Cave = true, Pillar = true, Island = true, Falls = true, Plateau = true, Pass = true }

-- Which egg types spawn in each region (weights).
EggConfig.Regions = {
	Haven = { { Id = "HavenEgg", Weight = 62 }, { Id = "GroveEgg", Weight = 24 }, { Id = "BloomEgg", Weight = 14 } },
	Frostpeak = { { Id = "FrostEgg", Weight = 58 }, { Id = "GlacierEgg", Weight = 28 }, { Id = "AuroraEgg", Weight = 14 } },
	EmberCaldera = { { Id = "EmberEgg", Weight = 58 }, { Id = "MagmaEgg", Weight = 28 }, { Id = "InfernoEgg", Weight = 14 } },
	Skyreach = { { Id = "SkyEgg", Weight = 58 }, { Id = "StormEgg", Weight = 28 }, { Id = "CelestialEgg", Weight = 14 } },
}
EggConfig.RegionNames = { Haven = "Dragon Haven", Frostpeak = "Frostpeak", EmberCaldera = "Ember Caldera", Skyreach = "Skyreach" }

-- Region of an egg spot without a "Region" attribute (landmarks of the valley).
EggConfig.AreaRegion = { Plateau = "Frostpeak", Pass = "Frostpeak", Falls = "Frostpeak", Cave = "EmberCaldera", Ruins = "EmberCaldera", Pillar = "Skyreach", Island = "Skyreach" }

-- Special eggs that can replace any spawn.
EggConfig.Specials = { { Id = "RainbowEgg", Chance = 0.003 }, { Id = "GoldenEgg", Chance = 0.015 } }

-- Every world egg rolls its own luck (shown above it, applied when it hatches).
EggConfig.LuckRolls = {
	{ Luck = 1, Weight = 50 },
	{ Luck = 2, Weight = 22 },
	{ Luck = 3, Weight = 11 },
	{ Luck = 5, Weight = 7.5 },
	{ Luck = 10, Weight = 4.8 },
	{ Luck = 25, Weight = 2.5 },
	{ Luck = 50, Weight = 1.3 },
	{ Luck = 100, Weight = 0.6 },
	{ Luck = 250, Weight = 0.22 },
	{ Luck = 1000, Weight = 0.08 },
}

-- Personal egg spawning (each player has their own eggs in the world).
EggConfig.Spawning = {
	MaxActive = 18,
	MaxActivePerRegion = 18, -- (legacy name)
	ScatterRadius = 70, -- eggs appear around a spawn area, not on one exact spot
	-- Roaming eggs: this share of every egg appears at a completely random place of the land (the
	-- rest scatter around the named areas, where the rare finds are). Wild eggs always roam.
	RoamingShare = 0.5,
	WorldBox = { MinX = -980, MaxX = 860, MinZ = -960, MaxZ = 900 },
	RoamAvoid = { "Pillar", "Island" }, -- areas that never name a roaming egg (sky / island spots)
	RoamMinSeparation = 260, -- a roaming wild egg appears at least this far from the previous one
	RespawnMin = 12,
	RespawnMax = 30,
}

local function weighted(list, rng: Random)
	local total = 0
	for _, e in list do
		total += e.Weight
	end
	local r = rng:NextNumber() * total
	for _, e in list do
		r -= e.Weight
		if r <= 0 then
			return e
		end
	end
	return list[#list]
end

-- Egg type for a spawn in a region (specials can appear anywhere).
function EggConfig.rollEgg(region: string, rng: Random): string
	for _, sp in EggConfig.Specials do
		if rng:NextNumber() < sp.Chance then
			return sp.Id
		end
	end
	local list = EggConfig.Regions[region] or EggConfig.Regions.Haven
	return weighted(list, rng).Id
end

-- Luck multiplier of a freshly spawned egg.
function EggConfig.rollLuck(eggType: string, rng: Random, rareSpot: boolean?): number
	local luck = weighted(EggConfig.LuckRolls, rng).Luck
	if rareSpot then
		luck = math.max(luck, weighted(EggConfig.LuckRolls, rng).Luck)
	end
	local def = EggConfig.Eggs[eggType]
	return math.max(luck, def and def.MinLuck or 1)
end

-- Display colour for a luck multiplier.
function EggConfig.luckColor(luck: number): Color3
	if luck >= 1000 then
		return Color3.fromRGB(80, 255, 230)
	elseif luck >= 250 then
		return Color3.fromRGB(255, 70, 70)
	elseif luck >= 100 then
		return Color3.fromRGB(255, 100, 190)
	elseif luck >= 50 then
		return Color3.fromRGB(255, 170, 50)
	elseif luck >= 25 then
		return Color3.fromRGB(190, 120, 255)
	elseif luck >= 10 then
		return Color3.fromRGB(90, 180, 255)
	elseif luck >= 3 then
		return Color3.fromRGB(110, 220, 100)
	end
	return Color3.fromRGB(235, 235, 235)
end

-- Luck applies to results whose rarity rank is >= this.
EggConfig.LuckMinRank = 3

-- Returns a list of { Id, Weight, P } with luck applied and probabilities.
function EggConfig.oddsFor(eggId: string, luck: number, rarityRankOf: (string) -> number)
	local egg = EggConfig.Eggs[eggId]
	local out = {}
	local total = 0
	for _, entry in egg.Hatch do
		local w = entry.Weight
		local rank = rarityRankOf(entry.Id)
		if rank >= EggConfig.LuckMinRank then
			w *= (1 + math.max(0, luck))
		elseif rank == EggConfig.LuckMinRank - 1 then
			w *= math.sqrt(1 + math.max(0, luck))
		end
		total += w
		table.insert(out, { Id = entry.Id, Weight = w, P = 0 })
	end
	for _, e in out do
		e.P = e.Weight / total
	end
	return out
end

return table.freeze(EggConfig)

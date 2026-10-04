--[[
	DragonConfig
	Species definitions, rarity table, level curve and stat formulas.
	Stats here are BASE values at level 1 with no mutation.

	Speed / FlightSpeed are "power" stats shown in the UI (can reach millions).
	Actual movement speed in studs/s is derived with a log curve in GameConfig
	so higher tiers always feel faster without breaking streaming/physics.
]]

local DragonConfig = {}

DragonConfig.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Exclusive" }

DragonConfig.Rarities = {
	Common = { Rank = 1, Color = Color3.fromRGB(184, 192, 200), Glow = Color3.fromRGB(220, 226, 232), HatchXP = 20 },
	Uncommon = { Rank = 2, Color = Color3.fromRGB(110, 208, 104), Glow = Color3.fromRGB(150, 240, 140), HatchXP = 45 },
	Rare = { Rank = 3, Color = Color3.fromRGB(77, 163, 255), Glow = Color3.fromRGB(130, 195, 255), HatchXP = 110 },
	Epic = { Rank = 4, Color = Color3.fromRGB(178, 102, 255), Glow = Color3.fromRGB(205, 150, 255), HatchXP = 260 },
	Legendary = { Rank = 5, Color = Color3.fromRGB(255, 176, 32), Glow = Color3.fromRGB(255, 210, 110), HatchXP = 700 },
	Mythic = { Rank = 6, Color = Color3.fromRGB(255, 79, 154), Glow = Color3.fromRGB(255, 140, 190), HatchXP = 1800 },
	Secret = { Rank = 7, Color = Color3.fromRGB(64, 236, 214), Glow = Color3.fromRGB(150, 255, 240), HatchXP = 5000 },
	-- not hatchable: Robux exclusives (Owner Dragon)
	Exclusive = { Rank = 8, Color = Color3.fromRGB(255, 64, 64), Glow = Color3.fromRGB(255, 190, 90), HatchXP = 0 },
}

DragonConfig.MaxLevel = 50

-- XP needed to go from `level` to `level + 1`.
function DragonConfig.xpToNext(level: number): number
	return math.floor(80 * level ^ 1.45 + 0.5)
end

-- Stat multiplier from level (linear, +8% of base per level).
function DragonConfig.levelMultiplier(level: number): number
	return 1 + 0.08 * (math.clamp(level, 1, DragonConfig.MaxLevel) - 1)
end

--[[
	Species fields:
	  Name, Rarity, Description
	  Speed, FlightSpeed, Income      base stats
	  Scale                           overall model scale (1 = Green Drake)
	  Handling = { Turn, Accel, Agility }  multipliers on base handling
	  FeedCost                        base cash cost per feed
	  Visual                          key into Shared/Dragons/Species
]]
DragonConfig.Species = {
	GreenDrake = {
		Name = "Green Drake",
		Rarity = "Common",
		Description = "A loyal, sure-footed drake. Every rider's first friend.",
		Speed = 120,
		FlightSpeed = 150,
		Income = 2,
		Scale = 1.0,
		Handling = { Turn = 1.0, Accel = 1.0, Agility = 1.0 },
		FeedCost = 25,
		Order = 1,
	},
	PebbleDrake = {
		Name = "Pebble Drake",
		Rarity = "Common",
		Description = "Built like a boulder and twice as stubborn.",
		Speed = 140,
		FlightSpeed = 165,
		Income = 2.5,
		Scale = 1.0,
		Handling = { Turn = 1.0, Accel = 1.0, Agility = 1.0 },
		FeedCost = 30,
		Order = 2,
	},
	EmberPup = {
		Name = "Ember Pup",
		Rarity = "Common",
		Description = "A playful hatchling whose tail never stops smouldering.",
		Speed = 160,
		FlightSpeed = 190,
		Income = 3,
		Scale = 0.95,
		Handling = { Turn = 1.0, Accel = 1.0, Agility = 1.0 },
		FeedCost = 36,
		Order = 3,
	},
	SproutDrake = {
		Name = "Sprout Drake",
		Rarity = "Common",
		Description = "Flowers bloom wherever it naps.",
		Speed = 170,
		FlightSpeed = 210,
		Income = 3.5,
		Scale = 1.0,
		Handling = { Turn = 1.0, Accel = 1.0, Agility = 1.0 },
		FeedCost = 42,
		Order = 4,
	},
	PuddleWyrm = {
		Name = "Puddle Wyrm",
		Rarity = "Common",
		Description = "Splashes through every puddle in Dragon Haven.",
		Speed = 185,
		FlightSpeed = 230,
		Income = 4,
		Scale = 1.0,
		Handling = { Turn = 1.0, Accel = 1.0, Agility = 1.0 },
		FeedCost = 48,
		Order = 5,
	},
	SandScuttler = {
		Name = "Sand Scuttler",
		Rarity = "Common",
		Description = "Quick on its feet and hard to spot in the dunes.",
		Speed = 200,
		FlightSpeed = 250,
		Income = 4.5,
		Scale = 1.0,
		Handling = { Turn = 1.0, Accel = 1.0, Agility = 1.0 },
		FeedCost = 54,
		Order = 6,
	},
	ForestWyvern = {
		Name = "Forest Wyvern",
		Rarity = "Uncommon",
		Description = "A nimble wyvern that glides between ancient trees.",
		Speed = 420,
		FlightSpeed = 600,
		Income = 9,
		Scale = 1.05,
		Handling = { Turn = 1.1, Accel = 1.08, Agility = 1.12 },
		FeedCost = 108,
		Order = 7,
	},
	CoralGlider = {
		Name = "Coral Glider",
		Rarity = "Uncommon",
		Description = "Rides the sea breeze for hours without a single flap.",
		Speed = 480,
		FlightSpeed = 680,
		Income = 11,
		Scale = 1.05,
		Handling = { Turn = 1.1, Accel = 1.08, Agility = 1.12 },
		FeedCost = 132,
		Order = 8,
	},
	Thornback = {
		Name = "Thornback",
		Rarity = "Uncommon",
		Description = "Its back is a forest of thorns. Hug carefully.",
		Speed = 520,
		FlightSpeed = 700,
		Income = 12.5,
		Scale = 1.1,
		Handling = { Turn = 1.1, Accel = 1.08, Agility = 1.12 },
		FeedCost = 150,
		Order = 9,
	},
	Frostling = {
		Name = "Frostling",
		Rarity = "Uncommon",
		Description = "A little ice drake that sneezes snowflakes.",
		Speed = 560,
		FlightSpeed = 760,
		Income = 14,
		Scale = 1.05,
		Handling = { Turn = 1.1, Accel = 1.08, Agility = 1.12 },
		FeedCost = 168,
		Order = 10,
	},
	SunbeamDrake = {
		Name = "Sunbeam Drake",
		Rarity = "Uncommon",
		Description = "Glows like the morning sun on its crowned head.",
		Speed = 620,
		FlightSpeed = 840,
		Income = 16,
		Scale = 1.05,
		Handling = { Turn = 1.1, Accel = 1.08, Agility = 1.12 },
		FeedCost = 192,
		Order = 11,
	},
	NightWyvern = {
		Name = "Night Wyvern",
		Rarity = "Uncommon",
		Description = "Hunts by moonlight with its huge, listening ears.",
		Speed = 700,
		FlightSpeed = 950,
		Income = 19,
		Scale = 1.1,
		Handling = { Turn = 1.1, Accel = 1.08, Agility = 1.12 },
		FeedCost = 228,
		Order = 12,
	},
	AquaSerpent = {
		Name = "Aqua Serpent",
		Rarity = "Rare",
		Description = "A river spirit whose long body ripples through the air like water.",
		Speed = 2500,
		FlightSpeed = 3300,
		Income = 60,
		Scale = 1.15,
		Handling = { Turn = 1.12, Accel = 1.1, Agility = 1.2 },
		FeedCost = 720,
		Order = 13,
	},
	CrystalWyvern = {
		Name = "Crystal Wyvern",
		Rarity = "Rare",
		Description = "Its wings refract sunlight into shards of color.",
		Speed = 3600,
		FlightSpeed = 4600,
		Income = 95,
		Scale = 1.1,
		Handling = { Turn = 1.12, Accel = 1.1, Agility = 1.2 },
		FeedCost = 1140,
		Order = 14,
	},
	StormHawk = {
		Name = "Storm Hawk",
		Rarity = "Rare",
		Description = "Chases thunderclouds for fun.",
		Speed = 4200,
		FlightSpeed = 5500,
		Income = 115,
		Scale = 1.15,
		Handling = { Turn = 1.12, Accel = 1.1, Agility = 1.2 },
		FeedCost = 1380,
		Order = 15,
	},
	MagmaBrute = {
		Name = "Magma Brute",
		Rarity = "Rare",
		Description = "Rivers of lava flow down its armoured back.",
		Speed = 4800,
		FlightSpeed = 6100,
		Income = 135,
		Scale = 1.2,
		Handling = { Turn = 1.12, Accel = 1.1, Agility = 1.2 },
		FeedCost = 1620,
		Order = 16,
	},
	JadeSerpent = {
		Name = "Jade Serpent",
		Rarity = "Rare",
		Description = "Guardian of the old temples, crowned with a golden mane.",
		Speed = 5600,
		FlightSpeed = 7200,
		Income = 160,
		Scale = 1.2,
		Handling = { Turn = 1.12, Accel = 1.1, Agility = 1.2 },
		FeedCost = 1920,
		Order = 17,
	},
	FrostDragon = {
		Name = "Frost Dragon",
		Rarity = "Epic",
		Description = "Born in blizzards above Frostpeak. Leaves a trail of glittering frost.",
		Speed = 42000,
		FlightSpeed = 55000,
		Income = 1100,
		Scale = 1.3,
		Handling = { Turn = 1.05, Accel = 1.15, Agility = 1.1 },
		FeedCost = 13200,
		Order = 18,
	},
	ThunderDragon = {
		Name = "Thunder Dragon",
		Rarity = "Epic",
		Description = "Rides the storm front. Lightning crackles along its wings.",
		Speed = 68000,
		FlightSpeed = 92000,
		Income = 1650,
		Scale = 1.3,
		Handling = { Turn = 1.05, Accel = 1.15, Agility = 1.1 },
		FeedCost = 19800,
		Order = 19,
	},
	ToxicWyrm = {
		Name = "Toxic Wyrm",
		Rarity = "Epic",
		Description = "Do not touch the glowing spikes.",
		Speed = 76000,
		FlightSpeed = 100000,
		Income = 1900,
		Scale = 1.3,
		Handling = { Turn = 1.05, Accel = 1.15, Agility = 1.1 },
		FeedCost = 22800,
		Order = 20,
	},
	BloodmoonDrake = {
		Name = "Bloodmoon Drake",
		Rarity = "Epic",
		Description = "Appears only when the moon turns red.",
		Speed = 88000,
		FlightSpeed = 115000,
		Income = 2300,
		Scale = 1.35,
		Handling = { Turn = 1.05, Accel = 1.15, Agility = 1.1 },
		FeedCost = 27600,
		Order = 21,
	},
	SakuraSpirit = {
		Name = "Sakura Spirit",
		Rarity = "Epic",
		Description = "Petals swirl in its wake as it dances through the sky.",
		Speed = 100000,
		FlightSpeed = 130000,
		Income = 2800,
		Scale = 1.35,
		Handling = { Turn = 1.05, Accel = 1.15, Agility = 1.1 },
		FeedCost = 33600,
		Order = 22,
	},
	InfernoDragon = {
		Name = "Inferno Dragon",
		Rarity = "Legendary",
		Description = "A walking volcano. The air shimmers wherever it lands.",
		Speed = 1800000,
		FlightSpeed = 2400000,
		Income = 92500,
		Scale = 1.55,
		Handling = { Turn = 0.95, Accel = 1.1, Agility = 1.0 },
		FeedCost = 1110000,
		Order = 23,
	},
	GoldenEmperor = {
		Name = "Golden Emperor",
		Rarity = "Legendary",
		Description = "Sovereign of the old dragon courts, crowned in living gold.",
		Speed = 2600000,
		FlightSpeed = 3100000,
		Income = 140000,
		Scale = 1.6,
		Handling = { Turn = 0.95, Accel = 1.1, Agility = 1.0 },
		FeedCost = 1680000,
		Order = 24,
	},
	AbyssLeviathan = {
		Name = "Abyss Leviathan",
		Rarity = "Legendary",
		Description = "Rises from the deepest trench, glowing like the stars below.",
		Speed = 3200000,
		FlightSpeed = 3900000,
		Income = 175000,
		Scale = 1.65,
		Handling = { Turn = 0.95, Accel = 1.1, Agility = 1.0 },
		FeedCost = 2100000,
		Order = 25,
	},
	PhoenixDrake = {
		Name = "Phoenix Drake",
		Rarity = "Legendary",
		Description = "Burns brighter every time it is reborn.",
		Speed = 3800000,
		FlightSpeed = 4600000,
		Income = 210000,
		Scale = 1.6,
		Handling = { Turn = 0.95, Accel = 1.1, Agility = 1.0 },
		FeedCost = 2520000,
		Order = 26,
	},
	CelestialDragon = {
		Name = "Celestial Dragon",
		Rarity = "Mythic",
		Description = "Swims through the clouds of the upper sky, haloed in starlight.",
		Speed = 85000000,
		FlightSpeed = 110000000,
		Income = 4200000,
		Scale = 1.7,
		Handling = { Turn = 1.1, Accel = 1.25, Agility = 1.15 },
		FeedCost = 50400000,
		Order = 27,
	},
	GalaxyDragon = {
		Name = "Galaxy Dragon",
		Rarity = "Mythic",
		Description = "Its wings hold entire constellations.",
		Speed = 120000000,
		FlightSpeed = 160000000,
		Income = 6500000,
		Scale = 1.8,
		Handling = { Turn = 1.1, Accel = 1.25, Agility = 1.15 },
		FeedCost = 78000000,
		Order = 28,
	},
	VoidDragon = {
		Name = "Void Dragon",
		Rarity = "Secret",
		Description = "Seen only at the edge of the world. Light bends around it.",
		Speed = 2500000000,
		FlightSpeed = 3200000000,
		Income = 180000000,
		Scale = 1.85,
		Handling = { Turn = 1.1, Accel = 1.4, Agility = 1.15 },
		FeedCost = 2160000000,
		Order = 29,
	},
	EternalDragon = {
		Name = "Eternal Dragon",
		Rarity = "Secret",
		Description = "Older than the mountains. Its runes never stop turning.",
		Speed = 4000000000,
		FlightSpeed = 5500000000,
		Income = 300000000,
		Scale = 2.0,
		Handling = { Turn = 1.1, Accel = 1.4, Agility = 1.15 },
		FeedCost = 3600000000,
		Order = 30,
	},
	-- Robux exclusive (Owner Dragon game pass): the strongest dragon in the game.
	OwnerDragon = {
		Name = "Owner Dragon",
		Rarity = "Exclusive",
		Description = "The owner's own dragon. Doubles your luck on every roll and outflies everything.",
		Speed = 9000000000,
		FlightSpeed = 12000000000,
		Income = 1000000000,
		Scale = 2.3,
		Handling = { Turn = 1.25, Accel = 1.6, Agility = 1.3 },
		FeedCost = 12000000000,
		Order = 31,
		Exclusive = true,
	},
	-- Robux exclusives (8999 R$ each): the strongest dragons, every mutation at once.
	N2RC1SDragon = {
		Name = "N2RC1S",
		Rarity = "Exclusive",
		Description = "A legend among legends. Every mutation burns inside it at once.",
		Speed = 90000000000,
		FlightSpeed = 120000000000,
		Income = 10000000000000,
		Scale = 2.5,
		Handling = { Turn = 1.3, Accel = 1.7, Agility = 1.35 },
		FeedCost = 100000000000000,
		Order = 32,
		Exclusive = true,
	},
	PrinceDragon = {
		Name = "PRINCE",
		Rarity = "Exclusive",
		Description = "Royal blood, golden crown, all mutations. Bow before the PRINCE.",
		Speed = 90000000000,
		FlightSpeed = 120000000000,
		Income = 10000000000000,
		Scale = 2.5,
		Handling = { Turn = 1.3, Accel = 1.7, Agility = 1.35 },
		FeedCost = 100000000000000,
		Order = 33,
		Exclusive = true,
	},
}

DragonConfig.StarterSpecies = "GreenDrake"

-- Species ids sorted by Order (stable list for the Index).
function DragonConfig.speciesList(): { string }
	local list = {}
	for id in DragonConfig.Species do
		table.insert(list, id)
	end
	table.sort(list, function(a, b)
		return DragonConfig.Species[a].Order < DragonConfig.Species[b].Order
	end)
	return list
end

function DragonConfig.rarityRank(rarity: string): number
	local r = DragonConfig.Rarities[rarity]
	return r and r.Rank or 0
end

return table.freeze(DragonConfig)

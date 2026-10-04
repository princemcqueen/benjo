--[[
	DuelConfig
	Turn-based dragon duels in a fixed scene, like the old Pokemon games (DuelService / DuelController):
	your dragon stands in front on the left, the opponent's behind on the right, a menu of four moves,
	hit point bars, one move each per turn. The server rolls every hit; the clients only play the scene.

	Opponents: NPC trainers (Trainers) and other players (challenge from the Battle window).

	Moves (the player chooses one per turn):
	  STRIKE   a bite and tail slam: reliable, free
	  FIRE     the dragon's element breath: strong, sometimes misses, limited uses
	  GUARD    goes first and halves the damage of this turn; fails if used twice in a row
	  SPECIAL  a mutated dragon: <MUTATION> BURST (the strongest hit, 3 uses); a normal dragon: ROAR
	           (no damage, +30% damage for 3 turns)

	Elements: every species has one; FIRE / WATER / NATURE / EARTH / STORM / ICE / DARK / LIGHT beat
	each other like in the table at Strong (x1.5), the reverse is x0.67, two that beat each other
	are neutral.
]]

local CombatConfig = require(script.Parent:WaitForChild("CombatConfig"))

local DuelConfig = {}

-- Hit points and damage come from the same formulas as the arena (level and rarity), scaled so a
-- duel lasts about five to seven turns.
DuelConfig.HPScale = 0.6
DuelConfig.DamageScale = 1.3
DuelConfig.Variance = { 0.9, 1.1 } -- every hit is multiplied by a number in this range
DuelConfig.CritChance = 0.08
DuelConfig.CritMultiplier = 1.5

DuelConfig.Moves = {
	Strike = { Name = "STRIKE", Power = 1.0, Accuracy = 0.95, PP = math.huge, Anim = "Strike", Blurb = "A bite and a tail slam" },
	Fire = { Name = "FIRE", Power = 1.6, Accuracy = 0.88, PP = 8, Anim = "Cast", Blurb = "Your element's breath" },
	Guard = { Name = "GUARD", Power = 0, Accuracy = 1, PP = 6, Anim = "Roar", Priority = 1, Blurb = "Half damage this turn" },
	Special = { Name = "SPECIAL", Power = 2.3, Accuracy = 0.8, PP = 3, Anim = "Cast", Blurb = "A mutated dragon's burst" },
	Roar = { Name = "ROAR", Power = 0, Accuracy = 1, PP = 4, Anim = "Roar", Buff = 1.3, BuffTurns = 3, Blurb = "+30% damage for 3 turns" },
}
DuelConfig.MoveOrder = { "Strike", "Fire", "Guard", "Special" }

DuelConfig.TurnSeconds = 30 -- a player who does not choose in time uses STRIKE (player duels)
DuelConfig.ChallengeSeconds = 30 -- how long a challenge waits for an answer

DuelConfig.Elements = { "Fire", "Water", "Nature", "Earth", "Storm", "Ice", "Dark", "Light" }
DuelConfig.Colors = {
	Fire = Color3.fromRGB(255, 120, 50),
	Water = Color3.fromRGB(70, 160, 255),
	Nature = Color3.fromRGB(110, 208, 104),
	Earth = Color3.fromRGB(190, 150, 90),
	Storm = Color3.fromRGB(255, 232, 90),
	Ice = Color3.fromRGB(150, 225, 255),
	Dark = Color3.fromRGB(170, 100, 255),
	Light = Color3.fromRGB(255, 240, 190),
}

-- Element -> the elements it is strong against.
DuelConfig.Strong = {
	Fire = { Nature = true, Ice = true },
	Water = { Fire = true, Earth = true },
	Nature = { Water = true, Earth = true },
	Earth = { Fire = true, Storm = true },
	Storm = { Water = true, Ice = true },
	Ice = { Nature = true, Earth = true },
	Dark = { Light = true },
	Light = { Dark = true },
}

DuelConfig.SpeciesElement = {
	GreenDrake = "Nature",
	PebbleDrake = "Earth",
	EmberPup = "Fire",
	SproutDrake = "Nature",
	PuddleWyrm = "Water",
	SandScuttler = "Earth",
	ForestWyvern = "Nature",
	CoralGlider = "Water",
	Thornback = "Nature",
	Frostling = "Ice",
	SunbeamDrake = "Light",
	NightWyvern = "Dark",
	AquaSerpent = "Water",
	CrystalWyvern = "Earth",
	StormHawk = "Storm",
	MagmaBrute = "Fire",
	JadeSerpent = "Nature",
	FrostDragon = "Ice",
	ThunderDragon = "Storm",
	ToxicWyrm = "Nature",
	BloodmoonDrake = "Dark",
	SakuraSpirit = "Light",
	InfernoDragon = "Fire",
	GoldenEmperor = "Light",
	AbyssLeviathan = "Water",
	PhoenixDrake = "Fire",
	CelestialDragon = "Light",
	GalaxyDragon = "Dark",
	VoidDragon = "Dark",
	EternalDragon = "Light",
	OwnerDragon = "Light",
	N2RC1SDragon = "Dark",
	PrinceDragon = "Light",
	M0nicaDragon = "Fire",
}

-- NPC trainers: the level of their dragon is the level of yours plus LevelDelta.
-- Species = what they may send out, Mutations = { id, chance } tried from the top.
-- Reward: cash = max(Min, your income * Minutes * 60), XP; the full reward only once per Cooldown
-- seconds per trainer (a rematch right away pays RematchShare of it).
DuelConfig.Trainers = {
	{
		Id = "Rookie",
		Name = "Rookie Ren",
		Title = "Rookie",
		LevelDelta = -2,
		Species = { "GreenDrake", "PebbleDrake", "EmberPup", "SproutDrake", "PuddleWyrm", "SandScuttler" },
		Mutations = { { "Shiny", 0.15 } },
		Reward = { Minutes = 2, Min = 1500, XP = 30 },
		Color = Color3.fromRGB(110, 208, 104),
	},
	{
		Id = "Ranger",
		Name = "Ranger Kai",
		Title = "Ranger",
		LevelDelta = 0,
		Species = { "ForestWyvern", "CoralGlider", "Thornback", "Frostling", "SunbeamDrake", "NightWyvern", "AquaSerpent", "StormHawk" },
		Mutations = { { "Neon", 0.1 }, { "Shiny", 0.25 } },
		Reward = { Minutes = 4, Min = 4000, XP = 70 },
		Color = Color3.fromRGB(77, 163, 255),
	},
	{
		Id = "Captain",
		Name = "Captain Vale",
		Title = "Captain",
		LevelDelta = 3,
		Species = { "MagmaBrute", "JadeSerpent", "FrostDragon", "ThunderDragon", "ToxicWyrm", "BloodmoonDrake", "InfernoDragon", "CrystalWyvern" },
		Mutations = { { "Frost", 0.1 }, { "Golden", 0.15 }, { "Neon", 0.25 } },
		Reward = { Minutes = 10, Min = 12000, XP = 160 },
		Color = Color3.fromRGB(178, 102, 255),
	},
	{
		Id = "Champion",
		Name = "Champion Ashka",
		Title = "Champion",
		LevelDelta = 6,
		Species = { "GoldenEmperor", "AbyssLeviathan", "PhoenixDrake", "CelestialDragon", "GalaxyDragon", "VoidDragon", "EternalDragon" },
		Mutations = { { "Crystal", 0.1 }, { "Lava", 0.15 }, { "Golden", 0.3 } },
		Reward = { Minutes = 30, Min = 50000, XP = 420 },
		Color = Color3.fromRGB(255, 176, 32),
	},
}
DuelConfig.TrainerCooldown = 180
DuelConfig.RematchShare = 0.25

-- A player duel pays the winner this (like a trainer of the loser's level), the loser gets a little XP.
DuelConfig.PlayerWin = { Minutes = 6, Min = 6000, XP = 100 }
DuelConfig.LoserXP = 15
DuelConfig.MinTurnsForReward = 3 -- a player duel that ends sooner (or by a forfeit) pays nothing
DuelConfig.PairCooldown = 600 -- the same two players within this many seconds: RematchShare of the prize
DuelConfig.IdleSeconds = 120 -- a trainer duel nobody plays for this long is over

-- ============================================================== helpers
function DuelConfig.elementOf(speciesId: string): string
	return DuelConfig.SpeciesElement[speciesId] or "Nature"
end

-- Damage multiplier of an attack of element `att` on a dragon of element `def`.
function DuelConfig.effectiveness(att: string, def: string): number
	local a = DuelConfig.Strong[att] and DuelConfig.Strong[att][def] == true
	local b = DuelConfig.Strong[def] and DuelConfig.Strong[def][att] == true
	if a and not b then
		return 1.5
	elseif b and not a then
		return 2 / 3
	end
	return 1
end

function DuelConfig.maxHP(level: number, rank: number): number
	return math.max(1, math.floor(CombatConfig.maxHP(level, rank) * DuelConfig.HPScale + 0.5))
end

function DuelConfig.baseDamage(level: number, rank: number): number
	return CombatConfig.baseDamage(level, rank) * DuelConfig.DamageScale
end

function DuelConfig.trainer(id: string)
	for _, t in DuelConfig.Trainers do
		if t.Id == id then
			return t
		end
	end
	return nil
end

return DuelConfig

--[[
	CombatConfig
	Dragon duels in the arena of the Race & Battle Island. Inside the arena (and only there)
	riders can hit each other:

	  STRIKE (F / tap)   a bite and tail slam in front of you: short range, quick, reliable
	  BLAST  (G / tap)   a fireball: long range, slow to recharge, needs aiming

	Everybody has hit points from their dragon (level and rarity, not from how much it earns), so a
	fresh dragon is never helpless against a legend but the better dragon has the edge.
	The server decides hits, damage, knockouts and respawns; clients only ask and draw.
]]

local RaceConfig = require(script.Parent:WaitForChild("RaceConfig"))

local CombatConfig = {}

-- Island-local arena cylinder (the dragons fly inside it as well).
CombatConfig.Arena = {
	Center = Vector3.new(0, 0, 98),
	Radius = 46,
	Height = 150, -- the top of the cylinder above the floor
}
CombatConfig.Entrance = Vector3.new(0, 0, 36) -- the prompt "Enter the Arena" (a walkway towards it)
CombatConfig.Respawns = { -- island-local spots (floor level), facing the centre
	Vector3.new(-34, 0, 98),
	Vector3.new(34, 0, 98),
	Vector3.new(0, 0, 64),
	Vector3.new(0, 0, 132),
}

-- Hit points: Base + PerLevel * level + PerRank * rarity rank (rank 1..8)
CombatConfig.HP = { Base = 800, PerLevel = 14, PerRank = 150 }
-- Damage per hit: Base + PerLevel * level + PerRank * rarity rank, multiplied per attack
CombatConfig.Damage = { Base = 70, PerLevel = 0.9, PerRank = 14 }

CombatConfig.Strike = {
	Multiplier = 1.0,
	Cooldown = 0.75,
	Reach = 17, -- studs from the dragon's centre (plus its body radius)
	Cone = 78, -- degrees either side of where you look
	Crit = 0.1, -- chance of a x1.5 hit
}

CombatConfig.Blast = {
	Multiplier = 1.7,
	Cooldown = 3.6,
	Speed = 170, -- studs per second
	Radius = 5.5, -- hit radius around the fireball (plus the target's body radius)
	Lifetime = 1.5,
	Step = 0.05, -- server simulation step
}

-- The training dummy in the middle of the arena: a target on a pole for trying your damage out.
-- Hits count like duel hits (crits, cooldowns) but it pays nothing and does not hit back.
CombatConfig.Dummy = {
	Name = "Training Dummy",
	Position = Vector3.new(0, 0, 98), -- island-local, on the arena floor
	Height = 13, -- the target's centre above the island surface
	Radius = 7,
	HP = 4000,
	Respawn = 4,
}

CombatConfig.RespawnDelay = 3
CombatConfig.Invulnerable = 3 -- seconds of protection after a respawn / after entering
CombatConfig.RegenPerSecond = 0.012 -- fraction of max HP, only when nobody hit you for 6 s
CombatConfig.RegenDelay = 6
CombatConfig.MaxAimSlack = 45 -- degrees the claimed look direction may differ from the dragon's heading

-- A kill pays minutes of the killer's sanctuary income (at least Min) + XP.
CombatConfig.KillReward = { Minutes = 4, Min = 4000, XP = 30 }

-- The server samples who is inside the arena this often.
CombatConfig.ZoneSeconds = 0.25

function CombatConfig.arenaWorld(): (Vector3, number, number)
	local a = CombatConfig.Arena
	return RaceConfig.toWorld(a.Center), a.Radius, a.Height
end

-- World position of the dummy's target (what strikes and fireballs aim at).
function CombatConfig.dummyWorld(): Vector3
	local d = CombatConfig.Dummy
	local p = RaceConfig.toWorld(d.Position)
	return Vector3.new(p.X, p.Y + d.Height, p.Z)
end

-- Max hit points / damage of a dragon record.
function CombatConfig.maxHP(level: number, rank: number): number
	local c = CombatConfig.HP
	return math.floor(c.Base + c.PerLevel * level + c.PerRank * rank + 0.5)
end

function CombatConfig.baseDamage(level: number, rank: number): number
	local c = CombatConfig.Damage
	return c.Base + c.PerLevel * level + c.PerRank * rank
end

return CombatConfig

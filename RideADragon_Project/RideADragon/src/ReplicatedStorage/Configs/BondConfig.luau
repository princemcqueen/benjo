--[[
	BondConfig
	Dragon Bond: the longer you ride ONE dragon, the stronger your bond with it
	(data.Dragons[uid].BondXP, stored per dragon, so everyone has "their" main
	dragon). Bond level is derived from the points; perks unlock by level:

	  level  5   Wind Dash        Q / B       burst of speed
	  level 10   Fire Breath      E (hold)    flames you can aim, burns Burnable things
	  level 20   Sky Dance        Z           showy barrel roll / rear-up flourish
	  level 50   Bond Aura        (automatic) exclusive golden aura around the dragon

	Points: 1 per second ridden on the ground-or-air, more in flight; the server
	only counts seconds in which the dragon actually moved (no AFK farming).
]]

local BondConfig = {}

BondConfig.MaxLevel = 50
BondConfig.PointsScale = 30 -- points needed to REACH level n = PointsScale * n^2
BondConfig.TickSeconds = 5
BondConfig.MinMove = 4 -- studs a dragon must have moved during a tick to earn points

-- Points per second while riding.
BondConfig.Rate = { Ground = 0.6, Fly = 1.0, Boost = 1.5 }

BondConfig.Perks = {
	{ Id = "Dash", Level = 5, Name = "Wind Dash", Key = "Q", Gamepad = "B", Text = "Burst forward in a blink of wind." },
	{ Id = "Fire", Level = 10, Name = "Fire Breath", Key = "E", Gamepad = "LB", Text = "Hold to breathe fire. Burns Burnable things." },
	{ Id = "Flourish", Level = 20, Name = "Sky Dance", Key = "Z", Gamepad = "RB", Text = "A show-off dance: barrel roll in the air, rear up on the ground." },
	{ Id = "Aura", Level = 50, Name = "Bond Aura", Key = nil, Gamepad = nil, Text = "An exclusive golden aura that follows your dragon." },
}

BondConfig.PerkById = {}
for _, p in BondConfig.Perks do
	BondConfig.PerkById[p.Id] = p
end

-- Ability tuning (server validates cooldowns and duration; clients animate).
BondConfig.Abilities = {
	Dash = { Cooldown = 6, Duration = 0.45, Multiplier = 2.7, Allowance = 1.4 },
	Fire = { Cooldown = 3.5, MaxSeconds = 3.5, Range = 46, Tick = 0.25 },
	Flourish = { Cooldown = 7, Duration = 1.7 },
}

function BondConfig.threshold(level: number): number
	return math.floor(BondConfig.PointsScale * level * level)
end

function BondConfig.levelFor(points: number?): number
	local p = math.max(0, tonumber(points) or 0)
	return math.clamp(math.floor(math.sqrt(p / BondConfig.PointsScale)), 0, BondConfig.MaxLevel)
end

-- level, points into the level, points needed for the next one (0 at max)
function BondConfig.progress(points: number?): (number, number, number)
	local p = math.max(0, tonumber(points) or 0)
	local level = BondConfig.levelFor(p)
	if level >= BondConfig.MaxLevel then
		return level, 0, 0
	end
	local base = BondConfig.threshold(level)
	return level, p - base, BondConfig.threshold(level + 1) - base
end

function BondConfig.has(points: number?, perkId: string): boolean
	local perk = BondConfig.PerkById[perkId]
	return perk ~= nil and BondConfig.levelFor(points) >= perk.Level
end

-- Next perk the bond level has not reached yet (nil when all are unlocked).
function BondConfig.nextPerk(level: number)
	for _, p in BondConfig.Perks do
		if level < p.Level then
			return p
		end
	end
	return nil
end

-- Perks unlocked when going from level `from` (exclusive) to `to` (inclusive).
function BondConfig.unlockedBetween(from: number, to: number)
	local out = {}
	for _, p in BondConfig.Perks do
		if p.Level > from and p.Level <= to then
			table.insert(out, p)
		end
	end
	return out
end

return table.freeze(BondConfig)

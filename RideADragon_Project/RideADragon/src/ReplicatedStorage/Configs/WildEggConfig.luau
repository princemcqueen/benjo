--[[
	WildEggConfig
	Lucky Wild Eggs: every few minutes ONE special egg appears somewhere in the world for
	everybody on the server ("A MYTHIC EGG HAS SPAWNED!  02:00"). It is a race: the first
	player (or ridden dragon) to reach it takes it - straight into their hand, with a big luck
	multiplier that applies when it hatches. Nobody there in time: it vanishes.
]]

local WildEggConfig = {}

WildEggConfig.FirstDelay = { Min = 90, Max = 180 } -- seconds after the server started
WildEggConfig.Interval = { Min = 600, Max = 1200 } -- seconds between two wild eggs
WildEggConfig.Lifetime = 120 -- seconds to find it
WildEggConfig.PickupRange = 14 -- studs (character or ridden dragon)
WildEggConfig.ClaimThrottle = 0.6 -- the client asks at most this often

-- Egg: one entry, or a list to pick from. Luck: { min, max } multiplier applied when it hatches.
WildEggConfig.Tiers = {
	{ Id = "Lucky", Name = "LUCKY EGG", Eggs = { "FrostEgg" }, Luck = { 25, 50 }, Weight = 52, Color = Color3.fromRGB(110, 230, 120) },
	{ Id = "Epic", Name = "EPIC EGG", Eggs = { "InfernoEgg", "SkyEgg", "StormEgg" }, Luck = { 60, 150 }, Weight = 30, Color = Color3.fromRGB(190, 120, 255) },
	{ Id = "Mythic", Name = "MYTHIC EGG", Eggs = { "CelestialEgg" }, Luck = { 200, 500 }, Weight = 14, Color = Color3.fromRGB(255, 80, 160) },
	{ Id = "Rainbow", Name = "RAINBOW EGG", Eggs = { "RainbowEgg" }, Luck = { 800, 2000 }, Weight = 4, Color = Color3.fromRGB(255, 150, 225) },
}

WildEggConfig.ById = {}
for _, t in WildEggConfig.Tiers do
	WildEggConfig.ById[t.Id] = t
end

-- Picks a tier (optionally forced), an egg type and a luck value.
function WildEggConfig.roll(rng: Random, forcedTier: string?)
	local tier = forcedTier and WildEggConfig.ById[forcedTier]
	if not tier then
		local total = 0
		for _, t in WildEggConfig.Tiers do
			total += t.Weight
		end
		local r = rng:NextNumber() * total
		for _, t in WildEggConfig.Tiers do
			r -= t.Weight
			if r <= 0 then
				tier = t
				break
			end
		end
		tier = tier or WildEggConfig.Tiers[1]
	end
	local egg = tier.Eggs[rng:NextInteger(1, #tier.Eggs)]
	local luck = rng:NextInteger(tier.Luck[1], tier.Luck[2])
	return tier, egg, luck
end

return table.freeze(WildEggConfig)

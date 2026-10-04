--[[
	CoinConfig
	Coins to collect on the map (CoinService / CoinController / CoinLayout).

	Three kinds:
	  Copper  small coins on trails along the roads: for walkers and low flyers
	  Gold    big sky coins in arcs above the roads: for riders
	  Gem     treasure piles at the landmarks (ruins, waterfall, caves, pillar, island, forests,
	          the ends of the roads): rare and rich

	A coin is worth some seconds of the player's income (so it stays worth picking up as the
	game goes on) with a floor for new players. Coins collected within a short time of each other
	build a CHAIN: every coin in the chain pays a bit more (up to x3). Every player has their
	own coins: they come back on their own timer.
]]

local CoinConfig = {}

CoinConfig.Kinds = {
	Copper = {
		Name = "Coin",
		Code = "c",
		Seconds = 0.6, -- worth this many seconds of income...
		Min = 6, -- ...but at least this much cash
		Respawn = 75, -- seconds until the player sees it again
		Radius = 9, -- pickup radius (studs, client)
		Size = 2.8, -- coin diameter
		Color = Color3.fromRGB(255, 196, 48),
		Rim = Color3.fromRGB(214, 150, 20),
	},
	Gold = {
		Name = "Sky Coin",
		Code = "g",
		Seconds = 2,
		Min = 20,
		Respawn = 100,
		Radius = 16,
		Size = 4.6,
		Color = Color3.fromRGB(255, 226, 90),
		Rim = Color3.fromRGB(255, 160, 30),
	},
	Gem = {
		Name = "Treasure",
		Code = "j",
		Seconds = 30,
		Min = 150,
		Respawn = 600,
		Radius = 14,
		Size = 4.2,
		Color = Color3.fromRGB(90, 230, 255),
		Rim = Color3.fromRGB(190, 110, 255),
	},
}

-- layout string code -> kind id
CoinConfig.KindOfCode = {}
for id, kind in CoinConfig.Kinds do
	CoinConfig.KindOfCode[kind.Code] = id
end

-- Coins collected within `Window` seconds of the previous one extend the chain; each coin of the
-- chain pays (1 + Step * (n - 1)) times its value, at most Max.
CoinConfig.Chain = { Window = 2.5, Step = 0.25, Max = 3 }

-- How far (studs) from a coin the server still accepts the pickup: the radius the client uses
-- plus this slack for lag and the speed of a dragon.
CoinConfig.ServerSlack = 42

-- The client builds the coins within this many studs of the camera / player.
CoinConfig.ViewRadius = 460

-- The client sends the touched coins in batches.
CoinConfig.Batch = { Size = 12, Interval = 0.2 }

-- Layout (the trails and arcs are generated from WorldConfig; see CoinLayout)
CoinConfig.Layout = {
	Spacing = 22, -- studs between the coins of a trail
	Weave = 5, -- the trail swings this far (studs) left and right of the road
	FromHub = 110, -- no coins closer than this to the village centre
	Lift = 3.4, -- height above the ground of a ground coin
	ArcCoins = 9, -- coins in a sky arc
	ArcSpacing = 36, -- studs between the coins of an arc
	ArcLift = { 62, 104 }, -- height above the ground at the ends / the top of an arc
	ArcEvery = 340, -- one arc per this many studs of road
	MaxSlope = 0.55, -- no ground coins where the ground is steeper than this (normal.Y below it)
}

-- Cash a coin is worth right now.
function CoinConfig.value(kindId: string, incomePerSecond: number): number
	local kind = CoinConfig.Kinds[kindId]
	if not kind then
		return 0
	end
	return math.max(kind.Min, math.floor(incomePerSecond * kind.Seconds + 0.5))
end

-- Pay multiplier of the n-th coin of a chain (n = 1 is the first coin).
function CoinConfig.multiplier(n: number): number
	local c = CoinConfig.Chain
	return math.min(c.Max, 1 + c.Step * (math.max(1, n) - 1))
end

return CoinConfig

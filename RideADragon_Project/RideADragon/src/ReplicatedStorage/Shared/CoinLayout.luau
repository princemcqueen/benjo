--[[
	CoinLayout
	Where the coins are. A pure function of the world layout (WorldConfig) and a few height
	queries, so the server (validation) and the tests build exactly the same list; clients get
	the list from CoinService once.

	  CoinLayout.generate(env) -> { { Kind = "Copper" | "Gold" | "Gem", Position = Vector3 } }
	    env.ground(x, z)  -> height, normalY, isWater   terrain only (nil when there is none)
	    env.surface(x, z) -> height | nil               the highest thing of any kind (rooftops,
	                                                    the top of the sky pillar...)

	Copper: trails along every road (swinging a little left and right of it)
	Gold:   arcs above the roads and a ring above the village
	Gem:    treasure piles at the landmarks and the ends of the roads
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local CoinConfig = require(Configs:WaitForChild("CoinConfig"))

local CoinLayout = {}

-- fixed order (dictionaries have no order and the layout must be the same every time)
local ROAD_ORDER = { "North", "East", "South", "West", "Ruins", "Falls" }

local function lengthOf(points: { Vector2 }): number
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
	end
	return total
end

-- Point and direction at distance s along a polyline.
local function pointAt(points: { Vector2 }, s: number): (Vector2, Vector2)
	local left = s
	for i = 2, #points do
		local seg = points[i] - points[i - 1]
		local len = seg.Magnitude
		if left <= len or i == #points then
			local dir = seg / math.max(len, 1e-6)
			return points[i - 1] + dir * math.min(left, len), dir
		end
		left -= len
	end
	return points[#points], Vector2.new(1, 0)
end

-- Landmarks that get a treasure pile: { x, z } (the height comes from env.surface)
local function pileSpots(): { { number } }
	local spots = {}
	local function add(x: number, z: number)
		table.insert(spots, { x, z })
	end
	local ruins = WorldConfig.Ruins
	for i = 0, 2 do
		local a = math.rad(30 + i * 120)
		add(ruins.Center.X + math.cos(a) * ruins.Radius * 0.45, ruins.Center.Z + math.sin(a) * ruins.Radius * 0.45)
	end
	local fall = WorldConfig.Waterfall
	add(fall.Top.X - 46, fall.Top.Z - 70) -- on the plateau above the falls
	add(fall.Bottom.X - 52, fall.Bottom.Z + 26) -- by the pool below
	local caves = WorldConfig.Caves
	add(caves.Mouth.X + math.sin(caves.Facing) * -34, caves.Mouth.Z + math.cos(caves.Facing) * -34)
	add(WorldConfig.SkyPillar.Center.X, WorldConfig.SkyPillar.Center.Z) -- the very top of the pillar
	add(WorldConfig.Lake.Island.Center.X, WorldConfig.Lake.Island.Center.Y)
	for _, forest in WorldConfig.Forests do
		add(forest.Center.X, forest.Center.Y)
	end
	-- the far ends of the roads: where the next regions begin
	for _, name in { "North", "East", "West", "South" } do
		local road = WorldConfig.Roads[name]
		local last = road[#road]
		add(last.X, last.Y)
	end
	return spots
end

function CoinLayout.generate(env): { { Kind: string, Position: Vector3 } }
	local L = CoinConfig.Layout
	local out = {}
	local hub = WorldConfig.Hub.Center
	local hubXZ = Vector2.new(hub.X, hub.Z)
	local function add(kind: string, pos: Vector3)
		table.insert(out, { Kind = kind, Position = pos })
	end

	-- 1) trails of copper coins along the roads
	for _, name in ROAD_ORDER do
		local road = WorldConfig.Roads[name]
		local total = lengthOf(road)
		local s = 0
		while s <= total do
			local p, dir = pointAt(road, s)
			local side = Vector2.new(-dir.Y, dir.X) * (math.sin(s * 0.045) * L.Weave)
			local q = p + side
			if (q - hubXZ).Magnitude >= L.FromHub then
				local y, ny, water = env.ground(q.X, q.Y)
				if y and not water and (ny or 1) >= L.MaxSlope then
					add("Copper", Vector3.new(q.X, y + L.Lift, q.Y))
				end
			end
			s += L.Spacing
		end
	end

	-- 2) a ring of sky coins above the village (the first thing a new rider sees)
	local ringCount = 14
	for i = 0, ringCount - 1 do
		local a = i / ringCount * math.pi * 2
		local x = hub.X + math.cos(a) * 150
		local z = hub.Z + math.sin(a) * 150
		local y = env.ground(x, z)
		if y then
			add("Gold", Vector3.new(x, y + 82 + math.sin(a * 3) * 12, z))
		end
	end

	-- 3) arcs of sky coins above the roads
	for _, name in ROAD_ORDER do
		local road = WorldConfig.Roads[name]
		local total = lengthOf(road)
		local arcLength = L.ArcSpacing * (L.ArcCoins - 1)
		local start = 260
		while start + arcLength < total do
			for i = 0, L.ArcCoins - 1 do
				local p = pointAt(road, start + i * L.ArcSpacing)
				local y = env.ground(p.X, p.Y)
				if y then
					local t = math.sin(math.pi * i / (L.ArcCoins - 1))
					add("Gold", Vector3.new(p.X, y + L.ArcLift[1] + (L.ArcLift[2] - L.ArcLift[1]) * t, p.Y))
				end
			end
			start += L.ArcEvery
		end
	end

	-- 4) treasure piles
	for _, spot in pileSpots() do
		local y = env.surface(spot[1], spot[2])
		if y then
			add("Gem", Vector3.new(spot[1], y + 2.8, spot[2]))
		end
	end
	return out
end

-- The layout as three strings of integers plus the kind codes (compact to send to clients).
function CoinLayout.pack(list: { { Kind: string, Position: Vector3 } }): { X: { number }, Y: { number }, Z: { number }, K: string }
	local X, Y, Z, K = {}, {}, {}, {}
	for i, coin in list do
		X[i] = math.floor(coin.Position.X + 0.5)
		Y[i] = math.floor(coin.Position.Y + 0.5)
		Z[i] = math.floor(coin.Position.Z + 0.5)
		K[i] = CoinConfig.Kinds[coin.Kind].Code
	end
	return { X = X, Y = Y, Z = Z, K = table.concat(K) }
end

function CoinLayout.unpack(packed): { { Kind: string, Position: Vector3 } }
	local out = {}
	for i = 1, #packed.X do
		local code = string.sub(packed.K, i, i)
		out[i] = { Kind = CoinConfig.KindOfCode[code] or "Copper", Position = Vector3.new(packed.X[i], packed.Y[i], packed.Z[i]) }
	end
	return out
end

return CoinLayout

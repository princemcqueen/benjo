--[[
	WorldConfig
	Shared layout of Dragon Haven (server builds it, clients use it for
	markers, objectives and region checks). Coordinates are studs; the valley
	is centered at the origin, north is -Z.

	Composition (top-down):
	                 Frostpeak pass (N)
	      ruins (NW)        waterfall + caves (NE)
	   west forest   HUB (village, statue)   river  east forest -> Ember pass (E)
	  sky pillar (W)    sanctuary ring (8 plots)
	                    lake + grove (S)
]]

local WorldConfig = {}

WorldConfig.MaxPlots = 8

WorldConfig.Hub = {
	Center = Vector3.new(0, 30, 0),
	PlazaRadius = 64,
	VillageRadius = 175,
	Height = 30,
}

WorldConfig.Spawn = CFrame.new(0, 34, 46) * CFrame.Angles(0, 0, 0)

-- Interactable stations around the plaza. Facing = yaw (radians) the
-- building front looks toward (the plaza).
local function yawToward(from: Vector3, to: Vector3): number
	local d = to - from
	return math.atan2(-d.X, -d.Z)
end
WorldConfig.yawToward = yawToward

WorldConfig.Stations = {
	Shop = { Name = "Dragon Market", Position = Vector3.new(0, 30, -118), Window = "Shop", Prompt = "Shop", Radius = 22 },
	Forge = { Name = "Dragonsmith Forge", Position = Vector3.new(-104, 30, -66), Window = "Shop", Tab = "Upgrades", Prompt = "Upgrades", Radius = 22 },
	Library = { Name = "Hall of Dragons", Position = Vector3.new(-122, 30, 32), Window = "Index", Prompt = "Dragon Index", Radius = 22 },
	Quests = { Name = "Elder Rowan", Position = Vector3.new(116, 30, -28), Window = "Quests", Prompt = "Quests", Radius = 20 },
}
for _, s in WorldConfig.Stations do
	s.Facing = yawToward(s.Position, WorldConfig.Hub.Center)
end

-- Personal sanctuary plots (assigned per player). Each plot faces the hub.
WorldConfig.PlotRing = 335
WorldConfig.PlotSize = Vector2.new(124, 104) -- width (across), depth (radial)
WorldConfig.Plots = {}
for i = 1, WorldConfig.MaxPlots do
	local a = math.rad(22.5 + (i - 1) * 45)
	local center = Vector3.new(math.sin(a) * WorldConfig.PlotRing, 0, -math.cos(a) * WorldConfig.PlotRing)
	local height = 34 + ((i % 3) - 1) * 4
	center = Vector3.new(center.X, height, center.Z)
	WorldConfig.Plots[i] = {
		Id = i,
		Center = center,
		Height = height,
		Facing = yawToward(center, WorldConfig.Hub.Center),
	}
end

-- Sanctuary layout in plot-local space: origin on the terrace centre at
-- ground level, -Z toward the gate (and the hub). Perches form a horseshoe
-- around the nest, open toward the gate; unlock order fills from the back
-- centre outward so the first dragons are the most visible.
WorldConfig.Sanctuary = {
	Nest = Vector3.new(0, 0, -6),
	PerchCount = 8,
	PerchRadius = 38,
	PerchSurface = 2.0, -- standing surface height of a perch
	PerchAngles = { -15, 15, -45, 45, -75, 75, -105, 105 }, -- degrees around the nest (0 = back)
	Shrine = Vector3.new(40, 0, -38),
}

-- World frame of a plot (terrace centre at ground level, -Z facing the hub).
function WorldConfig.plotFrame(plotId: number): CFrame?
	local p = WorldConfig.Plots[plotId]
	if not p then
		return nil
	end
	return CFrame.new(p.Center.X, p.Height, p.Center.Z) * CFrame.Angles(0, p.Facing, 0)
end

-- Plot-local frame of perch i at its standing surface; -Z faces the nest.
function WorldConfig.perchLocal(i: number): CFrame
	local s = WorldConfig.Sanctuary
	local a = math.rad(s.PerchAngles[i] or 0)
	local nest = s.Nest
	local pos = Vector3.new(nest.X + math.sin(a) * s.PerchRadius, s.PerchSurface, nest.Z + math.cos(a) * s.PerchRadius)
	return CFrame.lookAt(pos, Vector3.new(nest.X, s.PerchSurface, nest.Z))
end

function WorldConfig.perchWorld(plotId: number, i: number): CFrame?
	local f = WorldConfig.plotFrame(plotId)
	return f and f * WorldConfig.perchLocal(i) or nil
end

-- River (polyline in XZ, source -> lake) with water levels at both ends.
WorldConfig.River = {
	Points = {
		Vector2.new(424, -742),
		Vector2.new(452, -600),
		Vector2.new(486, -430),
		Vector2.new(470, -220),
		Vector2.new(452, -20),
		Vector2.new(474, 170),
		Vector2.new(430, 380),
		Vector2.new(330, 560),
		Vector2.new(214, 676),
	},
	WaterStart = 37,
	WaterEnd = 25,
	HalfWidthStart = 13,
	HalfWidthEnd = 20,
	Depth = 8,
	Bank = 20,
}

-- Upper stream on the cliff plateau that feeds the waterfall.
WorldConfig.UpperStream = {
	Points = { Vector2.new(400, -1010), Vector2.new(416, -900), Vector2.new(424, -786) },
	Water = 176,
	HalfWidth = 11,
	Depth = 6,
}

WorldConfig.Waterfall = {
	Top = Vector3.new(424, 176, -786),
	Bottom = Vector3.new(424, 37, -748),
	Width = 34,
	CliffZ = -774, -- cliff face line (plateau north of it)
	CliffX = { 300, 560 },
	PlateauHeight = 182,
}

WorldConfig.Lake = {
	Center = Vector2.new(150, 742),
	Radius = 196,
	Water = 25,
	Island = { Center = Vector2.new(196, 790), Radius = 34, Height = 33 },
}

WorldConfig.Ruins = { Center = Vector3.new(-500, 0, -540), Radius = 120, Height = 78 }
WorldConfig.Caves = { Mouth = Vector3.new(706, 0, -600), Facing = math.rad(220), Depth = 150 }
WorldConfig.SkyPillar = { Center = Vector3.new(-905, 0, 300), Radius = 48, Height = 360 }

WorldConfig.Forests = {
	{ Name = "Westwood", Center = Vector2.new(-560, -40), Radius = 330, Density = 1 },
	{ Name = "Eastwood", Center = Vector2.new(690, 60), Radius = 250, Density = 0.85 },
	{ Name = "Lakeside Grove", Center = Vector2.new(-120, 640), Radius = 200, Density = 0.6 },
	{ Name = "North Pines", Center = Vector2.new(-180, -720), Radius = 210, Density = 0.75 },
}

-- Region gates (positions from RegionConfig)
WorldConfig.Passes = {
	North = { Angle = math.rad(-7), Width = math.rad(9), Height = 128 }, -- toward Frostpeak
	East = { Angle = math.rad(78), Width = math.rad(8), Height = 92 }, -- toward Ember Caldera
}

-- Roads (XZ polylines) drawn as dirt paths; village streets are cobblestone.
WorldConfig.Roads = {
	North = { Vector2.new(-34, -58), Vector2.new(-62, -150), Vector2.new(-52, -300), Vector2.new(-90, -620), Vector2.new(-120, -1000) },
	East = { Vector2.new(70, 0), Vector2.new(300, 40), Vector2.new(455, 96), Vector2.new(700, 160), Vector2.new(1060, 220) },
	South = { Vector2.new(0, 70), Vector2.new(30, 300), Vector2.new(110, 520) },
	West = { Vector2.new(-70, 0), Vector2.new(-320, 60), Vector2.new(-620, 180), Vector2.new(-860, 290) },
	Ruins = { Vector2.new(-60, -60), Vector2.new(-300, -330), Vector2.new(-470, -500) },
	Falls = { Vector2.new(60, -60), Vector2.new(280, -420), Vector2.new(400, -700) },
}

WorldConfig.Bridges = {
	{ Name = "East Bridge", Road = "East" },
}

return WorldConfig

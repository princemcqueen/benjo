--[[
	RegionConfig
	World regions, unlock gates and per-region atmosphere.
	Bounds are horizontal circles (Center X/Z, Radius) used for region
	detection, lighting blends and egg spawns.
]]

local RegionConfig = {}

RegionConfig.Order = { "Haven", "Frostpeak", "EmberCaldera", "Skyreach" }

RegionConfig.Regions = {
	Haven = {
		Name = "Dragon Haven",
		Center = Vector2.new(0, 0),
		Radius = 1050,
		RequiredLevel = 1,
		Cost = 0,
		Music = "MusicHaven",
		Atmosphere = {
			Density = 0.3,
			Haze = 1.4,
			Color = Color3.fromRGB(205, 214, 232),
			Decay = Color3.fromRGB(120, 132, 156),
			Tint = Color3.fromRGB(255, 251, 244),
			Saturation = 0.08,
		},
	},
	Frostpeak = {
		Name = "Frostpeak Highlands",
		Center = Vector2.new(-150, -1650),
		Radius = 640,
		RequiredLevel = 5,
		Cost = 25000,
		Music = "MusicFrost",
		GatePosition = Vector3.new(-120, 132, -1010),
		Atmosphere = {
			Density = 0.38,
			Haze = 2.1,
			Color = Color3.fromRGB(214, 228, 245),
			Decay = Color3.fromRGB(150, 175, 205),
			Tint = Color3.fromRGB(236, 246, 255),
			Saturation = -0.02,
		},
	},
	EmberCaldera = {
		Name = "Ember Caldera",
		Center = Vector2.new(1700, 300),
		Radius = 620,
		RequiredLevel = 12,
		Cost = 5000000,
		Music = "MusicEmber",
		GatePosition = Vector3.new(1080, 96, 220),
		Atmosphere = {
			Density = 0.42,
			Haze = 2.4,
			Color = Color3.fromRGB(240, 190, 160),
			Decay = Color3.fromRGB(150, 80, 60),
			Tint = Color3.fromRGB(255, 236, 222),
			Saturation = 0.1,
		},
	},
	Skyreach = {
		Name = "Skyreach Isles",
		Center = Vector2.new(-1600, 450),
		Radius = 600,
		RequiredLevel = 20,
		Cost = 1000000000,
		Music = "MusicSky",
		MinHeight = 380,
		GatePosition = Vector3.new(-1060, 420, 330),
		Atmosphere = {
			Density = 0.24,
			Haze = 0.9,
			Color = Color3.fromRGB(220, 232, 250),
			Decay = Color3.fromRGB(160, 180, 230),
			Tint = Color3.fromRGB(250, 248, 255),
			Saturation = 0.05,
		},
	},
}

-- Returns region id for a world position (closest region whose circle contains it).
function RegionConfig.regionAt(position: Vector3): string
	local best, bestDist = "Haven", math.huge
	for id, r in RegionConfig.Regions do
		local d = (Vector2.new(position.X, position.Z) - r.Center).Magnitude
		if d <= r.Radius and d / r.Radius < bestDist then
			if not r.MinHeight or position.Y >= r.MinHeight - 120 then
				best, bestDist = id, d / r.Radius
			end
		end
	end
	return best
end

return table.freeze(RegionConfig)

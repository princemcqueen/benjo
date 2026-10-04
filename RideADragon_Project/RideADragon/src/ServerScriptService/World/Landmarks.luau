--[[
	Landmarks - plaza statue + fountain, stone bridges, the Ruins of Aldermere,
	the Silverfall waterfall, Emberdeep cave decor and the Sky Pillar islands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent:WaitForChild("Kit"))

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local C = Kit.C
local M = Kit.M

local Landmarks = {}

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

-- ============================================================== statue
-- Central dragon statue on a tiered plinth inside a fountain basin.
function Landmarks.statue(parent: Instance, at: Vector3, speciesId: string?)
	local b = Kit.new(parent, CF(at), "DragonStatue")
	local marble = Color3.fromRGB(206, 200, 188)
	-- fountain basin
	b:cyl(1.6, 40, V(0, 0.8, 0), C.Stone, M.Cobblestone)
	b:cyl(2.4, 41.5, V(0, 1.2, 0), C.StoneDark, M.Slate, { Transparency = 0 })
	b:cyl(0.6, 37.5, V(0, 2.1, 0), C.Water, M.Glass, { Transparency = 0.35, CanCollide = false })
	-- inner pool rim (hollow look: dark ring)
	b:cyl(2.5, 37, V(0, 1.15, 0), Color3.fromRGB(46, 70, 80), M.Slate)
	-- plinth tiers
	b:cyl(2, 20, V(0, 3, 0), marble, M.Limestone)
	b:cyl(2, 16, V(0, 5, 0), marble, M.Marble)
	b:box(V(11, 7, 11), V(0, 9.5, 0), marble, M.Marble)
	b:box(V(12.4, 1, 12.4), V(0, 13.5, 0), C.Gold, M.Foil)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			b:box(V(1.4, 7, 1.4), V(sx * 5.5, 9.5, sz * 5.5), C.Gold, M.Foil)
		end
	end
	-- water jets
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local spout = b:box(V(1.2, 1.2, 1.2), V(math.cos(a) * 10.5, 4.6, math.sin(a) * 10.5), marble, M.Marble)
		local att = Instance.new("Attachment")
		att.Parent = spout
		local pe = Instance.new("ParticleEmitter")
		pe.Texture = SPARKLE
		pe.Color = ColorSequence.new(Color3.fromRGB(200, 236, 255))
		pe.LightEmission = 0.4
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		pe.Size = NumberSequence.new(0.6, 0.2)
		pe.Lifetime = NumberRange.new(0.7, 0.9)
		pe.Rate = 30
		pe.Speed = NumberRange.new(9, 11)
		pe.SpreadAngle = Vector2.new(4, 4)
		pe.Acceleration = V(0, -24, 0)
		pe.EmissionDirection = Enum.NormalId.Top
		pe.Parent = att
		att.CFrame = CF(0, 0.6, 0) * ANG(0, 0, -math.cos(a) * 0.5) * ANG(math.sin(a) * 0.5, 0, 0)
	end
	-- the dragon: skinned mesh template in stone if available, else part statue
	local top = at + V(0, 14, 0)
	local ok = pcall(function()
		local DragonVisual = require(ReplicatedStorage.Shared.Dragons.DragonVisual)
		local id = speciesId or "GreenDrake"
		if DragonVisual.hasMesh(id) then
			local model = DragonVisual.build(id, { ScaleOverride = 1.15 })
			local mesh = model:FindFirstChildWhichIsA("MeshPart", true)
			for _, d in model:GetDescendants() do
				if d:IsA("SurfaceAppearance") then
					d:Destroy()
				end
			end
			if mesh then
				mesh.TextureID = ""
				mesh.Material = Enum.Material.Marble
				mesh.Color = Color3.fromRGB(196, 190, 178)
			end
			model.Name = "StatueDragon"
			model.Parent = b.Model
			local Species = require(ReplicatedStorage.Shared.Dragons.Species)
			local def = Species.get(id)
			local hip = def.HipHeight * (def.Scale or 1) * 1.15
			DragonVisual.pose(model, nil, CF(top + V(0, hip, 0)) * ANG(0, math.pi, 0))
		else
			local Builder = require(ReplicatedStorage.Shared.Dragons.Builder)
			local Species = require(ReplicatedStorage.Shared.Dragons.Species)
			local model = Builder.build(id, { Statue = true, StatueColor = Color3.fromRGB(196, 190, 178), Saddle = false })
			local def = Species.get(id)
			local hip = def.HipHeight * (def.Scale or 1)
			Builder.pose(model, nil, CF(top + V(0, hip, 0)) * ANG(0, math.pi, 0))
			model.Name = "StatueDragon"
			model.Parent = b.Model
		end
	end)
	if not ok then
		warn("[World] statue dragon failed")
	end
	return b.Model
end

-- ============================================================== bridge
-- Stone arch bridge; local -Z runs along the road. data: Span, Deck, Water, Width.
function Landmarks.bridge(parent: Instance, data)
	local origin = CF(data.X, data.Deck, data.Z) * ANG(0, data.Yaw, 0)
	local b = Kit.new(parent, origin, "Bridge")
	local span, wdt = data.Span, data.Width
	local depth = data.Deck - (data.Water - 9)
	-- deck
	b:box(V(wdt, 1.6, span), V(0, -0.8, 0), C.Stone, M.Cobblestone)
	b:box(V(wdt - 2, 0.3, span), V(0, 0.15, 0), C.Planks, M.WoodPlanks)
	-- arch made of segments under the deck
	local n = 9
	for i = 0, n - 1 do
		local t0, t1 = i / n, (i + 1) / n
		local z0 = -span / 2 + span * t0
		local z1 = -span / 2 + span * t1
		local a0 = math.sin(t0 * math.pi)
		local a1 = math.sin(t1 * math.pi)
		local y0 = -depth + a0 * (depth - 2.5)
		local y1 = -depth + a1 * (depth - 2.5)
		b:beam(V(0, y0, z0), V(0, y1, z1), 1, C.StoneDark, M.Slate, { Size = V(wdt, 2.2, math.abs(z1 - z0) + 0.6) })
		-- spandrel fill between the arch and the deck
		local zm = (z0 + z1) / 2
		local ym = (y0 + y1) / 2
		local hfill = -1.6 - ym
		if hfill > 0.5 then
			b:box(V(wdt - 0.6, hfill, math.abs(z1 - z0)), V(0, ym + hfill / 2, zm), C.Stone, M.Cobblestone)
		end
	end
	-- parapets with posts and lanterns
	for _, sx in { -1, 1 } do
		b:box(V(1.2, 2.6, span), V(sx * (wdt / 2 - 0.6), 1.3, 0), C.StoneWarm, M.Cobblestone)
		b:box(V(1.6, 0.5, span + 0.4), V(sx * (wdt / 2 - 0.6), 2.85, 0), C.Stone, M.Slate)
		for _, sz in { -1, 1 } do
			b:box(V(2.2, 4.2, 2.2), V(sx * (wdt / 2 - 0.6), 2.1, sz * (span / 2 - 1.1)), C.StoneDark, M.Cobblestone)
			b:lampPost(V(sx * (wdt / 2 - 0.6), 4.2, sz * (span / 2 - 1.1)), 5)
		end
	end
	-- piers into the river bed
	for _, sz in { -1, 1 } do
		b:box(V(wdt + 1, depth + 4, 4), V(0, -depth / 2 - 2, sz * (span / 2 - 2)), C.StoneDark, M.Slate)
	end
	return b.Model
end

-- ============================================================== ruins
function Landmarks.ruins(parent: Instance, center: Vector3, groundAt: (number, number) -> number)
	local b = Kit.new(parent, CF(center), "RuinsOfAldermere")
	local rng = Random.new(1337)
	local stone = Color3.fromRGB(176, 168, 150)
	local moss = Color3.fromRGB(96, 118, 70)
	local function gy(x: number, z: number): number
		return groundAt(center.X + x, center.Z + z) - center.Y
	end
	-- ring colonnade
	local R = 34
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		local x, z = math.cos(a) * R, math.sin(a) * R
		local y = gy(x, z)
		local broken = rng:NextNumber()
		local h = broken < 0.35 and rng:NextNumber(4, 9) or 18
		b:box(V(3.6, 1.2, 3.6), V(x, y + 0.2, z), stone, M.Limestone)
		if broken < 0.12 then
			-- fallen column lying on the ground
			local fa = rng:NextNumber(0, math.pi * 2)
			b:cylX(14, 2.6, CF(x + math.cos(fa) * 7, y + 1.3, z + math.sin(fa) * 7) * ANG(0, fa, 0), stone, M.Limestone)
		else
			b:cyl(h, 2.6, V(x, y + 0.8 + h / 2, z), stone, M.Limestone)
			if h >= 18 then
				b:box(V(3.8, 1.2, 3.8), V(x, y + 0.8 + h + 0.6, z), stone, M.Limestone)
			end
			b:box(V(2.7, 0.3, 2.7), V(x, y + 0.8 + h - 0.1, z), moss, M.LeafyGrass, { CastShadow = false })
		end
	end
	-- lintels connecting standing column tops on one side
	for i = 0, 5 do
		local a0 = (i + 1) / 16 * math.pi * 2
		local a1 = (i + 2) / 16 * math.pi * 2
		local p0 = V(math.cos(a0) * R, gy(math.cos(a0) * R, math.sin(a0) * R) + 20.6, math.sin(a0) * R)
		local p1 = V(math.cos(a1) * R, gy(math.cos(a1) * R, math.sin(a1) * R) + 20.6, math.sin(a1) * R)
		if i ~= 3 then
			b:beam(p0, p1, 1, stone, M.Limestone, { Size = V(3, 2, (p1 - p0).Magnitude + 2) })
		end
	end
	-- central altar with a rune circle
	local ay = gy(0, 0)
	b:cyl(1, 22, V(0, ay + 0.4, 0), stone:Lerp(Color3.new(0, 0, 0), 0.15), M.Slate)
	b:cyl(1, 16, V(0, ay + 1.2, 0), stone, M.Limestone)
	b:box(V(8, 4, 5), V(0, ay + 3.6, 0), stone, M.Marble)
	local rune = b:cyl(0.2, 21, V(0, ay + 0.95, 0), Color3.fromRGB(110, 210, 255), M.Neon, { Transparency = 0.55, CastShadow = false, CanCollide = false })
	rune.Name = "RuneCircle"
	local orb = b:ball(2.2, V(0, ay + 7.4, 0), Color3.fromRGB(140, 220, 255), M.Neon, { CastShadow = false })
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(140, 220, 255)
	pl.Range = 30
	pl.Brightness = 2
	pl.Parent = orb
	-- broken arches + scattered blocks
	for k = 1, 3 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(48, 70)
		local x, z = math.cos(a) * r, math.sin(a) * r
		local y = gy(x, z)
		local yaw = rng:NextNumber(0, math.pi)
		local arch = b:sub("Arch" .. k, CF(x, y, z) * ANG(0, yaw, 0))
		arch:box(V(4, 16, 4), V(-7, 8, 0), stone, M.Limestone)
		arch:box(V(4, k == 2 and 9 or 16, 4), V(7, (k == 2 and 9 or 16) / 2, 0), stone, M.Limestone)
		if k ~= 2 then
			arch:box(V(18, 3, 4.2), V(0, 17.5, 0), stone, M.Limestone)
		end
	end
	for _ = 1, 22 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(20, 80)
		local x, z = math.cos(a) * r, math.sin(a) * r
		local s = rng:NextNumber(2, 5)
		b:box(V(s * 1.4, s, s), CF(x, gy(x, z) + s * 0.35, z) * ANG(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6), rng:NextNumber(-0.3, 0.3)),
			stone:Lerp(moss, rng:NextNumber(0, 0.25)), M.Limestone)
	end
	return b.Model
end

-- ============================================================== waterfall
function Landmarks.waterfall(parent: Instance, top: Vector3, bottom: Vector3, width: number)
	local folder = Instance.new("Model")
	folder.Name = "Silverfall"
	folder.Parent = parent
	local anchor = Instance.new("Part")
	anchor.Name = "FallAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = V(1, 1, 1)
	anchor.CFrame = CF(top)
	anchor.Parent = folder
	local n = 7
	for i = 0, n - 1 do
		local off = (i / (n - 1) - 0.5) * width
		local a0 = Instance.new("Attachment")
		a0.WorldPosition = top + V(off, 0, 0)
		a0.Parent = anchor
		local a1 = Instance.new("Attachment")
		a1.WorldPosition = bottom + V(off * 1.15, 0, 0)
		a1.Parent = anchor
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Texture = SMOKE
		beam.TextureMode = Enum.TextureMode.Wrap
		beam.TextureLength = 18
		beam.TextureSpeed = 2.2 + (i % 3) * 0.35
		beam.Width0 = width / n * 1.6
		beam.Width1 = width / n * 2.1
		beam.LightEmission = 0.35
		beam.LightInfluence = 0.6
		beam.Color = ColorSequence.new(Color3.fromRGB(226, 242, 255))
		beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.85, 0.35), NumberSequenceKeypoint.new(1, 0.7) })
		beam.FaceCamera = true
		beam.Segments = 12
		beam.CurveSize0 = -6
		beam.CurveSize1 = 4
		beam.Parent = anchor
	end
	-- mist at the foot
	local mistPart = Instance.new("Part")
	mistPart.Name = "Mist"
	mistPart.Anchored = true
	mistPart.CanCollide = false
	mistPart.CanQuery = false
	mistPart.Transparency = 1
	mistPart.Size = V(width, 2, 12)
	mistPart.CFrame = CF(bottom + V(0, 2, 0))
	mistPart.Parent = folder
	local mist = Instance.new("ParticleEmitter")
	mist.Texture = SMOKE
	mist.Color = ColorSequence.new(Color3.fromRGB(240, 248, 255))
	mist.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 8), NumberSequenceKeypoint.new(1, 22) })
	mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
	mist.Lifetime = NumberRange.new(3, 5)
	mist.Rate = 14
	mist.Speed = NumberRange.new(4, 8)
	mist.SpreadAngle = Vector2.new(60, 60)
	mist.Acceleration = V(0, 2, 0)
	mist.LightEmission = 0.2
	mist.Parent = mistPart
	return folder
end

-- ============================================================== cave decor
function Landmarks.caveDecor(parent: Instance, path: { Vector3 })
	local b = Kit.new(parent, CFrame.identity, "Emberdeep")
	local rng = Random.new(77)
	for i, p in path do
		if i > 1 then
			for _ = 1, 4 do
				local off = V(rng:NextNumber(-12, 12), rng:NextNumber(-12, -6), rng:NextNumber(-12, 12))
				local h = rng:NextNumber(3, 8)
				local col = (i % 2 == 0) and Color3.fromRGB(255, 120, 60) or Color3.fromRGB(150, 110, 255)
				local gem = b:box(V(1.4, h, 1.4), CF(p + off) * ANG(rng:NextNumber(-0.4, 0.4), rng:NextNumber(0, 6), rng:NextNumber(-0.4, 0.4)),
					col, M.Neon, { CastShadow = false, Transparency = 0.05 })
				gem.Name = "Crystal"
			end
			local light = b:box(V(1, 1, 1), p + V(0, -4, 0), Color3.new(1, 1, 1), M.SmoothPlastic, { Transparency = 1, CanCollide = false, CanQuery = false })
			local pl = Instance.new("PointLight")
			pl.Color = (i % 2 == 0) and Color3.fromRGB(255, 140, 80) or Color3.fromRGB(170, 130, 255)
			pl.Range = 34
			pl.Brightness = 1.8
			pl.Parent = light
		end
	end
	return b.Model
end

-- ============================================================== sky pillar islands
function Landmarks.skyIslands(parent: Instance, terrain: Terrain, center: Vector3, height: number)
	local rng = Random.new(2024)
	local b = Kit.new(parent, CFrame.identity, "SkyPillar")
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local r = rng:NextNumber(90, 150)
		local y = rng:NextNumber(height * 0.45, height * 0.95)
		local p = center + V(math.cos(a) * r, y, math.sin(a) * r)
		local s = rng:NextNumber(10, 18)
		pcall(function()
			terrain:FillBall(p, s, Enum.Material.Rock)
			terrain:FillBall(p + V(0, s * 0.45, 0), s * 0.9, Enum.Material.Grass)
			terrain:FillBall(p + V(0, -s * 0.6, 0), s * 0.6, Enum.Material.Rock)
		end)
		for _ = 1, 3 do
			local off = V(rng:NextNumber(-s * 0.5, s * 0.5), -s * 0.9, rng:NextNumber(-s * 0.5, s * 0.5))
			b:box(V(1.2, 5, 1.2), CF(p + off) * ANG(math.pi + rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6), 0),
				Color3.fromRGB(120, 210, 255), M.Neon, { CastShadow = false })
		end
	end
	-- shrine on top of the pillar
	local topP = center + V(0, height + 2, 0)
	b:cyl(2, 26, topP + V(0, 1, 0), Color3.fromRGB(176, 168, 150), M.Limestone)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		b:cyl(10, 2, topP + V(math.cos(a) * 11, 6, math.sin(a) * 11), Color3.fromRGB(196, 190, 178), M.Marble)
	end
	local orb = b:ball(3.6, topP + V(0, 7, 0), Color3.fromRGB(150, 230, 255), M.Neon, { CastShadow = false })
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(150, 230, 255)
	pl.Range = 40
	pl.Brightness = 2.5
	pl.Parent = orb
	return b.Model
end

return Landmarks

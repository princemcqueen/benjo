--[[
	Kit - building toolkit for world structures.

	A Builder places anchored parts in a local frame (Origin CFrame; local -Z
	is the building's front). Recipes stay readable:
	    local b = Kit.new(parent, CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0), "Cottage")
	    b:box(Vector3.new(12, 1, 10), V(0, 0.5, 0), Kit.C.Stone, Kit.M.Slate)
	All positions given to a Builder are in its local frame.
]]

local Kit = {}

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local C3 = Color3.fromRGB
Kit.V = V

Kit.M = Enum.Material

-- One cohesive palette for Dragon Haven (stone, timber, plaster, slate, gold).
Kit.C = {
	Stone = C3(128, 124, 116),
	StoneDark = C3(92, 90, 86),
	StoneWarm = C3(150, 138, 118),
	Cobble = C3(112, 106, 98),
	Plaster = C3(222, 210, 186),
	PlasterWarm = C3(214, 192, 158),
	Timber = C3(84, 60, 42),
	TimberLight = C3(124, 92, 62),
	Planks = C3(132, 100, 70),
	RoofSlate = C3(70, 78, 92),
	RoofSlateDark = C3(52, 58, 70),
	RoofClay = C3(150, 84, 58),
	RoofMoss = C3(88, 96, 70),
	Gold = C3(206, 166, 86),
	Iron = C3(62, 62, 66),
	BannerRed = C3(126, 30, 38),
	BannerBlue = C3(38, 62, 126),
	BannerGreen = C3(40, 96, 62),
	Window = C3(255, 196, 120),
	Fabric = C3(176, 150, 112),
	Leaf = C3(70, 108, 52),
	Water = C3(70, 140, 170),
}

local Builder = {}
Builder.__index = Builder

function Kit.new(parent: Instance, origin: CFrame, name: string?): any
	local model = Instance.new("Model")
	model.Name = name or "Structure"
	model.Parent = parent
	local self = setmetatable({ Model = model, Origin = origin, Count = 0 }, Builder)
	return self
end

-- Child builder (same frame unless offset) in a sub-model.
function Builder:sub(name: string, offset: CFrame?)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = self.Model
	return setmetatable({ Model = m, Origin = self.Origin * (offset or CFrame.identity), Count = 0, Root = self.Root or self }, Builder)
end

function Builder:world(localCF: CFrame): CFrame
	return self.Origin * localCF
end

local function finish(self, p: BasePart, color: Color3?, material: Enum.Material?, props: { [string]: any }?)
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if color then
		p.Color = color
	end
	p.Material = material or Enum.Material.SmoothPlastic
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = self.Model
	self.Count += 1
	local root = self.Root or self
	root.Total = (root.Total or 0) + 1
	return p
end

local function toCF(at: any): CFrame
	if typeof(at) == "Vector3" then
		return CF(at)
	end
	return at
end

-- Axis-aligned (in local frame) box. `at` = Vector3 center or local CFrame.
function Builder:box(size: Vector3, at: any, color: Color3?, material: Enum.Material?, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = self.Origin * toCF(at)
	return finish(self, p, color, material, props) :: Part
end

-- Wedge: slope rises toward local -Z... (Roblox wedge: high at back (+Z), low at front (-Z)).
function Builder:wedge(size: Vector3, at: any, color: Color3?, material: Enum.Material?, props: { [string]: any }?): WedgePart
	local p = Instance.new("WedgePart")
	p.Size = size
	p.CFrame = self.Origin * toCF(at)
	return finish(self, p, color, material, props) :: WedgePart
end

-- Cylinder standing upright (height along local Y).
function Builder:cyl(height: number, diameter: number, at: any, color: Color3?, material: Enum.Material?, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Size = V(height, diameter, diameter)
	p.CFrame = self.Origin * toCF(at) * ANG(0, 0, math.rad(90))
	return finish(self, p, color, material, props) :: Part
end

-- Cylinder lying along local X.
function Builder:cylX(length: number, diameter: number, at: any, color: Color3?, material: Enum.Material?, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Size = V(length, diameter, diameter)
	p.CFrame = self.Origin * toCF(at)
	return finish(self, p, color, material, props) :: Part
end

function Builder:ball(diameter: number, at: any, color: Color3?, material: Enum.Material?, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = V(diameter, diameter, diameter)
	p.CFrame = self.Origin * toCF(at)
	return finish(self, p, color, material, props) :: Part
end

-- Beam between two local points (square cross-section).
function Builder:beam(a: Vector3, b: Vector3, thickness: number, color: Color3?, material: Enum.Material?, props: { [string]: any }?): Part?
	local d = b - a
	local len = d.Magnitude
	if len < 1e-3 then
		return nil
	end
	local cf = CFrame.lookAt((a + b) / 2, b, math.abs(d.Unit.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis)
	return self:box(V(thickness, thickness, len), cf, color, material, props)
end

-- Gable roof centred at `at` (local), ridge along local Z.
-- w = width across (X), d = depth (Z), h = ridge height above eaves, o = overhang.
function Builder:gableRoof(w: number, d: number, h: number, o: number, at: Vector3, color: Color3, material: Enum.Material?, thick: number?)
	local t = thick or 0.8
	local half = w / 2 + o
	local ang = math.atan2(h, w / 2)
	local L = half / math.cos(ang)
	local mat = material or Enum.Material.RoofShingles
	for _, s in { -1, 1 } do
		local cx = at.X + s * (half / 2)
		local cy = at.Y + h / 2 - (o / 2) * math.tan(ang) + t * 0.5
		local cf = CF(cx, cy, at.Z) * ANG(0, 0, s * -ang)
		self:box(V(L + 0.4, t, d + o * 2), cf, color, mat)
	end
	-- ridge cap
	self:box(V(0.9, 0.9, d + o * 2 + 0.2), CF(at.X, at.Y + h + t * 0.35, at.Z) * ANG(0, 0, math.rad(45)), color:Lerp(Color3.new(0, 0, 0), 0.2), mat)
end

-- Triangular gable wall (two wedges) at local z, spanning width w, height h.
function Builder:gableWall(w: number, h: number, thickness: number, at: Vector3, color: Color3, material: Enum.Material?)
	local half = w / 2
	-- a wedge is full height at its local +Z face; yaw +90 points that face to +X
	-- (the ridge) for the left half, yaw -90 to -X for the right half
	self:wedge(V(thickness, h, half), CF(at.X - half / 2, at.Y + h / 2, at.Z) * ANG(0, math.rad(90), 0), color, material)
	self:wedge(V(thickness, h, half), CF(at.X + half / 2, at.Y + h / 2, at.Z) * ANG(0, math.rad(-90), 0), color, material)
end

-- Warm window: glass pane + light glow + frame.
function Builder:window(at: CFrame, w: number, h: number, frameColor: Color3?, lit: boolean?)
	local fc = frameColor or Kit.C.Timber
	self:box(V(w, h, 0.25), at, Kit.C.Window, Enum.Material.Glass, { Transparency = 0.35, CastShadow = false })
	local glow = self:box(V(w - 0.3, h - 0.3, 0.12), at * CF(0, 0, 0.18), Kit.C.Window, Enum.Material.Neon,
		{ Transparency = lit == false and 1 or 0.55, CastShadow = false, CanCollide = false })
	glow.Name = "WindowGlow"
	self:box(V(w + 0.5, 0.35, 0.5), at * CF(0, -h / 2 - 0.1, -0.05), fc, Enum.Material.Wood)
	self:box(V(w + 0.5, 0.3, 0.45), at * CF(0, h / 2 + 0.1, -0.05), fc, Enum.Material.Wood)
	self:box(V(0.3, h, 0.45), at * CF(-w / 2 - 0.1, 0, -0.05), fc, Enum.Material.Wood)
	self:box(V(0.3, h, 0.45), at * CF(w / 2 + 0.1, 0, -0.05), fc, Enum.Material.Wood)
	self:box(V(0.18, h, 0.3), at * CF(0, 0, -0.08), fc, Enum.Material.Wood)
end

function Builder:door(at: CFrame, w: number, h: number)
	self:box(V(w, h, 0.4), at, Kit.C.Planks, Enum.Material.WoodPlanks)
	self:box(V(w + 0.8, 0.5, 0.6), at * CF(0, h / 2 + 0.25, -0.1), Kit.C.Timber, Enum.Material.Wood)
	self:box(V(0.4, h, 0.6), at * CF(-w / 2 - 0.2, 0, -0.1), Kit.C.Timber, Enum.Material.Wood)
	self:box(V(0.4, h, 0.6), at * CF(w / 2 + 0.2, 0, -0.1), Kit.C.Timber, Enum.Material.Wood)
	self:ball(0.35, at * CF(w * 0.32, 0, -0.3), Kit.C.Gold, Enum.Material.Metal)
end

-- Lantern on a post with a warm PointLight.
function Builder:lampPost(at: Vector3, height: number?)
	local h = height or 9
	self:cyl(h, 0.6, at + V(0, h / 2, 0), Kit.C.Iron, Enum.Material.Metal)
	self:box(V(1.8, 0.3, 0.3), at + V(0.6, h - 0.4, 0), Kit.C.Iron, Enum.Material.Metal)
	local lamp = self:box(V(1.0, 1.3, 1.0), at + V(1.3, h - 1.3, 0), Kit.C.Window, Enum.Material.Neon,
		{ Transparency = 0.15, CastShadow = false })
	lamp.Name = "Lamp"
	self:box(V(1.3, 0.25, 1.3), at + V(1.3, h - 0.55, 0), Kit.C.Iron, Enum.Material.Metal)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 190, 120)
	light.Range = 20
	light.Brightness = 1.4
	light.Shadows = false
	light.Parent = lamp
	return lamp
end

function Builder:banner(at: CFrame, w: number, h: number, color: Color3)
	self:box(V(w + 1, 0.35, 0.35), at * CF(0, h / 2 + 0.2, 0), Kit.C.Timber, Enum.Material.Wood)
	self:box(V(w, h, 0.12), at, color, Enum.Material.Fabric, { CastShadow = false })
	self:box(V(w, 0.22, 0.16), at * CF(0, -h / 2 + 0.6, -0.02), Kit.C.Gold, Enum.Material.Foil, { CastShadow = false })
	self:box(V(w * 0.42, w * 0.42, 0.14), at * CF(0, h * 0.12, -0.03) * ANG(0, 0, math.rad(45)), Kit.C.Gold, Enum.Material.Foil, { CastShadow = false })
end

function Builder:crate(at: CFrame, s: number?)
	local k = s or 3
	self:box(V(k, k, k), at, Kit.C.Planks, Enum.Material.WoodPlanks)
	self:box(V(k + 0.1, 0.3, k + 0.1), at * CF(0, k / 2 - 0.25, 0), Kit.C.Timber, Enum.Material.Wood)
	self:box(V(k + 0.1, 0.3, k + 0.1), at * CF(0, -k / 2 + 0.25, 0), Kit.C.Timber, Enum.Material.Wood)
end

function Builder:barrel(at: Vector3, s: number?)
	local k = s or 1
	self:cyl(3.2 * k, 2.4 * k, at + V(0, 1.6 * k, 0), Kit.C.TimberLight, Enum.Material.Wood)
	self:cyl(0.3, 2.55 * k, at + V(0, 0.6 * k, 0), Kit.C.Iron, Enum.Material.Metal)
	self:cyl(0.3, 2.55 * k, at + V(0, 2.6 * k, 0), Kit.C.Iron, Enum.Material.Metal)
end

-- Low stone wall segment between two local points (on the ground).
function Builder:stoneWall(a: Vector3, b: Vector3, height: number, thickness: number, color: Color3?)
	local d = b - a
	local len = Vector3.new(d.X, 0, d.Z).Magnitude
	if len < 0.5 then
		return
	end
	local mid = (a + b) / 2
	local cf = CFrame.lookAt(V(mid.X, mid.Y + height / 2, mid.Z), V(b.X, mid.Y + height / 2, b.Z))
	self:box(V(thickness, height, len), cf, color or Kit.C.Stone, Enum.Material.Cobblestone)
	self:box(V(thickness + 0.6, 0.6, len + 0.4), cf * CF(0, height / 2 + 0.3, 0), (color or Kit.C.Stone):Lerp(Color3.new(1, 1, 1), 0.08), Enum.Material.Slate)
end

function Builder:fence(a: Vector3, b: Vector3, height: number?)
	local h = height or 3.2
	local d = b - a
	local len = d.Magnitude
	local n = math.max(1, math.floor(len / 6))
	for i = 0, n do
		local p = a + d * (i / n)
		self:box(V(0.6, h, 0.6), p + V(0, h / 2, 0), Kit.C.Timber, Enum.Material.Wood)
	end
	for _, y in { h * 0.45, h * 0.85 } do
		self:beam(a + V(0, y, 0), b + V(0, y, 0), 0.35, Kit.C.TimberLight, Enum.Material.Wood)
	end
end

-- ============================================================== LEGO-style bricks
-- Chunky toy bricks with round studs on top (the game's building-block look).
Kit.STUD_PITCH = 4
Kit.STUD_D = 2.4
Kit.STUD_H = 0.8

local function studFinish(p: BasePart)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
end

-- Rectangular brick: size (w, h, d) centred at `at`; studs on a 4-stud grid unless opts.NoStuds.
function Builder:brick(size: Vector3, at: any, color: Color3, opts: { [string]: any }?): Part
	local o = opts or {}
	local cf = toCF(at)
	local p = self:box(size, cf, color, Enum.Material.SmoothPlastic, o.Props)
	if not o.NoStuds then
		local nx = math.max(1, math.floor(size.X / Kit.STUD_PITCH + 0.5))
		local nz = math.max(1, math.floor(size.Z / Kit.STUD_PITCH + 0.5))
		for ix = 1, nx do
			for iz = 1, nz do
				local sx = (ix - (nx + 1) / 2) * Kit.STUD_PITCH
				local sz = (iz - (nz + 1) / 2) * Kit.STUD_PITCH
				local stud = self:cyl(Kit.STUD_H, Kit.STUD_D, cf * CF(sx, size.Y / 2 + Kit.STUD_H / 2, sz), color, Enum.Material.SmoothPlastic)
				studFinish(stud)
			end
		end
	end
	return p
end

-- Round brick (upright cylinder). opts.Studs: "Top" (centre cluster), "Ring" (ring of studs at
-- opts.RingRadius), "None". Returns the part.
function Builder:roundBrick(height: number, diameter: number, at: any, color: Color3, opts: { [string]: any }?): Part
	local o = opts or {}
	local cf = toCF(at)
	local p = self:cyl(height, diameter, cf, color, Enum.Material.SmoothPlastic, o.Props)
	local mode = o.Studs or "None"
	local topY = height / 2 + Kit.STUD_H / 2
	if mode == "Top" then
		local radius = diameter / 2 - Kit.STUD_D
		local n = radius > 1.5 and math.max(1, math.floor(2 * math.pi * radius / (Kit.STUD_PITCH * 1.05))) or 0
		studFinish(self:cyl(Kit.STUD_H, Kit.STUD_D, cf * CF(0, topY, 0), color, Enum.Material.SmoothPlastic))
		for i = 1, n do
			local a = (i - 0.5) / n * math.pi * 2
			studFinish(self:cyl(Kit.STUD_H, Kit.STUD_D, cf * CF(math.cos(a) * radius, topY, math.sin(a) * radius), color, Enum.Material.SmoothPlastic))
		end
	elseif mode == "Ring" then
		local radius = o.RingRadius or (diameter / 2 - Kit.STUD_D)
		local n = math.max(3, math.floor(2 * math.pi * radius / (Kit.STUD_PITCH * 1.05)))
		for i = 1, n do
			local a = (i - 0.5) / n * math.pi * 2
			studFinish(self:cyl(Kit.STUD_H, Kit.STUD_D, cf * CF(math.cos(a) * radius, topY, math.sin(a) * radius), o.StudColor or color, Enum.Material.SmoothPlastic))
		end
	end
	return p
end

function Builder:prompt(attachTo: BasePart, action: string, object: string, attrs: { [string]: any }?)
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0
	p.MaxActivationDistance = 14
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	for k, v in attrs or {} do
		p:SetAttribute(k, v)
	end
	p.Parent = attachTo
	return p
end

return Kit

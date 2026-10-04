--[[
	BrickBuilder
	Toy-brick dragons: chunky bricks, slopes, round bricks, studs, printed
	eyes and glossy plastic colours, built directly from Roblox parts (no
	imported assets). Uses exactly the same Motor6D skeleton, pivots and
	attachments as Builder (Body, Chest, Pelvis, Neck1..n, Head, Jaw,
	Tail1..n, Arm/Hand, Leg/Foot, Wing1..5 + membrane anchors), so the
	procedural Animator, riding, Builder.mountInfo / pose / freeze all work
	unchanged.

	build(speciesId, { Mutation, Detail = "High"|"Medium"|"Low", Root, ScaleOverride,
	                   Statue, Saddle = false }) -> Model

	Geometry is authored in species units (Species def, scale 1) and
	multiplied by the species Scale like Builder; brick dimensions are rounded
	to whole studs where they show on top so the toy look stays crisp.
]]

local Primitives = require(script.Parent:WaitForChild("Primitives"))
local Species = require(script.Parent:WaitForChild("Species"))
local Membranes = require(script.Parent:WaitForChild("Membranes"))

local BrickBuilder = {}

local V3 = Vector3.new
local CF = CFrame.new
local rad = math.rad

local PLASTIC = Enum.Material.SmoothPlastic

-- ============================================================== context
local Ctx = {}
Ctx.__index = Ctx

local function newCtx(def, opts)
	local self = setmetatable({}, Ctx)
	self.Def = def
	self.S = (def.Scale or 1) * (opts.ScaleOverride or 1)
	self.ScaleOverride = opts.ScaleOverride or 1
	self.SpeciesId = opts.SpeciesId or "GreenDrake"
	self.Detail = opts.Detail or "High"
	self.Statue = opts.Statue == true
	self.BondAura = opts.BondAura == true
	self.Palette = def.Palette
	self.Brick = def.Brick or {}
	self.Model = Instance.new("Model")
	self.Bones = {}
	self.Build = {}
	self.PartCount = 0
	self.Features = {}
	for _, f in def.Features or {} do
		self.Features[f] = true
	end
	return self
end

function Ctx:v(x: number, y: number, z: number): Vector3
	return V3(x * self.S, y * self.S, z * self.S)
end

function Ctx:sc(v: Vector3): Vector3
	return v * self.S
end

function Ctx:color(key: string | Color3): Color3
	if typeof(key) == "Color3" then
		return key
	end
	return self.Palette[key] or self.Palette.Main
end

function Ctx:detail(minLevel: string): boolean
	local order = { Low = 1, Medium = 2, High = 3 }
	return order[self.Detail] >= order[minLevel]
end

function Ctx:add(part: BasePart, name: string?): BasePart
	part.Name = name or part.Name
	if self.Build[part] == nil then
		self.Build[part] = part.CFrame
	end
	part.Parent = self.Model
	self.PartCount += 1
	return part
end

function Ctx:bone(name: string, part: BasePart, parentName: string, pivot: Vector3)
	self:add(part, name)
	self.Bones[name] = part
	local parent = self.Bones[parentName]
	assert(parent, "missing parent bone " .. parentName)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = parent
	m.Part1 = part
	local pivotCF = CFrame.new(pivot)
	m.C0 = self.Build[parent]:ToObjectSpace(pivotCF)
	m.C1 = self.Build[part]:ToObjectSpace(pivotCF)
	m.Parent = part
	return part
end

function Ctx:deco(boneName: string, part: BasePart, name: string?): BasePart
	self:add(part, name or "Deco")
	local bone = self.Bones[boneName]
	local w = Instance.new("Weld")
	w.Name = "Weld"
	w.Part0 = bone
	w.Part1 = part
	w.C0 = self.Build[bone]:ToObjectSpace(self.Build[part])
	w.Parent = part
	return part
end

function Ctx:attach(boneName: string, name: string, worldPos: Vector3)
	local bone = self.Bones[boneName]
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = self.Build[bone]:ToObjectSpace(CFrame.new(worldPos))
	a.Parent = bone
	return a
end

-- ============================================================== brick factories
local function plastic(p: BasePart)
	p.Material = PLASTIC
	p.Reflectance = 0.02
	return p
end

-- Rounds a size to whole studs on the visible top (x, z) when it is big
-- enough to read as a brick; keeps small accents exact.
local function studRound(n: number): number
	if n < 1.4 then
		return n
	end
	return math.max(1, math.floor(n + 0.5))
end

local function brick(size: Vector3, cf: CFrame, color: Color3): BasePart
	return plastic(Primitives.block(size, cf, color))
end

-- Wedge whose slope faces `outward` (any horizontal-ish direction in the
-- frame given by `up`): full height on the inner side, zero at the outer edge.
local function slope(center: Vector3, outward: Vector3, up: Vector3, length: number, height: number, depth: number, color: Color3): BasePart
	local z = -outward.Unit
	local x = up:Cross(z).Unit
	local y = z:Cross(x).Unit
	return plastic(Primitives.wedge(V3(length, height, depth), CFrame.fromMatrix(center, x, y, z), color))
end

-- Round brick / cylinder whose axis is `axis`.
local function round(center: Vector3, axis: Vector3, length: number, diameter: number, color: Color3, material: Enum.Material?): BasePart
	local a = axis.Unit
	local helper = math.abs(a:Dot(Vector3.yAxis)) > 0.95 and Vector3.xAxis or Vector3.yAxis
	local y = helper:Cross(a).Unit
	local z = a:Cross(y).Unit
	local p = Primitives.block(V3(length, diameter, diameter), CFrame.fromMatrix(center, a, y, z), color, material)
	;(p :: Part).Shape = Enum.PartType.Cylinder
	if not material then
		plastic(p)
	end
	return p
end

-- Cone made of stacked round bricks (a toy "cone" / horn piece).
local function coneStack(c, boneName: string, a: Vector3, b: Vector3, d0: number, d1: number, color: Color3, steps: number, name: string)
	local dir = b - a
	for i = 0, steps - 1 do
		local t0, t1 = i / steps, (i + 1) / steps
		local p0, p1 = a + dir * t0, a + dir * t1
		local d = d0 + (d1 - d0) * (t0 + t1) * 0.5
		c:deco(boneName, round((p0 + p1) / 2, dir, (p1 - p0).Magnitude * 1.04, d, color), name)
	end
end

-- Grid of studs on a top face. frame: CFrame whose Y is the face normal,
-- centred on the face; nx x nz studs at `pitch` spacing.
local function studs(c, boneName: string, frame: CFrame, nx: number, nz: number, pitch: number, color: Color3)
	if not c:detail("High") then
		return
	end
	local d = pitch * 0.62
	local h = pitch * 0.2
	for ix = 0, nx - 1 do
		for iz = 0, nz - 1 do
			local x = (ix - (nx - 1) / 2) * pitch
			local z = (iz - (nz - 1) / 2) * pitch
			local p = frame * CF(x, h / 2, z)
			c:deco(boneName, round(p.Position, frame.UpVector, h, d, color), "Stud")
		end
	end
end

-- Printed toy eye: white disc, coloured iris, black pupil, white glint.
local function printedEye(c, boneName: string, center: Vector3, normal: Vector3, up: Vector3, d: number, iris: Color3, pupil: Color3)
	local n = normal.Unit
	local layer = d * 0.08
	c:deco(boneName, round(center, n, layer * 2, d, Color3.fromRGB(250, 250, 248)), "Eye")
	local r = up - n * up:Dot(n)
	r = r.Magnitude > 1e-3 and r.Unit or Vector3.yAxis
	c:deco(boneName, round(center + n * layer * 1.2, n, layer, d * 0.72, iris), "Iris")
	if c:detail("Medium") then
		c:deco(boneName, round(center + n * layer * 1.9 - r * d * 0.02, n, layer, d * 0.4, pupil), "Pupil")
		c:deco(boneName, round(center + n * layer * 2.5 + r * d * 0.17 + n:Cross(r) * d * 0.1, n, layer, d * 0.16, Color3.new(1, 1, 1)), "Glint")
	end
end

-- Frame along a segment a->b (forward = toward b) with a stable up.
local function segFrame(a: Vector3, b: Vector3, upHint: Vector3?): CFrame
	local f = (b - a).Unit
	local up = upHint or Vector3.yAxis
	if math.abs(f:Dot(up)) > 0.97 then
		up = Vector3.zAxis
	end
	return CFrame.lookAt((a + b) / 2, b, up)
end

-- ============================================================== torso
local function buildTorso(c)
	local d = c.Def.Body
	local L, W, H = d.Length, d.Width, d.Height
	local cs, hs = d.ChestScale or 1.05, d.HipScale or 0.9
	local S = c.S
	local main, dark, belly, accent = c:color("Main"), c:color("Dark"), c:color("Belly"), c:color("Accent")
	-- body core (pivot as Builder)
	local bw, bh, bl = studRound(W * S), H * 0.86 * S, studRound(L * 0.62 * S)
	local bodyC = c:v(0, 0.05, 0.4)
	c:bone("Body", brick(V3(bw, bh, bl), CF(bodyC), main), "Root", c:v(0, 0.1, 0.4))
	-- chest block (wider, front of the body)
	local cw, ch, cl = studRound(W * cs * S), H * cs * 0.9 * S, studRound(L * 0.42 * S)
	local chestC = c:v(0, 0.25, -L * 0.36)
	c:bone("Chest", brick(V3(cw, ch, cl), CF(chestC), main), "Body", c:v(0, 0.3, -L * 0.2))
	-- pelvis block (narrower, back)
	local pw, ph, pl = studRound(W * hs * S), H * hs * 0.88 * S, studRound(L * 0.36 * S)
	local pelC = c:v(0, 0.15, L * 0.43)
	c:bone("Pelvis", brick(V3(pw, ph, pl), CF(pelC), main), "Body", c:v(0, 0.2, L * 0.3))
	-- roof slopes along the back edges (rounded toy silhouette)
	local function roof(bone: string, center: Vector3, w: number, h: number, l: number)
		local sw = math.max(0.8 * S, w * 0.3)
		local sh = h * 0.28
		for _, side in { -1, 1 } do
			c:deco(bone, slope(center + V3(side * (w / 2 - sw / 2), h / 2 + sh / 2, 0), V3(side, 0, 0), Vector3.yAxis, l, sh, sw, main), "Roof")
		end
		-- flat dorsal tile between the slopes
		c:deco(bone, brick(V3(math.max(0.4 * S, w - sw * 2), sh * 0.55, l), CF(center + V3(0, h / 2 + sh * 0.275, 0)), main), "Ridge")
		-- belly plate underneath (lighter, wraps up the lower flanks)
		c:deco(bone, brick(V3(w * 0.9, h * 0.34, l * 0.96), CF(center + V3(0, -h / 2 + h * 0.08, 0)), belly), "Belly")
	end
	roof("Body", bodyC, bw, bh, bl)
	roof("Chest", chestC, cw, ch, cl)
	roof("Pelvis", pelC, pw, ph, pl)
	-- chest front slope toward the neck, pelvis back slope toward the tail
	c:deco("Chest", slope(chestC + V3(0, ch * 0.18, -cl / 2 - 0.45 * S), V3(0, 0, -1), Vector3.yAxis, cw * 0.84, ch * 0.62, 0.9 * S, main), "ChestSlope")
	c:deco("Chest", brick(V3(cw * 0.7, ch * 0.42, 0.9 * S), CF(chestC + V3(0, -ch * 0.22, -cl / 2 - 0.45 * S)), belly), "ChestPlate")
	c:deco("Pelvis", slope(pelC + V3(0, ph * 0.16, pl / 2 + 0.4 * S), V3(0, 0, 1), Vector3.yAxis, pw * 0.82, ph * 0.56, 0.8 * S, main), "HipSlope")
	c.Boxes = {
		Body = { C = bodyC, Size = V3(bw, bh, bl) },
		Chest = { C = chestC, Size = V3(cw, ch, cl) },
		Pelvis = { C = pelC, Size = V3(pw, ph, pl) },
	}
	-- round shoulder tiles (toy armour discs)
	if c:detail("Medium") then
		for _, side in { -1, 1 } do
			c:deco("Chest", round(chestC + V3(side * (cw / 2 + 0.06 * S), ch * 0.12, 0), V3(1, 0, 0), 0.14 * S, ch * 0.62, accent), "ShoulderDisc")
		end
	end
	-- studs on the shoulders and hips
	local top = CFrame.new(chestC + V3(0, ch / 2 + ch * 0.28 * 0.55 + 0.001, 0))
	local _ = top
	studs(c, "Chest", CF(chestC + V3(0, ch / 2, cl * 0.18)), 2, 1, S, dark)
	studs(c, "Pelvis", CF(pelC + V3(0, ph / 2, 0)), 2, 1, S, dark)
end

-- ============================================================== neck
local function neckPoints(c)
	local d = c.Def.Neck
	local pts = {}
	local L = c.Def.Body.Length
	local p = V3(0, 0.9 + (d.BaseRaise or 0), -L * 0.56)
	pts[1] = p
	local n = d.Segments
	local segLen = d.Length / n
	for i = 1, n do
		local a = rad(d.Rise + (i - 1) * (d.Curve or 8))
		local dir = V3(0, math.sin(a), -math.cos(a))
		p = p + dir * segLen
		pts[i + 1] = p
	end
	return pts
end
BrickBuilder.neckPoints = neckPoints

local function buildNeck(c)
	local d = c.Def.Neck
	local pts = neckPoints(c)
	local parent = "Chest"
	local S = c.S
	local main, belly, dark = c:color("Main"), c:color("Belly"), c:color("Dark")
	for i = 1, d.Segments do
		local t = (i - 1) / math.max(1, d.Segments - 1)
		local th = d.Thickness * (1 - (1 - (d.Taper or 0.75)) * t) * S
		local a, b = c:sc(pts[i]), c:sc(pts[i + 1])
		local len = (b - a).Magnitude
		local f = segFrame(a, b)
		local name = "Neck" .. i
		c:bone(name, brick(V3(th, th * 0.9, len * 1.08), f, main), parent, a)
		-- hinge (round brick across the joint)
		c:deco(name, round(a, f.RightVector, th * 1.02, th * 0.92, dark), "NeckJoint")
		-- throat plate
		c:deco(name, brick(V3(th * 0.8, th * 0.34, len * 1.02), f * CF(0, -th * 0.4, 0), belly), "Throat")
		-- back ridge tile
		if c:detail("Medium") then
			c:deco(name, slope((f * CF(0, th * 0.45 + th * 0.12, 0)).Position, -f.LookVector, f.UpVector, th * 0.36, th * 0.24, len * 0.8, c:color("Accent")), "NeckFin")
		end
		parent = name
	end
	return pts[#pts]
end

-- ============================================================== head
local function buildHead(c, neckEnd: Vector3)
	local d = c.Def.Head
	local hs = (d.Size or 1) * (c.Brick.HeadScale or 1.12)
	local S = c.S
	local main, dark, belly = c:color("Main"), c:color("Dark"), c:color("Belly")
	local base = neckEnd * S
	local tilt = rad(d.Tilt or -8)
	local fwd = V3(0, math.sin(tilt), -math.cos(tilt))
	local up = V3(0, math.cos(tilt), math.sin(tilt))
	local right = fwd:Cross(up).Unit
	local skullC = base + fwd * (0.95 * hs * S) + up * (0.25 * hs * S)
	local frame = CFrame.fromMatrix(skullC, right, up, -fwd)
	local u = hs * S
	local skull = V3(2.6 * u, 2.2 * u, 2.6 * u)
	c:bone("Head", brick(skull, frame, main), "Neck" .. c.Def.Neck.Segments, base)
	-- forehead slope + brow
	c:deco("Head", slope((frame * CF(0, skull.Y / 2 + 0.22 * u, -0.35 * u)).Position, fwd, up, skull.X * 0.92, 0.44 * u, 1.2 * u, main), "Forehead")
	-- snout: box + nose slope on top + cheek plates
	local sn = (d.Snout or 1) * 1.9 * u
	local snoutF = frame * CF(0, -0.3 * u, -skull.Z / 2 - sn / 2 + 0.1 * u)
	local snoutSize = V3(skull.X * 0.74 * (d.SnoutWidth or 1), 1.15 * u, sn)
	c:deco("Head", brick(snoutSize, snoutF, main), "Snout")
	c:deco("Head", slope((snoutF * CF(0, snoutSize.Y / 2 + 0.28 * u, 0.25 * u)).Position, fwd, up, snoutSize.X * 0.8, 0.56 * u, sn * 0.62, main), "NoseSlope")
	-- nostrils (dark round tiles on the nose front)
	if c:detail("Medium") then
		for _, side in { -1, 1 } do
			local np = (snoutF * CF(side * snoutSize.X * 0.24, snoutSize.Y * 0.28, -sn / 2 - 0.02 * u)).Position
			c:deco("Head", round(np, fwd, 0.08 * u, 0.32 * u, Color3.fromRGB(27, 42, 52)), "Nostril")
		end
	end
	-- jaw (bone): lighter lower jaw with fangs
	local hinge = skullC + up * (-0.6 * u) + fwd * (-0.1 * u)
	local jawF = frame * CF(0, -skull.Y / 2 + 0.05 * u, -skull.Z / 2 - sn * 0.42 + 0.35 * u)
	c:bone("Jaw", brick(V3(snoutSize.X * 0.92, 0.6 * u, sn * 0.9 + 0.9 * u), jawF, belly), "Head", hinge)
	if c:detail("Medium") then
		for _, side in { -1, 1 } do
			local tp = (snoutF * CF(side * snoutSize.X * 0.34, -snoutSize.Y / 2 - 0.16 * u, -sn * 0.28)).Position
			c:deco("Head", plastic(Primitives.spike(tp + up * 0.12 * u, tp - up * 0.34 * u, 0.26 * u, 0.2 * u, Color3.fromRGB(250, 250, 246))), "Tooth")
		end
	end
	-- cheek / jaw-hinge round bricks
	for _, side in { -1, 1 } do
		c:deco("Head", round((frame * CF(side * skull.X * 0.5, -0.45 * u, 0.25 * u)).Position, right, 0.3 * u, 1.05 * u, dark), "Cheek")
	end
	-- printed eyes on the skull sides, looking forward-out
	local eyeD = (d.EyeSize or 1) * (c.Brick.EyeScale or 1.2) * u
	for _, side in { -1, 1 } do
		local out = (right * side * 0.7 + fwd * 0.72).Unit
		local ec = (frame * CF(side * skull.X * 0.5, 0.28 * u, -skull.Z * 0.22)).Position + out * 0.04 * u
		printedEye(c, "Head", ec, out, up, eyeD, c:color("Eye"), c:color("Pupil"))
		-- angled brow slope (expression)
		local bc = ec + up * (eyeD * 0.62) - fwd * 0.05 * u
		c:deco("Head", slope(bc, (out + up * 0.2).Unit, up, eyeD * 1.05, 0.3 * u, 0.5 * u, dark), "Brow")
	end
	-- studs on top of the skull
	studs(c, "Head", frame * CF(0, skull.Y / 2, 0.55 * u), 2, 1, math.max(0.9 * u, S * 0.9), dark)
	return { Skull = skullC, Fwd = fwd, Up = up, Right = right, Hs = hs, Frame = frame, SkullSize = skull, U = u, Snout = snoutF, SnoutSize = snoutSize }
end

-- ============================================================== horns / frills
local function buildHorns(c, head)
	local d = c.Def.Head
	local style = c.Features.Antlers and "None" or (d.Horns or "Swept")
	local S, hs, u = c.S, head.Hs, head.U
	local fwd, up = head.Fwd, head.Up
	local frame = head.Frame
	local horn = c:color("Horn")
	local tipCol = c:color(c.Brick.HornTip or "Horn")
	local hornSides = if style == "None" then {} else { -1, 1 }
	for _, side in hornSides do
		local root = (frame * CF(side * head.SkullSize.X * 0.34, head.SkullSize.Y / 2, 0.5 * u)).Position
		local segs
		if style == "Swept" then
			segs = { V3(side * 0.25, 0.55, 1.15), V3(side * 0.12, 0.35, 1.0) }
		elseif style == "Long" then
			segs = { V3(side * 0.2, 0.7, 1.3), V3(side * 0.15, 0.45, 1.4), V3(side * 0.05, 0.2, 1.1) }
		elseif style == "Ram" then
			segs = { V3(side * 0.6, 0.45, 0.6), V3(side * 0.35, -0.6, 0.55), V3(side * -0.1, -0.5, -0.4) }
		elseif style == "Crown" then
			segs = { V3(side * 0.35, 1.0, 0.35), V3(side * 0.25, 0.9, 0.5) }
		else
			segs = { V3(side * 0.25, 0.55, 1.15), V3(side * 0.12, 0.35, 1.0) }
		end
		local p = root
		local thick = (d.HornThickness or 0.55) * hs * S * (c.Brick.HornScale or 1.6)
		for i, seg in segs do
			local dv = (fwd * -seg.Z + up * seg.Y + V3(seg.X, 0, 0)) * hs * S * (d.HornLength or 1)
			local q = p + dv
			local last = i == #segs
			coneStack(c, "Head", p, q, thick, thick * 0.66, last and tipCol or horn, 2, "Horn")
			thick *= 0.62
			p = q
		end
		-- tip
		local dir = (p - root).Unit
		c:deco("Head", plastic(Primitives.spike(p - dir * thick * 0.2, p + dir * thick * 2.2, thick, thick, tipCol)), "HornTip")
	end
	-- ear fins (toy wing plates on the back of the head)
	if c:detail("Medium") and d.Frills ~= false and not c.Features.BigEars then
		for _, side in { -1, 1 } do
			local fc = (frame * CF(side * head.SkullSize.X * 0.52, 0.15 * u, 0.55 * u)).Position
			local tip = fc + V3(side * 0.85 * u, 0.25 * u, 0) - fwd * (0.95 * u)
			c:deco("Head", plastic(Primitives.spike(fc, tip, 0.85 * u, 0.14 * u, c:color("Accent"))), "Frill")
		end
	end
end

-- ============================================================== tail
local function tailPoints(c)
	local d = c.Def.Tail
	local L = c.Def.Body.Length
	local pts = { V3(0, 0.25, L * 0.62) }
	local n = d.Segments
	local segLen = d.Length / n
	local p = pts[1]
	for i = 1, n do
		local t = (i - 1) / math.max(1, n - 1)
		local droop = rad((d.Droop or 8) * (1 - t) + (d.Lift or 0) * t)
		local dir = V3(0, -math.sin(droop), math.cos(droop))
		p = p + dir * segLen
		pts[i + 1] = p
	end
	return pts
end
BrickBuilder.tailPoints = tailPoints

local function buildTail(c)
	local d = c.Def.Tail
	local pts = tailPoints(c)
	local parent = "Pelvis"
	local n = d.Segments
	local S = c.S
	local main, dark, belly, accent = c:color("Main"), c:color("Dark"), c:color("Belly"), c:color("Accent")
	for i = 1, n do
		local t = (i - 1) / math.max(1, n - 1)
		local th = d.Thickness * (1 - (1 - (d.Taper or 0.3)) * t) * S
		local a, b = c:sc(pts[i]), c:sc(pts[i + 1])
		local len = (b - a).Magnitude
		local f = segFrame(a, b)
		local name = "Tail" .. i
		c:bone(name, brick(V3(th, th * 0.86, len * 1.06), f, main), parent, a)
		if i > 1 then
			c:deco(name, round(a, f.RightVector, th * 1.02, th * 0.88, dark), "TailJoint")
		end
		if c:detail("Medium") then
			c:deco(name, brick(V3(th * 0.7, th * 0.2, len * 0.98), f * CF(0, -th * 0.48, 0), belly), "TailBelly")
			-- dorsal tooth plates
			c:deco(name, plastic(Primitives.spike((f * CF(0, th * 0.43, len * 0.1)).Position, (f * CF(0, th * 0.43 + th * 0.55, len * 0.32)).Position, len * 0.45, th * 0.18, accent)), "TailSpike")
		end
		parent = name
	end
	-- tip
	local last = "Tail" .. n
	local e = c:sc(pts[n + 1])
	local tip = d.Tip or "Spade"
	local tipCol = c:color(c.Brick.TailTip or "Accent")
	if tip == "Spade" or tip == "Leaf" then
		local back = e + V3(0, 0, 2.1 * S)
		local l = e + V3(-1.0 * S, 0, 0.45 * S)
		local r = e + V3(1.0 * S, 0, 0.45 * S)
		local f = e + V3(0, 0, -0.55 * S)
		for _, p in Primitives.triangle(f, l, back, 0.28 * S, tipCol, PLASTIC) do
			c:deco(last, plastic(p), "TailTip")
		end
		for _, p in Primitives.triangle(f, r, back, 0.28 * S, tipCol, PLASTIC) do
			c:deco(last, plastic(p), "TailTip")
		end
	elseif tip == "Club" then
		c:deco(last, brick(V3(1.6, 1.4, 2.0) * S, CF(e + V3(0, 0, 0.6 * S)), c:color("Horn")), "TailClub")
		for _, ang in { 0, 120, 240 } do
			local o = V3(math.cos(rad(ang)) * 0.6, math.sin(rad(ang)) * 0.6 + 0.2, 0.5) * S
			c:deco(last, plastic(Primitives.spike(e + o, e + o * 2.1 + V3(0, 0, 0.4 * S), 0.45 * S, 0.35 * S, c:color("Horn"))), "TailSpike")
		end
	elseif tip == "Fin" or tip == "Plume" then
		for _, sgn in { 1, -1 } do
			for _, p in Primitives.triangle(e + V3(0, 0, -0.6 * S), e + V3(0, sgn * 1.5 * S, 0.6 * S), e + V3(0, 0, 2.2 * S), 0.22 * S, tipCol, PLASTIC) do
				c:deco(last, plastic(p), "TailFin")
			end
		end
	elseif tip == "Crystal" then
		for i, o in { V3(0, 0.3, 0.8), V3(-0.5, 0.1, 0.5), V3(0.5, 0.1, 0.5) } do
			local bp = e + o * S
			local spike = Primitives.spike(bp, bp + V3(o.X * 1.2, 1.2 + (i == 1 and 0.6 or 0), 0.9) * S, 0.55 * S, 0.5 * S, c:color("Crystal"), Enum.Material.Glass)
			spike.Transparency = 0.25
			c:deco(last, spike, "Crystal")
		end
	elseif tip == "Flame" then
		local fl = brick(V3(1.0, 1.0, 1.6) * S, CF(e + V3(0, 0, 0.5 * S)), c:color("Glow"))
		fl.Material = Enum.Material.Neon
		c:deco(last, fl, "TailFlame")
	end
	return pts
end

-- ============================================================== legs
local function buildLegs(c)
	local d = c.Def.Legs
	local L = c.Def.Body.Length
	local hip = c.Def.HipHeight
	local thick = d.Thickness or 1
	local groundY = -hip
	local S = c.S
	local main, dark = c:color("Main"), c:color("Dark")
	local function foot(boneName, parentName, pivot: Vector3, center: Vector3, size: Vector3, sideName: string)
		c:bone(boneName, brick(c:sc(size), CF(c:sc(center)), dark), parentName, c:sc(pivot))
		if c:detail("Medium") then
			for i = -1, 1 do
				local cp = c:sc(center + V3(i * size.X * 0.32, -size.Y * 0.22, -size.Z * 0.5))
				c:deco(boneName, plastic(Primitives.spike(cp, cp + c:sc(V3(i * 0.05, -0.12, -0.5)), 0.26 * S, 0.24 * S, c:color("Claw"))), "Claw")
			end
		end
		studs(c, boneName, CF(c:sc(center + V3(0, size.Y / 2, 0.15))), 2, 1, 0.75 * S, dark)
		c:attach(boneName, "Foot" .. sideName, c:sc(center + V3(0, -size.Y * 0.5, 0)))
	end
	for _, side in { -1, 1 } do
		local sn = side < 0 and "L" or "R"
		if d.Front then
			local sh = V3(side * c.Def.Body.Width * 0.4, -0.2, -L * 0.36)
			local el = sh + V3(side * 0.15, -(hip * 0.45), 0.25)
			local wr = el + V3(0, -(hip * 0.4), -0.15)
			local fc = V3(wr.X, groundY + 0.35, wr.Z - 0.35)
			local a1, b1 = c:sc(sh), c:sc(el)
			c:bone("Arm" .. sn .. "1", brick(V3(1.35 * thick * S, 1.35 * thick * S, (b1 - a1).Magnitude * 1.12), segFrame(a1, b1, Vector3.zAxis), main), "Chest", c:sc(sh))
			local a2, b2 = c:sc(el), c:sc(wr)
			c:bone("Arm" .. sn .. "2", brick(V3(1.05 * thick * S, 1.05 * thick * S, (b2 - a2).Magnitude * 1.1), segFrame(a2, b2, Vector3.zAxis), main), "Arm" .. sn .. "1", c:sc(el))
			c:deco("Arm" .. sn .. "2", round(c:sc(el), Vector3.xAxis, 1.2 * thick * S, 1.15 * thick * S, dark), "Elbow")
			c:deco("Arm" .. sn .. "1", round(c:sc(sh + V3(side * 0.1, -0.25, 0)), Vector3.xAxis, 1.7 * thick * S, 1.9 * thick * S, main), "Shoulder")
			foot("Hand" .. sn, "Arm" .. sn .. "2", wr, fc, V3(1.4 * thick, 0.7, 1.9 * thick), "F" .. sn)
		end
		if d.Back then
			local hp = V3(side * c.Def.Body.Width * 0.38, 0.1, L * 0.4)
			local kn = hp + V3(side * 0.25, -(hip * 0.4), -0.65)
			local an = kn + V3(0, -(hip * 0.45), 1.0)
			local fc = V3(an.X, groundY + 0.35, an.Z - 0.45)
			local thighC = (hp + kn) / 2 + V3(0, 0.2, 0.25)
			c:bone("Leg" .. sn .. "1", brick(c:sc(V3(2.0 * thick, hip * 0.62, 2.4 * thick)), CF(c:sc(thighC)) * CFrame.Angles(rad(-14), 0, 0), main), "Pelvis", c:sc(hp))
			c:deco("Leg" .. sn .. "1", slope(c:sc(thighC + V3(0, hip * 0.31 + 0.25, 0)), V3(side, 0, 0), Vector3.yAxis, 2.2 * thick * S, 0.5 * S, 1.0 * thick * S, main), "Haunch")
			local a2, b2 = c:sc(kn), c:sc(an)
			c:bone("Leg" .. sn .. "2", brick(V3(1.08 * thick * S, 1.08 * thick * S, (b2 - a2).Magnitude * 1.1), segFrame(a2, b2, Vector3.zAxis), main), "Leg" .. sn .. "1", c:sc(kn))
			c:deco("Leg" .. sn .. "2", round(c:sc(kn), Vector3.xAxis, 1.25 * thick * S, 1.2 * thick * S, dark), "Knee")
			foot("Foot" .. sn, "Leg" .. sn .. "2", an, fc, V3(1.5 * thick, 0.72, 2.1 * thick), "B" .. sn)
		end
	end
end

-- ============================================================== wings
local function buildWings(c)
	local d = c.Def.Wings
	if not d or d.Type == "None" then
		return
	end
	local span = d.Span or 13
	local chord = d.Chord or 5.5
	local L = c.Def.Body.Length
	local W = c.Def.Body.Width
	local S = c.S
	local k = span / 13
	local kc = chord / 5.5
	local boneCol = c:color(d.BoneColor or "Dark")
	local memColor = c:color("Membrane")
	local depth = d.Type == "Tattered" and 0.42 or (d.Scallop or 0.2)
	local thickness = 0.22 * S
	c.Model:SetAttribute("WingType", d.Type or "Bat")
	c.Model:SetAttribute("MembraneScallop", depth)
	c.Model:SetAttribute("MembraneThickness", thickness)
	for _, side in { -1, 1 } do
		local sn = side < 0 and "L" or "R"
		local function m(x, y, z)
			return V3(side * x, y, z)
		end
		local sh = m(W * 0.36, 1.6, -L * 0.27)
		local el = sh + m(4.0 * k, 0.8 * k, 0.5 * k)
		local wr = el + m(4.2 * k, 0.5 * k, 1.2 * k)
		local f1 = wr + m(3.6 * k, -0.2 * k, 1.3 * kc)
		local f2 = wr + m(1.8 * k, -0.6 * k, 4.0 * kc)
		local f3 = wr + m(-1.6 * k, -0.9 * k, 5.3 * kc)
		local bodyAttach = m(W * 0.36, 1.0, L * 0.36)
		local n = "Wing" .. sn
		local function rod(a: Vector3, b: Vector3, w: number)
			local A, B = c:sc(a), c:sc(b)
			return brick(V3(w, w, (B - A).Magnitude * 1.06), segFrame(A, B), boneCol)
		end
		c:bone(n .. "1", rod(sh, el, 0.75 * S), "Chest", c:sc(sh))
		c:bone(n .. "2", rod(el, wr, 0.6 * S), n .. "1", c:sc(el))
		c:bone(n .. "3", rod(wr, f1, 0.4 * S), n .. "2", c:sc(wr))
		c:bone(n .. "4", rod(wr, f2, 0.36 * S), n .. "3", c:sc(wr))
		c:bone(n .. "5", rod(wr, f3, 0.34 * S), n .. "3", c:sc(wr))
		c:deco(n .. "2", round(c:sc(el), V3(0, 1, 0), 0.8 * S, 0.9 * S, c:color("Accent")), "Knuckle")
		c:deco(n .. "3", round(c:sc(wr), V3(0, 1, 0), 0.7 * S, 0.8 * S, c:color("Accent")), "Knuckle")
		if c:detail("Medium") then
			c:deco(n .. "2", plastic(Primitives.spike(c:sc(wr), c:sc(wr + m(0.25, 0.35, -0.85)), 0.3 * S, 0.24 * S, c:color("Claw"))), "WingClaw")
			-- finger tip caps
			for i, f in { f1, f2, f3 } do
				c:deco(n .. tostring(2 + i), round(c:sc(f), V3(0, 1, 0), 0.4 * S, 0.5 * S, c:color("Accent")), "FingerTip")
			end
		end
		if d.Glow then
			local function glow(bone: string, a: Vector3, b: Vector3)
				local p = brick(V3(0.16 * S, 0.16 * S, (c:sc(b) - c:sc(a)).Magnitude), segFrame(c:sc(a), c:sc(b)), c:color("Glow"))
				p.Material = Enum.Material.Neon
				c:deco(bone, p, "Glow")
			end
			glow(n .. "3", wr, f1)
			glow(n .. "4", wr, f2)
			glow(n .. "5", wr, f3)
		end
		c:attach(n .. "1", "MemS" .. sn, c:sc(sh + m(-0.1, -0.15, 0.25)))
		c:attach(n .. "2", "MemE" .. sn, c:sc(el))
		c:attach(n .. "3", "MemW" .. sn, c:sc(wr))
		c:attach(n .. "3", "MemF1" .. sn, c:sc(f1))
		c:attach(n .. "4", "MemF2" .. sn, c:sc(f2))
		c:attach(n .. "5", "MemF3" .. sn, c:sc(f3))
		c:attach("Body", "MemB" .. sn, c:sc(bodyAttach))
		c:attach(n .. "3", "WingTip" .. sn, c:sc(f1))
		c:attach(n .. "3", "WingTipInner" .. sn, c:sc(f1 + (wr - f1) * 0.18))
		local P = {
			S = c:sc(sh + m(-0.1, -0.15, 0.25)),
			E = c:sc(el),
			W = c:sc(wr),
			F1 = c:sc(f1),
			F2 = c:sc(f2),
			F3 = c:sc(f3),
			B = c:sc(bodyAttach),
		}
		Membranes.buildPieces(c.Bones.Root, sn, P, thickness, depth, memColor, PLASTIC, function(part)
			part.Reflectance = 0.02
			c:add(part, "Membrane")
		end)
	end
end

-- ============================================================== back spikes
local function buildSpines(c)
	local d = c.Def.Spines
	if not d or d.Style == "None" or not c:detail("Medium") then
		return
	end
	local S = c.S
	local L = c.Def.Body.Length
	local H = c.Def.Body.Height
	local col = c:color(c.Brick.SpineColor or "Accent")
	for _, z in { -L * 0.32, L * 0.12, L * 0.38 } do
		if not (c.Def.Saddle ~= false and z > -L * 0.3 and z < L * 0.05) then
			local bone = z < -L * 0.2 and "Chest" or (z > L * 0.3 and "Pelvis" or "Body")
			local base = c:sc(V3(0, H * 0.43 + 0.55, z))
			c:deco(bone, plastic(Primitives.spike(base, base + V3(0, (d.Height or 0.9) * 1.1 * S, 0.55 * S), 1.1 * S, 0.3 * S, col)), "Spine")
		end
	end
end

-- ============================================================== saddle
local function buildSaddle(c)
	if c.Def.Saddle == false then
		return
	end
	local H = c.Def.Body.Height
	local L = c.Def.Body.Length
	local S = c.S
	local y = H * 0.5 + 0.05
	local z = -L * 0.16
	local leather = Color3.fromRGB(124, 80, 46)
	local cloth = c.Palette.Saddle or Color3.fromRGB(196, 40, 27)
	local gold = Color3.fromRGB(245, 205, 47)
	local W = math.floor(c.Def.Body.Width * S + 0.5)
	c:deco("Body", brick(V3(W + 0.2 * S, 0.24 * S, 3.0 * S), CF(c:sc(V3(0, y - 0.12, z))), cloth), "SaddleCloth")
	for _, dz in { -1.45, 1.45 } do
		c:deco("Body", brick(V3(W + 0.3 * S, 0.3 * S, 0.24 * S), CF(c:sc(V3(0, y - 0.1, z + dz))), gold), "SaddleTrim")
	end
	c:deco("Body", brick(c:sc(V3(2.2, 0.5, 2.6)), CF(c:sc(V3(0, y + 0.22, z))), leather), "Saddle")
	c:deco("Body", brick(c:sc(V3(1.0, 0.8, 0.5)), CF(c:sc(V3(0, y + 0.55, z - 1.15))), leather), "Pommel")
	c:deco("Body", brick(c:sc(V3(1.9, 0.7, 0.45)), CF(c:sc(V3(0, y + 0.5, z + 1.2))), leather), "Cantle")
	c:attach("Body", "SaddlePoint", c:sc(V3(0, y + 0.2, z)))
end

-- ============================================================== features
-- Unique per-species pieces (Species def.Features), all toy bricks.
local GOLD = Color3.fromRGB(245, 205, 47)
local GEM = Color3.fromRGB(196, 40, 27)
local FLOWER_MID = Color3.fromRGB(245, 205, 47)

local function rod(a: Vector3, b: Vector3, w: number, color: Color3): BasePart
	return brick(V3(w, w, (b - a).Magnitude * 1.04), segFrame(a, b), color)
end

local function neon(p: BasePart): BasePart
	p.Material = Enum.Material.Neon
	p.Reflectance = 0
	return p
end

local function glassy(p: BasePart, transparency: number?): BasePart
	p.Material = Enum.Material.Glass
	p.Transparency = transparency or 0.2
	p.Reflectance = 0.1
	return p
end

-- frame of one neck segment (same maths as buildNeck)
local function neckSegments(c)
	local d = c.Def.Neck
	local pts = neckPoints(c)
	local out = {}
	for i = 1, d.Segments do
		local t = (i - 1) / math.max(1, d.Segments - 1)
		local th = d.Thickness * (1 - (1 - (d.Taper or 0.75)) * t) * c.S
		local a, b = c:sc(pts[i]), c:sc(pts[i + 1])
		out[i] = { Bone = "Neck" .. i, F = segFrame(a, b), Th = th, Len = (b - a).Magnitude }
	end
	return out
end

local function tailSegments(c)
	local d = c.Def.Tail
	local pts = tailPoints(c)
	local out = {}
	for i = 1, d.Segments do
		local t = (i - 1) / math.max(1, d.Segments - 1)
		local th = d.Thickness * (1 - (1 - (d.Taper or 0.3)) * t) * c.S
		local a, b = c:sc(pts[i]), c:sc(pts[i + 1])
		out[i] = { Bone = "Tail" .. i, F = segFrame(a, b), Th = th, Len = (b - a).Magnitude }
	end
	return out
end

-- back positions that stay clear of the saddle
local function backSpots(c, list: { number })
	local L = c.Def.Body.Length
	local out = {}
	for _, fz in list do
		local z = L * fz
		if not (c.Def.Saddle ~= false and z > -L * 0.3 and z < L * 0.05) then
			local bone = z < -L * 0.2 and "Chest" or (z > L * 0.3 and "Pelvis" or "Body")
			local box = c.Boxes[bone]
			table.insert(out, { Bone = bone, Pos = V3(0, box.C.Y + box.Size.Y / 2 + box.Size.Y * 0.2, z * c.S) })
		end
	end
	return out
end

local function flower(c, bone: string, center: Vector3, normal: Vector3, size: number, petal: Color3)
	local n = normal.Unit
	local helper = math.abs(n:Dot(Vector3.xAxis)) > 0.9 and Vector3.zAxis or Vector3.xAxis
	local e1 = n:Cross(helper).Unit
	local e2 = n:Cross(e1).Unit
	local count = c:detail("High") and 5 or 4
	for i = 0, count - 1 do
		local a = i / count * math.pi * 2
		local pp = center + (e1 * math.cos(a) + e2 * math.sin(a)) * size * 0.4
		c:deco(bone, round(pp, n, size * 0.16, size * 0.52, petal), "Petal")
	end
	c:deco(bone, round(center + n * size * 0.07, n, size * 0.22, size * 0.36, FLOWER_MID), "FlowerMid")
end

local FEATURES = {}

-- long drooping whiskers from the snout (serpent dragons)
function FEATURES.Whiskers(c, head)
	local u = head.U
	local col = c:color("Mane")
	local sn = head.SnoutSize
	for _, side in { -1, 1 } do
		local r = head.Right * side
		local base = (head.Snout * CF(side * sn.X * 0.5, sn.Y * 0.1, -sn.Z * 0.25)).Position
		local p1 = base + r * 0.9 * u - head.Up * 0.3 * u + head.Fwd * 0.2 * u
		local p2 = p1 + r * 0.6 * u - head.Up * 0.9 * u - head.Fwd * 0.5 * u
		local p3 = p2 + r * 0.2 * u - head.Up * 0.8 * u - head.Fwd * 0.8 * u
		c:deco("Head", rod(base, p1, 0.26 * u, col), "Whisker")
		c:deco("Head", rod(p1, p2, 0.22 * u, col), "Whisker")
		c:deco("Head", rod(p2, p3, 0.18 * u, col), "Whisker")
		c:deco("Head", round(p3, (p3 - p2).Unit, 0.3 * u, 0.34 * u, c:color("Accent")), "WhiskerTip")
	end
end

-- fluffy crest along the neck and behind the head
function FEATURES.Mane(c, head)
	local col = c:color("Mane")
	for _, seg in neckSegments(c) do
		local f, th = seg.F, seg.Th
		local base = (f * CF(0, th * 0.42, 0)).Position
		local tip = base - f.LookVector * th * 0.95 + f.UpVector * th * 0.8
		c:deco(seg.Bone, plastic(Primitives.spike(base, tip, th * 0.95, th * 0.36, col)), "Mane")
		if c:detail("Medium") then
			for _, side in { -1, 1 } do
				local sb = (f * CF(side * th * 0.4, th * 0.2, 0)).Position
				local st = sb + f.RightVector * side * th * 0.55 - f.LookVector * th * 0.6 + f.UpVector * th * 0.3
				c:deco(seg.Bone, plastic(Primitives.spike(sb, st, th * 0.7, th * 0.24, col)), "Mane")
			end
		end
	end
	local u = head.U
	for _, side in { -1, 0, 1 } do
		local hb = (head.Frame * CF(side * head.SkullSize.X * 0.32, head.SkullSize.Y * 0.15, head.SkullSize.Z * 0.42)).Position
		local ht = hb - head.Fwd * 1.6 * u + head.Up * 0.8 * u + head.Right * side * 0.7 * u
		c:deco("Head", plastic(Primitives.spike(hb, ht, 1.1 * u, 0.32 * u, col)), "Mane")
	end
end

-- glowing ring above the head
function FEATURES.Halo(c, head)
	local u = head.U
	local n = c:detail("High") and 16 or (c:detail("Medium") and 12 or 8)
	local center = head.Skull + head.Up * (head.SkullSize.Y * 0.5 + 2.4 * u) - head.Fwd * 0.6 * u
	local normal = (head.Up - head.Fwd * 0.3).Unit
	local e1 = head.Right
	local e2 = normal:Cross(e1).Unit
	local R = 1.9 * u
	local col = c:color("Glow")
	for i = 0, n - 1 do
		local a0, a1 = (i / n) * math.pi * 2, ((i + 1) / n) * math.pi * 2
		local p0 = center + (e1 * math.cos(a0) + e2 * math.sin(a0)) * R
		local p1 = center + (e1 * math.cos(a1) + e2 * math.sin(a1)) * R
		c:deco("Head", neon(brick(V3(0.34 * u, 0.34 * u, (p1 - p0).Magnitude * 1.1), CFrame.lookAt((p0 + p1) / 2, p1, normal), col)), "Halo")
	end
end

-- golden crown with red gems
function FEATURES.Crown(c, head)
	local u = head.U
	local fr = head.Frame * CF(0, head.SkullSize.Y / 2 + 0.3 * u, 0.2 * u)
	local w = head.SkullSize.X * 0.5
	local h = 0.6 * u
	local t = 0.28 * u
	c:deco("Head", brick(V3(w, h, t), fr * CF(0, 0, -w / 2 + t / 2), GOLD), "Crown")
	c:deco("Head", brick(V3(w, h, t), fr * CF(0, 0, w / 2 - t / 2), GOLD), "Crown")
	c:deco("Head", brick(V3(t, h, w - 2 * t), fr * CF(-w / 2 + t / 2, 0, 0), GOLD), "Crown")
	c:deco("Head", brick(V3(t, h, w - 2 * t), fr * CF(w / 2 - t / 2, 0, 0), GOLD), "Crown")
	for _, o in { { -1, -1, 0.8 }, { 1, -1, 0.8 }, { -1, 1, 0.7 }, { 1, 1, 0.7 }, { 0, -1, 1.15 } } do
		local bp = (fr * CF(o[1] * (w / 2 - t / 2), h / 2, o[2] * (w / 2 - t / 2))).Position
		c:deco("Head", plastic(Primitives.spike(bp, bp + head.Up * o[3] * u, 0.42 * u, 0.26 * u, GOLD)), "CrownPoint")
	end
	if c:detail("Medium") then
		c:deco("Head", round((fr * CF(0, 0, -w / 2 - 0.03 * u)).Position, head.Fwd, 0.12 * u, 0.4 * u, GEM), "Gem")
		for _, side in { -1, 1 } do
			c:deco("Head", round((fr * CF(side * (w / 2 + 0.03 * u), 0, 0)).Position, head.Right, 0.12 * u, 0.34 * u, GEM), "Gem")
		end
	end
end

-- neon flames along the back (replace the spines)
function FEATURES.BackFlames(c)
	local S = c.S
	local outer, inner = c:color("Glow"), Color3.fromRGB(255, 226, 90)
	for i, spot in backSpots(c, { -0.4, -0.32, 0.12, 0.28, 0.44 }) do
		local k = (i % 2 == 0) and 0.8 or 1
		local base = spot.Pos
		c:deco(spot.Bone, neon(Primitives.spike(base, base + V3(0, 1.7 * k * S, 0.8 * S), 1.4 * k * S, 0.36 * S, outer)), "Flame")
		c:deco(spot.Bone, neon(Primitives.spike(base + V3(0, 0, 0.12 * S), base + V3(0, 1.05 * k * S, 0.55 * S), 0.85 * k * S, 0.42 * S, inner)), "Flame")
	end
	if c:detail("Medium") then
		for _, seg in tailSegments(c) do
			local i = tonumber(seg.Bone:sub(5))
			if i and i <= 3 then
				local base = (seg.F * CF(0, seg.Th * 0.45, 0)).Position
				c:deco(seg.Bone, neon(Primitives.spike(base, base + seg.F.UpVector * seg.Th * 0.9 + seg.F.LookVector * seg.Th * 0.5, seg.Len * 0.5, seg.Th * 0.22, outer)), "Flame")
			end
		end
	end
end

-- small glowing star tiles over the body, neck and tail
function FEATURES.Stars(c, _head, color: Color3?)
	local col = color or c:color("Glow")
	local S = c.S
	local spots = {
		{ "Chest", 1, 0.15, -0.3, 0.42 }, { "Chest", -1, -0.1, 0.2, 0.32 }, { "Body", 1, 0.1, 0.25, 0.3 },
		{ "Body", -1, 0.2, -0.2, 0.44 }, { "Pelvis", 1, -0.05, 0.1, 0.34 }, { "Pelvis", -1, 0.12, -0.25, 0.28 },
	}
	for _, sp in spots do
		local box = c.Boxes[sp[1]]
		local p = box.C + V3(sp[2] * (box.Size.X / 2 + 0.04 * S), sp[3] * box.Size.Y, sp[4] * box.Size.Z)
		c:deco(sp[1], neon(round(p, Vector3.xAxis, 0.1 * S, sp[5] * 1.6 * S, col)), "Star")
	end
	if c:detail("Medium") then
		for _, seg in tailSegments(c) do
			local i = tonumber(seg.Bone:sub(5)) or 0
			if i % 2 == 0 then
				local side = (i % 4 == 0) and 1 or -1
				c:deco(seg.Bone, neon(round((seg.F * CF(side * seg.Th * 0.47, 0, 0)).Position, seg.F.RightVector, 0.08 * S, seg.Th * 0.32, col)), "Star")
			end
		end
		for i, seg in neckSegments(c) do
			if i % 2 == 1 then
				c:deco(seg.Bone, neon(round((seg.F * CF(-seg.Th * 0.47, 0.1 * seg.Th, 0)).Position, seg.F.RightVector, 0.08 * S, seg.Th * 0.3, col)), "Star")
			end
		end
	end
end

-- glass crystal clusters on the back (replace the spines) and head
function FEATURES.Crystals(c, head)
	local col = c:color("Crystal")
	local S = c.S
	local function cluster(bone: string, base: Vector3, size: number)
		local dirs = { V3(0, 1, 0.2), V3(-0.55, 0.8, 0.3), V3(0.55, 0.8, 0.3) }
		for i, dv in dirs do
			if i == 1 or c:detail("Medium") then
				local d = dv.Unit
				local h = size * (i == 1 and 1.7 or 1.15)
				local b = base + V3(dv.X * size * 0.32, 0, 0)
				c:deco(bone, glassy(Primitives.spike(b, b + d * h, size * 0.62, size * 0.55, col)), "Crystal")
			end
		end
	end
	for i, spot in backSpots(c, { -0.36, 0.14, 0.4 }) do
		cluster(spot.Bone, spot.Pos - V3(0, 0.2 * S, 0), (i == 2 and 1.0 or 1.25) * S)
	end
	local u = head.U
	cluster("Head", (head.Frame * CF(0, head.SkullSize.Y / 2, 0.6 * u)).Position, 0.75 * u)
end

-- flowers on the head, back and tail
function FEATURES.Flowers(c, head)
	local u = head.U
	local S = c.S
	local petal = c:color("Accent")
	flower(c, "Head", (head.Frame * CF(head.SkullSize.X * 0.22, head.SkullSize.Y / 2 + 0.05 * u, -0.25 * u)).Position, head.Up, 1.0 * u, petal)
	for i, spot in backSpots(c, { -0.38, 0.16, 0.42 }) do
		local side = (i % 2 == 0) and -1 or 1
		local box = c.Boxes[spot.Bone]
		local p = V3(side * box.Size.X * 0.28, box.C.Y + box.Size.Y / 2 + box.Size.Y * 0.16, spot.Pos.Z)
		flower(c, spot.Bone, p, Vector3.yAxis, 1.15 * S, petal)
	end
	if c:detail("Medium") then
		local segs = tailSegments(c)
		local seg = segs[math.max(1, math.floor(#segs * 0.5))]
		flower(c, seg.Bone, (seg.F * CF(seg.Th * 0.3, seg.Th * 0.46, 0)).Position, seg.F.UpVector, seg.Th * 0.75, petal)
	end
end

-- branching antlers (replace the horns)
function FEATURES.Antlers(c, head)
	local u = head.U
	local col = c:color("Horn")
	local fwd, up = head.Fwd, head.Up
	for _, side in { -1, 1 } do
		local r = head.Right * side
		local root = (head.Frame * CF(side * head.SkullSize.X * 0.3, head.SkullSize.Y / 2 - 0.1 * u, 0.4 * u)).Position
		local p1 = root + up * 1.3 * u + r * 0.5 * u - fwd * 0.4 * u
		local p2 = p1 + up * 1.2 * u + r * 0.8 * u - fwd * 0.6 * u
		local p3 = p2 + up * 1.0 * u + r * 0.5 * u - fwd * 0.8 * u
		c:deco("Head", rod(root, p1, 0.55 * u, col), "Antler")
		c:deco("Head", rod(p1, p2, 0.46 * u, col), "Antler")
		c:deco("Head", rod(p2, p3, 0.4 * u, col), "Antler")
		c:deco("Head", rod(p1, p1 + up * 1.0 * u + fwd * 0.7 * u, 0.34 * u, col), "Antler")
		c:deco("Head", rod(p2, p2 + up * 0.9 * u + fwd * 0.6 * u + r * 0.2 * u, 0.32 * u, col), "Antler")
		c:deco("Head", rod(p3, p3 + up * 0.7 * u + r * 0.6 * u - fwd * 0.2 * u, 0.28 * u, col), "Antler")
		if c:detail("Medium") then
			c:deco("Head", round(p1, r, 0.6 * u, 0.62 * u, col), "AntlerKnob")
			c:deco("Head", round(p2, r, 0.5 * u, 0.52 * u, col), "AntlerKnob")
			-- little leaves (it's a forest dragon)
			c:deco("Head", plastic(Primitives.spike(p2, p2 + r * 0.9 * u + up * 0.3 * u, 0.6 * u, 0.12 * u, c:color("Membrane"))), "Leaf")
		end
	end
end

-- rows of sharp thorns on the flanks and tail
function FEATURES.Thorns(c)
	local S = c.S
	local col = c:color("Horn")
	for _, name in { "Chest", "Body", "Pelvis" } do
		local box = c.Boxes[name]
		for _, side in { -1, 1 } do
			for _, fz in (name == "Body" and { 0 } or { -0.25, 0.25 }) do
				local base = box.C + V3(side * box.Size.X / 2, box.Size.Y * 0.18, fz * box.Size.Z)
				local tip = base + V3(side * 1.0 * S, 0.45 * S, 0.35 * S)
				c:deco(name, plastic(Primitives.spike(base, tip, 0.7 * S, 0.5 * S, col)), "Thorn")
			end
		end
	end
	if c:detail("Medium") then
		for _, seg in tailSegments(c) do
			local i = tonumber(seg.Bone:sub(5)) or 0
			if i % 2 == 1 and i < c.Def.Tail.Segments then
				for _, side in { -1, 1 } do
					local base = (seg.F * CF(side * seg.Th * 0.48, 0, 0)).Position
					local tip = base + seg.F.RightVector * side * seg.Th * 0.7 + seg.F.LookVector * seg.Th * 0.3
					c:deco(seg.Bone, plastic(Primitives.spike(base, tip, seg.Th * 0.5, seg.Th * 0.35, col)), "Thorn")
				end
			end
		end
	end
end

-- big bat ears (replace the frills)
function FEATURES.BigEars(c, head)
	local u = head.U
	local k = c.Brick.EarScale or 1.5
	local outer, inner = c:color("Main"), c:color("Accent")
	for _, side in { -1, 1 } do
		local r = head.Right * side
		local a = (head.Frame * CF(side * head.SkullSize.X * 0.4, head.SkullSize.Y * 0.42, -0.1 * u)).Position
		local b = (head.Frame * CF(side * head.SkullSize.X * 0.42, head.SkullSize.Y * 0.2, 1.0 * u)).Position
		local tip = a + r * 1.0 * k * u + head.Up * 1.9 * k * u - head.Fwd * 0.9 * k * u
		for _, p in Primitives.triangle(a, b, tip, 0.24 * u, outer, PLASTIC) do
			c:deco("Head", plastic(p), "Ear")
		end
		if c:detail("Medium") then
			local n = (b - a):Cross(tip - a).Unit
			if n:Dot(head.Fwd + r * 0.5) < 0 then
				n = -n
			end
			local mid = (a + b + tip) / 3
			local function shrink(p: Vector3)
				return mid + (p - mid) * 0.62 + n * 0.16 * u
			end
			for _, p in Primitives.triangle(shrink(a), shrink(b), shrink(tip), 0.12 * u, inner, PLASTIC) do
				c:deco("Head", plastic(p), "EarInner")
			end
		end
	end
end

-- ============================================================== aura (exclusive dragons)
local AURA_SPECS = {
	{ Kind = "Sparkle", Color = Color3.fromRGB(255, 205, 60) },
	{ Kind = "Sparkle", Color = Color3.fromRGB(255, 70, 50) },
}

-- Dragon Bond level 50: golden-white sparkles and a warm glow around the dragon
local BOND_AURA_SPECS = {
	{ Kind = "Sparkle", Color = Color3.fromRGB(255, 226, 120) },
	{ Kind = "Sparkle", Color = Color3.fromRGB(255, 255, 255) },
	{ Kind = "Sparkle", Color = Color3.fromRGB(255, 160, 210) },
}

-- ============================================================== mutation fx
-- Part roles from names (palette slot each piece was built from).
local NAME_ROLE = {
	Body = "Main", Chest = "Main", Pelvis = "Main", Head = "Main", Roof = "Main", Ridge = "Main", ChestSlope = "Main",
	HipSlope = "Main", Forehead = "Main", Snout = "Main", NoseSlope = "Main", Shoulder = "Main", Haunch = "Main", Ear = "Main",
	NeckJoint = "Dark", TailJoint = "Dark", Cheek = "Dark", Brow = "Dark", Stud = "Dark", Elbow = "Dark", Knee = "Dark",
	Belly = "Belly", ChestPlate = "Belly", Throat = "Belly", Jaw = "Belly", TailBelly = "Belly",
	ShoulderDisc = "Accent", NeckFin = "Accent", TailSpike = "Accent", Spine = "Accent", Frill = "Accent", Knuckle = "Accent",
	FingerTip = "Accent", TailTip = "Accent", TailFin = "Accent", EarInner = "Accent", WhiskerTip = "Accent", Petal = "Accent",
	Horn = "Horn", HornTip = "Horn", TailClub = "Horn", Thorn = "Horn", Antler = "Horn", AntlerKnob = "Horn",
	Membrane = "Membrane", Claw = "Claw", WingClaw = "Claw", Tooth = "Claw",
	Glow = "Glow", TailFlame = "Glow", Flame = "Glow", Halo = "Glow", Star = "Glow",
	Crystal = "Crystal", Mane = "Mane", Whisker = "Mane",
}

local function roleOf(name: string): string?
	local r = NAME_ROLE[name]
	if r then
		return r
	end
	if name:match("^Neck%d") or name:match("^Tail%d") or name:match("^Arm") or name:match("^Leg") then
		return "Main"
	end
	if name:match("^Hand") or name:match("^Foot") or name:match("^Wing") then
		return "Dark"
	end
	return nil
end
BrickBuilder.roleOf = roleOf

local C3 = Color3.fromRGB
local MUTATION_FX = {
	Shiny = { Particles = { { Kind = "Sparkle", Color = C3(170, 240, 255) } } },
	Golden = {
		Reflect = { Main = 0.32, Dark = 0.32, Belly = 0.22, Horn = 0.32, Accent = 0.3, Membrane = 0.18, Mane = 0.25 },
		Particles = { { Kind = "Sparkle", Color = C3(255, 220, 110) } },
	},
	Frost = { Glass = { Horn = true, Accent = true, Claw = true, Crystal = true }, Particles = { { Kind = "Snow", Color = C3(230, 248, 255) } } },
	Toxic = { Neon = { Accent = true, Glow = true }, Particles = { { Kind = "Bubbles", Color = C3(150, 255, 70) } } },
	Lava = { Neon = { Accent = true, Belly = true, Glow = true }, Particles = { { Kind = "Fire", Color = C3(255, 130, 30) } } },
	Shadow = { Neon = { Accent = true, Glow = true }, Particles = { { Kind = "Smoke", Color = C3(110, 50, 190) } } },
	Diamond = {
		Reflect = { Main = 0.26, Dark = 0.26, Belly = 0.2, Membrane = 0.2 },
		Glass = { Horn = true, Accent = true, Claw = true, Crystal = true },
		Particles = { { Kind = "Sparkle", Color = C3(235, 250, 255) } },
	},
	Galaxy = { Neon = { Accent = true, Glow = true }, Stars = C3(255, 255, 255), Particles = { { Kind = "Sparkle", Color = C3(150, 170, 255) } } },
	Rainbow = { Rainbow = true, Particles = { { Kind = "Sparkle", Rainbow = true } } },
	Void = {
		Neon = { Accent = true, Glow = true },
		Stars = C3(225, 180, 255),
		Particles = { { Kind = "Smoke", Color = C3(45, 0, 70) }, { Kind = "Sparkle", Color = C3(200, 120, 255) } },
	},
	-- Neon: every plate glows in electric cyan / magenta and the wings leave light ribbons
	Neon = {
		Neon = { Main = true, Dark = true, Belly = true, Membrane = true, Accent = true, Glow = true, Horn = true },
		Light = { Color = C3(80, 255, 230), Range = 15, Brightness = 1.2 },
		Trail = { Color = C3(80, 255, 230), Color2 = C3(255, 70, 210) },
		Particles = { { Kind = "Sparkle", Color = C3(90, 255, 235) }, { Kind = "Sparkle", Color = C3(255, 80, 220) } },
	},
	-- Infernal: burning red body, hellfire, embers and a smoky trail
	Infernal = {
		Neon = { Accent = true, Belly = true, Glow = true },
		Light = { Color = C3(255, 110, 30), Range = 17, Brightness = 1.5 },
		Trail = { Color = C3(255, 120, 30), Color2 = C3(110, 10, 10) },
		Particles = { { Kind = "Fire", Color = C3(255, 130, 30) }, { Kind = "Embers" }, { Kind = "Smoke", Color = C3(60, 20, 20) } },
	},
	-- Corrupted: glitching magenta/cyan static around a purple-black body, red eyes
	Corrupted = {
		Neon = { Accent = true, Glow = true },
		Light = { Color = C3(255, 30, 150), Range = 13, Brightness = 1 },
		Particles = { { Kind = "Glitch" }, { Kind = "Smoke", Color = C3(70, 0, 90) } },
	},
	-- Crystal: a translucent amethyst body with crystal clusters instead of spines
	Crystal = {
		Glass = { Main = true, Dark = true, Horn = true, Accent = true, Claw = true, Crystal = true, Membrane = true },
		Reflect = { Belly = 0.25 },
		Features = { "Crystals" },
		Light = { Color = C3(190, 140, 255), Range = 15, Brightness = 1 },
		Particles = { { Kind = "Sparkle", Color = C3(210, 170, 255) }, { Kind = "Sparkle", Color = C3(150, 255, 235) } },
	},
	-- Lightning: electric blue body, yellow neon veins, crackling sparks, spark ribbons
	Lightning = {
		Neon = { Accent = true, Glow = true, Horn = true, Belly = true },
		Light = { Color = C3(255, 240, 90), Range = 19, Brightness = 1.7 },
		Trail = { Color = C3(255, 245, 120), Color2 = C3(255, 255, 255) },
		Particles = { { Kind = "Zap", Color = C3(255, 245, 140) }, { Kind = "Zap", Color = C3(150, 200, 255) } },
	},
	-- Angelic: halo, glowing wings, drifting white feathers and a golden light trail
	Angelic = {
		Neon = { Membrane = true, Glow = true },
		Reflect = { Main = 0.12, Horn = 0.3 },
		Features = { "Halo" },
		Light = { Color = C3(255, 240, 200), Range = 19, Brightness = 1.3 },
		Trail = { Color = C3(255, 246, 215), Color2 = C3(255, 215, 110) },
		Particles = { { Kind = "Feathers" }, { Kind = "Sparkle", Color = C3(255, 224, 130) } },
	},
	-- every mutation at once (exclusive dragons): glowing accents, stars,
	-- golden shine, rainbow + gold sparkles, fire and a void haze
	Omni = {
		Neon = { Accent = true, Glow = true },
		Reflect = { Main = 0.14, Dark = 0.14, Horn = 0.3, Belly = 0.1 },
		Stars = C3(255, 255, 255),
		Particles = {
			{ Kind = "Sparkle", Rainbow = true },
			{ Kind = "Sparkle", Color = C3(255, 220, 110) },
			{ Kind = "Fire", Color = C3(255, 130, 30) },
			{ Kind = "Smoke", Color = C3(70, 20, 110) },
		},
	},
}
BrickBuilder.MutationFx = MUTATION_FX

local TEX = {
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Fire = "rbxasset://textures/particles/fire_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
}

local function seq(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

local RAINBOW_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0, C3(255, 90, 90)),
	ColorSequenceKeypoint.new(0.2, C3(255, 200, 60)),
	ColorSequenceKeypoint.new(0.4, C3(120, 255, 100)),
	ColorSequenceKeypoint.new(0.6, C3(80, 200, 255)),
	ColorSequenceKeypoint.new(0.8, C3(170, 110, 255)),
	ColorSequenceKeypoint.new(1, C3(255, 110, 200)),
})

local function emitter(c, spec)
	local host = c.Bones.Body
	local S = c.S
	local k = c:detail("High") and 1 or 0.5
	local e = Instance.new("ParticleEmitter")
	e.Name = "MutationFx"
	e.Color = spec.Rainbow and RAINBOW_SEQ or ColorSequence.new(spec.Color or Color3.new(1, 1, 1))
	e.LightEmission = 1
	e.LightInfluence = 0
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	if spec.Kind == "Sparkle" then
		e.Texture = TEX.Sparkle
		e.Rate = 10 * k
		e.Lifetime = NumberRange.new(0.8, 1.5)
		e.Speed = NumberRange.new(0.5, 2)
		e.Drag = 2
		e.Size = seq({ { 0, 0 }, { 0.3, 0.7 * S }, { 1, 0 } })
	elseif spec.Kind == "Snow" then
		e.Texture = TEX.Sparkle
		e.Rate = 9 * k
		e.Lifetime = NumberRange.new(1.8, 2.8)
		e.Speed = NumberRange.new(0.3, 1)
		e.Acceleration = Vector3.new(0, -2.5, 0)
		e.Size = seq({ { 0, 0.35 * S }, { 1, 0.15 * S } })
		e.Transparency = seq({ { 0, 0.1 }, { 0.8, 0.3 }, { 1, 1 } })
	elseif spec.Kind == "Bubbles" then
		e.Texture = TEX.Sparkle
		e.Rate = 8 * k
		e.Lifetime = NumberRange.new(1, 1.8)
		e.Speed = NumberRange.new(0.5, 1.5)
		e.Acceleration = Vector3.new(0, 3, 0)
		e.Size = seq({ { 0, 0.2 * S }, { 0.6, 0.55 * S }, { 1, 0 } })
		e.Transparency = seq({ { 0, 0.2 }, { 1, 0.6 } })
	elseif spec.Kind == "Fire" then
		e.Texture = TEX.Fire
		e.Rate = 16 * k
		e.Lifetime = NumberRange.new(0.5, 0.9)
		e.Speed = NumberRange.new(1, 3)
		e.SpreadAngle = Vector2.new(25, 25)
		e.Acceleration = Vector3.new(0, 7, 0)
		e.Color = ColorSequence.new(C3(255, 200, 80), C3(255, 70, 20))
		e.Size = seq({ { 0, 1.0 * S }, { 1, 0.1 * S } })
		e.Transparency = seq({ { 0, 0.3 }, { 1, 1 } })
	elseif spec.Kind == "Smoke" then
		e.Texture = TEX.Smoke
		e.Rate = 5 * k
		e.Lifetime = NumberRange.new(1.5, 2.5)
		e.Speed = NumberRange.new(0.3, 1)
		e.Acceleration = Vector3.new(0, 1.2, 0)
		e.LightEmission = 0.2
		e.Size = seq({ { 0, 1.0 * S }, { 1, 2.6 * S } })
		e.Transparency = seq({ { 0, 0.55 }, { 1, 1 } })
	elseif spec.Kind == "Embers" then
		-- glowing sparks drifting up (Infernal)
		e.Texture = TEX.Sparkle
		e.Rate = 14 * k
		e.Lifetime = NumberRange.new(1.2, 2.2)
		e.Speed = NumberRange.new(2, 5)
		e.SpreadAngle = Vector2.new(40, 40)
		e.Acceleration = Vector3.new(0, 6, 0)
		e.Color = ColorSequence.new(C3(255, 200, 80), C3(255, 70, 20))
		e.Size = seq({ { 0, 0.4 * S }, { 1, 0 } })
		e.Transparency = seq({ { 0, 0 }, { 0.7, 0.3 }, { 1, 1 } })
	elseif spec.Kind == "Glitch" then
		-- flickering static blocks (Corrupted): magenta, cyan and black in fast succession
		e.Texture = TEX.Sparkle
		e.Rate = 26 * k
		e.Lifetime = NumberRange.new(0.2, 0.45)
		e.Speed = NumberRange.new(0, 3)
		e.RotSpeed = NumberRange.new(-400, 400)
		e.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C3(255, 30, 160)),
			ColorSequenceKeypoint.new(0.5, C3(40, 240, 255)),
			ColorSequenceKeypoint.new(1, C3(20, 0, 30)),
		})
		e.Size = seq({ { 0, 0.55 * S }, { 0.5, 0.3 * S }, { 1, 0.7 * S } })
		e.Shape = Enum.ParticleEmitterShape.Box
	elseif spec.Kind == "Zap" then
		-- fast, short-lived electric sparks (Lightning)
		e.Texture = TEX.Sparkle
		e.Rate = 34 * k
		e.Lifetime = NumberRange.new(0.12, 0.28)
		e.Speed = NumberRange.new(12, 26)
		e.Drag = 0
		e.Size = seq({ { 0, 0.45 * S }, { 1, 0 } })
		e.Transparency = seq({ { 0, 0 }, { 1, 0.6 } })
	elseif spec.Kind == "Feathers" then
		-- white feathers floating down (Angelic)
		e.Texture = TEX.Sparkle
		e.Rate = 5 * k
		e.Lifetime = NumberRange.new(2.4, 3.4)
		e.Speed = NumberRange.new(0.3, 1)
		e.Acceleration = Vector3.new(0, -1.6, 0)
		e.LightEmission = 0.5
		e.RotSpeed = NumberRange.new(-120, 120)
		e.Color = ColorSequence.new(Color3.new(1, 1, 1))
		e.Size = seq({ { 0, 0.55 * S }, { 1, 0.4 * S } })
		e.Transparency = seq({ { 0, 0.1 }, { 0.7, 0.3 }, { 1, 1 } })
		e.Shape = Enum.ParticleEmitterShape.Box
	end
	e.Parent = host
	return e
end

local function rainbowColors(c)
	local zmin, zmax, xmax = math.huge, -math.huge, 1
	for part, cf in c.Build do
		if part ~= c.Bones.Root then
			local p = cf.Position
			zmin = math.min(zmin, p.Z)
			zmax = math.max(zmax, p.Z)
			if part.Name == "Membrane" then
				xmax = math.max(xmax, math.abs(p.X))
			end
		end
	end
	local span = math.max(1, zmax - zmin)
	for part, cf in c.Build do
		local role = roleOf(part.Name)
		local t = (cf.Position.Z - zmin) / span
		local h = (t * 0.85) % 1
		if role == "Main" then
			part.Color = Color3.fromHSV(h, 0.62, 1)
		elseif role == "Dark" then
			part.Color = Color3.fromHSV(h, 0.85, 0.82)
		elseif role == "Accent" or role == "Glow" then
			part.Color = Color3.fromHSV((h + 0.4) % 1, 0.7, 1)
		elseif role == "Membrane" then
			part.Color = Color3.fromHSV((math.abs(cf.Position.X) / xmax * 0.8) % 1, 0.5, 1)
		end
	end
end

local function applyFx(c, mutation: string?)
	if c.Statue then
		return
	end
	if c.Features.Aura and c:detail("Medium") then
		for _, spec in AURA_SPECS do
			emitter(c, spec)
		end
	end
	if c.BondAura and c:detail("Medium") then
		for _, spec in BOND_AURA_SPECS do
			local e = emitter(c, spec)
			e.Name = "BondAura"
			e.Rate *= 1.6
		end
		local glow = Instance.new("PointLight")
		glow.Name = "BondGlow"
		glow.Color = Color3.fromRGB(255, 214, 140)
		glow.Range = 16 * c.S
		glow.Brightness = 1.1
		glow.Shadows = false
		glow.Parent = c.Bones.Body
	end
	local shine = c.Brick.Shine
	local fx = mutation and MUTATION_FX[mutation]
	if not fx and not shine then
		return
	end
	if fx and fx.Stars and not c.Features.Stars then
		FEATURES.Stars(c, nil, fx.Stars)
	end
	if fx and fx.Rainbow then
		rainbowColors(c)
	end
	for part in c.Build do
		local role = roleOf(part.Name)
		if role then
			if shine and (role == "Main" or role == "Dark" or role == "Horn") then
				part.Reflectance = shine
			end
			if fx then
				if fx.Reflect and fx.Reflect[role] then
					part.Reflectance = fx.Reflect[role]
				end
				if fx.Glass and fx.Glass[role] then
					glassy(part, 0.15)
				end
				if fx.Neon and fx.Neon[role] then
					neon(part)
				end
			end
		end
	end
	if fx and fx.Particles and c:detail("Medium") then
		for _, spec in fx.Particles do
			emitter(c, spec)
		end
	end
	if fx and fx.Light and c:detail("Medium") then
		-- the dragon lights up its surroundings in its mutation colour
		local light = Instance.new("PointLight")
		light.Name = "MutationLight"
		light.Color = fx.Light.Color
		light.Range = fx.Light.Range * c.S
		light.Brightness = fx.Light.Brightness
		light.Shadows = false
		light.Parent = c.Bones.Body
	end
	if fx and fx.Trail and c:detail("Medium") then
		-- ribbons of light behind both wing tips (only visible while the wings move)
		for _, side in { "L", "R" } do
			local tip = c.Bones["Wing" .. side .. "3"]
			local a0 = tip and tip:FindFirstChild("WingTip" .. side)
			local a1 = tip and tip:FindFirstChild("WingTipInner" .. side)
			if a0 and a1 then
				local trail = Instance.new("Trail")
				trail.Name = "MutationTrail"
				trail.Attachment0 = a0
				trail.Attachment1 = a1
				trail.Color = ColorSequence.new(fx.Trail.Color, fx.Trail.Color2)
				trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
				trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.1) })
				trail.Lifetime = 0.6
				trail.MinLength = 0.05
				trail.LightEmission = 1
				trail.LightInfluence = 0
				trail.FaceCamera = true
				trail.Parent = tip
			end
		end
	end
end

-- ============================================================== public
local function buildRoot(c, existing: BasePart?)
	local root = existing
	if root then
		c.Build[root] = CFrame.identity
	else
		root = require(script.Parent:WaitForChild("Builder")).makeRoot(c.SpeciesId, c.ScaleOverride)
		c.Build[root] = CFrame.identity
		root.Parent = c.Model
		c.Model.PrimaryPart = root
	end
	c.Bones.Root = root
	c.Model:SetAttribute("HipHeight", c.Def.HipHeight * c.S)
end

function BrickBuilder.build(speciesId: string, opts: { [string]: any }?)
	local o = table.clone(opts or {})
	o.SpeciesId = speciesId
	local def = Species.get(speciesId)
	local c = newCtx(def, o)
	if o.Mutation and o.Mutation ~= "None" then
		c.Palette = Species.mutatePalette(def.Palette, o.Mutation)
	end
	if o.Statue then
		c.Palette = Species.statuePalette(o.StatueColor)
	end
	local mfx = o.Mutation and MUTATION_FX[o.Mutation]
	if mfx and mfx.Features then
		for _, f in mfx.Features do
			-- (a mutation's crystals replace the spines like the species' own do)
			c.MutationFeatures = c.MutationFeatures or {}
			c.MutationFeatures[f] = not c.Features[f]
			c.Features[f] = true
		end
	end
	buildRoot(c, o.Root)
	buildTorso(c)
	local neckEnd = buildNeck(c)
	local head = buildHead(c, neckEnd)
	buildHorns(c, head)
	buildTail(c)
	buildLegs(c)
	buildWings(c)
	if not (c.Features.BackFlames or c.Features.Crystals) then
		buildSpines(c)
	end
	if not o.Statue and o.Saddle ~= false then
		buildSaddle(c)
	end
	for _, feature in def.Features or {} do
		local fn = FEATURES[feature]
		if fn then
			fn(c, head)
		end
	end
	-- features the mutation brings along (halo, crystals) unless the species has them already
	for feature, extra in c.MutationFeatures or {} do
		local fn = FEATURES[feature]
		if fn and extra then
			fn(c, head)
		end
	end
	applyFx(c, o.Mutation)
	c:attach("Jaw", "Mouth", head.Skull + head.Fwd * (2.6 * head.Hs * c.S) + head.Up * (-0.5 * head.Hs * c.S))
	local model = c.Model
	model.Name = def.Name or speciesId
	model:SetAttribute("SpeciesId", speciesId)
	model:SetAttribute("Scale", c.S)
	model:SetAttribute("BodyRadius", (def.BodyRadius or 4.2) * c.S)
	model:SetAttribute("Parts", c.PartCount)
	model:SetAttribute("Rig", def.Rig or "Quadruped")
	model:SetAttribute("Style", "Brick")
	if o.Mutation then
		model:SetAttribute("Mutation", o.Mutation)
	end
	return model
end

return BrickBuilder

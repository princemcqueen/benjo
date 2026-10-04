--[[
	Dragon Builder
	Parametric, code-built dragons with a Motor6D skeleton.

	build(speciesId, { Mutation, Detail = "High"|"Medium"|"Low", Statue = bool,
	                   Material = Enum.Material? }) -> Model

	Model layout:
	  Root (invisible physics body, PrimaryPart)
	    Motor6D chain: Body, Chest, Pelvis, Neck1..n, Head, Jaw, Tail1..n,
	    ArmL1/2/HandL (+R), LegL1/2/FootL (+R), WingL1/2/3 (+R)
	  Decorations are Welded to their bone.
	  Seat "Saddle" welded to Body (riders sit here).

	All joints use model-aligned pivot frames so animation rotations are
	authored in a consistent space: X = pitch, Y = yaw, Z = roll.
	Coordinates are authored for scale 1 (Green Drake) and multiplied by the
	species Scale.
]]

local Primitives = require(script.Parent:WaitForChild("Primitives"))
local Species = require(script.Parent:WaitForChild("Species"))
local Membranes = require(script.Parent:WaitForChild("Membranes"))

local Builder = {}

local V3 = Vector3.new
local rad = math.rad

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
	self.Palette = def.Palette
	self.Model = Instance.new("Model")
	self.Bones = {}
	self.Build = {} -- [part] = build-space CFrame (root at the origin)
	self.PartCount = 0
	self.Material = opts.Material
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

function Ctx:mat(key: string?): Enum.Material
	if self.Material then
		return self.Material
	end
	if key then
		local m = self.Def.Materials and self.Def.Materials[key]
		if m then
			return m
		end
	end
	return Enum.Material.SmoothPlastic
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

-- Bone: a visible part that animation joints drive.
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

-- Decoration welded to a bone.
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

function Ctx:decoMany(boneName: string, parts: { BasePart }, name: string?)
	for _, p in parts do
		self:deco(boneName, p, name)
	end
end

function Ctx:attach(boneName: string, name: string, worldPos: Vector3)
	local bone = self.Bones[boneName]
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = self.Build[bone]:ToObjectSpace(CFrame.new(worldPos))
	a.Parent = bone
	return a
end

local E = Primitives.ellipsoid
local EB = Primitives.ellipsoidBetween

-- ============================================================== body parts
local function buildTorso(c)
	local d = c.Def.Body
	local L, W, H = d.Length, d.Width, d.Height
	local cs, hs = d.ChestScale or 1.05, d.HipScale or 0.9
	c:bone("Body", E(c:v(W, H, L), CFrame.new(c:v(0, 0.1, 0.4)), c:color("Main"), c:mat("Main")), "Root", c:v(0, 0.1, 0.4))
	c:bone("Chest", E(c:v(W * cs, H * cs, L * 0.6), CFrame.new(c:v(0, 0.35, -L * 0.36)), c:color("Main"), c:mat("Main")), "Body", c:v(0, 0.3, -L * 0.2))
	c:bone("Pelvis", E(c:v(W * hs, H * hs, L * 0.55), CFrame.new(c:v(0, 0.2, L * 0.43)), c:color("Main"), c:mat("Main")), "Body", c:v(0, 0.2, L * 0.3))
	-- belly plates (lighter underside)
	c:deco("Body", E(c:v(W * 0.74, H * 0.42, L * 0.86), CFrame.new(c:v(0, -H * 0.27, 0.3)), c:color("Belly"), c:mat("Belly")), "Belly")
	c:deco("Chest", E(c:v(W * 0.72, H * 0.62, L * 0.44), CFrame.new(c:v(0, -H * 0.12, -L * 0.48)), c:color("Belly"), c:mat("Belly")), "Belly")
	-- darker back ridge for depth
	if c:detail("Medium") then
		c:deco("Body", E(c:v(W * 0.55, H * 0.35, L * 0.92), CFrame.new(c:v(0, H * 0.36, 0.3)), c:color("Dark"), c:mat("Main")), "Ridge")
	end
end

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

local function buildNeck(c)
	local d = c.Def.Neck
	local pts = neckPoints(c)
	local parent = "Chest"
	for i = 1, d.Segments do
		local t = (i - 1) / math.max(1, d.Segments - 1)
		local th = d.Thickness * (1 - (1 - (d.Taper or 0.75)) * t)
		local a, b = c:sc(pts[i]), c:sc(pts[i + 1])
		local name = "Neck" .. i
		c:bone(name, EB(a, b, th * c.S, th * c.S * 0.98, c:color("Main"), c:mat("Main"), 1.6), parent, a)
		-- joint filler keeps the neck continuous while it bends
		c:deco(name, Primitives.ball(th * 0.98 * c.S, CFrame.new(a), c:color("Main"), c:mat("Main")), "NeckJoint")
		-- throat plate
		c:deco(name, EB(a + V3(0, -th * 0.28 * c.S, -0.1 * c.S), b + V3(0, -th * 0.28 * c.S, -0.1 * c.S), th * 0.62 * c.S, th * 0.5 * c.S, c:color("Belly"), c:mat("Belly"), 1.2), "Throat")
		parent = name
	end
	return pts[#pts]
end

local function buildHead(c, neckEnd: Vector3)
	local d = c.Def.Head
	local hs = d.Size or 1
	local S = c.S
	local base = neckEnd * S
	local tilt = rad(d.Tilt or -8)
	local fwd = V3(0, math.sin(tilt), -math.cos(tilt))
	local up = V3(0, math.cos(tilt), math.sin(tilt))
	local skullC = base + fwd * (0.95 * hs * S) + up * (0.25 * hs * S)
	local skullCF = CFrame.lookAt(skullC, skullC + fwd, up)
	local skullSize = V3(2.5, 2.1, 2.8) * hs * S * (d.SkullScale or 1)
	c:bone("Head", E(skullSize, skullCF, c:color("Main"), c:mat("Main")), "Neck" .. c.Def.Neck.Segments, base)

	local snoutLen = (d.Snout or 1) * 2.6 * hs * S
	local snoutC = skullC + fwd * (1.45 * hs * S + snoutLen * 0.18) + up * (-0.28 * hs * S)
	c:deco("Head", E(V3(1.75 * hs * S * (d.SnoutWidth or 1), 1.28 * hs * S, snoutLen), CFrame.lookAt(snoutC, snoutC + fwd, up), c:color("Main"), c:mat("Main")), "Snout")
	-- upper lip / nose bridge in darker tone
	c:deco("Head", E(V3(1.1 * hs * S, 0.7 * hs * S, snoutLen * 0.8), CFrame.lookAt(snoutC + up * 0.42 * hs * S, snoutC + up * 0.42 * hs * S + fwd, up), c:color("Dark"), c:mat("Main")), "Bridge")

	-- jaw (separate bone for roar / eat)
	local hinge = skullC + up * (-0.6 * hs * S) + fwd * (-0.1 * hs * S)
	local jawC = hinge + fwd * (1.35 * hs * S) + up * (-0.22 * hs * S)
	c:bone("Jaw", E(V3(1.45 * hs * S, 0.62 * hs * S, 2.5 * hs * S * (d.Snout or 1)), CFrame.lookAt(jawC, jawC + fwd, up), c:color("Belly"), c:mat("Belly")), "Head", hinge)
	if c:detail("Medium") then
		-- teeth
		for _, side in { -1, 1 } do
			for i = 0, 1 do
				local tp = snoutC + fwd * ((0.4 - i * 0.7) * hs * S) + up * (-0.62 * hs * S) + V3(side * 0.55 * hs * S, 0, 0)
				c:deco("Head", Primitives.spike(tp, tp + up * (-0.32 * hs * S), 0.18 * hs * S, 0.12 * hs * S, c:color("Tooth")), "Tooth")
			end
		end
	end

	-- eyes: amber glow + slit pupil + brow ridge
	for _, side in { -1, 1 } do
		local eyeC = skullC + up * (0.36 * hs * S) + fwd * (0.62 * hs * S) + V3(side * 0.86 * hs * S * (d.EyeSpread or 1), 0, 0)
		local eyeCF = CFrame.lookAt(eyeC, eyeC + V3(side, 0, 0) + fwd * 0.6, up)
		c:deco("Head", E(V3(0.62, 0.52, 0.3) * hs * S, eyeCF, c:color("Eye"), Enum.Material.Neon), "Eye")
		if c:detail("Medium") then
			c:deco("Head", Primitives.block(V3(0.07, 0.4, 0.1) * hs * S, eyeCF * CFrame.new(0, 0, -0.1 * hs * S), c:color("Pupil")), "Pupil")
		end
		local browC = eyeC + up * (0.3 * hs * S) + fwd * (-0.05 * hs * S)
		c:deco("Head", E(V3(0.5, 0.36, 1.2) * hs * S, CFrame.lookAt(browC, browC + fwd, up) * CFrame.Angles(0, 0, rad(side * 18)), c:color("Dark"), c:mat("Main")), "Brow")
		if c:detail("High") then
			local nos = snoutC + fwd * (snoutLen * 0.44) + up * (0.32 * hs * S) + V3(side * 0.34 * hs * S, 0, 0)
			c:deco("Head", Primitives.ball(0.24 * hs * S, CFrame.new(nos), c:color("Pupil")), "Nostril")
		end
	end
	return { Skull = skullC, Fwd = fwd, Up = up, Hs = hs }
end

local function buildHorns(c, head)
	local d = c.Def.Head
	local style = d.Horns or "Swept"
	local S, hs = c.S, head.Hs
	local fwd, up = head.Fwd, head.Up
	if style == "None" then
		return
	end
	for _, side in { -1, 1 } do
		local root = head.Skull + up * (0.82 * hs * S) + fwd * (-0.55 * hs * S) + V3(side * 0.62 * hs * S, 0, 0)
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
		local thick = (d.HornThickness or 0.55) * hs * S
		for _, seg in segs do
			local dv = (fwd * -seg.Z + up * seg.Y + V3(seg.X, 0, 0)) * hs * S * (d.HornLength or 1)
			local q = p + dv
			c:deco("Head", EB(p, q, thick, thick, c:color("Horn"), c:mat("Horn"), 1.3), "Horn")
			thick *= 0.62
			p = q
		end
		c:deco("Head", EB(p - (p - root).Unit * thick * 0.5, p + (p - root).Unit * thick * 1.6, thick, thick, c:color("Horn"), c:mat("Horn"), 1.0), "HornTip")
	end
	-- small cheek frills
	if c:detail("Medium") and (d.Frills ~= false) then
		for _, side in { -1, 1 } do
			local fc = head.Skull + up * (-0.05 * hs * S) + fwd * (-0.75 * hs * S) + V3(side * 1.05 * hs * S, 0, 0)
			c:deco("Head", Primitives.spike(fc, fc + V3(side * 0.6 * hs * S, 0.1 * hs * S, 0) + fwd * (-0.6 * hs * S), 0.5 * hs * S, 0.12 * hs * S, c:color("Accent")), "Frill")
		end
	end
end

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

local function buildTail(c)
	local d = c.Def.Tail
	local pts = tailPoints(c)
	local parent = "Pelvis"
	local n = d.Segments
	for i = 1, n do
		local t = (i - 1) / math.max(1, n - 1)
		local th = d.Thickness * (1 - (1 - (d.Taper or 0.3)) * t)
		local a, b = c:sc(pts[i]), c:sc(pts[i + 1])
		local name = "Tail" .. i
		c:bone(name, EB(a, b, th * c.S, th * 0.92 * c.S, c:color("Main"), c:mat("Main"), 1.55), parent, a)
		if i > 1 then
			c:deco(name, E(V3(th, th * 0.92, th) * c.S, CFrame.new(a), c:color("Main"), c:mat("Main")), "TailJoint")
		end
		if c:detail("Medium") then
			c:deco(name, EB(a + V3(0, -th * 0.3 * c.S, 0), b + V3(0, -th * 0.3 * c.S, 0), th * 0.6 * c.S, th * 0.45 * c.S, c:color("Belly"), c:mat("Belly"), 1.2), "TailBelly")
		end
		parent = name
	end
	-- tip
	local last = "Tail" .. n
	local e = c:sc(pts[n + 1])
	local tip = d.Tip or "Spade"
	local S = c.S
	if tip == "Spade" then
		local back = e + V3(0, 0, 1.35 * S)
		local l = e + V3(-0.78 * S, 0, 0.3 * S)
		local r = e + V3(0.78 * S, 0, 0.3 * S)
		local f = e + V3(0, 0, -0.75 * S)
		c:decoMany(last, Primitives.triangle(f, l, back, 0.16 * S, c:color("Dark")), "TailTip")
		c:decoMany(last, Primitives.triangle(f, r, back, 0.16 * S, c:color("Dark")), "TailTip")
	elseif tip == "Club" then
		c:deco(last, E(V3(1.6, 1.3, 2.0) * S, CFrame.new(e + V3(0, 0, 0.6 * S)), c:color("Horn"), c:mat("Horn")), "TailClub")
		for _, a in { 0, 120, 240 } do
			local o = V3(math.cos(rad(a)) * 0.6, math.sin(rad(a)) * 0.6 + 0.2, 0.5) * S
			c:deco(last, Primitives.spike(e + o, e + o * 2.1 + V3(0, 0, 0.4 * S), 0.4 * S, 0.3 * S, c:color("Horn")), "TailSpike")
		end
	elseif tip == "Fin" then
		local back = e + V3(0, 0, 2.2 * S)
		c:decoMany(last, Primitives.triangle(e + V3(0, 0, -0.6 * S), e + V3(0, 1.6 * S, 0.6 * S), back, 0.14 * S, c:color("Membrane")), "TailFin")
		c:decoMany(last, Primitives.triangle(e + V3(0, 0, -0.6 * S), e + V3(0, -1.3 * S, 0.6 * S), back, 0.14 * S, c:color("Membrane")), "TailFin")
	elseif tip == "Leaf" then
		local back = e + V3(0, 0, 2.4 * S)
		c:decoMany(last, Primitives.triangle(e + V3(0, 0, -0.4 * S), e + V3(-0.9 * S, 0.1 * S, 0.9 * S), back, 0.12 * S, c:color("Accent")), "TailLeaf")
		c:decoMany(last, Primitives.triangle(e + V3(0, 0, -0.4 * S), e + V3(0.9 * S, 0.1 * S, 0.9 * S), back, 0.12 * S, c:color("Accent")), "TailLeaf")
	elseif tip == "Crystal" then
		for i, o in { V3(0, 0.3, 0.8), V3(-0.5, 0.1, 0.5), V3(0.5, 0.1, 0.5) } do
			local base = e + o * S
			c:deco(last, Primitives.spike(base, base + V3(o.X * 1.2, 1.2 + (i == 1 and 0.6 or 0), 0.9) * S, 0.5 * S, 0.45 * S, c:color("Crystal"), Enum.Material.Glass), "Crystal")
		end
	elseif tip == "Flame" then
		c:deco(last, E(V3(1.0, 1.0, 1.6) * S, CFrame.new(e + V3(0, 0, 0.5 * S)), c:color("Glow"), Enum.Material.Neon), "TailFlame")
	elseif tip == "Plume" then
		for i = -1, 1 do
			local back = e + V3(i * 0.7 * S, 0, 2.6 * S)
			c:decoMany(last, Primitives.triangle(e, e + V3(i * 1.2 * S, 0.2 * S, 1.2 * S), back, 0.12 * S, c:color(i == 0 and "Accent" or "Membrane")), "TailPlume")
		end
	end
	return pts
end

local function buildLegs(c)
	local d = c.Def.Legs
	local L = c.Def.Body.Length
	local hip = c.Def.HipHeight
	local thick = d.Thickness or 1
	local groundY = -hip
	local function foot(boneName, parentName, pivot: Vector3, center: Vector3, size: Vector3, sideName: string)
		c:bone(boneName, E(c:sc(size), CFrame.new(c:sc(center)), c:color("Dark"), c:mat("Main")), parentName, c:sc(pivot))
		if c:detail("High") then
			for i = -1, 1 do
				local cp = c:sc(center + V3(i * size.X * 0.32, -size.Y * 0.1, -size.Z * 0.45))
				c:deco(boneName, Primitives.spike(cp, cp + c:sc(V3(i * 0.06, -0.25, -0.55)), 0.22 * c.S, 0.18 * c.S, c:color("Claw")), "Claw")
			end
		end
		c:attach(boneName, "Foot" .. sideName, c:sc(center + V3(0, -size.Y * 0.5, 0)))
	end
	for _, side in { -1, 1 } do
		local sn = side < 0 and "L" or "R"
		if d.Front then
			local sh = V3(side * c.Def.Body.Width * 0.4, -0.2, -L * 0.36)
			local el = sh + V3(side * 0.15, -(hip * 0.45), 0.25)
			local wr = el + V3(0, -(hip * 0.4), -0.15)
			local fc = V3(wr.X, groundY + 0.35, wr.Z - 0.35)
			c:bone("Arm" .. sn .. "1", EB(c:sc(sh), c:sc(el), 1.35 * thick * c.S, 1.45 * thick * c.S, c:color("Main"), c:mat("Main"), 1.3), "Chest", c:sc(sh))
			c:bone("Arm" .. sn .. "2", EB(c:sc(el), c:sc(wr), 1.05 * thick * c.S, 1.05 * thick * c.S, c:color("Main"), c:mat("Main"), 1.3), "Arm" .. sn .. "1", c:sc(el))
			c:deco("Arm" .. sn .. "2", Primitives.ball(1.12 * thick * c.S, CFrame.new(c:sc(el)), c:color("Main"), c:mat("Main")), "Elbow")
			c:deco("Arm" .. sn .. "1", E(c:sc(V3(1.7 * thick, 1.9, 1.9 * thick)), CFrame.new(c:sc(sh + V3(side * 0.05, -0.35, 0))), c:color("Main"), c:mat("Main")), "Shoulder")
			foot("Hand" .. sn, "Arm" .. sn .. "2", wr, fc, V3(1.3 * thick, 0.7, 1.85 * thick), "F" .. sn)
		end
		if d.Back then
			local hp = V3(side * c.Def.Body.Width * 0.38, 0.1, L * 0.4)
			local kn = hp + V3(side * 0.25, -(hip * 0.4), -0.65)
			local an = kn + V3(0, -(hip * 0.45), 1.0)
			local fc = V3(an.X, groundY + 0.35, an.Z - 0.45)
			local thighC = (hp + kn) / 2 + V3(0, 0.2, 0.25)
			c:bone("Leg" .. sn .. "1", E(c:sc(V3(2.0 * thick, hip * 0.66, 2.6 * thick)), CFrame.lookAt(c:sc(thighC), c:sc(thighC + V3(0, 0, -1))) * CFrame.Angles(rad(-14), 0, 0), c:color("Main"), c:mat("Main")), "Pelvis", c:sc(hp))
			c:bone("Leg" .. sn .. "2", EB(c:sc(kn), c:sc(an), 1.08 * thick * c.S, 1.08 * thick * c.S, c:color("Main"), c:mat("Main"), 1.3), "Leg" .. sn .. "1", c:sc(kn))
			c:deco("Leg" .. sn .. "2", Primitives.ball(1.2 * thick * c.S, CFrame.new(c:sc(kn)), c:color("Main"), c:mat("Main")), "Knee")
			foot("Foot" .. sn, "Leg" .. sn .. "2", an, fc, V3(1.4 * thick, 0.72, 2.0 * thick), "B" .. sn)
		end
	end
end

-- Bat-style wing: 5-bone skeleton per side (humerus, forearm, hand + main
-- finger, finger 2, finger 3). Membranes are dynamic (see Membranes.luau):
-- thin wedge meshes re-stretched between anchor attachments, so the wing can
-- fold tightly against the body and flex through every wing beat.
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
	local memMat = c:mat("Membrane")
	local depth = d.Type == "Tattered" and 0.42 or (d.Scallop or 0.2)
	local thickness = 0.14 * S
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
		-- bones
		c:bone(n .. "1", EB(c:sc(sh), c:sc(el), 0.8 * S, 0.72 * S, boneCol, c:mat("Main"), 1.15), "Chest", c:sc(sh))
		c:bone(n .. "2", EB(c:sc(el), c:sc(wr), 0.62 * S, 0.56 * S, boneCol, c:mat("Main"), 1.12), n .. "1", c:sc(el))
		c:bone(n .. "3", EB(c:sc(wr), c:sc(f1), 0.36 * S, 0.32 * S, boneCol, c:mat("Main"), 1.05), n .. "2", c:sc(wr))
		c:bone(n .. "4", EB(c:sc(wr), c:sc(f2), 0.32 * S, 0.3 * S, boneCol, c:mat("Main"), 1.04), n .. "3", c:sc(wr))
		c:bone(n .. "5", EB(c:sc(wr), c:sc(f3), 0.3 * S, 0.28 * S, boneCol, c:mat("Main"), 1.04), n .. "3", c:sc(wr))
		-- joint knuckles keep the arm continuous while folding
		c:deco(n .. "2", Primitives.ball(0.7 * S, CFrame.new(c:sc(el)), boneCol, c:mat("Main")), "Knuckle")
		c:deco(n .. "3", Primitives.ball(0.56 * S, CFrame.new(c:sc(wr)), boneCol, c:mat("Main")), "Knuckle")
		-- wing thumb claw
		if c:detail("Medium") then
			c:deco(n .. "2", Primitives.spike(c:sc(wr), c:sc(wr + m(0.25, 0.35, -0.85)), 0.26 * S, 0.2 * S, c:color("Claw")), "WingClaw")
		end
		-- glowing veins (crystal / celestial variants)
		if d.Glow then
			c:deco(n .. "3", EB(c:sc(wr), c:sc(f1), 0.16 * S, 0.16 * S, c:color("Glow"), Enum.Material.Neon, 1.0), "Glow")
			c:deco(n .. "4", EB(c:sc(wr), c:sc(f2), 0.14 * S, 0.14 * S, c:color("Glow"), Enum.Material.Neon, 1.0), "Glow")
			c:deco(n .. "5", EB(c:sc(wr), c:sc(f3), 0.12 * S, 0.12 * S, c:color("Glow"), Enum.Material.Neon, 1.0), "Glow")
		end
		-- membrane anchor points
		c:attach(n .. "1", "MemS" .. sn, c:sc(sh + m(-0.1, -0.15, 0.25)))
		c:attach(n .. "2", "MemE" .. sn, c:sc(el))
		c:attach(n .. "3", "MemW" .. sn, c:sc(wr))
		c:attach(n .. "3", "MemF1" .. sn, c:sc(f1))
		c:attach(n .. "4", "MemF2" .. sn, c:sc(f2))
		c:attach(n .. "5", "MemF3" .. sn, c:sc(f3))
		c:attach("Body", "MemB" .. sn, c:sc(bodyAttach))
		-- trail attachments
		c:attach(n .. "3", "WingTip" .. sn, c:sc(f1))
		c:attach(n .. "3", "WingTipInner" .. sn, c:sc(f1 + (wr - f1) * 0.18))
		-- membranes at the rest (spread) pose
		local P = {
			S = c:sc(sh + m(-0.1, -0.15, 0.25)),
			E = c:sc(el),
			W = c:sc(wr),
			F1 = c:sc(f1),
			F2 = c:sc(f2),
			F3 = c:sc(f3),
			B = c:sc(bodyAttach),
		}
		Membranes.buildPieces(c.Bones.Root, sn, P, thickness, depth, memColor, memMat, function(part)
			c:add(part, "Membrane")
		end)
	end
end

local function buildSpines(c)
	local d = c.Def.Spines
	if not d or d.Style == "None" or not c:detail("Medium") then
		return
	end
	local S = c.S
	local h0 = d.Height or 0.9
	local col = c:color(d.Color or "Dark")
	local mat = d.Material
	local function spineOn(boneName: string, base: Vector3, height: number)
		local tip = base + V3(0, height, height * 0.55)
		if d.Style == "Crystal" then
			c:deco(boneName, Primitives.spike(base, base + V3(0, height * 1.3, height * 0.2), height * 0.7, height * 0.55, c:color("Crystal"), Enum.Material.Glass), "Spine")
		else
			c:deco(boneName, Primitives.spike(base, tip, height * 1.0, 0.22 * S, col, mat), "Spine")
		end
	end
	-- neck
	local npts = neckPoints(c)
	for i = 1, c.Def.Neck.Segments do
		local a, b = npts[i], npts[i + 1]
		local th = c.Def.Neck.Thickness
		local p = (a + b) / 2 + V3(0, th * 0.42, 0.1)
		spineOn("Neck" .. i, c:sc(p), h0 * 0.8 * S)
	end
	-- back
	local L = c.Def.Body.Length
	local H = c.Def.Body.Height
	for i, z in { -L * 0.32, -L * 0.08, L * 0.16, L * 0.4 } do
		if c:detail("High") or i % 2 == 1 then
			local bone = z < -L * 0.2 and "Chest" or (z > L * 0.3 and "Pelvis" or "Body")
			if not (c.Def.Saddle ~= false and z > -L * 0.3 and z < L * 0.05) then
				spineOn(bone, c:sc(V3(0, H * 0.48 + 0.15, z)), h0 * S)
			end
		end
	end
	-- tail
	local tpts = tailPoints(c)
	for i = 1, c.Def.Tail.Segments - 1 do
		local a, b = tpts[i], tpts[i + 1]
		local t = (i - 1) / math.max(1, c.Def.Tail.Segments - 1)
		local th = c.Def.Tail.Thickness * (1 - (1 - (c.Def.Tail.Taper or 0.3)) * t)
		spineOn("Tail" .. i, c:sc((a + b) / 2 + V3(0, th * 0.42, 0)), h0 * (1 - t * 0.6) * S)
	end
end

local function buildSaddle(c)
	if c.Def.Saddle == false then
		return
	end
	local H = c.Def.Body.Height
	local L = c.Def.Body.Length
	local y = H * 0.5 + 0.05
	local z = -L * 0.16
	local leather = Color3.fromRGB(96, 58, 34)
	local cloth = c.Palette.Saddle or Color3.fromRGB(150, 36, 40)
	local gold = Color3.fromRGB(214, 172, 86)
	if c:detail("Medium") then
		c:deco("Body", Primitives.block(c:sc(V3(c.Def.Body.Width * 0.95, 0.16, 3.0)), CFrame.new(c:sc(V3(0, y - 0.18, z))), cloth, Enum.Material.Fabric), "SaddleCloth")
		c:deco("Body", Primitives.block(c:sc(V3(c.Def.Body.Width * 0.97, 0.12, 0.18)), CFrame.new(c:sc(V3(0, y - 0.16, z - 1.45))), gold, Enum.Material.Metal), "SaddleTrim")
		c:deco("Body", Primitives.block(c:sc(V3(c.Def.Body.Width * 0.97, 0.12, 0.18)), CFrame.new(c:sc(V3(0, y - 0.16, z + 1.45))), gold, Enum.Material.Metal), "SaddleTrim")
	end
	c:deco("Body", E(c:sc(V3(2.4, 0.62, 2.8)), CFrame.new(c:sc(V3(0, y + 0.08, z))), leather, Enum.Material.Leather), "Saddle")
	c:deco("Body", E(c:sc(V3(1.1, 0.9, 0.7)), CFrame.new(c:sc(V3(0, y + 0.35, z - 1.2))), leather, Enum.Material.Leather), "Pommel")
	c:deco("Body", E(c:sc(V3(2.0, 0.8, 0.6)), CFrame.new(c:sc(V3(0, y + 0.3, z + 1.25))), leather, Enum.Material.Leather), "Cantle")
	-- riders are jointed to the physics root (see Builder.mountInfo); this
	-- attachment marks the saddle surface on the animated body
	c:attach("Body", "SaddlePoint", c:sc(V3(0, y + 0.2, z)))
end

-- Physics root shared by server and client: invisible, non-colliding body.
function Builder.makeRoot(speciesId: string, scaleOverride: number?): BasePart
	local def = Species.get(speciesId)
	local S = (def.Scale or 1) * (scaleOverride or 1)
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = V3(def.Body.Width * 0.7, 3, def.Body.Length * 0.8) * S
	root.CFrame = CFrame.new()
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Massless = false
	root.Anchored = false
	root.RootPriority = 127
	root.CastShadow = false
	local att = Instance.new("Attachment")
	att.Name = "RootAttachment"
	att.Parent = root
	return root
end

local function buildRoot(c, existing: BasePart?)
	local root = existing
	if root then
		c.Build[root] = CFrame.identity
	else
		root = Builder.makeRoot(c.SpeciesId, c.ScaleOverride)
		c.Build[root] = CFrame.identity
		root.Parent = c.Model
		c.Model.PrimaryPart = root
	end
	c.Bones.Root = root
	c.Model:SetAttribute("HipHeight", c.Def.HipHeight * c.S)
end

-- ============================================================== public
-- Mount/physics numbers for a species without building any instances
-- (used by the server, which only owns the physics root).
function Builder.mountInfo(speciesId: string, scaleOverride: number?)
	local def = Species.get(speciesId)
	local S = (def.Scale or 1) * (scaleOverride or 1)
	local H, L = def.Body.Height, def.Body.Length
	return {
		Scale = S,
		HipHeight = def.HipHeight * S,
		BodyRadius = (def.BodyRadius or 4.2) * S,
		RootSize = V3(def.Body.Width * 0.7, 3, L * 0.8) * S,
		-- saddle seat surface in root space (matches buildSaddle)
		Saddle = CFrame.new(0, (H * 0.5 + 0.05 + 0.36) * S, -L * 0.16 * S),
		Length = (L + def.Tail.Length + def.Neck.Length) * S,
		WingSpan = def.Wings and (def.Wings.Span or 13) * 2 * S or 0,
	}
end

function Builder.build(speciesId: string, opts: { [string]: any }?)
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
	buildRoot(c, o.Root)
	buildTorso(c)
	local neckEnd = buildNeck(c)
	local head = buildHead(c, neckEnd)
	buildHorns(c, head)
	buildTail(c)
	buildLegs(c)
	buildWings(c)
	buildSpines(c)
	if not o.Statue and o.Saddle ~= false then
		buildSaddle(c)
	end
	-- mouth attachment for breath / roar FX
	c:attach("Jaw", "Mouth", head.Skull + head.Fwd * (2.6 * head.Hs * c.S) + head.Up * (-0.5 * head.Hs * c.S))
	if def.Features then
		for _, feature in def.Features do
			local fn = Species.FeatureBuilders[feature.Kind]
			if fn then
				fn(c, feature, head)
			end
		end
	end
	local model = c.Model
	model.Name = def.Name or speciesId
	model:SetAttribute("SpeciesId", speciesId)
	model:SetAttribute("Scale", c.S)
	model:SetAttribute("BodyRadius", (def.BodyRadius or 4.2) * c.S)
	model:SetAttribute("Parts", c.PartCount)
	model:SetAttribute("Rig", def.Rig or "Quadruped")
	if o.Mutation then
		model:SetAttribute("Mutation", o.Mutation)
	end
	return model
end

-- Static pose for previews, statues and ViewportFrames. Computes forward
-- kinematics from the joint data, anchors every part, removes the joints,
-- places the parts and stretches the wing membranes to match.
-- pose: { [jointName] = CFrame } (missing joints stay at rest).
function Builder.pose(model: Model, pose: { [string]: CFrame }?, rootCF: CFrame?)
	local root = model.PrimaryPart :: BasePart
	local rc = rootCF or root.CFrame
	local children: { [BasePart]: { any } } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("Weld") then
			local j = d :: any
			if j.Part0 and j.Part1 then
				children[j.Part0] = children[j.Part0] or {}
				table.insert(children[j.Part0], j)
			end
		end
	end
	local cfs: { [BasePart]: CFrame } = { [root] = rc }
	local boneCF: { [string]: CFrame } = { Root = rc }
	local function walk(part: BasePart, depth: number)
		if depth > 64 then
			return
		end
		for _, j in children[part] or {} do
			local p1 = j.Part1
			if not cfs[p1] then
				local isBone = j:IsA("Motor6D") and j.Name ~= "MemJoint"
				local tr = (isBone and pose and pose[j.Name]) or CFrame.identity
				local cf = cfs[part] * j.C0 * tr * j.C1:Inverse()
				cfs[p1] = cf
				if isBone then
					boneCF[p1.Name] = cf
				end
				walk(p1, depth + 1)
			end
		end
	end
	walk(root, 0)
	Builder.freeze(model)
	for part, cf in cfs do
		part.CFrame = cf
	end
	Membranes.new(model):Solve(boneCF, true)
end
Builder.bakePose = Builder.pose

-- Anchors everything (for static displays inside ViewportFrames).
function Builder.freeze(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		elseif d:IsA("JointInstance") then
			d:Destroy()
		end
	end
end

return Builder

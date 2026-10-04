--[[
	Primitives
	Part factories for code-built creatures. Every visual part is massless,
	non-colliding, non-queryable and non-touchable (the rig's invisible Root
	is the only physics body), so dragons never snag on the world or
	interfere with raycasts.
]]

local Primitives = {}

local function base(className: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = Instance.new(className) :: BasePart
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = true
	p.Material = material or Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

function Primitives.block(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	return base("Part", size, cf, color, material)
end

-- Smooth ellipsoid: a part with a Sphere SpecialMesh fills its Size exactly.
function Primitives.ellipsoid(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = base("Part", size, cf, color, material)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	return p
end

function Primitives.ball(diameter: number, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = base("Part", Vector3.new(diameter, diameter, diameter), cf, color, material)
	;(p :: Part).Shape = Enum.PartType.Ball
	return p
end

-- Cylinder whose axis runs from a to b.
function Primitives.cylinderBetween(a: Vector3, b: Vector3, diameter: number, color: Color3, material: Enum.Material?): BasePart
	local len = (b - a).Magnitude
	local mid = (a + b) / 2
	local cf = CFrame.lookAt(mid, b) * CFrame.Angles(0, math.rad(90), 0)
	local p = base("Part", Vector3.new(len, diameter, diameter), cf, color, material)
	;(p :: Part).Shape = Enum.PartType.Cylinder
	return p
end

-- Ellipsoid stretched between two points (good for bones, horns, limbs).
function Primitives.ellipsoidBetween(a: Vector3, b: Vector3, width: number, height: number?, color: Color3, material: Enum.Material?, overlap: number?): BasePart
	local dir = b - a
	local len = dir.Magnitude * (overlap or 1.15)
	local mid = (a + b) / 2
	local cf = CFrame.lookAt(mid, b)
	return Primitives.ellipsoid(Vector3.new(width, height or width, len), cf, color, material)
end

function Primitives.wedge(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	return base("WedgePart", size, cf, color, material)
end

-- Pure math for a flat triangle a-b-c built from two wedges.
-- Returns cf1, size1, cf2, size2 (or nil for a degenerate triangle).
function Primitives.triangleFrames(a: Vector3, b: Vector3, c: Vector3, thickness: number): (CFrame?, Vector3?, CFrame?, Vector3?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab)
	if right.Magnitude < 1e-5 or bc.Magnitude < 1e-4 then
		return nil, nil, nil, nil
	end
	right = right.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local d1 = math.abs(ab:Dot(back))
	local d2 = math.abs(ac:Dot(back))
	return CFrame.fromMatrix((a + b) / 2, right, up, back), Vector3.new(thickness, height, d1),
		CFrame.fromMatrix((a + c) / 2, -right, up, -back), Vector3.new(thickness, height, d2)
end

-- Flat triangle a-b-c made from two WedgeParts (thickness along the normal).
function Primitives.triangle(a: Vector3, b: Vector3, c: Vector3, thickness: number, color: Color3, material: Enum.Material?): { BasePart }
	local cf1, s1, cf2, s2 = Primitives.triangleFrames(a, b, c, thickness)
	if not cf1 then
		return {}
	end
	return { base("WedgePart", s1 :: Vector3, cf1, color, material), base("WedgePart", s2 :: Vector3, cf2 :: CFrame, color, material) }
end

-- Resizable wedge: a Part whose SpecialMesh (Wedge) is scaled at runtime, so
-- animated membranes never touch Part.Size (render-only updates).
function Primitives.meshWedge(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = base("Part", size, cf, color, material)
	p.CastShadow = true
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Wedge
	m.Scale = Vector3.one
	m.Parent = p
	return p
end

-- Spike (single wedge) standing on `basePos`, pointing toward `tipDir`,
-- with its flat side facing `side` (usually the creature's right vector).
function Primitives.spike(basePos: Vector3, tip: Vector3, width: number, thickness: number, color: Color3, material: Enum.Material?): BasePart
	local up = (tip - basePos)
	local h = up.Magnitude
	local upU = up.Unit
	local right = Vector3.xAxis
	if math.abs(upU:Dot(right)) > 0.95 then
		right = Vector3.zAxis
	end
	local back = right:Cross(upU).Unit
	right = upU:Cross(back).Unit
	local cf = CFrame.fromMatrix(basePos + upU * (h / 2), right, upU, back)
	return base("WedgePart", Vector3.new(thickness, h, width), cf, color, material)
end

return Primitives

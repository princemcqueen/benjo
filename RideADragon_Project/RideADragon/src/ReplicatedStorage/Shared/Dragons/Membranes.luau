--[[
	Membranes
	Dynamic wing membranes. Each membrane is a set of thin wedge meshes that
	are re-stretched between named anchor points on the wing bones whenever
	the pose changes, so wings fold tightly against the body, flex during
	flaps and never tear apart (rigid membrane panels cannot fold).

	Bat wing topology (per side):
	  S shoulder, E elbow, W wrist, F1..F3 finger tips, B body anchor.
	  Q12 / Q23 / Q3B are derived scallop points that curve the trailing edge.

	Pieces are Parts with a Wedge SpecialMesh joined to the Root by a Motor6D
	("MemJoint"). Updates write Motor6D.Transform and SpecialMesh.Scale only
	(render-side properties), never Part.Size.
]]

local Primitives = require(script.Parent:WaitForChild("Primitives"))

local Membranes = {}
Membranes.__index = Membranes

local TRIS = {
	{ "S", "E", "B" },
	{ "E", "Q3B", "B" },
	{ "E", "F3", "Q3B" },
	{ "E", "W", "F3" },
	{ "W", "F3", "Q23" },
	{ "W", "Q23", "F2" },
	{ "W", "F2", "Q12" },
	{ "W", "Q12", "F1" },
}
Membranes.Tris = TRIS

local KEYS = { "S", "E", "W", "F1", "F2", "F3", "B" }
Membranes.Keys = KEYS

local triangleFrames = Primitives.triangleFrames
local TINY = Vector3.new(0.001, 0.001, 0.001)

local function scallop(p: Vector3, q: Vector3, toward: Vector3, depth: number): Vector3
	local mid = (p + q) * 0.5
	return mid + (toward - mid) * depth
end

-- Adds the derived scallop points to a point table (in place).
function Membranes.derive(P: { [string]: Vector3 }, depth: number)
	P.Q12 = scallop(P.F1, P.F2, P.W, depth)
	P.Q23 = scallop(P.F2, P.F3, P.W, depth)
	P.Q3B = scallop(P.F3, P.B, P.E, depth * 0.8)
	return P
end

-- Build-time: creates the membrane pieces for one side at the rest pose.
-- P holds rest-pose points (model space, root at identity).
function Membranes.buildPieces(root: BasePart, side: string, P: { [string]: Vector3 }, thickness: number, depth: number, color: Color3, material: Enum.Material, addPart: (BasePart) -> ())
	Membranes.derive(P, depth)
	for i, tri in TRIS do
		local cf1, s1, cf2, s2 = triangleFrames(P[tri[1]], P[tri[2]], P[tri[3]], thickness)
		for half = 1, 2 do
			local cf = if half == 1 then cf1 else cf2
			local s = if half == 1 then s1 else s2
			if not cf or not s then
				cf = CFrame.new(P[tri[1]])
				s = TINY
			end
			-- generous part bounds so culling never clips a stretched mesh
			local size = Vector3.new(math.max(s.X * 1.3, 0.2), math.max(s.Y * 1.3, 0.4), math.max(s.Z * 1.3, 0.4))
			local part = Primitives.meshWedge(size, cf, color, material)
			part.Name = "Membrane"
			part.CastShadow = true
			part:SetAttribute("MSide", side)
			part:SetAttribute("MTri", i)
			part:SetAttribute("MHalf", half)
			local mesh = part:FindFirstChildOfClass("SpecialMesh") :: SpecialMesh
			mesh.Scale = s / size
			addPart(part)
			local motor = Instance.new("Motor6D")
			motor.Name = "MemJoint"
			motor.Part0 = root
			motor.Part1 = part
			motor.C0 = cf -- build space: the root sits at the origin
			motor.C1 = CFrame.identity
			motor.Parent = part
		end
	end
end

-- ============================================================== runtime
function Membranes.new(model: Model)
	local self = setmetatable({}, Membranes)
	self.Model = model
	self.Depth = model:GetAttribute("MembraneScallop") or 0.18
	self.Thickness = model:GetAttribute("MembraneThickness") or 0.14
	self.Sides = {}
	self.Count = 0
	for _, sn in { "L", "R" } do
		local side = { Points = {}, P = {}, Pieces = {} }
		local ok = true
		for _, key in KEYS do
			local att = model:FindFirstChild("Mem" .. key .. sn, true)
			if not att or not att:IsA("Attachment") or not att.Parent then
				ok = false
				break
			end
			side.Points[key] = { Bone = (att.Parent :: Instance).Name, Local = (att :: Attachment).Position }
		end
		if ok then
			self.Sides[sn] = side
		end
	end
	for _, d in model:GetDescendants() do
		if d.Name == "Membrane" and d:IsA("BasePart") then
			local sd = self.Sides[d:GetAttribute("MSide")]
			local i, half = d:GetAttribute("MTri"), d:GetAttribute("MHalf")
			if sd and i and half then
				local motor = d:FindFirstChild("MemJoint") :: Motor6D?
				local mesh = d:FindFirstChildOfClass("SpecialMesh")
				sd.Pieces[i] = sd.Pieces[i] or {}
				sd.Pieces[i][half] = {
					Part = d,
					Motor = motor,
					Mesh = mesh,
					C0inv = motor and motor.C0:Inverse() or CFrame.identity,
					InvSize = Vector3.one / d.Size,
				}
				self.Count += 1
			end
		end
	end
	self.Valid = next(self.Sides) ~= nil and self.Count > 0
	return self
end

-- Bones the solver needs (for partial forward kinematics).
function Membranes:RequiredBones(): { [string]: boolean }
	local out = {}
	for _, side in self.Sides do
		for _, src in side.Points do
			out[src.Bone] = true
		end
	end
	return out
end

local function setPiece(piece, cf: CFrame?, size: Vector3?, world: boolean)
	if not piece then
		return
	end
	if cf and size then
		if world then
			piece.Part.CFrame = cf
		elseif piece.Motor then
			piece.Motor.Transform = piece.C0inv * cf
		end
		if piece.Mesh then
			piece.Mesh.Scale = size * piece.InvSize
		end
	elseif piece.Mesh then
		piece.Mesh.Scale = TINY
	end
end

-- boneCF: { [boneName] = CFrame } in Root space (runtime, writes Motor
-- transforms) or world space with world = true (static/anchored models).
function Membranes:Solve(boneCF: { [string]: CFrame }, world: boolean?)
	if not self.Valid then
		return
	end
	local th = self.Thickness
	for _, side in self.Sides do
		local P = side.P
		for key, src in side.Points do
			local cf = boneCF[src.Bone]
			if not cf then
				return
			end
			P[key] = cf * src.Local
		end
		Membranes.derive(P, self.Depth)
		for i, tri in TRIS do
			local pieces = side.Pieces[i]
			if pieces then
				local cf1, s1, cf2, s2 = triangleFrames(P[tri[1]], P[tri[2]], P[tri[3]], th)
				setPiece(pieces[1], cf1, s1, world == true)
				setPiece(pieces[2], cf2, s2, world == true)
			end
		end
	end
end

return Membranes

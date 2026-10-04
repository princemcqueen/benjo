-- Builds a block R15 rig onto an existing character model (sim testing only).
local character = ...
local hrp = character:FindFirstChild("HumanoidRootPart")
for _, c in character:GetChildren() do
	if c:IsA("BasePart") and c ~= hrp then
		c:Destroy()
	end
end
for _, d in hrp:GetChildren() do
	if d:IsA("Motor6D") then
		d:Destroy()
	end
end
local skin = Color3.fromRGB(234, 184, 146)
local shirt = Color3.fromRGB(52, 98, 168)
local pants = Color3.fromRGB(46, 46, 58)
local function part(name, size, color)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.CanCollide = false
	p.CFrame = hrp.CFrame
	p.Parent = character
	return p
end
local function joint(name, p0, p1, c0, c1)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = p0
	m.Part1 = p1
	m.C0 = c0
	m.C1 = c1
	m.Parent = p1
	return m
end
local V = Vector3.new
local C = CFrame.new
local lt = part("LowerTorso", V(2, 0.4, 1), pants)
local ut = part("UpperTorso", V(2, 1.6, 1), shirt)
local head = part("Head", V(1.2, 1.2, 1.2), skin)
joint("Root", hrp, lt, C(0, -0.8, 0), C())
joint("Waist", lt, ut, C(0, 0.2, 0), C(0, -0.8, 0))
joint("Neck", ut, head, C(0, 0.8, 0), C(0, -0.6, 0))
for _, s in { { "Left", -1 }, { "Right", 1 } } do
	local n, x = s[1], s[2]
	local ul = part(n .. "UpperLeg", V(0.95, 1.2, 0.95), pants)
	local ll = part(n .. "LowerLeg", V(0.9, 1.2, 0.9), pants)
	local ft = part(n .. "Foot", V(0.9, 0.3, 1.2), Color3.fromRGB(70, 50, 40))
	joint(n .. "Hip", lt, ul, C(0.5 * x, -0.2, 0), C(0, 0.6, 0))
	joint(n .. "Knee", ul, ll, C(0, -0.6, 0), C(0, 0.6, 0))
	joint(n .. "Ankle", ll, ft, C(0, -0.6, 0), C(0, 0.15, 0.1))
	local ua = part(n .. "UpperArm", V(0.9, 1.2, 0.9), shirt)
	local la = part(n .. "LowerArm", V(0.85, 1.1, 0.85), skin)
	local hd = part(n .. "Hand", V(0.8, 0.3, 0.8), skin)
	joint(n .. "Shoulder", ut, ua, C(1.0 * x, 0.6, 0), C(-0.45 * x, 0.5, 0))
	joint(n .. "Elbow", ua, la, C(0, -0.6, 0), C(0, 0.55, 0))
	joint(n .. "Wrist", la, hd, C(0, -0.55, 0), C(0, 0.15, 0))
end

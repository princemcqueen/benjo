--[[
	GreatTree - the giant LEGO-style tree in the plaza (skill tree station).

	A stepped stone base, a trunk of stacked round bricks, a tiered studded crown
	and five limbs, one per TreeConfig category (Luck, Wealth, Flight, Nest,
	Bond). Every limb ends in a pod with five fruit orbs; an orb lights up for
	every fifth of the category's levels the player has bought. The orbs are
	tagged "TreeOrb" with attributes Category / Level (1-5): the client lights
	them (TreeController), so the tree itself shows your progress.

	Local frame: origin on the ground in the middle of the base, local -Z faces
	the plaza (where the prompt and the sign are).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent:WaitForChild("Kit"))
local Village = require(script.Parent:WaitForChild("Village"))
local TreeConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TreeConfig"))

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local C = Kit.C
local M = Kit.M

local GreatTree = {}

local BARK = { Color3.fromRGB(122, 78, 48), Color3.fromRGB(104, 66, 42) }
local LEAF = {
	Color3.fromRGB(52, 140, 60),
	Color3.fromRGB(68, 160, 70),
	Color3.fromRGB(88, 180, 80),
	Color3.fromRGB(112, 200, 94),
	Color3.fromRGB(140, 220, 108),
}
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local ORB_OFF = Color3.fromRGB(88, 94, 104)

GreatTree.CrownTop = 28.8 + 5 * 3.4 -- height of the crown top above the base

-- World position (plaza, north-east of the statue) from TreeConfig.
function GreatTree.position(ground: (number, number) -> number): (Vector3, number)
	local a = math.rad(TreeConfig.WorldAngle)
	local x, z = math.sin(a) * TreeConfig.WorldRing, -math.cos(a) * TreeConfig.WorldRing
	local yaw = math.atan2(x, z) -- local -Z looks back at the plaza centre
	return V(x, ground(x, z), z), yaw
end

local function label(parent: BasePart, text: string, color: Color3, offset: Vector3)
	local gui = Instance.new("BillboardGui")
	gui.Name = "BranchLabel"
	gui.Size = UDim2.fromOffset(180, 34)
	gui.StudsOffsetWorldSpace = offset
	gui.AlwaysOnTop = false
	gui.MaxDistance = 140
	gui.LightInfluence = 0
	gui.Adornee = parent
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.35)
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Color = Color3.fromRGB(22, 30, 22)
	st.Parent = t
	t.Parent = gui
	gui.Parent = parent
end

function GreatTree.build(parent: Instance, at: Vector3, yaw: number)
	local b = Kit.new(parent, CF(at) * ANG(0, yaw, 0), "GreatTree")
	b.Model:SetAttribute("Station", "Tree")
	local rng = Random.new(2026)

	-- ---- stepped stone base (each step is at most 1.4 studs: walkable)
	b:cyl(1.4, 32, V(0, 0.7, 0), C.StoneDark, M.Cobblestone)
	b:cyl(1.0, 26, V(0, 1.9, 0), C.Stone, M.Slate)
	b:roundBrick(0.8, 22, V(0, 2.8, 0), LEAF[1], { Studs = "Ring", RingRadius = 9.4 })
	-- toy flower bricks around the edge
	local flowers = { Color3.fromRGB(226, 70, 70), Color3.fromRGB(252, 206, 60), Color3.fromRGB(246, 150, 60), Color3.fromRGB(150, 110, 230) }
	for i = 1, 12 do
		local a = i / 12 * math.pi * 2 + 0.2
		if math.abs(math.sin(a) + 1) > 0.35 then -- keep the front (local -Z) clear for the sign
			local br = b:brick(V(2.4, 2.4, 2.4), CF(math.cos(a) * 12.6, 3.4, math.sin(a) * 12.6) * ANG(0, -a, 0), flowers[(i % #flowers) + 1], { NoStuds = true })
			br.CanCollide = false
			b:roundBrick(1, 1.6, V(math.cos(a) * 12.6, 4.9, math.sin(a) * 12.6), LEAF[3], { Studs = "None", Props = { CanCollide = false } })
		end
	end

	-- ---- trunk: stacked round bricks, slightly tapering
	local y0 = 3.2
	for i = 0, 7 do
		b:roundBrick(3.2, 9.6 - i * 0.35, V(0, y0 + i * 3.2 + 1.6, 0), BARK[i % 2 + 1], { Studs = "None" })
	end
	-- roots
	for k = 0, 4 do
		local a = math.rad(k * 72 + 36)
		b:beam(V(math.cos(a) * 3.6, 6.2, math.sin(a) * 3.6), V(math.cos(a) * 11.5, 3.1, math.sin(a) * 11.5), 3, BARK[1], M.SmoothPlastic)
	end

	-- ---- crown: tiered studded layers
	local crownBase = y0 + 8 * 3.2 -- 28.8
	local dia = { 34, 27, 20, 13.5, 7 }
	local crownTop
	for i = 1, 5 do
		local d = dia[i]
		local y = crownBase + (i - 1) * 3.4 + 1.7
		local opts
		if i < 5 then
			opts = { Studs = "Ring", RingRadius = (d / 2 + dia[i + 1] / 2) / 2 }
		else
			opts = { Studs = "Top" }
		end
		local layer = b:roundBrick(3.4, d, V(0, y, 0), LEAF[i], opts)
		layer.Name = "Crown" .. i
		crownTop = layer
	end
	-- leaf puffs around the lower rim
	for i = 1, 11 do
		local a = i / 11 * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local r = 17.2 + rng:NextNumber(-0.8, 1.2)
		b:roundBrick(3.4, rng:NextNumber(5.5, 7.5), V(math.cos(a) * r, crownBase + (i % 2 == 0 and 1.7 or 0.3), math.sin(a) * r), LEAF[(i % 3) + 1], { Studs = "Top" })
	end
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(190, 255, 160)
	pl.Range = 38
	pl.Brightness = 0.9
	pl.Shadows = false
	pl.Parent = crownTop
	-- drifting sparkles over the crown
	local fx = b:box(V(30, 1, 30), V(0, crownBase + 17.5, 0), C.Leaf, M.SmoothPlastic, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	fx.Name = "CrownFX"
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SPARKLE
	pe.Color = ColorSequence.new(Color3.fromRGB(190, 255, 150), Color3.fromRGB(255, 240, 150))
	pe.LightEmission = 0.6
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(4, 6)
	pe.Rate = 5
	pe.Speed = NumberRange.new(1, 3)
	pe.Acceleration = V(0, -2.5, 0)
	pe.SpreadAngle = Vector2.new(60, 60)
	pe.EmissionDirection = Enum.NormalId.Bottom
	pe.Parent = fx
	CollectionService:AddTag(pe, "FX")

	-- ---- five limbs: one per category, each ending in a pod with five fruit orbs
	local limbY = { 13, 11, 15, 12, 14 }
	for idx, cat in TreeConfig.Categories do
		local a = math.rad((idx - 1) * 72 + 18)
		local radial = V(math.cos(a), 0, math.sin(a))
		local tangent = V(-math.sin(a), 0, math.cos(a))
		local pod = radial * 13.5 + V(0, limbY[idx] + 3, 0)
		b:beam(radial * 3.8 + V(0, limbY[idx], 0), pod, 2.2, BARK[2], M.SmoothPlastic)
		b:roundBrick(3.6, 11, pod, LEAF[2], { Studs = "None" })
		local top = b:roundBrick(2.4, 7.5, pod + V(0, 3, 0), cat.Color, { Studs = "Top" })
		top.Name = "Pod_" .. cat.Id
		label(top, string.upper(cat.Name), cat.Color, V(0, 10, 0))
		for level = 1, 5 do
			local p = pod + V(0, 7.4, 0) + tangent * ((level - 3) * 3.4)
			local orb = b:ball(2.4, p, ORB_OFF, M.SmoothPlastic, { Transparency = 0.35, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
			orb.Name = string.format("Orb_%s_%d", cat.Id, level)
			orb:SetAttribute("Category", cat.Id)
			orb:SetAttribute("Level", level)
			CollectionService:AddTag(orb, "TreeOrb")
			local light = Instance.new("PointLight")
			light.Color = cat.Color
			light.Range = 9
			light.Brightness = 1.4
			light.Shadows = false
			light.Enabled = false
			light.Parent = orb
		end
	end

	-- ---- sign + interaction
	for _, sx in { -1, 1 } do
		b:box(V(0.9, 6.4, 0.9), V(sx * 7.2, 6, -13.2), C.Timber, M.Wood)
	end
	Village.signBoard(b, CF(0, 7.4, -13.2), 14, 3, "THE GREAT TREE")
	local trigger = b:box(V(12, 8, 7), V(0, 7, -9.5), C.Planks, M.WoodPlanks, { Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false })
	trigger.Name = "TreeTrigger"
	local prompt = b:prompt(trigger, "Upgrade", "Great Tree", { Station = "Tree", Window = "Tree" })
	prompt.MaxActivationDistance = 24
	prompt.Name = "StationPrompt"
	return b.Model
end

return GreatTree

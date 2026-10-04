--[[
	TreeController
	Keeps the Great Tree in the plaza in sync with the player's upgrades: the five
	pods are the five categories (Luck, Wealth, Flight, Nest, Bond); each has five
	fruit orbs (tagged "TreeOrb", attributes Category / Level 1-5, built by the
	server in World/GreatTree). Orb n glows in the category colour once n/5 of the
	category's levels are bought, and a sparkle burst plays on the orb that just
	lit up. Purely visual and local - the levels live in data.Tree (TreeService).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TreeConfig"))

local TreeController = {}

local registry
local progress: { [string]: number } = {} -- category id -> bought fraction (0..1)
local lastLit: { [string]: number }? = nil -- category id -> number of lit orbs
local lit: { [BasePart]: { Light: PointLight?, Level: number } } = {}

local OFF_COLOR = Color3.fromRGB(88, 94, 104)
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

-- number of lit orbs (0-5) for a category progress
local function litCount(fraction: number): number
	return math.min(5, math.floor(fraction * 5 + 1e-6))
end

local function paintOrb(orb: Instance)
	if not orb:IsA("BasePart") then
		return
	end
	local cat = TreeConfig.CategoryById[orb:GetAttribute("Category")]
	local level = orb:GetAttribute("Level")
	if not cat or type(level) ~= "number" then
		return
	end
	local owned = litCount(progress[cat.Id] or 0) >= level
	orb.Material = owned and Enum.Material.Neon or Enum.Material.SmoothPlastic
	orb.Color = owned and cat.Color or OFF_COLOR
	orb.Transparency = owned and 0.05 or 0.4
	local light = orb:FindFirstChildOfClass("PointLight")
	if light then
		light.Enabled = owned
	end
	lit[orb :: BasePart] = owned and { Light = light, Level = level } or nil
end

local function repaintAll()
	for _, orb in CollectionService:GetTagged("TreeOrb") do
		paintOrb(orb)
	end
end

-- Sparkle burst on the orb that just lit up.
local function burst(orb: BasePart, color: Color3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(orb.Position)
	p.Parent = Workspace
	local e = Instance.new("ParticleEmitter")
	e.Texture = SPARKLE
	e.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.4), color)
	e.LightEmission = 1
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.8, 1.4)
	e.Speed = NumberRange.new(10, 22)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -8, 0)
	e.Drag = 2
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.1), NumberSequenceKeypoint.new(1, 0) })
	e.Parent = p
	e:Emit(46)
	task.delay(2, function()
		p:Destroy()
	end)
end

local function onTree(tree)
	local data = { Tree = type(tree) == "table" and tree or {} }
	local lit = {}
	progress = {}
	for _, cat in TreeConfig.Categories do
		progress[cat.Id] = TreeConfig.categoryProgress(data, cat.Id)
		lit[cat.Id] = litCount(progress[cat.Id])
	end
	repaintAll()
	if lastLit then
		for _, orb in CollectionService:GetTagged("TreeOrb") do
			local id, level = orb:GetAttribute("Category"), orb:GetAttribute("Level")
			if id and level and (lastLit[id] or 0) < level and lit[id] >= level then
				burst(orb :: BasePart, TreeConfig.CategoryById[id].Color)
			end
		end
	end
	lastLit = lit
end

function TreeController.Init(reg)
	registry = reg
end

function TreeController.Start()
	CollectionService:GetInstanceAddedSignal("TreeOrb"):Connect(paintOrb)
	CollectionService:GetInstanceRemovedSignal("TreeOrb"):Connect(function(orb)
		lit[orb :: BasePart] = nil
	end)
	registry.DataController.observe("Tree", onTree)
	-- lit fruit breathes softly
	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		for _, info in lit do
			if info.Light then
				info.Light.Brightness = 1.3 + 0.45 * math.sin(t * 2.2 + info.Level)
			end
		end
	end)
end

-- Fraction (0..1) of a category that is bought (for tests / other UI).
function TreeController.progress(): { [string]: number }
	return progress
end

return TreeController

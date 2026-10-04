--[[
	AnimationController
	Builds the visual model for every dragon root the client can see
	(companions now, sanctuary dragons later) and runs its procedural
	Animator with distance/visibility LOD.

	Visual models are built locally (DragonVisual.build with the server Root:
	a skinned mesh template when the species has one, otherwise the
	procedural part-built dragon) so the server never replicates visuals per
	dragon, and detail can follow the graphics preset. Builds are queued.

	Each frame (PreSimulation):
	  1. DragonController.preStep(dt)  - local riding / follow AI
	  2. every tracked dragon: params (local exact or estimated from the
	     replicated root), Animator Update/Apply, rider joint + rider pose.

	API: track(model), get(model), setLocal(model, params), play(model, shot)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Dragons = Shared:WaitForChild("Dragons")
local DragonVisual = require(Dragons:WaitForChild("DragonVisual"))
local Animator = require(Dragons:WaitForChild("Animator"))
local RiderPose = require(Dragons:WaitForChild("RiderPose"))
local MathUtil = require(Shared:WaitForChild("Util"):WaitForChild("MathUtil"))

local AnimationController = {}

local registry
local tracked: { [Model]: any } = {}
local buildQueue: { Model } = {}
local folders: { Instance } = {}
local LocalPlayer = Players.LocalPlayer

local TIERS = {
	{ Distance = 150, Interval = 0, Membranes = 0 },
	{ Distance = 420, Interval = 1 / 30, Membranes = 1 / 30 },
	{ Distance = 800, Interval = 1 / 12, Membranes = 1 / 6 },
}

local function animMode(mode: string?): string
	if mode == "Ground" or mode == nil then
		return "Ground"
	elseif mode == "Air" then
		return "Air"
	elseif mode == "Sleep" then
		return "Sleep"
	elseif mode == "Rest" then
		return "Rest"
	end
	return "Fly"
end

local function detailFor(model: Model): string
	if model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
		return "High"
	end
	local gc = registry and registry.GraphicsController
	if gc and gc.Preset == "Medium" then
		return "Medium"
	end
	return "High"
end

-- ============================================================== building
local function buildVisual(model: Model)
	local entry = tracked[model]
	if not entry or entry.Visual then
		return
	end
	local root = model:FindFirstChild("Root") :: BasePart?
	local species = model:GetAttribute("SpeciesId")
	if not root or type(species) ~= "string" then
		return
	end
	local displayScale = model:GetAttribute("DisplayScale")
	local visual = DragonVisual.build(species, {
		Root = root,
		Mutation = model:GetAttribute("Mutation") or "None",
		Detail = detailFor(model),
		ScaleOverride = type(displayScale) == "number" and displayScale or nil,
	})
	visual.Name = "Visual"
	for _, d in visual:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = "Dragons"
		end
	end
	visual.Parent = model
	local anim = Animator.new(visual)
	anim.Params.RunSpeed = model:GetAttribute("RunSpeed") or 40
	local startMode = model:GetAttribute("Mode")
	if startMode == "Rest" or startMode == "Sleep" then
		anim.Params.Mode = startMode
		anim:Snap(startMode)
	elseif model:GetAttribute("Anchored") or root.Anchored then
		anim:Snap("Idle")
	end
	entry.Visual = visual
	entry.Anim = anim
	entry.BodyMotor = anim.Motors.Body
	local bodyJoint = anim.Joints.Body
	entry.BodyC0 = bodyJoint and bodyJoint.C0 or CFrame.identity
	entry.BodyC0inv = entry.BodyC0:Inverse()
	local audio = registry.AudioController
	anim.OnFootstep = function()
		if entry.Tier == 1 and audio then
			audio.play3D("Footstep", root, 0.12, math.clamp((anim.Params.Speed or 0) / 40, 0.4, 1))
		end
	end
	anim.OnFlap = function()
		if entry.Tier <= 2 and audio then
			audio.play3D("WingFlap", root, 0.1)
		end
	end
end

function AnimationController.track(model: Model)
	if tracked[model] then
		return tracked[model]
	end
	local entry = {
		Model = model,
		Visual = nil,
		Anim = nil,
		Local = nil,
		LastYaw = nil,
		YawRate = 0,
		Accum = 0,
		MemAccum = 0,
		Tier = 1,
		ShotId = model:GetAttribute("ShotId") or 0,
		IdleTime = 0,
		NextIdle = 8 + math.random() * 6,
		RiderChar = nil,
		Perch = model:GetAttribute("Kind") == "Perch",
	}
	tracked[model] = entry
	-- the local player's dragon is built immediately; others are queued
	if model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
		buildVisual(model)
	else
		table.insert(buildQueue, model)
	end
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			AnimationController.untrack(model)
		end
	end)
	-- hot swap (equip switch / mutation): rebuild the visual on the same root
	model:GetAttributeChangedSignal("VisualRev"):Connect(function()
		if tracked[model] ~= entry then
			return
		end
		if entry.RiderChar then
			RiderPose.clear(entry.RiderChar)
			entry.RiderChar = nil
		end
		if entry.Visual then
			entry.Visual:Destroy()
		end
		entry.Visual, entry.Anim, entry.BodyMotor = nil, nil, nil
		buildVisual(model)
	end)
	model:GetAttributeChangedSignal("ShotId"):Connect(function()
		local id = model:GetAttribute("ShotId")
		if entry.Anim and id ~= entry.ShotId and model:GetAttribute("OwnerUserId") ~= LocalPlayer.UserId then
			local shot = model:GetAttribute("Shot")
			if type(shot) == "string" then
				entry.Anim:Play(shot)
			end
		end
		entry.ShotId = id
	end)
	return entry
end

function AnimationController.untrack(model: Model)
	local entry = tracked[model]
	if not entry then
		return
	end
	if entry.RiderChar then
		RiderPose.clear(entry.RiderChar)
	end
	tracked[model] = nil
end

function AnimationController.get(model: Model)
	return tracked[model]
end

-- Exact parameters for the local player's dragon (from Locomotion).
function AnimationController.setLocal(model: Model, params)
	local entry = tracked[model]
	if entry then
		entry.Local = params
	end
end

function AnimationController.play(model: Model, shot: string)
	local entry = tracked[model]
	if entry and entry.Anim then
		entry.Anim:Play(shot)
	end
end

local function watchFolder(folder: Instance)
	table.insert(folders, folder)
	local function consider(child: Instance)
		if child:IsA("Model") then
			task.spawn(function()
				local root = child:WaitForChild("Root", 10)
				if root and child.Parent then
					AnimationController.track(child :: Model)
				end
			end)
		end
	end
	for _, child in folder:GetChildren() do
		consider(child)
	end
	folder.ChildAdded:Connect(consider)
end
AnimationController.watchFolder = watchFolder

-- ============================================================== per-frame
local function estimateParams(entry, root: BasePart, dt: number)
	local model = entry.Model
	local v = root.AssemblyLinearVelocity
	local cf = root.CFrame
	local look = cf.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	if entry.LastYaw then
		local rate = MathUtil.angleDelta(entry.LastYaw, yaw) / math.max(dt, 1 / 240)
		entry.YawRate = MathUtil.expDecay(entry.YawRate, math.clamp(rate, -4, 4), 8, dt)
	end
	entry.LastYaw = yaw
	local mode = model:GetAttribute("Mode")
	local am = animMode(mode)
	local horiz = Vector3.new(v.X, 0, v.Z).Magnitude
	local p = entry.Anim.Params
	p.Speed = am == "Fly" and v.Magnitude or horiz
	p.Vertical = v.Y
	p.TurnRate = entry.YawRate
	p.Bank = math.asin(math.clamp(cf.RightVector.Y, -1, 1))
	p.Mode = am
	p.Boost = model:GetAttribute("Boost") == true
end

local function updateRider(entry, root: BasePart)
	local model = entry.Model
	local riderId = model:GetAttribute("RiderUserId") or 0
	local character = nil
	if riderId ~= 0 then
		local player = Players:GetPlayerByUserId(riderId)
		character = player and player.Character
	end
	if entry.RiderChar and entry.RiderChar ~= character then
		RiderPose.clear(entry.RiderChar)
		entry.RiderChar = nil
	end
	if not character then
		return
	end
	entry.RiderChar = character
	local joint = root:FindFirstChild("RiderJoint") :: Motor6D?
	local anim = entry.Anim
	local bounce = 0
	if joint and entry.BodyMotor then
		-- saddle follows the animated body: T = Cs^-1 * (C0b * Tb * C0b^-1) * Cs
		local tb = entry.BodyMotor.Transform
		local m = entry.BodyC0 * tb * entry.BodyC0inv
		local cs = joint.C0
		joint.Transform = cs:Inverse() * m * cs
		bounce = tb.Position.Y
	end
	local p = anim.Params
	local lean = p.Boost and 1 or math.clamp((p.Speed or 0) / 260, 0, 0.45)
	RiderPose.apply(character, { Lean = lean, Bounce = bounce, Bank = p.Bank or 0 })
end

local function idleBehaviour(entry, dt: number)
	local anim = entry.Anim
	local p = anim.Params
	if p.Mode == "Ground" and (p.Speed or 0) < 1 and #anim.Shots == 0 then
		entry.IdleTime += dt
		local ridden = (entry.Model:GetAttribute("RiderUserId") or 0) ~= 0
		if entry.IdleTime > 75 and not ridden then
			p.Mode = "Sleep"
		elseif entry.IdleTime > entry.NextIdle then
			entry.NextIdle = entry.IdleTime + 9 + math.random() * 8
			anim:Play(math.random() < 0.82 and "IdleVariant" or "Roar")
		end
	else
		entry.IdleTime = 0
		entry.NextIdle = 8 + math.random() * 6
	end
end

-- Sanctuary perch dragons: alternate between resting (lying, head up),
-- dozing and standing up for a stretch or a roar; gentle look-arounds.
local function perchBehaviour(entry, dt: number)
	local anim = entry.Anim
	local p = anim.Params
	p.Speed, p.Vertical, p.TurnRate, p.Bank = 0, 0, 0, 0
	entry.MoodTime = (entry.MoodTime or (6 + math.random() * 10)) - dt
	if entry.MoodTime <= 0 and #anim.Shots == 0 then
		local r = math.random()
		local mood = r < 0.55 and "Rest" or (r < 0.8 and "Sleep" or "Ground")
		if mood == p.Mode then
			mood = "Rest"
		end
		p.Mode = mood
		entry.MoodTime = mood == "Sleep" and (24 + math.random() * 30) or (12 + math.random() * 16)
		entry.NextShot = 2.5 + math.random() * 3
	end
	if p.Mode == "Ground" then
		-- standing: a stretch or a roar now and then
		entry.NextShot = (entry.NextShot or 3) - dt
		if entry.NextShot <= 0 and #anim.Shots == 0 then
			entry.NextShot = 6 + math.random() * 7
			anim:Play(math.random() < 0.75 and "IdleVariant" or "Roar")
		end
	elseif p.Mode == "Rest" then
		-- glance around (additive head look, spring-smoothed by the Animator)
		entry.LookTime = (entry.LookTime or 0) - dt
		if entry.LookTime <= 0 then
			entry.LookTime = 2.5 + math.random() * 4
			p.Look = Vector2.new((math.random() - 0.5) * 0.9, (math.random() - 0.4) * 0.3)
		end
	else
		p.Look = Vector2.zero
	end
end

function AnimationController.stepAll(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	local camLook = cam and cam.CFrame.LookVector or Vector3.zero
	local gc = registry.GraphicsController
	local maxDist = gc and gc.AnimationDistance or 800

	-- a couple of queued builds per frame
	for _ = 1, 2 do
		local m = table.remove(buildQueue, 1)
		if not m then
			break
		end
		if m.Parent and tracked[m] then
			buildVisual(m)
		end
	end

	for model, entry in tracked do
		local anim = entry.Anim
		if not anim then
			continue
		end
		local root = model:FindFirstChild("Root") :: BasePart?
		if not root then
			continue
		end
		local isLocal = entry.Local ~= nil
		local offset = root.Position - camPos
		local dist = offset.Magnitude
		local facing = dist < 1 or offset.Unit:Dot(camLook) > -0.2
		local tier
		if isLocal or dist < TIERS[1].Distance then
			tier = 1
		elseif dist < TIERS[2].Distance and facing then
			tier = 2
		elseif dist < math.min(TIERS[3].Distance, maxDist) and facing then
			tier = 3
		else
			tier = 4
		end
		entry.Tier = tier
		if tier == 4 then
			continue
		end
		entry.Accum += dt
		local interval = tier == 1 and 0 or TIERS[tier].Interval
		if entry.Accum < interval then
			continue
		end
		local step = entry.Accum
		entry.Accum = 0
		if entry.Perch then
			perchBehaviour(entry, step)
		else
			if isLocal then
				anim:SetParams(entry.Local)
			else
				estimateParams(entry, root, step)
			end
			idleBehaviour(entry, step)
		end
		anim:Update(step)
		entry.MemAccum += step
		local memInterval = tier == 1 and 0 or TIERS[tier].Membranes
		local doMembranes = entry.MemAccum >= memInterval
		if doMembranes then
			entry.MemAccum = 0
		end
		anim:Apply(doMembranes)
		if tier <= 2 then
			updateRider(entry, root)
		end
	end
end

function AnimationController.Init(reg)
	registry = reg
end

function AnimationController.Start()
	local dragons = Workspace:WaitForChild("Dragons", 30)
	if dragons then
		watchFolder(dragons)
	end
	RunService.PreSimulation:Connect(function(dt)
		local dc = registry.DragonController
		if dc and dc.preStep then
			dc.preStep(dt)
		end
		AnimationController.stepAll(dt)
	end)
end

return AnimationController

--[[
	HatchController
	Hatching cinematic + result card.

	Sequence (client-only, the server already decided the result):
	  1. APPROACH  the room darkens, the camera glides to the egg and the egg
	               lifts into a pool of light
	  2. CHARGE    the egg wobbles faster and faster while the RNG roll spins;
	               glowing cracks open one by one (flash, sparks, camera shake)
	  3. BURST     white flash, shell shards, shock ring and a pillar of light
	  4. WALK      the dragon steps out of the light and WALKS TOWARDS THE CAMERA
	  5. ROAR      it stops, rears up and ROARS (camera push-in, shock wave,
	               mutation burst)
	  6. CARD      result card (rarity, name, mutation, NEW, stats, Ride it /
	               Awesome) while the camera slowly orbits the idling dragon
	Rare results (rarity or "1 in N") get a longer charge and more cracks.
	A SKIP button jumps straight to the result card.

	All timing is frame-time based (not wall clock), so the cinematic can be
	driven and tested in the simulator.

	HatchController.Phase: "" | Approach | Charge | Burst | Walk | Roar | Card
	HatchController.Stage / .Dragon: the live stage folder and hatchling (tests, tools)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local DragonVisual = require(Shared:WaitForChild("Dragons"):WaitForChild("DragonVisual"))
local Animator = require(Shared:WaitForChild("Dragons"):WaitForChild("Animator"))
local Species = require(Shared:WaitForChild("Dragons"):WaitForChild("Species"))
local Builder = require(Shared:WaitForChild("Dragons"):WaitForChild("Builder"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local HatchConfig = require(Configs:WaitForChild("HatchConfig"))
local Odds = require(Shared:WaitForChild("Odds"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Kit = require(UI:WaitForChild("Kit"))
local Responsive = require(UI:WaitForChild("Responsive"))

local C = Theme.Colors

local HatchController = {}
HatchController.Phase = ""
HatchController.Stage = nil :: Folder?
HatchController.Dragon = nil :: any
HatchController.Framing = nil :: any

local registry
local busy = false
local active: { Cleanup: () -> () }? = nil
local LocalPlayer = Players.LocalPlayer

-- ============================================================== helpers
local function ease(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- One frame of time (a missing dt must never stall the cinematic).
local function frame(): number
	local dt = RunService.RenderStepped:Wait()
	if type(dt) ~= "number" then
		dt = 1 / 60
	end
	return math.min(dt, 0.1)
end

-- Runs fn(a, t, dt) for `duration` seconds (a = 0..1). Returns false when the
-- player skipped the cinematic.
local function run(state, duration: number, fn: (number, number, number) -> ()): boolean
	local t = 0
	while true do
		if state.Skip then
			return false
		end
		local dt = frame()
		t += dt
		local a = math.clamp(t / duration, 0, 1)
		fn(a, t, dt)
		if a >= 1 then
			return true
		end
	end
end

local function tweenCamera(state, camera: Camera, to: CFrame, duration: number)
	local from = camera.CFrame
	if not run(state, duration, function(a)
		camera.CFrame = from:Lerp(to, ease(a))
	end) then
		camera.CFrame = to
	end
end

local function neonBall(color: Color3, size: number, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(size, size, size)
	p.CFrame = cf
	p.Parent = parent
	return p
end

-- Flat neon ring / disc lying on the ground (diameter d).
local function neonDisc(color: Color3, d: number, at: Vector3, parent: Instance, transparency: number): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = Enum.PartType.Cylinder
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(0.15, d, d)
	p.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	p.Transparency = transparency
	p.Parent = parent
	return p
end

local function shards(color: Color3, at: Vector3, parent: Instance)
	for i = 1, 16 do
		local s = Instance.new("Part")
		s.CanCollide = false
		s.CanQuery = false
		s.CanTouch = false
		s.Material = Enum.Material.SmoothPlastic
		s.Color = color
		s.Size = Vector3.new(0.6, 0.15, 0.8) * (0.7 + math.random() * 0.8)
		s.CFrame = CFrame.new(at) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		s.Parent = parent
		local a = i / 16 * math.pi * 2
		s.AssemblyLinearVelocity = Vector3.new(math.cos(a) * 18, 22 + math.random() * 14, math.sin(a) * 18)
		s.AssemblyAngularVelocity = Vector3.new(math.random() * 20, math.random() * 20, math.random() * 20)
		task.delay(2.2, function()
			s:Destroy()
		end)
	end
end

-- One-off burst of sparkles / confetti from a point.
local function confetti(parent: Instance, at: Vector3, colors: { Color3 }, count: number)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new(at)
	holder.Parent = parent
	local keys = {}
	for i, col in colors do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / math.max(1, #colors - 1), col))
	end
	if #keys == 1 then
		table.insert(keys, ColorSequenceKeypoint.new(1, colors[1]))
	end
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(keys)
	pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.9, 1.7)
	pe.Speed = NumberRange.new(14, 34)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, -14, 0)
	pe.Rate = 0
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.15, 1.1), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = holder
	pe:Emit(count)
	task.delay(2.2, function()
		holder:Destroy()
	end)
end

-- ============================================================== cinematic dressing
-- Darkened, cinematic grade + edge vignette + white flash layer. Everything is
-- removed again by Fx.Cleanup().
local function newFx(layer: Instance)
	local fx = { Items = {} }
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "HatchGrade"
	cc.Parent = Lighting
	table.insert(fx.Items, cc)
	local dof = Instance.new("DepthOfFieldEffect")
	dof.Name = "HatchFocus"
	dof.FarIntensity = 0
	dof.NearIntensity = 0
	dof.InFocusRadius = 60
	dof.FocusDistance = 14
	dof.Parent = Lighting
	table.insert(fx.Items, dof)
	fx.Grade, fx.Focus = cc, dof

	local vignette = Instance.new("Frame")
	vignette.Name = "HatchVignette"
	vignette.BackgroundTransparency = 1
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.ZIndex = 0
	vignette.Parent = layer
	table.insert(fx.Items, vignette)
	fx.Edges = {}
	local function edge(anchor: Vector2, pos: UDim2, size: UDim2, rotation: number)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.AnchorPoint = anchor
		f.Position = pos
		f.Size = size
		local g = Instance.new("UIGradient")
		g.Rotation = rotation
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		f.Parent = vignette
		table.insert(fx.Edges, f)
	end
	edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.24), 90)
	edge(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.24), 270)
	edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.17, 1), 0)
	edge(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.17, 1), 180)

	local flash = Instance.new("Frame")
	flash.Name = "HatchFlash"
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 50
	flash.Parent = layer
	table.insert(fx.Items, flash)
	fx.Flash = flash

	function fx.Darken(on: boolean, seconds: number)
		local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(cc, info, {
			Brightness = on and -0.2 or 0,
			Contrast = on and 0.14 or 0,
			Saturation = on and -0.16 or 0,
		}):Play()
		TweenService:Create(dof, info, { FarIntensity = on and 0.5 or 0, NearIntensity = on and 0.2 or 0 }):Play()
		for _, e in fx.Edges do
			TweenService:Create(e, info, { BackgroundTransparency = on and 0 or 1 }):Play()
		end
	end

	-- white flash: 0 -> opaque -> clear
	function fx.Pulse(peak: number, seconds: number)
		flash.BackgroundTransparency = 1 - peak
		TweenService:Create(flash, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	end

	function fx.Cleanup()
		for _, inst in fx.Items do
			inst:Destroy()
		end
		table.clear(fx.Items)
	end
	return fx
end

local function skipButton(layer: Instance, state)
	local btn = Kit.button({
		Name = "HatchSkip",
		Text = "SKIP",
		Style = "Secondary",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18),
		Size = UDim2.fromScale(0.1, 0.06),
		Parent = layer,
	})
	Responsive.bind(btn.Instance, "Size", function(R)
		if R.Device == "Phone" then
			return R.Portrait and UDim2.fromScale(0.3, 0.07) or UDim2.fromScale(0.16, 0.13)
		end
		return UDim2.fromScale(0.1, 0.06)
	end)
	btn.Instance.Visible = false
	btn.Activated:Connect(function()
		state.Skip = true
	end)
	return btn
end

-- ============================================================== egg cracks
-- A glowing crack on the shell: a short zig-zag of neon bars (rides along with the egg).
local function addCrack(egg: Model, def, index: number, rng: Random)
	local shell = egg.PrimaryPart
	if not shell then
		return Vector3.zero
	end
	local size = shell.Size
	local u = rng:NextNumber(-0.45, 0.72)
	local a = rng:NextNumber(0, math.pi * 2)
	local r = math.sqrt(math.max(0, 1 - u * u))
	local n = Vector3.new(math.cos(a) * r, u, math.sin(a) * r)
	local p = Vector3.new(n.X * size.X / 2, n.Y * size.Y / 2, n.Z * size.Z / 2)
	local base = CFrame.lookAt(p * 1.01, p * 1.01 + n) * CFrame.Angles(0, 0, rng:NextNumber(0, math.pi * 2))
	local color = def.Glow:Lerp(Color3.new(1, 1, 1), 0.55)
	local cf = base
	for seg = 1, 3 do
		local len = rng:NextNumber(0.5, 0.85)
		local bar = Instance.new("Part")
		bar.Name = "Crack" .. index .. "_" .. seg
		bar.Anchored = true
		bar.CanCollide = false
		bar.CanQuery = false
		bar.CanTouch = false
		bar.CastShadow = false
		bar.Material = Enum.Material.Neon
		bar.Color = color
		bar.Size = Vector3.new(0.075, len, 0.075)
		bar.CFrame = shell.CFrame * (cf * CFrame.new(0, len / 2, 0))
		bar.Parent = egg
		cf = cf * CFrame.new(0, len, 0) * CFrame.Angles(0, 0, rng:NextNumber(-0.45, 0.45))
	end
	local att = Instance.new("Attachment")
	att.Name = "CrackSpark" .. index
	att.CFrame = base
	att.Parent = shell
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(color)
	pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.4, 0.9)
	pe.Speed = NumberRange.new(4, 11)
	pe.SpreadAngle = Vector2.new(70, 70)
	pe.Rate = 0
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, 0.5), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = att
	pe:Emit(14)
	return shell.CFrame:PointToWorldSpace(p)
end

-- ============================================================== companion
-- The player's own companion dragon would stand in the shot: hide it (client-side only,
-- nothing replicates) until the show is over. Returns the function that brings it back.
local function hideCompanion(): () -> ()
	local dragons = Workspace:FindFirstChild("Dragons")
	local mine = dragons and dragons:FindFirstChild("Dragon_" .. LocalPlayer.UserId)
	if not mine then
		return function() end
	end
	local saved = {}
	for _, d in mine:GetDescendants() do
		if d:IsA("BasePart") then
			saved[d] = d.LocalTransparencyModifier
			d.LocalTransparencyModifier = 1
		elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Light") then
			saved[d] = d.Enabled
			d.Enabled = false
		end
	end
	return function()
		for inst, value in saved do
			if inst.Parent then
				if inst:IsA("BasePart") then
					inst.LocalTransparencyModifier = value
				else
					(inst :: any).Enabled = value
				end
			end
		end
	end
end

-- ============================================================== camera spot
-- The plot has a gate, walls, lamps and a shrine: find a camera spot `dist` away from the
-- nest (and above it) whose whole line of sight - and the slow sway around it during the
-- result card - is clear. The player's side is tried first, then the directions fan out
-- left and right. Returns the direction and how much of the way was clear (1 = all).
local SWAY = 0.3 -- radians the camera may swing to either side while the card is up

local function clearSpot(focus: Vector3, preferred: Vector3, dist: number, ignore: { Instance }): (Vector3, number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = ignore
	-- high enough that the probe sphere never scrapes the plot floor
	local origin = focus + Vector3.new(0, 6, 0)
	local function lineClear(dir: Vector3): number
		local camPos = focus + dir * dist + Vector3.new(0, dist * 0.3, 0)
		local delta = camPos - origin
		local hit = Workspace:Spherecast(origin, 4.5, delta, params)
		local clear = hit and (hit.Position - origin).Magnitude / delta.Magnitude or 1
		if #Workspace:GetPartBoundsInRadius(camPos, 5, overlap) > 0 then
			clear = math.min(clear, 0.5)
		end
		return clear
	end
	local base = math.atan2(preferred.X, preferred.Z)
	local best, bestClear = preferred, -1
	for _, deg in { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180 } do
		local a = base + math.rad(deg)
		local clear = 1
		for _, sway in { 0, SWAY, -SWAY } do
			local dir = Vector3.new(math.sin(a + sway), 0, math.cos(a + sway))
			clear = math.min(clear, lineClear(dir))
		end
		if clear >= 1 then
			return Vector3.new(math.sin(a), 0, math.cos(a)), 1
		end
		if clear > bestClear then
			best, bestClear = Vector3.new(math.sin(a), 0, math.cos(a)), clear
		end
	end
	return best, bestClear
end

-- ============================================================== live hatchling
-- The dragon as a living, animated model (Animator) so it can walk and roar.
local function spawnDragon(record, rootCF: CFrame, parent: Instance)
	local ok, result = pcall(function()
		local holder = Instance.new("Model")
		holder.Name = "Hatchling"
		local root = Builder.makeRoot(record.SpeciesId, nil)
		root.Anchored = true
		root.CFrame = rootCF
		root.Parent = holder
		holder.PrimaryPart = root
		local visual = DragonVisual.build(record.SpeciesId, { Root = root, Mutation = record.Mutation, Detail = "High", Saddle = false })
		visual.Name = "Visual"
		local fade = {}
		for _, d in visual:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				fade[d] = d.Transparency
			end
		end
		visual.Parent = holder
		holder.Parent = parent
		local anim = Animator.new(visual)
		anim:Snap("Idle")
		return { Model = holder, Root = root, Visual = visual, Anim = anim, Fade = fade }
	end)
	if ok then
		return result
	end
	warn("[Hatch] dragon failed: " .. tostring(result))
	return nil
end

-- Fades the dragon in (0 = invisible, 1 = as built).
local function setReveal(dragon, k: number)
	for part, orig in dragon.Fade do
		if part.Parent then
			part.Transparency = 1 - (1 - orig) * k
		end
	end
end

local function animate(dragon, dt: number)
	if dragon and dragon.Anim then
		dragon.Anim:Update(dt)
		dragon.Anim:Apply(true)
	end
end

-- ============================================================== result card
local function resultCard(record, isNew: boolean, onEquip: () -> (), onContinue: () -> ())
	local uic = registry.UIController
	local layer = uic.Layers.GameModal and uic.Layers.GameModal.Root or uic.Layers.GameUI.Root
	local rarity = DragonConfig.Rarities[record.Rarity] or DragonConfig.Rarities.Common
	local root = Kit.frame({ Name = "HatchResult", Size = UDim2.fromScale(1, 1), Parent = layer })
	local card = Kit.surface({
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.95),
		Size = UDim2.fromScale(0.36, 0.34),
		Color = C.Panel,
		Transparency = 0.08,
		StrokeColor = rarity.Color,
		StrokeTransparency = 0.15,
		Radius = "Window",
		Parent = root,
	})
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.7
	aspect.Parent = card
	Responsive.bind(card, "Size", function(R)
		if R.Device == "Phone" then
			return UDim2.fromScale(R.Portrait and 0.94 or 0.56, R.Portrait and 0.36 or 0.62)
		elseif R.Device == "Tablet" then
			return UDim2.fromScale(0.52, 0.36)
		end
		return UDim2.fromScale(0.36, 0.34)
	end)
	local pad = Kit.frame({ Name = "Pad", Size = UDim2.fromScale(1, 1), Parent = card })
	Kit.scalePadding(pad, 0.07, 0.06, 0.07, 0.06)
	-- top row: rarity + badges
	local top = Kit.frame({ Name = "Top", Size = UDim2.fromScale(1, 0.13), Parent = pad })
	Kit.list(top, "H", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	Kit.badge({ Text = string.upper(record.Rarity), Color = rarity.Color, LayoutOrder = 1, Parent = top })
	if record.Mutation and record.Mutation ~= "None" then
		local m = MutationConfig.Mutations[record.Mutation]
		Kit.badge({ Text = string.upper(m and m.Name or record.Mutation), Color = m and m.Color or C.Gold, LayoutOrder = 2, Parent = top })
	end
	if isNew then
		Kit.badge({ Text = "NEW!", Color = C.Accent, LayoutOrder = 3, Parent = top })
	end
	local name = Kit.text({
		Name = "Name",
		Text = string.upper(record.Name),
		Role = "Display",
		Scaled = true,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.14),
		Size = UDim2.fromScale(1, 0.22),
		Parent = pad,
	})
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(rarity.Glow, rarity.Color)
	grad.Parent = name
	-- RNG title: "1 in 12,500,000"
	local odds = Odds.ofRecord(record)
	local exclusive = Odds.isExclusive(record.SpeciesId)
	local title = Kit.text({
		Name = "OddsTitle",
		Text = Odds.format(odds, exclusive),
		Role = "Title",
		Scaled = true,
		Color = exclusive and rarity.Glow or Odds.color(odds),
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.37),
		Size = UDim2.fromScale(1, 0.12),
		Parent = pad,
	})
	title.TextStrokeTransparency = 0.4
	-- stats
	local stats = Kit.frame({ Name = "Stats", Position = UDim2.fromScale(0.08, 0.5), Size = UDim2.fromScale(0.84, 0.28), Parent = pad })
	Kit.list(stats, "V", 2, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	Kit.statRow({ Icon = "Speed", Label = "Run speed", Value = Format.abbreviate(record.Speed), Size = UDim2.fromScale(1, 0.32), LayoutOrder = 1, Parent = stats })
	Kit.statRow({ Icon = "Wing", Label = "Flight speed", Value = Format.abbreviate(record.FlightSpeed), Size = UDim2.fromScale(1, 0.32), LayoutOrder = 2, Parent = stats })
	Kit.statRow({ Icon = "Income", Label = "Income", Value = Format.perSecond(record.IncomePerSecond), ValueColor = C.GoldBright, Size = UDim2.fromScale(1, 0.32), LayoutOrder = 3, Parent = stats })
	-- buttons
	local row = Kit.frame({ Name = "Buttons", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(1, 0.18), Parent = pad })
	Kit.list(row, "H", 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local equip = Kit.button({ Name = "Equip", Text = "RIDE IT", Icon = "Dragon", Style = "Secondary", Size = UDim2.fromScale(0.42, 1), LayoutOrder = 1, Parent = row })
	local cont = Kit.button({ Name = "Continue", Text = "AWESOME!", Style = "Primary", Size = UDim2.fromScale(0.42, 1), LayoutOrder = 2, Parent = row })
	equip.Activated:Connect(onEquip)
	cont.Activated:Connect(onContinue)
	-- entrance: slide up + fade
	local scale = Instance.new("UIScale")
	scale.Scale = 0.85
	scale.Parent = card
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	return root, equip, cont
end

-- ============================================================== RNG roll
-- Center-screen "roll": names and odds flash by, slow down and land on the
-- real result right when the egg bursts.
local function rollStrip(layer: Instance, eggType: string, record)
	local egg = EggConfig.Eggs[eggType] or EggConfig.Eggs.HavenEgg
	local pool, total = {}, 0
	for _, e in egg.Hatch do
		table.insert(pool, e)
		total += e.Weight
	end
	local rng = Random.new()
	local root = Kit.frame({
		Name = "HatchRoll",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromScale(0.62, 0.2),
		Parent = layer,
	})
	local header = Kit.text({ Name = "Header", Text = "ROLLING...", Role = "Label", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 0.16), Parent = root })
	local tag = Kit.text({ Name = "Tag", Text = "", Role = "Label", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.16), Size = UDim2.fromScale(1, 0.14), Parent = root })
	local name = Kit.text({ Name = "Name", Text = "", Role = "Display", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.3), Size = UDim2.fromScale(1, 0.38), Parent = root })
	local title = Kit.text({ Name = "Title", Text = "", Role = "Title", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.7), Size = UDim2.fromScale(1, 0.3), Parent = root })
	for _, t in { name, title, tag } do
		t.TextStrokeTransparency = 0.25
	end
	local scale = Instance.new("UIScale")
	scale.Parent = root
	local function show(speciesId: string, mutation: string, odds: number)
		local sp = DragonConfig.Species[speciesId]
		local rar = sp and DragonConfig.Rarities[sp.Rarity] or DragonConfig.Rarities.Common
		name.Text = string.upper(sp and sp.Name or speciesId)
		name.TextColor3 = rar.Glow
		title.Text = Odds.format(odds)
		title.TextColor3 = Odds.color(odds)
		local m = MutationConfig.Mutations[mutation]
		tag.Text = (m and mutation ~= "None") and string.upper(m.Name) or ""
		tag.TextColor3 = m and m.Color or C.Text
	end
	local function randomCandidate()
		local r = rng:NextNumber() * total
		local pick = pool[#pool]
		-- flatten the odds so rare names flash by too (that's the fun)
		if rng:NextNumber() < 0.45 then
			pick = pool[rng:NextInteger(1, #pool)]
		else
			for _, e in pool do
				r -= e.Weight
				if r <= 0 then
					pick = e
					break
				end
			end
		end
		local mutation = "None"
		if rng:NextNumber() < 0.22 then
			local order = MutationConfig.Order
			mutation = order[rng:NextInteger(2, math.min(#order - 1, 12))]
		end
		return pick.Id, mutation
	end
	local self = {}
	local nextAt, lastId = 0, nil
	function self.Step(a: number, t: number, audio)
		if t < nextAt then
			return
		end
		local interval = 0.045 + 0.3 * a * a
		nextAt = t + interval
		local id, mutation = randomCandidate()
		if id == lastId and #pool > 1 then
			id, mutation = randomCandidate()
		end
		lastId = id
		show(id, mutation, Odds.fromEgg(eggType, id, mutation))
		scale.Scale = 1.06
		if audio then
			audio.playUI("Click")
		end
	end
	function self.Land()
		local odds = Odds.ofRecord(record)
		show(record.SpeciesId, record.Mutation or "None", odds)
		header.Text = "YOU ROLLED"
		header.TextColor3 = Odds.color(odds)
		scale.Scale = 1.35
		TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	function self.Settle(dt: number)
		scale.Scale += (1 - scale.Scale) * math.min(1, dt * 14)
	end
	function self.Fade(duration: number)
		for _, t in { header, tag, name, title } do
			TweenService:Create(t, TweenInfo.new(duration), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
		task.delay(duration + 0.05, function()
			root:Destroy()
		end)
	end
	function self.Destroy()
		root:Destroy()
	end
	return self
end

-- ============================================================== cinematic
local function play(slot: number, result)
	local camera = Workspace.CurrentCamera
	local cam = registry.CameraController
	local uic = registry.UIController
	local sanct = registry.SanctuaryController
	local audio = registry.AudioController
	local record = result.Dragon
	local eggType = result.Egg
	local slotCF = sanct and sanct.slotCFrame(slot)
	local nestCF = sanct and sanct.nestCFrame()
	if not slotCF or not nestCF then
		uic.Notify("success", "Hatched " .. record.Name .. "!")
		return
	end
	local cfg = HatchConfig.Cinematic
	local rarity = DragonConfig.Rarities[record.Rarity] or DragonConfig.Rarities.Common
	local resultOdds = Odds.ofRecord(record)
	local rare = resultOdds >= HatchConfig.RareOdds or DragonConfig.rarityRank(record.Rarity) >= HatchConfig.RareRank
	local ultra = resultOdds >= HatchConfig.Announce.MinOdds
	local mutated = record.Mutation ~= nil and record.Mutation ~= "None"
	local mutation = mutated and MutationConfig.Mutations[record.Mutation] or nil
	local accent = mutation and mutation.Color or rarity.Color
	local def = EggConfig.Eggs[eggType] or EggConfig.Eggs.HavenEgg
	local rng = Random.new()
	local state = { Skip = false }

	local modal = uic.Layers.GameModal and uic.Layers.GameModal.Root or uic.Layers.GameUI.Root
	local stage = Instance.new("Folder")
	stage.Name = "HatchStage"
	stage.Parent = Workspace
	HatchController.Stage = stage
	local fx = newFx(modal)
	local skip = skipButton(modal, state)
	local roll = nil
	local card = nil
	local conn = nil
	local fov0 = camera.FieldOfView
	local showCompanion = hideCompanion()
	local function cleanup()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if card then
			card:Destroy()
			card = nil
		end
		if roll then
			roll.Destroy()
			roll = nil
		end
		skip.Instance:Destroy()
		fx.Cleanup()
		showCompanion()
		stage:Destroy()
		camera.FieldOfView = fov0
		HatchController.Phase = ""
		HatchController.Stage = nil
		HatchController.Dragon = nil
		HatchController.Framing = nil
	end
	active = { Cleanup = cleanup }

	if cam then
		cam.beginCinematic()
	end
	uic.SetHudVisible(false)
	task.delay(cfg.SkipAfter, function()
		if skip.Instance.Parent then
			skip.Instance.Visible = true
		end
	end)
	-- hide the nest egg of this slot (data sync will remove it anyway)
	local mySanct = Workspace:FindFirstChild("MySanctuary")
	local nestEgg = mySanct and mySanct:FindFirstChild("NestEgg" .. slot)
	if nestEgg then
		nestEgg:Destroy()
	end
	local egg = EggVisual.build(eggType, { Beam = false, Scale = 1.15 })
	EggVisual.place(egg, slotCF)
	egg.Parent = stage
	local eggPos = slotCF.Position
	local shell = egg.PrimaryPart
	local light = shell and shell:FindFirstChildOfClass("PointLight")

	-- ---- 1) APPROACH: darken, glide to the egg, lift it into a pool of light
	HatchController.Phase = "Approach"
	fx.Darken(true, cfg.Approach)
	local fromDir = (camera.CFrame.Position - eggPos) * Vector3.new(1, 0, 1)
	if fromDir.Magnitude < 1 then
		fromDir = -nestCF.LookVector
	end
	fromDir = fromDir.Unit
	local shot = CFrame.lookAt(eggPos + fromDir * 10.5 + Vector3.new(0, 3.8, 0), eggPos + Vector3.new(0, 1.9, 0))
	local pool = neonDisc(def.Glow, 9, eggPos - Vector3.new(0, 1.55, 0), stage, 0.55)
	local lift = 0
	local from = camera.CFrame
	run(state, cfg.Approach, function(a, t)
		camera.CFrame = from:Lerp(shot, ease(a))
		lift = 1.3 * ease(a)
		EggVisual.place(egg, slotCF * CFrame.new(0, lift, 0) * CFrame.Angles(math.sin(t * 5) * 0.03, 0, 0))
		pool.Transparency = 0.7 - 0.3 * ease(a)
	end)

	-- ---- 2) CHARGE: wobble, the roll spins, cracks open one by one
	HatchController.Phase = "Charge"
	roll = rollStrip(modal, eggType, record)
	local chargeTime = rare and cfg.ChargeRare or cfg.Charge
	local crackCount = rare and cfg.CracksRare or cfg.Cracks
	local crackAt = {}
	for i = 1, crackCount do
		crackAt[i] = 0.2 + 0.72 * (i - 1) / crackCount
	end
	local nextCrack, nextShake, flare = 1, 0, 0
	local lastT = 0
	if not state.Skip then
		run(state, chargeTime, function(a, t, dt)
			roll.Step(a, t, audio)
			roll.Settle(t - lastT)
			lastT = t
			if nextCrack <= crackCount and a >= crackAt[nextCrack] then
				addCrack(egg, def, nextCrack, rng)
				nextCrack += 1
				flare = 1
				if audio and shell then
					audio.play3D("EggCrack", shell, 0.1)
				end
				if cam then
					cam.shake(0.22 + 0.12 * a)
				end
			end
			flare = math.max(0, flare - dt * 3.5)
			local amp = 0.04 + 0.3 * a * a
			local freq = 8 + 18 * a
			EggVisual.place(egg, slotCF * CFrame.new(0, lift + math.sin(t * 3) * 0.08, 0) * CFrame.Angles(math.sin(t * freq) * amp, 0, math.cos(t * freq * 0.83) * amp))
			if light then
				light.Brightness = 1.5 + 6 * a + 5 * flare
				light.Range = 10 + 18 * a
			end
			pool.Transparency = 0.4 - 0.25 * a + 0.15 * math.sin(t * 9)
			pool.Size = Vector3.new(0.15, 9 + 5 * a, 9 + 5 * a)
			if t > nextShake then
				nextShake = t + 0.55 - 0.35 * a
				if audio and shell then
					audio.play3D("EggShake", shell, 0.1)
				end
				if cam then
					cam.shake(0.06 + 0.2 * a)
				end
			end
			camera.CFrame = shot * CFrame.new(0, 0, -1.8 * ease(a)) * CFrame.Angles(0, math.sin(t * 0.9) * 0.02, 0)
		end)
	end

	-- ---- 3) BURST: the roll lands, flash, shards, shock ring, pillar of light
	HatchController.Phase = "Burst"
	local quick = state.Skip
	local burstAt = eggPos + Vector3.new(0, lift, 0)
	if quick then
		-- skipped: no show, just clear the shell away
		roll.Destroy()
		roll = nil
		egg:Destroy()
		pool:Destroy()
	else
		roll.Land()
		local rollRef = roll
		task.delay(2.4, function()
			rollRef.Fade(0.5)
		end)
		roll = nil
		local flash = neonBall(rarity.Glow, 2, CFrame.new(burstAt), stage)
		shards(def.Shell, burstAt, stage)
		egg:Destroy()
		pool:Destroy()
		fx.Pulse(ultra and 1 or (rare and 0.85 or 0.6), ultra and 0.9 or 0.55)
		if audio then
			audio.play3D(DragonConfig.rarityRank(record.Rarity) >= 4 and "RareHatch" or "Hatch", flash, 0)
		end
		local ring = neonDisc(accent, 4, eggPos - Vector3.new(0, 1.2, 0), stage, 0.1)
		local pillar = Instance.new("Part")
		pillar.Anchored = true
		pillar.CanCollide = false
		pillar.CanQuery = false
		pillar.CanTouch = false
		pillar.CastShadow = false
		pillar.Shape = Enum.PartType.Cylinder
		pillar.Material = Enum.Material.Neon
		pillar.Color = accent
		pillar.Size = Vector3.new(220, 6, 6) -- cylinder axis is X (rotated upright below)
		pillar.CFrame = CFrame.new(eggPos + Vector3.new(0, 110, 0)) * CFrame.Angles(0, 0, math.rad(90))
		pillar.Transparency = 0.35
		pillar.Parent = stage
		local burstLight = Instance.new("PointLight")
		burstLight.Color = rarity.Glow
		burstLight.Range = 42
		burstLight.Brightness = 8
		burstLight.Parent = flash
		TweenService:Create(flash, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(26, 26, 26), Transparency = 1 }):Play()
		TweenService:Create(ring, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.15, 80, 80), Transparency = 1 }):Play()
		TweenService:Create(pillar, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = Vector3.new(220, 0.5, 0.5), Transparency = 1 }):Play()
		TweenService:Create(burstLight, TweenInfo.new(1.4), { Brightness = 0 }):Play()
		confetti(stage, burstAt, { rarity.Glow, accent, Color3.new(1, 1, 1) }, ultra and 120 or (rare and 70 or 36))
		if cam then
			cam.shake(0.9)
		end
	end

	-- ---- 4) WALK: the dragon steps out of the light and walks to the camera
	local sp = Species.get(record.SpeciesId)
	local S = sp.Scale or 1
	local hip = sp.HipHeight * S
	local center = nestCF.Position
	local floorY = center.Y - 2.6
	local focusBase = Vector3.new(center.X, floorY + hip * 0.9, center.Z)
	-- the dragon is built first so its real nose position decides the framing
	local startPos = Vector3.new(center.X, floorY + hip, center.Z)
	local dragon = spawnDragon(record, CFrame.lookAt(startPos, startPos + fromDir), stage)
	HatchController.Dragon = dragon
	-- framing: the camera waits `dist` away from the nest (it pulls back while the flash
	-- hides it) and the dragon walks towards it, stopping with its HEAD still well in front
	-- of the lens (headReach = root to nose, measured on the built model)
	local headReach = ((sp.Body and sp.Body.Length or 7) * 0.5 + (sp.Neck and sp.Neck.Length or 5) + 3) * S
	local mouth = dragon and dragon.Visual:FindFirstChild("Mouth", true)
	if mouth and dragon then
		local rel = dragon.Root.CFrame:PointToObjectSpace((mouth :: any).WorldPosition)
		headReach = math.max(headReach * 0.6, -rel.Z * 1.15 + 2) -- (a roaring head reaches further)
	end
	-- how far the lens must be for the dragon to fill about 70% of the screen width (wings open
	-- for the roar, so a fifth more than the idle pose): works for every species and aspect ratio
	local viewport = camera.ViewportSize
	local aspect = math.clamp(viewport.X / math.max(1, viewport.Y), 0.4, 2.4)
	local frameW = 20
	if dragon then
		animate(dragon, 0.03) -- idle pose first
		local ext = dragon.Visual:GetExtentsSize()
		frameW = math.max(ext.X * 1.2, ext.Y * 1.4)
	end
	local fillDist = frameW / (0.7 * 2 * math.tan(math.rad(fov0 / 2)) * aspect)
	local margin = math.clamp(fillDist, 9, 70) -- nose to lens
	local walkDist = math.clamp(headReach + 4, 8, 22)
	local finalDist = headReach + margin
	local dist = math.max(26, finalDist + walkDist)
	local ignore = {}
	for _, inst in { stage, LocalPlayer.Character, Workspace:FindFirstChild("Dragons"), Workspace:FindFirstChild("MySanctuary"), Workspace:FindFirstChild("MyEggs"), Workspace:FindFirstChild("HeldEggs") } do
		table.insert(ignore, inst)
	end
	local faceDir, clear = clearSpot(focusBase, fromDir, dist, ignore)
	if clear < 1 then
		-- cramped plot: everything shrinks towards the nest, the head keeps its margin
		local k = math.max(0.55, clear * 0.92)
		dist = math.max(16, dist * k)
		finalDist = math.max(headReach + 6, finalDist * k)
		walkDist = math.max(6, dist - finalDist)
	end
	HatchController.Framing = { Dir = faceDir, Dist = dist, Clear = clear, Final = finalDist, HeadReach = headReach }
	if dragon then
		dragon.Root.CFrame = CFrame.lookAt(startPos, startPos + faceDir)
	end
	-- walking pace matches the gait cycle (stride length grows with the dragon)
	local walkTime = math.clamp(walkDist / math.clamp(10 * S, 8, 22), 1.8, cfg.Walk + 0.8)
	local walkSpeed = walkDist / walkTime
	local orbitStart = math.atan2(faceDir.X, faceDir.Z)
	local function orbitCF(angle: number, d: number, focus: Vector3): CFrame
		local dir = Vector3.new(math.sin(angle), 0, math.cos(angle))
		return CFrame.lookAt(focus + dir * d + Vector3.new(0, d * 0.3, 0), focus)
	end
	local walkShot = orbitCF(orbitStart, dist, focusBase)
	camera.CFrame = walkShot
	camera.FieldOfView = fov0
	local footSize = math.clamp(S * 0.4, 0.3, 1)
	if dragon then
		setReveal(dragon, 0)
		dragon.Anim.OnFootstep = function()
			if cam then
				cam.shake(0.05 + 0.1 * footSize)
			end
			if audio then
				audio.play3D("Footstep", dragon.Root, 0.12, 0.5 + 0.5 * footSize)
			end
		end
	end
	HatchController.Phase = "Walk"
	local position = startPos
	local walkDone = run(state, walkTime, function(a, t, dt)
		if dragon then
			position = startPos + faceDir * (walkDist * a)
			dragon.Root.CFrame = CFrame.lookAt(position, position + faceDir)
			dragon.Anim:SetParams({ Mode = "Ground", Speed = a < 0.88 and walkSpeed or walkSpeed * (1 - a) * 8, Look = Vector2.zero })
			setReveal(dragon, math.clamp(a * 4, 0, 1))
			animate(dragon, dt)
		end
		-- the camera holds the shot (a hair of drift), tracking the dragon's head height
		camera.CFrame = walkShot * CFrame.Angles(0, math.sin(t * 0.6) * 0.012, 0)
	end)

	-- ---- 5) ROAR: stop, rear up, shake the world
	HatchController.Phase = "Roar"
	local roarPos = startPos + faceDir * walkDist
	-- the camera looks at the roaring head, not at the hips
	local roarFocus = Vector3.new(roarPos.X, focusBase.Y, roarPos.Z) + faceDir * (headReach * 0.5) + Vector3.new(0, hip * 0.4, 0)
	if dragon then
		dragon.Root.CFrame = CFrame.lookAt(roarPos, roarPos + faceDir)
		setReveal(dragon, 1)
		dragon.Anim:SetParams({ Mode = "Ground", Speed = 0 })
		dragon.Anim:Play("Roar")
	end
	if walkDone then
		local roared = false
		local camBase = walkShot.Position
		run(state, cfg.Roar, function(a, _t, dt)
			animate(dragon, dt)
			if not roared and a >= 0.32 then
				roared = true
				if cam then
					cam.shake(0.85)
				end
				fx.Pulse(mutated and 0.55 or 0.3, 0.5)
				if audio and dragon then
					audio.play3D("Roar", dragon.Root, 0.04)
				end
				local wave = neonDisc(accent, 6, Vector3.new(roarPos.X, floorY + 0.3, roarPos.Z), stage, 0.25)
				TweenService:Create(wave, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.15, 120, 120), Transparency = 1 }):Play()
				confetti(stage, roarPos + Vector3.new(0, hip * 1.4, 0), mutated and { accent, Color3.new(1, 1, 1), rarity.Glow } or { rarity.Glow, Color3.new(1, 1, 1) }, mutated and 90 or 40)
			end
			-- slow push-in towards the roaring head, field of view tightens
			camera.FieldOfView = fov0 - 12 * ease(a)
			camera.CFrame = CFrame.lookAt(camBase:Lerp(roarFocus, 0.12 * ease(a)), roarFocus)
		end)
	end
	camera.FieldOfView = fov0
	skip.Instance.Visible = false

	-- ---- 6) CARD: the dragon idles, the camera orbits slowly, the card shows the result
	HatchController.Phase = "Card"
	fx.Darken(false, 0.8)
	if dragon then
		dragon.Root.CFrame = CFrame.lookAt(roarPos, roarPos + faceDir)
		setReveal(dragon, 1)
		dragon.Anim:SetParams({ Mode = "Ground", Speed = 0 })
	end
	local cardDist = (walkShot.Position - roarFocus).Magnitude * 0.95
	local swayT = 0
	tweenCamera({ Skip = false }, camera, orbitCF(orbitStart, cardDist, roarFocus), 0.9)
	local done = false
	local equipped = false
	conn = RunService.RenderStepped:Connect(function(dt)
		-- a slow sway around the clear line of sight (never swings into the walls)
		swayT += dt
		camera.CFrame = orbitCF(orbitStart + SWAY * math.sin(swayT * 0.4), cardDist, roarFocus)
		animate(dragon, dt)
	end)
	card = resultCard(record, result.New == true, function()
		if equipped then
			return
		end
		equipped = true
		task.spawn(function()
			local res = Net.request("Dragon", "Equip", { Id = record.UniqueId })
			if uic.HandleResult(res, record.Name .. " is now your dragon!") then
				done = true
			else
				equipped = false
			end
		end)
	end, function()
		done = true
	end)
	if dragon and rare and audio then
		audio.playUI("LevelUp")
	end
	while not done do
		task.wait()
	end

	-- ---- 7) back to the player
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if conn then
		conn:Disconnect()
		conn = nil
	end
	if card then
		card:Destroy()
		card = nil
	end
	if hrp then
		local back = CFrame.lookAt(hrp.Position - hrp.CFrame.LookVector * 16 + Vector3.new(0, 7, 0), hrp.Position + Vector3.new(0, 2, 0))
		tweenCamera({ Skip = false }, camera, back, 0.6)
	end
	cleanup()
	active = nil
	uic.SetHudVisible(true)
	if cam then
		cam.endCinematic()
	end
end

function HatchController.hatch(slot: number)
	if busy then
		return
	end
	busy = true
	local uic = registry.UIController
	local ok, err = pcall(function()
		local res = Net.request("Egg", "Hatch", { Slot = slot })
		if not res.ok then
			uic.HandleResult(res)
			return
		end
		play(slot, res.data)
	end)
	if not ok then
		warn("[Hatch] " .. tostring(err))
		if active then
			pcall(active.Cleanup)
			active = nil
		end
		local cam = registry.CameraController
		if cam and cam.inCinematic() then
			cam.endCinematic()
		end
		uic.SetHudVisible(true)
	end
	busy = false
end

-- UILab: show the result card with a sample dragon (no cinematic).
local previewCard: Instance? = nil
function HatchController.previewResult()
	HatchController.closePreview()
	local DragonStats = require(Shared:WaitForChild("DragonStats"))
	local record = DragonStats.newRecord("PREVIEW", "InfernoDragon", "Golden", os.time())
	previewCard = resultCard(record, true, function() end, function()
		HatchController.closePreview()
	end)
end

function HatchController.closePreview()
	if previewCard then
		previewCard:Destroy()
		previewCard = nil
	end
end

function HatchController.isBusy(): boolean
	return busy
end

function HatchController.Init(reg)
	registry = reg
end

return HatchController

--[[
	HatchController
	Hatching cinematic + result card.

	Sequence (client-only, server already decided the result):
	  camera glides to the nest -> egg wobbles faster and faster -> flash,
	  shell shards and a rarity-coloured shock ring -> the dragon grows out of
	  the light and roars -> slow orbit + result card (rarity, name, mutation,
	  NEW badge, stats, Equip / Continue) -> camera returns.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
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
local Odds = require(Shared:WaitForChild("Odds"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Kit = require(UI:WaitForChild("Kit"))
local Responsive = require(UI:WaitForChild("Responsive"))

local C = Theme.Colors

local HatchController = {}

local registry
local busy = false
local LocalPlayer = Players.LocalPlayer

-- ============================================================== helpers
local function ease(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function run(duration: number, fn: (number, number) -> ())
	local t0 = os.clock()
	while true do
		local t = os.clock() - t0
		local a = math.clamp(t / duration, 0, 1)
		fn(a, t)
		if a >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
end

local function tweenCamera(camera: Camera, to: CFrame, duration: number)
	local from = camera.CFrame
	run(duration, function(a)
		camera.CFrame = from:Lerp(to, ease(a))
	end)
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

local function shards(color: Color3, at: Vector3, parent: Instance)
	for i = 1, 14 do
		local s = Instance.new("Part")
		s.CanCollide = false
		s.CanQuery = false
		s.CanTouch = false
		s.Material = Enum.Material.SmoothPlastic
		s.Color = color
		s.Size = Vector3.new(0.6, 0.15, 0.8) * (0.7 + math.random() * 0.8)
		s.CFrame = CFrame.new(at) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		s.Parent = parent
		local a = i / 14 * math.pi * 2
		s.AssemblyLinearVelocity = Vector3.new(math.cos(a) * 18, 22 + math.random() * 14, math.sin(a) * 18)
		s.AssemblyAngularVelocity = Vector3.new(math.random() * 20, math.random() * 20, math.random() * 20)
		task.delay(2.2, function()
			s:Destroy()
		end)
	end
end

-- Builds a static showcase model of the hatched dragon in a pose.
local function showcaseDragon(record, rootCF: CFrame, parent: Instance): Model?
	local ok, model = pcall(function()
		local m = DragonVisual.build(record.SpeciesId, { Mutation = record.Mutation, Saddle = false })
		local pose = Animator.samplePose(m, "Roar", 0.85)
		if m:GetAttribute("MeshRig") then
			DragonVisual.pose(m, pose, rootCF)
		else
			Builder.pose(m, pose, rootCF)
		end
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		m.Parent = parent
		return m
	end)
	if ok then
		return model
	end
	warn("[Hatch] showcase failed: " .. tostring(model))
	return nil
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
		Position = UDim2.fromScale(0.5, 0.3),
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
			mutation = order[rng:NextInteger(2, math.min(#order, 7))]
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
	local rarity = DragonConfig.Rarities[record.Rarity] or DragonConfig.Rarities.Common
	local stage = Instance.new("Folder")
	stage.Name = "HatchStage"
	stage.Parent = Workspace
	if cam then
		cam.beginCinematic()
	end
	uic.SetHudVisible(false)
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
	-- 1) glide to the egg (keep the player's viewing side)
	local fromDir = (camera.CFrame.Position - eggPos) * Vector3.new(1, 0, 1)
	if fromDir.Magnitude < 1 then
		fromDir = -nestCF.LookVector
	end
	fromDir = fromDir.Unit
	local shot = CFrame.lookAt(eggPos + fromDir * 13 + Vector3.new(0, 5.5, 0), eggPos + Vector3.new(0, 1.2, 0))
	tweenCamera(camera, shot, 0.75)
	-- 2) wobble, faster and faster, while the RNG roll spins
	local shell = egg.PrimaryPart
	local light = shell and shell:FindFirstChildOfClass("PointLight")
	local nextShake = 0
	local modal = uic.Layers.GameModal and uic.Layers.GameModal.Root or uic.Layers.GameUI.Root
	local roll = rollStrip(modal, eggType, record)
	local resultOdds = Odds.ofRecord(record)
	local rareRoll = Odds.tier(resultOdds) >= 4 or DragonConfig.rarityRank(record.Rarity) >= 4
	local lastT = 0
	run(rareRoll and 2.8 or 2.2, function(a, t)
		roll.Step(a, t, audio)
		roll.Settle(t - lastT)
		lastT = t
		local amp = 0.04 + 0.32 * a * a
		local freq = 8 + 18 * a
		EggVisual.place(egg, slotCF * CFrame.Angles(math.sin(t * freq) * amp, 0, math.cos(t * freq * 0.83) * amp))
		if light then
			light.Brightness = 1 + 6 * a
			light.Range = 10 + 16 * a
		end
		if t > nextShake then
			nextShake = t + 0.55 - 0.35 * a
			if audio and shell then
				audio.play3D("EggShake", shell, 0.1)
			end
			if cam then
				cam.shake(0.1 + 0.3 * a)
			end
		end
		camera.CFrame = shot * CFrame.new(0, 0, -1.5 * ease(a))
	end)
	-- 3) burst: the roll lands on the real result
	roll.Land()
	task.delay(2.4, function()
		roll.Fade(0.5)
	end)
	local flash = neonBall(rarity.Glow, 2, CFrame.new(eggPos), stage)
	local def = EggConfig.Eggs[eggType] or EggConfig.Eggs.HavenEgg
	shards(def.Shell, eggPos, stage)
	egg:Destroy()
	if audio and flash then
		audio.play3D(DragonConfig.rarityRank(record.Rarity) >= 4 and "RareHatch" or "Hatch", flash, 0)
	end
	local ring = Instance.new("Part")
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = rarity.Color
	ring.Size = Vector3.new(0.3, 4, 4)
	ring.CFrame = CFrame.new(eggPos) * CFrame.Angles(0, 0, math.rad(90))
	ring.CastShadow = false
	ring.Parent = stage
	local burstLight = Instance.new("PointLight")
	burstLight.Color = rarity.Glow
	burstLight.Range = 40
	burstLight.Brightness = 8
	burstLight.Parent = flash
	TweenService:Create(flash, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(26, 26, 26), Transparency = 1 }):Play()
	TweenService:Create(ring, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.3, 70, 70), Transparency = 1 }):Play()
	TweenService:Create(burstLight, TweenInfo.new(1.2), { Brightness = 0 }):Play()
	if cam then
		cam.shake(0.9)
	end
	-- 4) the dragon grows out of the light
	local def2 = Species.get(record.SpeciesId)
	local S = def2.Scale or 1
	local hip = def2.HipHeight * S
	local length = ((def2.Body and def2.Body.Length or 7) + (def2.Tail and def2.Tail.Length or 12) + (def2.Neck and def2.Neck.Length or 5)) * S
	local faceDir = fromDir
	local center = nestCF.Position
	local rootCF = CFrame.lookAt(center + Vector3.new(0, hip - 2.4, 0), center + Vector3.new(0, hip - 2.4, 0) + faceDir)
	local dragon = showcaseDragon(record, rootCF, stage)
	if dragon then
		pcall(function()
			local base = dragon:GetScale()
			dragon:ScaleTo(base * 0.25)
			run(0.45, function(a)
				dragon:ScaleTo(base * (0.25 + 0.75 * ease(a)))
			end)
		end)
	end
	-- 5) frame the dragon and orbit slowly while the card is open
	local dist = math.max(28, length * 1.15)
	local focus = center + Vector3.new(0, hip * 0.9, 0)
	local orbitStart = math.atan2(faceDir.X, faceDir.Z)
	local function orbitCF(angle: number): CFrame
		local dir = Vector3.new(math.sin(angle), 0, math.cos(angle))
		return CFrame.lookAt(focus + dir * dist + Vector3.new(0, dist * 0.32, 0), focus)
	end
	tweenCamera(camera, orbitCF(orbitStart + 0.35), 0.9)
	local done = false
	local equipped = false
	local orbit = 0.35
	local conn = RunService.RenderStepped:Connect(function(dt)
		orbit += dt * 0.12
		camera.CFrame = orbitCF(orbitStart + orbit)
	end)
	local card
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
	while not done do
		task.wait()
	end
	conn:Disconnect()
	if card then
		card:Destroy()
	end
	-- 6) back to the player
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local back = CFrame.lookAt(hrp.Position - hrp.CFrame.LookVector * 16 + Vector3.new(0, 7, 0), hrp.Position + Vector3.new(0, 2, 0))
		tweenCamera(camera, back, 0.6)
	end
	stage:Destroy()
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

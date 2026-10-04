--[[
	DuelController
	The client of the turn-based duels (DuelService / DuelConfig): a FIXED SCENE like the old Pokemon
	games. Nothing of it exists on the server: the controller builds a little stage high above the
	world, shows both dragons on it (yours in front on the left, the opponent's behind on the right),
	locks the camera and plays what the server decided, turn by turn.

	Flow: Duel.Start / Duel.Respond (or the signal DuelStart) -> begin(view)
	  intro (the camera swoops in, VS banner, both dragons appear)
	  menu (STRIKE / FIRE / GUARD / SPECIAL, keys 1-4) -> Duel.Move -> signal DuelTurn { Events }
	  each event: a line of text, the move (lunge / fireball / shield / roar), damage numbers, HP bars
	  KO: the dragon sinks away; DuelEnd -> VICTORY / DEFEAT card with the rewards -> everything back.

	The HUD, prompts and your own companion are hidden while the scene runs; the character is held.
	DuelController.State() / .choose(move) are for tests and tools; .preview(kind) is for the UI Lab.
	Signals (server): DuelStart, DuelTurn, DuelEnd, DuelChallenge, DuelChallengeEnd.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local PromptGate = require(Shared:WaitForChild("Util"):WaitForChild("PromptGate"))
local DragonVisual = require(Shared:WaitForChild("Dragons"):WaitForChild("DragonVisual"))
local Animator = require(Shared:WaitForChild("Dragons"):WaitForChild("Animator"))
local Builder = require(Shared:WaitForChild("Dragons"):WaitForChild("Builder"))
local DuelConfig = require(Configs:WaitForChild("DuelConfig"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Create = require(UI:WaitForChild("Create"))
local Kit = require(UI:WaitForChild("Kit"))

local C = Theme.Colors
local H = Theme.Hud
local LocalPlayer = Players.LocalPlayer

local DuelController = {}
DuelController.Phase = ""

local registry
local ui: any = nil -- HUD elements (built once)
local session: any = nil -- the running duel
local challengeUI: any = nil
local HP_GOOD = Color3.fromRGB(110, 210, 110)
local HP_MID = Color3.fromRGB(240, 200, 60)
local HP_LOW = Color3.fromRGB(235, 70, 60)

-- The stage floats far above the world; its centre is the origin of the scene's coordinates.
local STAGE = Vector3.new(0, 4200, 0)
local MY_SPOT = Vector3.new(-9, 0, 10) -- relative to the stage centre (ground level)
local FOE_SPOT = Vector3.new(10, 0, -9)
local DRAGON_SIZE = 12 -- studs: every dragon is scaled to this width on the stage

-- ============================================================== helpers
local function hpColor(ratio: number): Color3
	if ratio > 0.5 then
		return HP_MID:Lerp(HP_GOOD, (ratio - 0.5) * 2)
	end
	return HP_LOW:Lerp(HP_MID, ratio * 2)
end

-- Waits `seconds` of frame time; false when the session ended meanwhile.
local function sleep(mine: any, seconds: number): boolean
	local t = 0
	while t < seconds do
		t += RunService.RenderStepped:Wait()
		if session ~= mine then
			return false
		end
	end
	return session == mine
end

-- Runs fn(a) for a = 0..1 over `seconds` of frame time.
local function tween(mine: any, seconds: number, fn: (number) -> ()): boolean
	local t = 0
	fn(0)
	while t < seconds do
		t += RunService.RenderStepped:Wait()
		if session ~= mine then
			return false
		end
		fn(math.min(t / seconds, 1))
	end
	return true
end

local function ease(a: number): number
	return a * a * (3 - 2 * a)
end

local function sound(key: string)
	local audio = registry and registry.AudioController
	if audio and audio.playUI then
		audio.playUI(key)
	end
end

-- ============================================================== stage
local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function cylinder(parent: Instance, name: string, height: number, diameter: number, center: Vector3, color: Color3, material: Enum.Material?)
	-- (a cylinder part lies along X: turn it upright)
	return part(parent, name, Vector3.new(height, diameter, diameter), CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90)), color, material, Enum.PartType.Cylinder)
end

local function buildStage(mine: any): Folder
	local folder = Instance.new("Folder")
	folder.Name = "DuelStage"
	local o = STAGE
	local grass = Color3.fromRGB(104, 168, 84)
	-- ground and the two platforms
	cylinder(folder, "Ground", 4, 190, o + Vector3.new(0, -2.2, 0), grass)
	cylinder(folder, "GroundRing", 0.3, 120, o + Vector3.new(0, -0.1, 0), Color3.fromRGB(128, 188, 98))
	local function platform(spot: Vector3, radius: number, color: Color3)
		cylinder(folder, "Platform", 1.4, radius * 2, o + spot + Vector3.new(0, 0.7, 0), Color3.fromRGB(196, 168, 120), Enum.Material.Slate)
		cylinder(folder, "PlatformTop", 0.3, radius * 2 - 3, o + spot + Vector3.new(0, 1.45, 0), Color3.fromRGB(222, 198, 150), Enum.Material.Cobblestone)
		cylinder(folder, "PlatformRing", 0.2, radius * 2 - 0.6, o + spot + Vector3.new(0, 1.62, 0), color, Enum.Material.Neon)
		cylinder(folder, "PlatformRingInner", 0.25, radius * 2 - 2, o + spot + Vector3.new(0, 1.65, 0), Color3.fromRGB(222, 198, 150), Enum.Material.Cobblestone)
	end
	platform(MY_SPOT, 8.5, Color3.fromRGB(255, 200, 70))
	platform(FOE_SPOT, 7.5, Color3.fromRGB(255, 110, 90))
	-- a backdrop: far hills and clouds (the sky of the world is behind them)
	local rng = Random.new(41)
	for i = 1, 8 do
		local x = -170 + i * 40 + rng:NextNumber(-12, 12)
		local h = rng:NextNumber(26, 56)
		part(folder, "Hill", Vector3.new(h * 2.6, h, h * 2.2), CFrame.new(o + Vector3.new(x, h * 0.1, -125 + rng:NextNumber(-12, 12))), Color3.fromRGB(96, 156, 100):Lerp(Color3.fromRGB(132, 170, 196), rng:NextNumber()), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end
	for i = 1, 9 do
		local c = part(folder, "Cloud", Vector3.new(rng:NextNumber(18, 34), rng:NextNumber(6, 10), rng:NextNumber(10, 16)), CFrame.new(o + Vector3.new(rng:NextNumber(-130, 130), rng:NextNumber(34, 70), rng:NextNumber(-120, -80))), Color3.fromRGB(252, 252, 255), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		c.Transparency = 0.08
	end
	-- pines around the field (LEGO-like stacked cones)
	for i = 1, 14 do
		local a = i / 14 * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
		local r = rng:NextNumber(58, 78)
		local base = o + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if math.sin(a) > -0.2 or math.cos(a) < 0.6 then
			cylinder(folder, "Trunk", 5, 2.2, base + Vector3.new(0, 2.5, 0), Color3.fromRGB(110, 78, 50), Enum.Material.Wood)
			for k = 0, 2 do
				cylinder(folder, "Leaves", 5, 14 - k * 3.4, base + Vector3.new(0, 7 + k * 3.6, 0), Color3.fromRGB(52, 120, 70):Lerp(Color3.fromRGB(86, 160, 92), k / 3), Enum.Material.SmoothPlastic)
			end
		end
	end
	folder.Parent = Workspace
	return folder
end

-- ============================================================== dragons
-- The dragon of a fighter view as a living model (Animator) on the stage.
local function spawnDragon(fighter, spot: Vector3, lookAt: Vector3)
	local ok, result = pcall(function()
		local holder = Instance.new("Model")
		holder.Name = "DuelDragon"
		local root = Builder.makeRoot(fighter.Species, nil)
		root.Anchored = true
		local info = Builder.mountInfo(fighter.Species, nil)
		local hip = info and info.HipHeight or 3
		local base = CFrame.lookAt(STAGE + spot + Vector3.new(0, 1.8 + hip, 0), STAGE + lookAt + Vector3.new(0, 1.8 + hip, 0))
		root.CFrame = base
		root.Parent = holder
		holder.PrimaryPart = root
		local visual = DragonVisual.build(fighter.Species, { Root = root, Mutation = fighter.Mutation, Detail = "High", Saddle = false })
		visual.Name = "Visual"
		-- every dragon fills the same space on the stage, whatever its species
		local size = visual:GetExtentsSize()
		local k = math.clamp(DRAGON_SIZE / math.max(size.X, size.Z, 1), 0.5, 1.7)
		if math.abs(k - 1) > 0.04 then
			pcall(function()
				visual:ScaleTo(visual:GetScale() * k)
			end)
		end
		local fade = {}
		for _, d in visual:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.CastShadow = false
				fade[d] = d.Transparency
			end
		end
		visual.Parent = holder
		holder.Parent = Workspace:FindFirstChild("DuelStage") or Workspace
		local anim = Animator.new(visual)
		anim:Snap("Idle")
		return { Model = holder, Root = root, Visual = visual, Anim = anim, Fade = fade, Base = base, Offset = Vector3.zero, Scale = k, Hip = hip }
	end)
	if ok then
		return result
	end
	warn("[Duel] dragon failed: " .. tostring(result))
	return nil
end

local function setReveal(dragon, k: number)
	for p, orig in dragon.Fade do
		if p.Parent then
			p.Transparency = 1 - (1 - orig) * k
		end
	end
end

local function place(dragon, offset: Vector3?, lift: number?)
	if dragon and dragon.Root and dragon.Root.Parent then
		local o = offset or Vector3.zero
		dragon.Root.CFrame = dragon.Base * CFrame.new(o.X, lift or 0, o.Z)
	end
end

-- Dragon centre in the world (for projectiles, numbers, flashes).
local function centerOf(dragon): Vector3
	return dragon.Root.Position + Vector3.new(0, 3.2, 0)
end

-- ============================================================== effects
local function floatText(position: Vector3, text: string, color: Color3, big: boolean?)
	local anchor = Instance.new("Part")
	anchor.Name = "DuelText"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = position
	anchor.Parent = Workspace:FindFirstChild("DuelStage") or Workspace
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(big and 260 or 190, big and 70 or 50)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	local info = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, info, { Position = position + Vector3.new(0, 7, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1.2)
end

local function burst(position: Vector3, color: Color3, count: number?)
	local anchor = Instance.new("Part")
	anchor.Name = "DuelBurst"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = position
	anchor.Parent = Workspace:FindFirstChild("DuelStage") or Workspace
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	pe.LightEmission = 1
	pe.Rate = 0
	pe.Lifetime = NumberRange.new(0.4, 0.9)
	pe.Speed = NumberRange.new(10, 22)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = anchor
	pe:Emit(count or 18)
	Debris:AddItem(anchor, 1.4)
end

local function flash(dragon, color: Color3)
	local h = Instance.new("Highlight")
	h.FillColor = color
	h.OutlineColor = color
	h.FillTransparency = 0.3
	h.OutlineTransparency = 0.2
	h.Parent = dragon.Visual
	TweenService:Create(h, TweenInfo.new(0.3), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	Debris:AddItem(h, 0.4)
end

-- A glowing ball flying from one dragon to the other; returns when it has landed.
local function fireball(mine: any, from, to, color: Color3, size: number): boolean
	local a = centerOf(from) + (centerOf(to) - centerOf(from)).Unit * 3
	local b = centerOf(to)
	local ball = part(Workspace:FindFirstChild("DuelStage") or Workspace, "Fireball", Vector3.one * size, CFrame.new(a), color, Enum.Material.Neon, Enum.PartType.Ball)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 18
	light.Brightness = 2
	light.Parent = ball
	local trail = Instance.new("ParticleEmitter")
	trail.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	trail.Color = ColorSequence.new(color)
	trail.LightEmission = 1
	trail.Rate = 40
	trail.Lifetime = NumberRange.new(0.3, 0.5)
	trail.Speed = NumberRange.new(1, 3)
	trail.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.5), NumberSequenceKeypoint.new(1, 0) })
	trail.Parent = ball
	local ok = tween(mine, 0.55, function(t)
		local e = ease(t)
		local pos = a:Lerp(b, e) + Vector3.new(0, math.sin(math.pi * e) * 4, 0)
		ball.Position = pos
		ball.Size = Vector3.one * (size * (0.8 + 0.4 * math.sin(t * 16)))
	end)
	ball:Destroy()
	return ok
end

local function shield(dragon, color: Color3): Part
	local s = part(Workspace:FindFirstChild("DuelStage") or Workspace, "Shield", Vector3.one * 13, CFrame.new(centerOf(dragon)), color, Enum.Material.ForceField, Enum.PartType.Ball)
	s.Transparency = 0.45
	return s
end

-- ============================================================== HUD
local function makeLayer(): Frame
	local gui = Create("ScreenGui", {
		Name = "GameDuel",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Theme.Layers.Hud + 3,
	})
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	end)
	local root = Create("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local scale = Create("UIScale", { Parent = root })
	Responsive.registerRoot(root, scale)
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	return root
end

local function panel(name: string, parent: Instance): Frame
	local f = Kit.surface({ Name = name, Color = H.Panel, Transparency = H.Transparency, StrokeColor = H.Stroke, StrokeTransparency = H.StrokeTransparency, Radius = "Window", Parent = parent })
	return f
end

-- name / level / element / HP of one side
local function plate(parent: Instance, name: string, withNumbers: boolean)
	local p = panel(name, parent)
	local pad = Kit.frame({ Name = "Pad", Size = UDim2.fromScale(1, 1), Parent = p })
	Kit.scalePadding(pad, 0.1, 0.05, 0.1, 0.05)
	local view = {
		Panel = p,
		Name = Kit.text({ Name = "Name", Text = "", Role = "Heading", Scaled = true, Color = H.Text, Size = UDim2.fromScale(0.64, 0.3), Truncate = true, Parent = pad }),
		Level = Kit.text({ Name = "Level", Text = "", Role = "Label", Scaled = true, Color = H.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.66, 0), Size = UDim2.fromScale(0.34, 0.3), Parent = pad }),
		Owner = Kit.text({ Name = "Owner", Text = "", Role = "Caption", Scaled = true, Color = H.TextMuted, Position = UDim2.fromScale(0, 0.32), Size = UDim2.fromScale(0.5, 0.2), Truncate = true, Parent = pad }),
		Element = Kit.text({ Name = "Element", Text = "", Role = "Caption", Scaled = true, Color = H.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.5, 0.32), Size = UDim2.fromScale(0.5, 0.2), Parent = pad }),
		Bar = Kit.progress({ Name = "Hp", Color = HP_GOOD, Color2 = HP_GOOD, Track = H.Track, Position = UDim2.fromScale(0, 0.56), Size = UDim2.fromScale(1, 0.2), Parent = pad }),
		Numbers = withNumbers and Kit.text({ Name = "Numbers", Text = "", Role = "Label", Scaled = true, Font = Theme.Fonts.Number, Color = H.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0, 0.78), Size = UDim2.fromScale(1, 0.22), Parent = pad }) or nil,
		Buff = Kit.text({ Name = "Buff", Text = "", Role = "Caption", Scaled = true, Color = Color3.fromRGB(255, 140, 40), Position = UDim2.fromScale(0, 0.78), Size = UDim2.fromScale(0.5, 0.2), Parent = pad }),
	}
	return view
end

local function setPlate(view, fighter, hp: number?)
	local f = fighter
	view.Name.Text = string.upper(f.Name)
	view.Level.Text = "Lv " .. tostring(f.Level)
	view.Owner.Text = f.Owner and (f.Owner .. "'s") or ""
	view.Element.Text = string.upper(f.Element or "")
	view.Element.TextColor3 = DuelConfig.Colors[f.Element] or H.Text
	local hpNow = hp or f.HP
	local ratio = f.MaxHP > 0 and hpNow / f.MaxHP or 0
	view.Bar:SetColors(hpColor(ratio), hpColor(ratio))
	view.Bar:SetValue(ratio, false)
	if view.Numbers then
		view.Numbers.Text = string.format("%s / %s", Format.commas(hpNow), Format.commas(f.MaxHP))
	end
	view.Buff.Text = (f.Buff or 1) > 1 and "ATTACK UP" or ""
end

local function slideHp(mine: any, view, fighter, from: number, to: number)
	tween(mine, 0.6, function(a)
		local hp = from + (to - from) * ease(a)
		local ratio = fighter.MaxHP > 0 and hp / fighter.MaxHP or 0
		view.Bar:SetColors(hpColor(ratio), hpColor(ratio))
		view.Bar:SetValue(ratio, false)
		if view.Numbers then
			view.Numbers.Text = string.format("%s / %s", Format.commas(math.floor(hp + 0.5)), Format.commas(fighter.MaxHP))
		end
	end)
end

local MOVE_KEYS = { "Strike", "Fire", "Guard", "Special" }

local function buildHud(parent: Instance)
	ui = { Root = parent }
	-- opponent (top left)
	ui.Foe = plate(parent, "FoePlate", false)
	ui.Foe.Panel.Visible = false
	-- you (above the menu, right)
	ui.Me = plate(parent, "MePlate", true)
	ui.Me.Panel.Visible = false
	-- the message box (bottom left)
	local box = panel("Message", parent)
	box.Visible = false
	ui.Box = box
	ui.Text = Kit.text({ Name = "Line", Text = "", Role = "Heading", Scaled = true, Wrapped = true, Color = H.Text, YAlign = Enum.TextYAlignment.Center, Position = UDim2.fromScale(0.05, 0.1), Size = UDim2.fromScale(0.9, 0.8), Parent = box })
	-- the menu (bottom right): 2 x 2
	local menu = Kit.frame({ Name = "Menu", Parent = parent })
	menu.Visible = false
	ui.Menu = menu
	ui.Moves = {}
	for i, id in MOVE_KEYS do
		local def = DuelConfig.Moves[id]
		local cell = Kit.surface({ Name = id, Color = H.Panel, Transparency = H.Transparency, StrokeColor = C.Gold, StrokeTransparency = 0.45, Radius = "Card", Position = UDim2.fromScale(((i - 1) % 2) * 0.505, math.floor((i - 1) / 2) * 0.505), Size = UDim2.fromScale(0.495, 0.495), Parent = menu })
		local key = Kit.text({ Name = "Key", Text = tostring(i), Role = "Micro", Scaled = true, Color = H.TextMuted, Position = UDim2.fromScale(0.05, 0.06), Size = UDim2.fromScale(0.14, 0.3), Parent = cell })
		local label = Kit.text({ Name = "Label", Text = def.Name, Role = "Heading", Scaled = true, Color = H.Text, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.08, 0.1), Size = UDim2.fromScale(0.84, 0.46), Truncate = true, Parent = cell })
		local pp = Kit.text({ Name = "PP", Text = "", Role = "Caption", Scaled = true, Color = H.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.08, 0.58), Size = UDim2.fromScale(0.84, 0.32), Parent = cell })
		local hit = Create("TextButton", { Name = "Hit", BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = cell })
		hit.Activated:Connect(function()
			DuelController.choose(id)
		end)
		ui.Moves[id] = { Cell = cell, Label = label, PP = pp, Key = key }
	end
	-- turn and forfeit
	ui.Turn = Kit.text({ Name = "Turn", Text = "", Role = "Label", Scaled = true, Color = Color3.fromRGB(255, 255, 255), XAlign = Enum.TextXAlignment.Center, Parent = parent })
	ui.Turn.Visible = false
	ui.Forfeit = Kit.button({ Name = "Forfeit", Text = "RUN AWAY", Style = "Danger", Parent = parent })
	ui.Forfeit.Instance.Visible = false
	ui.Forfeit.Activated:Connect(function()
		DuelController.forfeit()
	end)
	-- the VS banner and the fade
	ui.Fade = Kit.frame({ Name = "Fade", BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(8, 10, 20), ZIndex = 30, Parent = parent })
	ui.Fade.Visible = false
	ui.Banner = Kit.frame({ Name = "Banner", Size = UDim2.fromScale(1, 0.3), Position = UDim2.fromScale(0, 0.32), ZIndex = 31, Parent = parent })
	ui.Banner.Visible = false
	ui.BannerLeft = Kit.text({ Name = "Left", Text = "", Role = "Display", Scaled = true, Color = Color3.fromRGB(255, 214, 90), XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.02, 0), Size = UDim2.fromScale(0.42, 1), ZIndex = 32, Parent = ui.Banner })
	ui.BannerVs = Kit.text({ Name = "Vs", Text = "VS", Role = "Display", Scaled = true, Color = Color3.new(1, 1, 1), XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.44, 0), Size = UDim2.fromScale(0.12, 1), ZIndex = 33, Parent = ui.Banner })
	ui.BannerRight = Kit.text({ Name = "Right", Text = "", Role = "Display", Scaled = true, Color = Color3.fromRGB(255, 120, 100), XAlign = Enum.TextXAlignment.Left, Position = UDim2.fromScale(0.56, 0), Size = UDim2.fromScale(0.42, 1), ZIndex = 32, Parent = ui.Banner })
	-- the end card
	local card = Kit.surface({ Name = "EndCard", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(0.36, 0.42), Color = C.Panel, Transparency = 0.04, StrokeColor = C.Gold, StrokeTransparency = 0.2, Radius = "Window", ZIndex = 40, Parent = parent })
	card.Visible = false
	ui.End = card
	ui.EndTitle = Kit.text({ Name = "Title", Text = "", Role = "Display", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.06), Size = UDim2.fromScale(0.9, 0.24), ZIndex = 41, Parent = card })
	ui.EndSub = Kit.text({ Name = "Sub", Text = "", Role = "Label", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.31), Size = UDim2.fromScale(0.9, 0.1), ZIndex = 41, Truncate = true, Parent = card })
	ui.EndRewards = Kit.text({ Name = "Rewards", Text = "", Role = "Heading", Scaled = true, Wrapped = true, Color = C.GoldBright, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.43), Size = UDim2.fromScale(0.9, 0.24), ZIndex = 41, Parent = card })
	ui.EndButton = Kit.button({ Name = "Continue", Text = "CONTINUE", Style = "Success", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.94), Size = UDim2.fromScale(0.6, 0.2), Parent = card })
	ui.EndButton.Instance.ZIndex = 42
	ui.EndButton.Activated:Connect(function()
		if session and session.OnContinue then
			session.OnContinue()
		end
	end)
end

local function layout()
	if not ui then
		return
	end
	local R = Responsive
	local phone = R.Device == "Phone"
	local portrait = phone and R.Portrait
	local bottom = portrait and 0.34 or (phone and 0.4 or 0.3)
	ui.Foe.Panel.AnchorPoint = Vector2.new(0, 0)
	ui.Foe.Panel.Position = UDim2.fromScale(0.03, phone and 0.04 or 0.06)
	ui.Foe.Panel.Size = portrait and UDim2.fromScale(0.62, 0.12) or UDim2.fromScale(phone and 0.34 or 0.3, phone and 0.2 or 0.15)
	ui.Me.Panel.AnchorPoint = Vector2.new(1, 1)
	ui.Me.Panel.Position = UDim2.fromScale(0.97, 1 - bottom - 0.02)
	ui.Me.Panel.Size = portrait and UDim2.fromScale(0.62, 0.12) or UDim2.fromScale(phone and 0.34 or 0.3, phone and 0.2 or 0.15)
	ui.Box.AnchorPoint = Vector2.new(0, 1)
	ui.Box.Position = UDim2.fromScale(0.03, 0.97)
	ui.Box.Size = portrait and UDim2.fromScale(0.94, bottom * 0.4) or UDim2.fromScale(phone and 0.46 or 0.5, bottom)
	ui.Menu.AnchorPoint = Vector2.new(1, 1)
	ui.Menu.Position = UDim2.fromScale(0.97, 0.97)
	ui.Menu.Size = portrait and UDim2.fromScale(0.94, bottom * 0.56) or UDim2.fromScale(phone and 0.44 or 0.4, bottom)
	if portrait then
		ui.Box.Position = UDim2.fromScale(0.03, 0.97 - bottom * 0.58)
	end
	ui.Turn.AnchorPoint = Vector2.new(0.5, 0)
	ui.Turn.Position = UDim2.fromScale(0.5, 0.02)
	ui.Turn.Size = UDim2.fromScale(0.2, 0.05)
	ui.Forfeit.Instance.AnchorPoint = Vector2.new(1, 0)
	ui.Forfeit.Instance.Position = UDim2.fromScale(0.97, 0.03)
	ui.Forfeit.Instance.Size = UDim2.fromScale(portrait and 0.26 or 0.13, portrait and 0.04 or 0.06)
	ui.Fade.Size = UDim2.fromScale(1, 1)
	ui.End.Size = portrait and UDim2.fromScale(0.9, 0.42) or UDim2.fromScale(phone and 0.5 or 0.36, phone and 0.7 or 0.42)
end

-- Types a line of text (about 70 characters a second); true when it was shown to the end.
local function type_(mine: any, text: string): boolean
	local n = #text
	local shown = 0
	local t = 0
	while shown < n do
		t += RunService.RenderStepped:Wait()
		if session ~= mine then
			return false
		end
		shown = math.min(n, math.floor(t * 70))
		ui.Text.Text = string.sub(text, 1, shown)
	end
	ui.Text.Text = text
	return true
end

local function setMenu(on: boolean)
	if not ui then
		return
	end
	ui.Menu.Visible = on
	ui.Box.Visible = true
	ui.Turn.Visible = true
end

local function refreshMenu()
	if not ui or not session then
		return
	end
	local me = session.Fighters[1]
	for id, view in ui.Moves do
		local left, enabled
		if id == "Strike" then
			left, enabled = "", true
			view.PP.Text = "ALWAYS READY"
		elseif id == "Special" then
			view.Label.Text = me.SpecialName or "SPECIAL"
			left = me.PP.Special
			view.PP.Text = string.format("%d LEFT", left)
			enabled = left > 0
		else
			left = me.PP[id]
			view.PP.Text = string.format("%d LEFT", left)
			enabled = left > 0
		end
		local color = DuelConfig.Colors[me.Element] or C.Gold
		local stroke = view.Cell:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = (id == "Fire" or id == "Special") and color or C.Gold
			stroke.Transparency = enabled and 0.35 or 0.85
		end
		view.Label.TextTransparency = enabled and 0 or 0.6
		view.PP.TextTransparency = enabled and 0 or 0.6
	end
end

-- ============================================================== playing a turn
local function actorName(side: number, fighter): string
	return side == 1 and string.upper(fighter.Name) or ("FOE " .. string.upper(fighter.Name))
end

local function playEvent(mine: any, e)
	local s = session
	local me, foe = s.Fighters[1], s.Fighters[2]
	local side = e.Side
	local actor = side == 1 and s.Dragons[1] or s.Dragons[2]
	local target = side == 1 and s.Dragons[2] or s.Dragons[1]
	local actorF = side == 1 and me or foe
	local targetF = side == 1 and foe or me
	local element = DuelConfig.Colors[actorF.Element] or Color3.new(1, 1, 1)
	-- what is announced
	local line
	if e.Move == "Guard" then
		line = e.Fail and string.format("%s tried to guard... but it failed!", actorName(side, actorF)) or string.format("%s braces itself!", actorName(side, actorF))
	elseif e.Move == "Roar" then
		line = string.format("%s roars! Its attacks grow stronger.", actorName(side, actorF))
	else
		line = string.format("%s used %s!", actorName(side, actorF), e.Name)
	end
	if not type_(mine, line) then
		return false
	end
	-- the move
	local a = actor and actor.Anim
	local dir = (target and actor) and (target.Root.Position - actor.Root.Position) * Vector3.new(1, 0, 1) or Vector3.zero
	dir = dir.Magnitude > 0 and dir.Unit or Vector3.zero
	if e.Move == "Strike" then
		if a then
			a:Play("Strike")
		end
		-- a lunge at the other dragon and back
		if actor and target then
			local ok = tween(mine, 0.5, function(t)
				local k = t < 0.45 and ease(t / 0.45) or (1 - ease((t - 0.45) / 0.55))
				actor.Offset = Vector3.new(0, 0, 0)
				actor.Root.CFrame = actor.Base + dir * (9 * k)
			end)
			if not ok then
				return false
			end
			place(actor)
		end
	elseif e.Move == "Fire" or e.Move == "Special" then
		if a then
			a:Play("Cast")
		end
		if not sleep(mine, 0.45) then
			return false
		end
		if actor and target and not fireball(mine, actor, target, element, e.Move == "Special" and 3.6 or 2.4) then
			return false
		end
	elseif e.Move == "Roar" then
		if a then
			a:Play("Roar")
		end
		burst(centerOf(actor), Color3.fromRGB(255, 160, 60), 24)
		floatText(centerOf(actor) + Vector3.new(0, 3, 0), "ATTACK UP", Color3.fromRGB(255, 160, 60), true)
		sleep(mine, 0.8)
	elseif e.Move == "Guard" then
		if a then
			a:Play("Roar")
		end
		if not e.Fail then
			s.Shields[side] = shield(actor, Color3.fromRGB(120, 200, 255))
			burst(centerOf(actor), Color3.fromRGB(120, 200, 255), 12)
		end
		sleep(mine, 0.6)
	end
	-- the hit
	if e.Move == "Strike" or e.Move == "Fire" or e.Move == "Special" then
		if e.Hit then
			local hpBefore = side == 1 and e.HP2 + e.Damage or e.HP1 + e.Damage
			local view = side == 1 and ui.Foe or ui.Me
			if target then
				target.Anim:Play("Hurt")
				flash(target, Color3.fromRGB(255, 255, 255))
				burst(centerOf(target), element, e.Crit and 30 or 16)
				floatText(centerOf(target) + Vector3.new(0, 2, 0), "-" .. tostring(e.Damage), e.Crit and Color3.fromRGB(255, 205, 60) or (side == 2 and Color3.fromRGB(255, 90, 80) or Color3.new(1, 1, 1)), e.Crit)
				s.Shake = e.Crit and 1 or 0.55
				local recoil = dir * 2.6
				tween(mine, 0.16, function(t)
					target.Root.CFrame = target.Base + recoil * math.sin(t * math.pi)
				end)
				place(target)
			end
			sound("Hit")
			slideHp(mine, view, targetF, hpBefore, side == 1 and e.HP2 or e.HP1)
			if e.Guarded and s.Shields[3 - side] then
				burst(centerOf(target), Color3.fromRGB(120, 200, 255), 10)
			end
			-- the comments, one at a time
			if e.Crit then
				type_(mine, "A critical hit!")
				sleep(mine, 0.5)
			end
			if e.Eff and e.Eff > 1 then
				type_(mine, "It's super effective!")
				sleep(mine, 0.5)
			elseif e.Eff and e.Eff < 1 then
				type_(mine, "It's not very effective...")
				sleep(mine, 0.5)
			end
			if e.Guarded then
				type_(mine, string.format("%s guarded!", actorName(3 - side, targetF)))
				sleep(mine, 0.5)
			end
		else
			type_(mine, string.format("%s's attack missed!", actorName(side, actorF)))
			sleep(mine, 0.6)
		end
	end
	if session ~= mine then
		return false
	end
	return true
end

local function faint(mine: any, side: number)
	local s = session
	local dragon = s.Dragons[side]
	local fighter = s.Fighters[side]
	if not dragon then
		return
	end
	dragon.Anim:Play("Hurt")
	type_(mine, string.format("%s fainted!", actorName(side == 1 and 1 or 2, fighter)))
	sound("Knockout")
	tween(mine, 1.1, function(t)
		setReveal(dragon, 1 - ease(t))
		dragon.Root.CFrame = dragon.Base * CFrame.new(0, -2.6 * ease(t), 0)
	end)
	burst(centerOf(dragon), Color3.fromRGB(255, 255, 255), 24)
end

local function showEnd(mine: any, info)
	local s = session
	if not ui or session ~= mine then
		return
	end
	setMenu(false)
	ui.Forfeit.Instance.Visible = false
	ui.Foe.Panel.Visible = false
	ui.Me.Panel.Visible = false
	ui.Box.Visible = false
	ui.Turn.Visible = false
	local won = info.Winner == info.Side
	ui.EndTitle.Text = won and "VICTORY!" or (info.Winner == nil and "DUEL OVER" or "DEFEAT")
	ui.EndTitle.TextColor3 = won and Color3.fromRGB(255, 214, 90) or Color3.fromRGB(235, 100, 90)
	ui.EndSub.Text = info.Forfeit and (won and "Your opponent gave up." or "You gave up.") or string.format("%s vs %s", s.Fighters[1].Owner or "You", s.Fighters[2].Owner or "Foe")
	local r = info.Reward
	if r then
		local parts = {}
		if (r.Cash or 0) > 0 then
			table.insert(parts, Format.cash(r.Cash))
		end
		if (r.XP or 0) > 0 then
			table.insert(parts, string.format("%d XP", r.XP))
		end
		local text = table.concat(parts, "   +   ")
		if r.Rematch and won then
			text ..= "\n(a rematch pays less)"
		end
		ui.EndRewards.Text = text ~= "" and text or "No reward this time."
	else
		ui.EndRewards.Text = ""
	end
	ui.End.Visible = true
	sound(won and "LevelUp" or "Click")
	if won and s.Dragons[1] then
		s.Dragons[1].Anim:Play("Cheer")
	end
end

-- ============================================================== the session
local function cleanup(mine: any)
	if session ~= mine then
		return
	end
	session = nil
	pcall(function()
		RunService:UnbindFromRenderStep("RAD_Duel")
	end)
	if mine.Conn then
		mine.Conn:Disconnect()
	end
	if ui then
		ui.Foe.Panel.Visible = false
		ui.Me.Panel.Visible = false
		ui.Box.Visible = false
		ui.Menu.Visible = false
		ui.Turn.Visible = false
		ui.Forfeit.Instance.Visible = false
		ui.Fade.Visible = false
		ui.Banner.Visible = false
		ui.End.Visible = false
	end
	for _, shield_ in mine.Shields do
		shield_:Destroy()
	end
	if mine.Stage then
		mine.Stage:Destroy()
	end
	if mine.ShowCompanion then
		mine.ShowCompanion()
	end
	local camera = Workspace.CurrentCamera
	if camera then
		camera.FieldOfView = mine.Fov0 or 70
	end
	local cam = registry and registry.CameraController
	if cam and cam.endCinematic then
		cam.endCinematic()
	end
	local uic = registry and registry.UIController
	if uic then
		uic.SetHudVisible(true)
	end
	PromptGate.set("Duel", false)
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and mine.Walk then
		humanoid.WalkSpeed = mine.Walk
		humanoid.JumpPower = mine.Jump
	end
end

local function hideCompanion(): () -> ()
	local dragons = Workspace:FindFirstChild("Dragons")
	local mineModel = dragons and dragons:FindFirstChild("Dragon_" .. LocalPlayer.UserId)
	if not mineModel then
		return function() end
	end
	local saved = {}
	for _, d in mineModel:GetDescendants() do
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

-- The camera: a fixed three-quarter shot over your dragon's shoulder, with a slow sway and shake.
local CAMERA_HOME = Vector3.new(2, 12, 40)
local CAMERA_FOCUS = Vector3.new(0.5, 5, -3)
local CAMERA_FOV = 40

local function cameraFrame(s): (CFrame, number)
	local t = s.Clock
	local sway = Vector3.new(math.sin(t * 0.35) * 0.9, math.sin(t * 0.27) * 0.4, math.cos(t * 0.31) * 0.6)
	local shake = Vector3.new((math.random() - 0.5), (math.random() - 0.5), (math.random() - 0.5)) * s.Shake * 1.6
	local home = CAMERA_HOME
	local focus = CAMERA_FOCUS
	local intro = s.Intro or 1 -- 0 = high and far, 1 = in place
	local e = ease(intro)
	local from = Vector3.new(-48, 46, 62)
	local pos = from:Lerp(home, e) + sway + shake
	local look = Vector3.new(0, 6, 0):Lerp(focus, e)
	return CFrame.lookAt(STAGE + pos, STAGE + look), CAMERA_FOV + (1 - e) * 12
end

function DuelController.cameraFrame()
	if session then
		return cameraFrame(session)
	end
	return nil, nil
end

local function begin(view)
	if session then
		return
	end
	local mine = {
		Id = view.Id,
		Side = view.Side,
		Kind = view.Kind,
		Fighters = view.Fighters,
		Dragons = {},
		Shields = {},
		Phase = "Intro",
		Turn = view.Turn or 1,
		Clock = 0,
		Shake = 0,
		Intro = 0,
		Queue = {},
		Choice = nil,
		Ended = nil,
		Log = {},
	}
	session = mine
	DuelController.Phase = "Intro"
	local uic = registry.UIController
	local cam = registry.CameraController
	if not ui then
		buildHud(makeLayer())
		layout()
		Responsive.Changed:Connect(layout)
	end
	layout()
	-- take the screen: no HUD, no world prompts, no companion, the character stays where it is
	uic.SetHudVisible(false)
	if uic.Close and uic.IsOpen and uic.IsOpen() then
		uic.Close()
	end
	PromptGate.set("Duel", true)
	mine.ShowCompanion = hideCompanion()
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		mine.Walk, mine.Jump = humanoid.WalkSpeed, humanoid.JumpPower
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end
	if cam and cam.beginCinematic then
		cam.beginCinematic()
	end
	local camera = Workspace.CurrentCamera
	mine.Fov0 = camera and camera.FieldOfView or 70
	mine.Stage = buildStage(mine)
	DuelController.Stage = mine.Stage
	local me, foe = view.Fighters[1], view.Fighters[2]
	mine.Dragons[1] = spawnDragon(me, MY_SPOT, FOE_SPOT)
	mine.Dragons[2] = spawnDragon(foe, FOE_SPOT, MY_SPOT)
	for _, d in mine.Dragons do
		setReveal(d, 0)
	end
	DuelController.Dragons = mine.Dragons
	setPlate(ui.Foe, foe)
	setPlate(ui.Me, me)

	RunService:BindToRenderStep("RAD_Duel", Enum.RenderPriority.Camera.Value + 3, function(dt)
		if session ~= mine then
			return
		end
		mine.Clock += dt
		mine.Shake = math.max(0, mine.Shake - dt * 2.4)
		local cf, fov = cameraFrame(mine)
		local c = Workspace.CurrentCamera
		if c then
			c.CFrame = cf
			c.FieldOfView = fov
		end
		for _, d in mine.Dragons do
			if d.Anim then
				d.Anim:SetParams({ Mode = "Ground", Speed = 0, Look = Vector2.zero })
				d.Anim:Update(dt)
				d.Anim:Apply(true)
			end
		end
	end)
	mine.Conn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or session ~= mine or mine.Phase ~= "Menu" then
			return
		end
		local idx = ({ [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4 })[input.KeyCode]
		if idx then
			DuelController.choose(MOVE_KEYS[idx])
		end
	end)

	local function finishAndLeave()
		local gate = mine
		-- fade out, leave
		ui.Fade.BackgroundTransparency = 1
		ui.Fade.Visible = true
		tween(mine, 0.45, function(a)
			ui.Fade.BackgroundTransparency = 1 - a
		end)
		if session ~= gate then
			return
		end
		cleanup(mine)
	end
	mine.OnContinue = function()
		task.spawn(finishAndLeave)
	end

	task.spawn(function()
		-- INTRO: from black, the camera swoops in, the VS banner, both dragons appear
		ui.Fade.BackgroundTransparency = 0
		ui.Fade.Visible = true
		ui.Banner.Visible = false
		ui.Box.Visible = true
		ui.Text.Text = ""
		tween(mine, 0.5, function(a)
			ui.Fade.BackgroundTransparency = a
		end)
		ui.Fade.Visible = false
		sound("DuelStart")
		tween(mine, 1.7, function(a)
			mine.Intro = a
		end)
		ui.BannerLeft.Text = string.upper(me.Owner or "YOU")
		ui.BannerRight.Text = string.upper(foe.Owner or "FOE")
		ui.Banner.Visible = true
		ui.BannerLeft.Position = UDim2.fromScale(-0.5, 0)
		ui.BannerRight.Position = UDim2.fromScale(1, 0)
		tween(mine, 0.45, function(a)
			local e = ease(a)
			ui.BannerLeft.Position = UDim2.fromScale(-0.5 + 0.52 * e, 0)
			ui.BannerRight.Position = UDim2.fromScale(1 - 0.44 * e, 0)
		end)
		sleep(mine, 0.9)
		ui.Banner.Visible = false
		if session ~= mine then
			return
		end
		ui.Foe.Panel.Visible = true
		ui.Box.Visible = true
		-- the opponent first
		tween(mine, 0.6, function(a)
			setReveal(mine.Dragons[2], a)
		end)
		if mine.Dragons[2] then
			mine.Dragons[2].Anim:Play("Roar")
		end
		type_(mine, string.format("%s wants to duel!", foe.Owner or "Foe"))
		sleep(mine, 0.7)
		type_(mine, string.format("%s sends out %s!", foe.Owner or "Foe", string.upper(foe.Name)))
		sleep(mine, 0.5)
		ui.Me.Panel.Visible = true
		tween(mine, 0.6, function(a)
			setReveal(mine.Dragons[1], a)
		end)
		if mine.Dragons[1] then
			mine.Dragons[1].Anim:Play("Roar")
		end
		type_(mine, string.format("Go! %s!", string.upper(me.Name)))
		sleep(mine, 0.6)
		-- THE TURNS
		while session == mine and not mine.Ended do
			mine.Phase = "Menu"
			DuelController.Phase = "Menu"
			mine.Choice = nil
			refreshMenu()
			ui.Turn.Text = "TURN " .. tostring(mine.Turn)
			ui.Forfeit.Instance.Visible = true
			setMenu(true)
			type_(mine, string.format("What will %s do?", string.upper(me.Name)))
			-- waiting for the choice and the server's answer (the turn arrives as a signal)
			while session == mine and #mine.Queue == 0 and not mine.Ended do
				RunService.RenderStepped:Wait()
			end
			if session ~= mine then
				return
			end
			mine.Phase = "Play"
			DuelController.Phase = "Play"
			ui.Menu.Visible = false
			ui.Forfeit.Instance.Visible = false
			local turn = table.remove(mine.Queue, 1)
			if turn then
				for _, e in turn.Events do
					if not playEvent(mine, e) then
						return
					end
					sleep(mine, 0.25)
				end
				-- the state after the turn
				for i = 1, 2 do
					mine.Fighters[i] = turn.State.Fighters[i]
				end
				setPlate(ui.Me, mine.Fighters[1])
				setPlate(ui.Foe, mine.Fighters[2])
				for side, sh in mine.Shields do
					sh:Destroy()
					mine.Shields[side] = nil
				end
				mine.Turn = turn.Turn
				-- a knockout?
				if mine.Fighters[1].HP <= 0 then
					faint(mine, 1)
				elseif mine.Fighters[2].HP <= 0 then
					faint(mine, 2)
					if mine.Dragons[1] then
						mine.Dragons[1].Anim:Play("Roar")
					end
				end
				if mine.Fighters[1].HP <= 0 or mine.Fighters[2].HP <= 0 then
					-- the end arrives with the signal DuelEnd (a moment later)
					local waited = 0
					while session == mine and not mine.Ended and waited < 5 do
						waited += RunService.RenderStepped:Wait()
					end
				end
			end
		end
		if session ~= mine then
			return
		end
		mine.Phase = "End"
		DuelController.Phase = "End"
		showEnd(mine, mine.Ended)
	end)
end

-- ============================================================== public
function DuelController.active(): boolean
	return session ~= nil
end

function DuelController.State()
	local s = session
	if not s then
		return { Active = false, Phase = DuelController.Phase or "" }
	end
	return {
		Active = true,
		Phase = s.Phase,
		Turn = s.Turn,
		Id = s.Id,
		Hp1 = s.Fighters[1].HP,
		Hp2 = s.Fighters[2].HP,
		MaxHp1 = s.Fighters[1].MaxHP,
		MaxHp2 = s.Fighters[2].MaxHP,
		Ended = s.Ended ~= nil,
	}
end

function DuelController.choose(move: string)
	local s = session
	if not s or s.Phase ~= "Menu" or s.Choice then
		return false
	end
	local me = s.Fighters[1]
	if (move == "Fire" or move == "Guard") and me.PP[move] <= 0 then
		return false
	end
	if move == "Special" and me.PP.Special <= 0 then
		return false
	end
	s.Choice = move
	sound("Click")
	task.spawn(function()
		local res = Net.request("Duel", "Move", { Id = s.Id, Move = move })
		if not res.ok and session == s then
			-- (the move was refused: choose again)
			s.Choice = nil
			if ui then
				ui.Text.Text = res.msg or "That did not work."
			end
		end
	end)
	return true
end

-- Presses CONTINUE on the end card (tools and tests).
function DuelController.dismiss()
	if session and session.OnContinue and session.Ended then
		session.OnContinue()
		return true
	end
	return false
end

function DuelController.forfeit()
	local s = session
	if not s or s.Ended then
		return
	end
	task.spawn(function()
		Net.request("Duel", "Forfeit", { Id = s.Id })
	end)
end

-- Starts a duel against a trainer (called by the Battle window); returns ok, message.
function DuelController.startTrainer(trainerId: string): (boolean, string?)
	if session then
		return false, "You are already in a duel."
	end
	local res = Net.request("Duel", "Start", { Trainer = trainerId })
	if not res.ok then
		return false, res.msg or res.err
	end
	begin(res.data)
	return true
end

function DuelController.challenge(userId: number): (boolean, string?)
	local res = Net.request("Duel", "Challenge", { UserId = userId })
	if not res.ok then
		return false, res.msg or res.err
	end
	return true
end

function DuelController.respond(fromUserId: number, accept: boolean)
	local res = Net.request("Duel", "Respond", { From = fromUserId, Accept = accept })
	if res.ok and accept and res.data and res.data.Id then
		begin(res.data)
	elseif not res.ok then
		local uic = registry and registry.UIController
		if uic then
			uic.Notify("warning", res.msg or "That challenge is over.")
		end
	end
end

-- ============================================================== incoming challenge
local function hideChallenge()
	if challengeUI then
		challengeUI.Panel.Visible = false
		challengeUI.From = nil
	end
end

local function showChallenge(payload)
	local uic = registry and registry.UIController
	if not uic then
		return
	end
	if not challengeUI then
		local layer = uic.Layers.GameModal and uic.Layers.GameModal.Root or uic.Layers.GameUI.Root
		local p = Kit.surface({ Name = "DuelChallenge", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.04), Size = UDim2.fromScale(0.34, 0.14), Color = C.Panel, Transparency = 0.04, StrokeColor = Color3.fromRGB(255, 110, 90), StrokeTransparency = 0.1, Radius = "Window", Parent = layer })
		local text = Kit.text({ Name = "Text", Text = "", Role = "Heading", Scaled = true, Wrapped = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.06), Size = UDim2.fromScale(0.9, 0.46), Parent = p })
		local accept = Kit.button({ Name = "Accept", Text = "ACCEPT", Style = "Success", Position = UDim2.fromScale(0.06, 0.58), Size = UDim2.fromScale(0.42, 0.34), Parent = p })
		local decline = Kit.button({ Name = "Decline", Text = "DECLINE", Style = "Danger", Position = UDim2.fromScale(0.52, 0.58), Size = UDim2.fromScale(0.42, 0.34), Parent = p })
		challengeUI = { Panel = p, Text = text }
		accept.Activated:Connect(function()
			local from = challengeUI.From
			hideChallenge()
			if from then
				task.spawn(DuelController.respond, from, true)
			end
		end)
		decline.Activated:Connect(function()
			local from = challengeUI.From
			hideChallenge()
			if from then
				task.spawn(DuelController.respond, from, false)
			end
		end)
		Responsive.bind(p, "Size", function(R)
			if R.Device == "Phone" then
				return UDim2.fromScale(R.Portrait and 0.92 or 0.5, R.Portrait and 0.16 or 0.3)
			end
			return UDim2.fromScale(0.34, 0.14)
		end)
	end
	challengeUI.From = payload.From
	challengeUI.Text.Text = string.format("%s challenges you to a DUEL!", string.upper(payload.Name or "A player"))
	challengeUI.Panel.Visible = true
	sound("DuelStart")
end

-- ============================================================== UI Lab
-- A look at the HUD with sample data (no stage, no camera).
function DuelController.preview(kind: string)
	if not ui then
		buildHud(makeLayer())
		layout()
		Responsive.Changed:Connect(layout)
	end
	layout()
	local sampleMe = { Name = "Frost Dragon", Owner = "You", Species = "FrostDragon", Mutation = "Frost", Level = 18, Rarity = "Epic", Element = "Ice", MaxHP = 1010, HP = 730, Special = "Burst", SpecialName = "FROST BURST", PP = { Fire = 6, Guard = 4, Special = 2 }, Buff = 1.3 }
	local sampleFoe = { Name = "Magma Brute", Owner = "Ranger Kai", Species = "MagmaBrute", Mutation = "None", Level = 20, Rarity = "Rare", Element = "Fire", MaxHP = 920, HP = 400, Special = "Roar", SpecialName = "ROAR", PP = { Fire = 8, Guard = 6, Special = 4 }, Buff = 1 }
	DuelController.PreviewSession = { Fighters = { sampleMe, sampleFoe } }
	setPlate(ui.Foe, sampleFoe)
	setPlate(ui.Me, sampleMe)
	ui.Foe.Panel.Visible = true
	ui.Me.Panel.Visible = true
	ui.Box.Visible = true
	ui.Text.Text = "What will FROST DRAGON do?"
	ui.Turn.Text = "TURN 3"
	ui.Turn.Visible = true
	if kind == "End" then
		ui.Menu.Visible = false
		ui.Foe.Panel.Visible = false
		ui.Me.Panel.Visible = false
		ui.Box.Visible = false
		ui.Turn.Visible = false
		ui.EndTitle.Text = "VICTORY!"
		ui.EndTitle.TextColor3 = Color3.fromRGB(255, 214, 90)
		ui.EndSub.Text = "You vs Ranger Kai"
		ui.EndRewards.Text = "$12.4K   +   70 XP"
		ui.End.Visible = true
	else
		-- the menu uses the sample fighter's moves
		local saved = session
		session = { Fighters = { sampleMe, sampleFoe }, Phase = "Preview" }
		refreshMenu()
		session = saved
		ui.Menu.Visible = true
		ui.Forfeit.Instance.Visible = true
		ui.End.Visible = false
	end
end

function DuelController.clear()
	if not ui or session then
		return
	end
	ui.Foe.Panel.Visible = false
	ui.Me.Panel.Visible = false
	ui.Box.Visible = false
	ui.Menu.Visible = false
	ui.Turn.Visible = false
	ui.Forfeit.Instance.Visible = false
	ui.End.Visible = false
end

function DuelController.Init(reg)
	registry = reg
end

function DuelController.Start()
	Net.onSignal("DuelStart", function(view)
		-- (the challenged player accepted: the challenger's scene starts)
		hideChallenge()
		begin(view)
	end)
	Net.onSignal("DuelTurn", function(payload)
		local s = session
		if s and s.Id == payload.Id then
			table.insert(s.Queue, payload)
		end
	end)
	Net.onSignal("DuelEnd", function(payload)
		local s = session
		if s and s.Id == payload.Id then
			s.Ended = payload
		end
	end)
	Net.onSignal("DuelChallenge", function(payload)
		if not session then
			showChallenge(payload)
		end
	end)
	Net.onSignal("DuelChallengeEnd", function(payload)
		hideChallenge()
		local uic = registry and registry.UIController
		if uic and payload.Reason ~= "Left" then
			local text = payload.Reason == "Declined" and (payload.Name or "The player") .. " declined the duel." or "The challenge ran out."
			if payload.Reason == "Declined" or payload.Reason == "Expired" then
				uic.Notify("info", text)
			end
		end
	end)
end

return DuelController

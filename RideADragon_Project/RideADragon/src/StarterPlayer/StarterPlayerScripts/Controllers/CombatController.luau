--[[
	CombatController
	The client side of the arena duels on the Race Island (CombatService decides every hit):

	  input   STRIKE: F / left click / gamepad X      BLAST: G / gamepad R3      (touch: the two buttons)
	          bound only while you are a fighter (inside the arena, riding, on your feet)
	  HUD     your hit points + the two cooldowns, a crosshair, the KNOCKED OUT screen, a kill feed
	  others  a name + hit point bar over every fighter's dragon, damage numbers, a flash when hit
	  FX      strike shockwave, fireball (flown here from the server's origin and direction), sparks

	Net signals (CombatService): CombatEnter, CombatLeave, CombatDown, CombatRespawn, CombatReward,
	CombatFx, CombatHit, CombatKO, CombatBlastEnd
	Net events to the server: CombatStrike {}, CombatBlast { Dir }
]]

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local BreathFX = require(Shared:WaitForChild("Dragons"):WaitForChild("BreathFX"))
local CombatConfig = require(Configs:WaitForChild("CombatConfig"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Create = require(UI:WaitForChild("Create"))
local Kit = require(UI:WaitForChild("Kit"))

local C = Theme.Colors
local H = Theme.Hud
local LocalPlayer = Players.LocalPlayer

local CombatController = {}

local BIND_NAME = "RAD_CombatFx"
local TEX = {
	Fire = "rbxasset://textures/particles/fire_main.dds",
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
}
local HP_GOOD = Color3.fromRGB(110, 210, 110)
local HP_LOW = Color3.fromRGB(235, 70, 60)

local registry
local layer: Frame? = nil
local ui: { [string]: any } = {}
local bars: { [Player]: BillboardGui } = {}
local blastFx: { [number]: any } = {}
local fxFolder: Folder? = nil
local keysBound = false
local strikeReadyAt, blastReadyAt = 0, 0
local protectedUntil = 0
local downUntil = 0
local barTimer = 0
local feedLines: { TextLabel } = {}
local dummyCache: Model? = nil
local dummyBar: BillboardGui? = nil

-- ============================================================== helpers
local function clock(): number
	return Workspace:GetServerTimeNow()
end

local function short(): number
	return math.min(Responsive.Width, Responsive.Height)
end

local function dragonController()
	return registry and registry.DragonController
end

local function localModel(): Model?
	local dc = dragonController()
	return dc and dc.getModel()
end

local function modelOf(userId: number): Model?
	local folder = Workspace:FindFirstChild("Dragons")
	local m = folder and folder:FindFirstChild("Dragon_" .. userId)
	return m and m:IsA("Model") and m or nil
end

local function rootOf(model: Model?): BasePart?
	local r = model and model:FindFirstChild("Root")
	return r and r:IsA("BasePart") and r or nil
end

local function isFighter(): boolean
	local dc = dragonController()
	return LocalPlayer:GetAttribute("InArena") == true and not LocalPlayer:GetAttribute("Downed") and dc ~= nil and dc.isRiding()
end

local function folder(): Folder
	if fxFolder and fxFolder.Parent then
		return fxFolder
	end
	local f = Instance.new("Folder")
	f.Name = "CombatFx"
	f.Parent = Workspace
	fxFolder = f
	return f
end

local function hudPanel(name: string, parent: Instance): Frame
	local f = Create("Frame", {
		Name = name,
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
	})
	Kit.corner(f, 16)
	Kit.stroke(f, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), H.Shade), Parent = f })
	f.Parent = parent
	return f :: Frame
end

local function theme(userId: number)
	local m = modelOf(userId)
	local mutation = m and m:GetAttribute("Mutation") or "None"
	return BreathFX.Themes[mutation] or BreathFX.Themes.None
end

local function part(size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	if shape then
		p.Shape = shape
	end
	p.Parent = folder()
	return p
end

local function burst(position: Vector3, color1: Color3, color2: Color3, count: number, speed: number)
	local anchor = part(Vector3.one * 0.3, color1)
	anchor.Transparency = 1
	anchor.Position = position
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX.Sparkle
	e.Color = ColorSequence.new(color1, color2)
	e.LightEmission = 1
	e.Lifetime = NumberRange.new(0.35, 0.7)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.2), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	e.Rate = 0
	e.Parent = anchor
	e:Emit(count)
	Debris:AddItem(anchor, 1.2)
end

-- ============================================================== floating numbers
local function floatText(position: Vector3, text: string, color: Color3, big: boolean)
	local anchor = part(Vector3.one * 0.2, color)
	anchor.Transparency = 1
	anchor.Position = position
	local gui = Instance.new("BillboardGui")
	gui.Name = "Damage"
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(big and 170 or 120, big and 56 or 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(30, 14, 14)
	stroke.Parent = label
	TweenService:Create(gui, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffsetWorldSpace = Vector3.new(0, 10, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1 }):Play()
	TweenService:Create(stroke, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
	Debris:AddItem(anchor, 1.1)
end

local function flash(model: Model?, color: Color3)
	if not model then
		return
	end
	local h = Instance.new("Highlight")
	h.FillColor = color
	h.FillTransparency = 0.35
	h.OutlineTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = model
	h.Parent = model
	TweenService:Create(h, TweenInfo.new(0.22), { FillTransparency = 1 }):Play()
	Debris:AddItem(h, 0.3)
end

-- ============================================================== strike / blast visuals
local function strikeFx(position: Vector3, direction: Vector3, userId: number)
	local th = theme(userId)
	local center = position + direction * (CombatConfig.Strike.Reach * 0.55)
	local ring = part(Vector3.new(0.5, 12, 12), th.Mid, Enum.PartType.Cylinder)
	-- a Cylinder's axis is its X axis: point it along the strike
	ring.CFrame = CFrame.lookAt(center, center + direction) * CFrame.Angles(0, math.rad(90), 0)
	ring.Transparency = 0.25
	TweenService:Create(ring, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.3, 34, 34), Transparency = 1 }):Play()
	Debris:AddItem(ring, 0.4)
	burst(center, th.Core, th.Spark2, 10, 40)
end

local function newBlast(data)
	local th = theme(data.From)
	local ball = part(Vector3.one * 5.5, th.Core, Enum.PartType.Ball)
	ball.Position = data.Pos
	local halo = part(Vector3.one * 9, th.Mid, Enum.PartType.Ball)
	halo.Transparency = 0.7
	halo.Position = data.Pos
	local light = Instance.new("PointLight")
	light.Color = th.Light
	light.Range = 26
	light.Brightness = 3
	light.Parent = ball
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX.Fire
	e.Color = ColorSequence.new(th.Core, th.Edge)
	e.LightEmission = 1
	e.Lifetime = NumberRange.new(0.25, 0.5)
	e.Speed = NumberRange.new(2, 8)
	e.SpreadAngle = Vector2.new(30, 30)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Rate = 70
	e.Parent = ball
	blastFx[data.Id] = {
		Ball = ball,
		Halo = halo,
		Pos = data.Pos,
		Dir = data.Dir,
		Speed = data.Speed or CombatConfig.Blast.Speed,
		Born = clock(),
		Life = data.Life or CombatConfig.Blast.Lifetime,
		Theme = th,
	}
end

local function endBlast(id: number, position: Vector3?, hit: boolean)
	local b = blastFx[id]
	if not b then
		return
	end
	blastFx[id] = nil
	local at = position or b.Ball.Position
	b.Ball:Destroy()
	b.Halo:Destroy()
	local th = b.Theme
	local boom = part(Vector3.one * 6, th.Core, Enum.PartType.Ball)
	boom.Position = at
	boom.Transparency = 0.15
	TweenService:Create(boom, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * (hit and 24 or 12), Transparency = 1 }):Play()
	Debris:AddItem(boom, 0.45)
	burst(at, th.Core, th.Edge, hit and 26 or 10, hit and 60 or 30)
end

local function stepFx()
	local t = clock()
	for id, b in blastFx do
		local age = t - b.Born
		if age >= b.Life + 0.3 then
			endBlast(id, nil, false)
		else
			local position = b.Pos + b.Dir * (b.Speed * math.min(age, b.Life))
			b.Ball.Position = position
			b.Halo.Position = position
			b.Halo.Size = Vector3.one * (9 + math.sin(t * 22) * 1.2)
		end
	end
end

-- ============================================================== HUD
local function makeLayer(): Frame
	local gui = Create("ScreenGui", {
		Name = "GameCombat",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Theme.Layers.Hud + 2,
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

local function buildHud(parent: Instance)
	-- your hit points
	local panel = hudPanel("ArenaHud", parent)
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(0.5, 0)
	ui.Hud = panel
	Kit.text({ Name = "Caption", Text = "DUEL ARENA", Role = "Micro", Scaled = true, Color = C.AccentDeep, Position = UDim2.fromScale(0.04, 0.06), Size = UDim2.fromScale(0.4, 0.22), Parent = panel })
	ui.HpText = Kit.text({ Name = "Hp", Text = "", Role = "Heading", Scaled = true, Font = Theme.Fonts.Number, Color = H.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.44, 0.04), Size = UDim2.fromScale(0.52, 0.3), Parent = panel })
	ui.HpBar = Kit.progress({ Name = "HpBar", Color = HP_GOOD, Color2 = HP_GOOD, Track = H.Track, Position = UDim2.fromScale(0.04, 0.42), Size = UDim2.fromScale(0.92, 0.26), Parent = panel })
	ui.Protected = Kit.text({ Name = "Protected", Text = "", Role = "Caption", Scaled = true, Color = Color3.fromRGB(46, 150, 70), XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.72), Size = UDim2.fromScale(0.92, 0.22), Parent = panel })

	-- key hints with cooldown fills (touch players have the button fills instead)
	local keys = hudPanel("ArenaKeys", parent)
	keys.Visible = false
	keys.AnchorPoint = Vector2.new(0.5, 1)
	ui.Keys = keys
	for i, def in { { Id = "Strike", Key = "F", Text = "STRIKE" }, { Id = "Blast", Key = "G", Text = "BLAST" } } do
		local cell = Kit.frame({ Name = def.Id, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), Parent = keys })
		Kit.text({ Name = "Label", Text = string.format("[%s]  %s", def.Key, def.Text), Role = "Label", Scaled = true, Color = H.Text, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.14), Size = UDim2.fromScale(0.9, 0.42), Parent = cell })
		ui[def.Id .. "Bar"] = Kit.progress({ Name = "Cool", Color = C.Accent, Color2 = C.GoldBright, Track = H.Track, Position = UDim2.fromScale(0.1, 0.66), Size = UDim2.fromScale(0.8, 0.14), Parent = cell })
		ui[def.Id .. "Bar"]:SetValue(1)
	end

	-- crosshair
	local cross = Kit.frame({ Name = "Crosshair", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromOffset(26, 26), Visible = false, Parent = parent })
	local ring = Kit.frame({ BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = cross })
	Kit.corner(ring, 999)
	local ringStroke = Kit.stroke(ring, Color3.fromRGB(255, 255, 255), 2, 0.25)
	ringStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	local dot = Kit.frame({ BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(255, 220, 90), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4), Parent = cross })
	Kit.corner(dot, 999)
	ui.Cross = cross

	-- knocked out
	local down = Kit.frame({ Name = "Down", BackgroundColor3 = Color3.fromRGB(70, 6, 10), BackgroundTransparency = 0.5, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 8, Parent = parent })
	ui.Down = down
	ui.DownTitle = Kit.text({ Name = "Title", Text = "KNOCKED OUT", Role = "Display", Scaled = true, Font = Enum.Font.GothamBlack, Color = Color3.fromRGB(255, 96, 84), XAlign = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromScale(0.7, 0.16), ZIndex = 9, Parent = down })
	local titleStroke = Instance.new("UIStroke")
	titleStroke.Thickness = 4
	titleStroke.Color = Color3.fromRGB(26, 10, 14)
	titleStroke.Parent = ui.DownTitle
	ui.DownSub = Kit.text({ Name = "Sub", Text = "", Role = "Heading", Scaled = true, Color = Color3.fromRGB(255, 255, 255), XAlign = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.53), Size = UDim2.fromScale(0.6, 0.07), ZIndex = 9, Parent = down })

	-- red flash when you are hit
	local hurt = Kit.frame({ Name = "Hurt", BackgroundColor3 = Color3.fromRGB(200, 20, 20), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = parent })
	ui.Hurt = hurt

	-- kill feed
	local feed = Kit.frame({ Name = "Feed", Size = UDim2.fromOffset(300, 200), Parent = parent })
	Kit.list(feed, "V", 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	ui.Feed = feed
end

function CombatController.layout()
	if not layer then
		return
	end
	local R = Responsive
	local S = short()
	local phone = R.Device == "Phone"
	local top
	if phone then
		top = R.Portrait and (R.TopInset + math.floor(S * 0.3)) or math.floor(S * 0.19)
	else
		top = R.TopInset + math.floor(S * 0.13)
	end
	local w = phone and (R.Portrait and R.Width * 0.7 or S * 0.62) or S * 0.42
	local h = phone and (R.Portrait and w * 0.3 or S * 0.17) or S * 0.1
	ui.Hud.Position = UDim2.new(0.5, 0, 0, top)
	ui.Hud.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
	local margin = math.floor(S * 0.022)
	ui.Keys.Position = UDim2.new(0.5, 0, 1, -(margin + math.floor(S * 0.082) + math.floor(S * 0.03)))
	ui.Keys.Size = UDim2.fromOffset(math.floor(S * 0.5), math.floor(S * 0.07))
	ui.Feed.Position = UDim2.new(0, margin, 0, top + math.floor(S * (phone and 0.12 or 0.02)))
end

local function refreshHud()
	if not layer then
		return
	end
	local fighter = LocalPlayer:GetAttribute("InArena") == true
	local maxHP = tonumber(LocalPlayer:GetAttribute("MaxHP")) or 1
	local hp = tonumber(LocalPlayer:GetAttribute("HP")) or 0
	ui.Hud.Visible = fighter
	ui.Keys.Visible = fighter and not Responsive.isMobile()
	ui.Cross.Visible = isFighter()
	if fighter then
		local ratio = math.clamp(hp / math.max(1, maxHP), 0, 1)
		ui.HpBar:SetValue(ratio, true)
		local color = HP_LOW:Lerp(HP_GOOD, ratio)
		ui.HpBar:SetColors(color, color)
		ui.HpText.Text = string.format("%s / %s", Format.commas(hp), Format.commas(maxHP))
	end
end

local function updateCooldowns()
	local t = clock()
	local strike = math.clamp((strikeReadyAt - t) / CombatConfig.Strike.Cooldown, 0, 1)
	local blast = math.clamp((blastReadyAt - t) / CombatConfig.Blast.Cooldown, 0, 1)
	if ui.StrikeBar then
		ui.StrikeBar:SetValue(1 - strike)
		ui.BlastBar:SetValue(1 - blast)
	end
	if registry.Hud and registry.Hud.SetArenaCooldowns then
		registry.Hud:SetArenaCooldowns(strike, blast)
	end
	if ui.Protected then
		local left = protectedUntil - t
		ui.Protected.Text = left > 0 and string.format("PROTECTED  %.1fs", left) or ""
	end
	if ui.Down and ui.Down.Visible then
		local left = math.max(0, downUntil - t)
		ui.DownSub.Text = string.format("Back in %.1f s", left)
	end
end

local function feedLine(text: string, color: Color3)
	local line = Kit.text({ Name = "Line", Text = text, Role = "Label", Color = color, Size = UDim2.fromOffset(300, 22), Parent = ui.Feed })
	line.TextStrokeTransparency = 0.4
	line.TextStrokeColor3 = Color3.fromRGB(20, 20, 30)
	table.insert(feedLines, line)
	while #feedLines > 5 do
		local old = table.remove(feedLines, 1)
		if old then
			old:Destroy()
		end
	end
	task.delay(6, function()
		local i = table.find(feedLines, line)
		if i then
			table.remove(feedLines, i)
		end
		line:Destroy()
	end)
end

-- ============================================================== other fighters' bars
local function buildBar(adornee: BasePart, title: string, offsetY: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "ArenaBar"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(170, 44)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 520
	gui.LightInfluence = 0
	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, 0.46)
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.Text = title
	name.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(20, 20, 30)
	stroke.Parent = name
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	track.BackgroundTransparency = 0.2
	track.BorderSizePixel = 0
	track.Position = UDim2.fromScale(0.04, 0.54)
	track.Size = UDim2.fromScale(0.92, 0.3)
	track.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = track
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = HP_GOOD
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill
	gui.Parent = adornee
	return gui
end

local function setBar(gui: BillboardGui, hp: number, maxHP: number)
	local ratio = math.clamp(hp / math.max(1, maxHP), 0, 1)
	local track = gui:FindFirstChild("Track")
	local fill = track and track:FindFirstChild("Fill") :: Frame?
	if fill then
		fill.Size = UDim2.fromScale(ratio, 1)
		fill.BackgroundColor3 = HP_LOW:Lerp(HP_GOOD, ratio)
	end
end

local function barFor(player: Player): BillboardGui?
	local existing = bars[player]
	if existing and existing.Parent then
		return existing
	end
	local model = modelOf(player.UserId)
	local root = rootOf(model)
	if not root then
		return nil
	end
	local scale = model and model:GetAttribute("Scale") or 1
	local gui = buildBar(root, player.DisplayName, 8 + 5 * scale)
	bars[player] = gui
	return gui
end

local function dummyModel(): Model?
	if dummyCache and dummyCache.Parent then
		return dummyCache
	end
	local m = Workspace:FindFirstChild("TrainingDummy", true)
	dummyCache = m and m:IsA("Model") and m or nil
	return dummyCache
end

local function refreshBars()
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer then
			if player:GetAttribute("InArena") == true and LocalPlayer:GetAttribute("InArena") == true then
				local gui = barFor(player)
				if gui then
					setBar(gui, tonumber(player:GetAttribute("HP")) or 0, tonumber(player:GetAttribute("MaxHP")) or 1)
					gui.Enabled = player:GetAttribute("Downed") ~= true
				end
			elseif bars[player] then
				bars[player]:Destroy()
				bars[player] = nil
			end
		end
	end
	for player, gui in bars do
		if player.Parent == nil then
			gui:Destroy()
			bars[player] = nil
		end
	end
	-- the training dummy shows its hit points to fighters
	local dummy = LocalPlayer:GetAttribute("InArena") == true and dummyModel() or nil
	local target = dummy and dummy:FindFirstChild("Target") :: BasePart?
	if dummy and target then
		if not dummyBar or not dummyBar.Parent then
			dummyBar = buildBar(target, string.upper(CombatConfig.Dummy.Name), CombatConfig.Dummy.Radius + 4)
		end
		setBar(dummyBar, tonumber(dummy:GetAttribute("HP")) or 0, tonumber(dummy:GetAttribute("MaxHP")) or 1)
		dummyBar.Enabled = dummy:GetAttribute("Down") ~= true
	elseif dummyBar then
		dummyBar:Destroy()
		dummyBar = nil
	end
end

-- ============================================================== input
local function aimDirection(): Vector3
	local cam = registry.CameraController
	if cam and cam.getLook then
		return cam.getLook()
	end
	local camera = Workspace.CurrentCamera
	return camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)
end

function CombatController.strike(): boolean
	if not isFighter() then
		return false
	end
	local t = clock()
	if t < strikeReadyAt then
		return false
	end
	strikeReadyAt = t + CombatConfig.Strike.Cooldown
	Net.fire("CombatStrike", {})
	local model = localModel()
	local root = rootOf(model)
	if model and root then
		registry.AnimationController.play(model, "Strike")
		local look = root.CFrame.LookVector
		strikeFx(root.Position, look, LocalPlayer.UserId)
		registry.AudioController.play3D("Strike", root, 0.06)
	end
	registry.CameraController.shake(0.06)
	return true
end

function CombatController.blast(): boolean
	if not isFighter() then
		return false
	end
	local t = clock()
	if t < blastReadyAt then
		return false
	end
	blastReadyAt = t + CombatConfig.Blast.Cooldown
	Net.fire("CombatBlast", { Dir = aimDirection() })
	local model = localModel()
	local root = rootOf(model)
	if model and root then
		registry.AnimationController.play(model, "Cast")
		registry.AudioController.play3D("Blast", root, 0.05)
	end
	registry.CameraController.shake(0.1)
	return true
end

local function onKey(name: string, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		if name == "RAD_ArenaStrike" then
			CombatController.strike()
		else
			CombatController.blast()
		end
	end
	return Enum.ContextActionResult.Sink
end

-- Keys are only taken while you can fight: outside the arena F stays the roar, G the inventory.
local function refreshInput()
	local want = isFighter()
	if want == keysBound then
		return
	end
	keysBound = want
	if want then
		ContextActionService:BindActionAtPriority("RAD_ArenaStrike", onKey, false, 3600, Enum.KeyCode.F, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonX)
		ContextActionService:BindActionAtPriority("RAD_ArenaBlast", onKey, false, 3600, Enum.KeyCode.G, Enum.KeyCode.ButtonR3)
	else
		ContextActionService:UnbindAction("RAD_ArenaStrike")
		ContextActionService:UnbindAction("RAD_ArenaBlast")
	end
end

-- ============================================================== signals
local function onEnter(data)
	protectedUntil = clock() + (tonumber(data.Invulnerable) or 0)
	registry.UIController.Notify("warning", "DUEL ARENA - other riders can hit you here. Fly out to leave.")
	if registry.Hud and registry.Hud.SetArena then
		registry.Hud:SetArena(true)
	end
	strikeReadyAt, blastReadyAt = 0, 0
	refreshHud()
	refreshInput()
end

local function onLeave()
	if registry.Hud and registry.Hud.SetArena then
		registry.Hud:SetArena(false)
	end
	ui.Down.Visible = false
	protectedUntil = 0
	refreshHud()
	refreshInput()
	refreshBars()
end

local function onDown(data)
	-- the server moved the dragon to a respawn pad and froze it: no speed may be left over
	local dc = dragonController()
	if dc then
		dc.stand()
	end
	downUntil = clock() + (tonumber(data.Delay) or 3)
	ui.Down.Visible = true
	ui.DownSub.Text = ""
	local by = data.By
	ui.DownTitle.Text = (by and by ~= "") and "KNOCKED OUT" or "DOWN"
	registry.AudioController.playUI("Knockout")
	registry.CameraController.shake(0.35)
	refreshInput()
end

local function onRespawn(data)
	local dc = dragonController()
	if dc then
		dc.stand()
	end
	ui.Down.Visible = false
	protectedUntil = clock() + (tonumber(data.Invulnerable) or 0)
	refreshHud()
	refreshInput()
end

local function onReward(data)
	feedLine(string.format("+$%s  +%d XP   %s", Format.abbreviate(data.Cash or 0), data.XP or 0, data.Victim or ""), Color3.fromRGB(150, 235, 150))
end

local function onFx(data)
	if data.From == LocalPlayer.UserId and data.Kind == "Strike" then
		return -- drawn at once when you pressed the key
	end
	if data.Kind == "Strike" then
		strikeFx(data.Pos, data.Dir, data.From)
		local model = modelOf(data.From)
		local root = rootOf(model)
		if root then
			registry.AudioController.play3D("Strike", root, 0.06)
		end
	elseif data.Kind == "Blast" then
		newBlast(data)
	end
end

local function onHit(data)
	local mine = data.Target == LocalPlayer.UserId
	local color = data.Crit and Color3.fromRGB(255, 220, 70) or (mine and Color3.fromRGB(255, 96, 84) or Color3.fromRGB(255, 255, 255))
	floatText(data.Pos, (data.Crit and "CRIT " or "") .. "-" .. Format.commas(data.Damage), color, data.Crit == true)
	local model = data.Target == 0 and dummyModel() or modelOf(data.Target)
	flash(model, Color3.fromRGB(255, 70, 60))
	local root = data.Target == 0 and (model and model:FindFirstChild("Target") :: BasePart?) or rootOf(model)
	if root then
		registry.AudioController.play3D("Hit", root, 0.08)
	end
	if mine then
		ui.Hurt.BackgroundTransparency = 0.7
		TweenService:Create(ui.Hurt, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
		registry.CameraController.shake(0.3)
		local own = localModel()
		if own then
			registry.AnimationController.play(own, "Hurt")
		end
	end
end

local function onKO(data)
	local killer = data.KillerName ~= "" and data.KillerName or "?"
	local mine = data.Victim == LocalPlayer.UserId or data.Killer == LocalPlayer.UserId
	feedLine(string.format("%s  >  %s", killer, data.VictimName), mine and Color3.fromRGB(255, 220, 110) or Color3.fromRGB(235, 235, 245))
end

-- ============================================================== previews (UILab)
function CombatController.clear()
	if not layer then
		return
	end
	ui.Hud.Visible = false
	ui.Keys.Visible = false
	ui.Cross.Visible = false
	ui.Down.Visible = false
	for _, line in feedLines do
		line:Destroy()
	end
	table.clear(feedLines)
end

function CombatController.preview(kind: string)
	CombatController.clear()
	ui.Hud.Visible = true
	ui.HpText.Text = "2,340 / 3,000"
	ui.HpBar:SetValue(0.78)
	ui.HpBar:SetColors(HP_LOW:Lerp(HP_GOOD, 0.78), HP_LOW:Lerp(HP_GOOD, 0.78))
	ui.Keys.Visible = not Responsive.isMobile()
	ui.Cross.Visible = true
	protectedUntil = clock() + 2.1
	feedLine("Alice  >  Bob", Color3.fromRGB(255, 220, 110))
	feedLine("+$1.2M  +30 XP   Bob", Color3.fromRGB(150, 235, 150))
	if kind == "Down" then
		ui.Down.Visible = true
		ui.DownSub.Text = "Back in 2.0 s"
		ui.Cross.Visible = false
	end
end

-- ============================================================== public
function CombatController.Init(reg)
	registry = reg
end

function CombatController.Start()
	layer = makeLayer()
	buildHud(layer)
	CombatController.layout()
	Responsive.Changed:Connect(CombatController.layout)
	Net.onSignal("CombatEnter", onEnter)
	Net.onSignal("CombatLeave", onLeave)
	Net.onSignal("CombatDown", onDown)
	Net.onSignal("CombatRespawn", onRespawn)
	Net.onSignal("CombatReward", onReward)
	Net.onSignal("CombatFx", onFx)
	Net.onSignal("CombatHit", onHit)
	Net.onSignal("CombatKO", onKO)
	Net.onSignal("CombatBlastEnd", function(data)
		endBlast(data.Id, data.Pos, data.Hit == true)
	end)
	-- touch buttons (MobileControls) press the virtual actions
	registry.InputController.Pressed:Connect(function(action)
		if action == "Strike" then
			CombatController.strike()
		elseif action == "Blast" then
			CombatController.blast()
		end
	end)
	for _, attribute in { "InArena", "HP", "MaxHP", "Downed" } do
		LocalPlayer:GetAttributeChangedSignal(attribute):Connect(function()
			refreshHud()
			refreshInput()
		end)
	end
	registry.DragonController.RidingChanged:Connect(function()
		refreshHud()
		refreshInput()
	end)
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 2, function(dt)
		stepFx()
		updateCooldowns()
		barTimer += dt
		if barTimer > 0.2 then
			barTimer = 0
			refreshBars()
		end
	end)
	refreshHud()
end

return CombatController

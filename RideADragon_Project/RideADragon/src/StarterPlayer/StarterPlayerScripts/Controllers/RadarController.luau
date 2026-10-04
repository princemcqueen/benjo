--[[
	RadarController
	The Egg Radar: the Forge upgrade (250 / 600 / 1200 studs / the whole map), unlimited with
	the Robux boost "Radar" for a while or the Egg Hunter pass for good.

	  * every egg of yours inside the radar range gets a marker that shows through walls and
	    mountains: its luck and how far away it is
	  * a chip under the level badge points an arrow at the best egg around (high luck, not
	    too far), with its luck, distance and what is powering the radar
	It reads the replicated data (Upgrades / Boosts / Flags) and the eggs EggController knows.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local EggReach = require(Shared:WaitForChild("EggReach"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Kit = require(UI:WaitForChild("Kit"))
local Icons = require(UI:WaitForChild("Icons"))

local C = Theme.Colors
local LocalPlayer = Players.LocalPlayer

local RadarController = {}

local registry
local chip: Frame? = nil
local parts: any = nil
local clock = 0
local acc = 0
local active = false
local preview = false
local markers: { [string]: BillboardGui } = {}

-- ============================================================== helpers
local function distText(d: number): string
	if d >= 1000 then
		return string.format("%.1fk studs", d / 1000)
	end
	return string.format("%d studs", math.floor(d))
end

-- What powers the radar right now: boost timer, pass, or the Forge upgrade's range.
local function powerText(data, now: number, range: number): string
	local left = EggReach.radarSeconds(data, now)
	local phone = Responsive.Device == "Phone" -- the chip is narrow there: shorter words
	if left == math.huge then
		return phone and "HUNTER" or "EGG HUNTER"
	elseif left > 0 then
		left = math.floor(left)
		return string.format("%s  %d:%02d", phone and "RADAR" or "EGG RADAR", left // 60, left % 60)
	end
	return range >= 100000 and "RADAR  WHOLE MAP" or string.format("RADAR  %d studs", range)
end

-- ============================================================== chip
local function layout()
	if not chip then
		return
	end
	local R = Responsive
	local short = math.min(R.Width, R.Height)
	local phone = R.Device == "Phone"
	local margin = math.floor(short * (phone and 0.03 or 0.022) + 0.5)
	local top = R.TopInset + math.floor(short * 0.012)
	local levelH = short * (phone and 0.095 or 0.058)
	local levelW = short * (phone and 0.36 or 0.235)
	chip.AnchorPoint = Vector2.new(0, 0)
	if phone and R.Portrait then
		-- portrait phone: right of the level badge (below it the cash pill and its pills take the width)
		chip.Position = UDim2.new(0, margin + math.floor(levelW) + math.floor(short * 0.015), 0, top)
	else
		chip.Position = UDim2.new(0, margin, 0, top + math.floor(levelH + short * 0.012))
	end
	chip.SizeConstraint = R.Portrait and Enum.SizeConstraint.RelativeXX or Enum.SizeConstraint.RelativeYY
	chip.Size = phone and UDim2.fromScale(0.36, 0.1) or UDim2.fromScale(0.235, 0.064)
end

local function buildChip()
	if chip and chip.Parent then
		return
	end
	local uic = registry and registry.UIController
	local layer = uic and uic.Layers and uic.Layers.GameHUD
	if not layer then
		return
	end
	chip = Kit.surface({
		Name = "EggRadar",
		Size = UDim2.fromScale(0.235, 0.064),
		Color = Theme.Hud.Panel,
		Transparency = Theme.Hud.Transparency,
		StrokeColor = Theme.Hud.Stroke,
		StrokeTransparency = Theme.Hud.StrokeTransparency,
		Radius = "Window",
		Parent = layer.Root,
	})
	chip.Visible = false
	chip:SetAttribute("QARegion", "HudRadar")
	local disc = Kit.frame({
		Name = "Icon",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.03, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = Theme.Hud.Track,
		Parent = chip,
	})
	disc.BackgroundTransparency = 0
	Kit.corner(disc, "pill")
	local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.66, 0.66), Parent = disc })
	Icons.make("Radar", { Color = Theme.Hud.Icon, Accent = C.Accent }).Parent = iconBox
	local texts = Kit.frame({ Name = "Texts", Position = UDim2.fromScale(0.22, 0.1), Size = UDim2.fromScale(0.52, 0.8), Parent = chip })
	local best = Kit.text({
		Name = "Best",
		Text = "",
		Role = "Heading",
		Scaled = true,
		MinTextSize = 9,
		Color = Theme.Hud.Text,
		Size = UDim2.fromScale(1, 0.56),
		Truncate = true,
		Parent = texts,
	})
	local info = Kit.text({
		Name = "Info",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Scaled = true,
		MinTextSize = 9,
		Color = Theme.Hud.TextMuted,
		Position = UDim2.fromScale(0, 0.58),
		Size = UDim2.fromScale(1, 0.38),
		Truncate = true,
		Parent = texts,
	})
	local arrow = Kit.frame({
		Name = "Arrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.88, 0.5),
		Size = UDim2.fromScale(0.66, 0.66),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = chip,
	})
	Icons.make("Ascend", { Color = Theme.Hud.Icon, Accent = C.Accent }).Parent = arrow
	parts = { Best = best, Info = info, Arrow = arrow }
	layout()
end

-- ============================================================== markers
local function marker(egg): BillboardGui?
	local shell = egg.Model and egg.Model.PrimaryPart
	if not shell then
		return nil
	end
	local existing = markers[egg.Key]
	if existing and existing.Parent then
		return existing
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "RadarMarker"
	bb.Size = UDim2.fromOffset(120, 30)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 8000
	bb.LightInfluence = 0
	bb.Parent = shell
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextStrokeTransparency = 0.25
	label.Parent = bb
	markers[egg.Key] = bb
	return bb
end

local function clearMarkers()
	for key, bb in markers do
		bb:Destroy()
		markers[key] = nil
	end
end

-- ============================================================== per-frame
local function origin(): Vector3?
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return hrp and hrp.Position or nil
end

local function update()
	local data = registry.DataController.all()
	local now = Workspace:GetServerTimeNow()
	local range = EggReach.radarRange(data, now)
	local on = preview or range > 0
	if on ~= active then
		active = on
		if not on then
			clearMarkers()
		end
	end
	if not chip then
		if on then
			buildChip()
		else
			return
		end
	end
	if chip then
		chip.Visible = on
	end
	if not on or not chip or not parts then
		return
	end
	local from = origin()
	local eggs = registry.EggController and registry.EggController.list() or {}
	local seen = {}
	local bestEgg, bestScore, bestD = nil, -1, 0
	if from then
		for key, egg in eggs do
			local d = (egg.Position - from).Magnitude
			if d > range and not preview then
				continue
			end
			seen[key] = true
			local bb = marker(egg)
			if bb then
				local text = bb:FindFirstChild("Text") :: TextLabel
				text.Text = string.format("x%d  %s", egg.Luck or 1, distText(d))
				text.TextColor3 = EggConfig.luckColor(egg.Luck or 1)
				bb.Enabled = d > 24
			end
			-- the best target: lucky first, near preferred
			local score = (egg.Luck or 1) / (1 + d / 350)
			if score > bestScore then
				bestEgg, bestScore, bestD = egg, score, d
			end
		end
	end
	for key, bb in markers do
		if not seen[key] then
			bb:Destroy()
			markers[key] = nil
		end
	end
	parts.Info.Text = preview and (Responsive.Device == "Phone" and "RADAR  12:34" or "EGG RADAR  12:34") or powerText(data, now, range)
	if bestEgg and from then
		parts.Best.Text = string.format("x%d  %s", bestEgg.Luck or 1, distText(bestD))
		parts.Best.TextColor3 = EggConfig.luckColor(bestEgg.Luck or 1)
		local camera = Workspace.CurrentCamera
		if camera then
			local look = camera.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			local to = Vector3.new(bestEgg.Position.X - from.X, 0, bestEgg.Position.Z - from.Z)
			if forward.Magnitude > 0.01 and to.Magnitude > 0.5 then
				forward, to = forward.Unit, to.Unit
				parts.Arrow.Rotation = math.deg(math.atan2(-forward:Cross(to).Y, forward:Dot(to)))
			end
		end
	else
		parts.Best.Text = preview and "x250  412 studs" or "No egg nearby"
		parts.Best.TextColor3 = Theme.Hud.TextMuted
	end
end

function RadarController.isActive(): boolean
	return active
end

-- UILab: the chip with sample text, whatever the data says.
function RadarController.preview(on: boolean?)
	preview = on ~= false
	if not preview then
		clearMarkers()
	end
	update()
end

function RadarController.Init(reg)
	registry = reg
end

function RadarController.Start()
	Responsive.Changed:Connect(layout)
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		acc += dt
		if acc >= 0.2 then
			acc = 0
			update()
		end
	end)
end

return RadarController

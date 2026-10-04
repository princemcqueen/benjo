--[[
	WildEggController
	Client side of the Lucky Wild Eggs (WildEggService / WildEggConfig):

	  * a headline "A MYTHIC EGG HAS SPAWNED!" for a few seconds, then a compact tracker
	    under the cash row: tier + luck, region / area, a countdown (02:00), an arrow that
	    points at the egg and the distance to it
	  * the egg itself (a server model with a tall pillar of light) bobs and spins and gets
	    a big label that can be read from far away
	  * flying / walking into it asks the server to claim it (first come first served);
	    a win flies the egg into your hand

	Net signals: "WildEggSpawn" info, "WildEggClaimed" { Player, Name, Luck }, "WildEggGone"
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))
local WildEggConfig = require(Configs:WaitForChild("WildEggConfig"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Kit = require(UI:WaitForChild("Kit"))
local Icons = require(UI:WaitForChild("Icons"))

local C = Theme.Colors
local LocalPlayer = Players.LocalPlayer

local WildEggController = {}

local registry
local holder: Frame? = nil
local ui: any = nil -- the tracker's elements
local info: any = nil -- the wild egg that is out right now
local pending = false
local lastClaim = -10
local lastFull = -10
local clock = 0
local labelled: Model? = nil
local preview = false -- UI Lab: no claiming, fake distance

-- ============================================================== layout
local function layout()
	if not holder then
		return
	end
	local R = Responsive
	local short = math.min(R.Width, R.Height)
	local top, w, h
	if R.Device == "Phone" then
		top = R.TopInset + short * 0.2
		if R.Portrait then
			w = R.Width * 0.94
			h = w * 0.2
		else
			h = short * 0.17
			w = h * 4.8
		end
	else
		top = R.TopInset + short * 0.145
		h = short * 0.095
		w = h * 5.6
	end
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, math.floor(top))
	holder.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

local function getHolder(): Frame?
	if holder and holder.Parent then
		return holder
	end
	local uic = registry and registry.UIController
	local layer = uic and uic.Layers and (uic.Layers.GameNotifications or uic.Layers.GameUI)
	if not layer then
		return nil
	end
	holder = Kit.frame({ Name = "WildEgg", Size = UDim2.fromOffset(300, 60), Parent = layer.Root })
	holder.ZIndex = 25
	holder.Visible = false
	layout()
	return holder
end

local function mmss(seconds: number): string
	seconds = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- ============================================================== tracker UI
local function build(data)
	local parent = getHolder()
	if not parent then
		return nil
	end
	local color: Color3 = data.Color
	local chip = Kit.surface({
		Name = "Chip",
		Size = UDim2.fromScale(1, 1),
		Color = C.Panel,
		Transparency = 0.06,
		StrokeColor = color,
		StrokeTransparency = 0.05,
		Radius = "Window",
		Parent = parent,
	})
	local stroke = chip:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke.Thickness = 3
	end
	-- egg disc (tier colour)
	local disc = Kit.frame({
		Name = "Disc",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.025, 0.5),
		Size = UDim2.fromScale(0.74, 0.74),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.45),
		Parent = chip,
	})
	disc.BackgroundTransparency = 0
	Kit.corner(disc, "pill")
	local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.66, 0.66), Parent = disc })
	Icons.make("Egg", { Color = Color3.new(1, 1, 1), Accent = color }).Parent = iconBox
	-- title / place
	local texts = Kit.frame({ Name = "Texts", Position = UDim2.fromScale(0.2, 0.08), Size = UDim2.fromScale(0.38, 0.84), Parent = chip })
	local title = Kit.text({
		Name = "Title",
		Text = string.format("%s  x%d", data.Name, data.Luck),
		Role = "Heading",
		Scaled = true,
		MinTextSize = 9,
		Color = color,
		Size = UDim2.fromScale(1, 0.56),
		Truncate = true,
		Parent = texts,
	})
	local where = Kit.text({
		Name = "Where",
		Text = string.format("%s - %s", EggConfig.RegionNames[data.Region] or data.Region or "?", data.Area or "?"),
		Role = "Micro",
		Scaled = true,
		MinTextSize = 8,
		Color = C.TextMuted,
		Position = UDim2.fromScale(0, 0.58),
		Size = UDim2.fromScale(1, 0.4),
		Truncate = true,
		Parent = texts,
	})
	-- arrow (rotates towards the egg)
	local arrowHolder = Kit.frame({
		Name = "Arrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.655, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = chip,
	})
	Icons.make("Ascend", { Color = Color3.new(1, 1, 1), Accent = color }).Parent = arrowHolder
	-- timer + distance
	local timer = Kit.text({
		Name = "Timer",
		Text = mmss(WildEggConfig.Lifetime),
		Role = "Title",
		Scaled = true,
		MinTextSize = 9,
		Color = Color3.new(1, 1, 1),
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.74, 0.08),
		Size = UDim2.fromScale(0.24, 0.5),
		Parent = chip,
	})
	local distance = Kit.text({
		Name = "Distance",
		Text = "",
		Role = "Micro",
		Scaled = true,
		MinTextSize = 8,
		Color = C.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.74, 0.6),
		Size = UDim2.fromScale(0.24, 0.34),
		Parent = chip,
	})
	-- headline under the chip (first seconds only)
	local headline = Kit.text({
		Name = "Headline",
		Text = string.format("A %s HAS SPAWNED!", data.Name),
		Role = "Display",
		Scaled = true,
		MinTextSize = 12,
		Color = color,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 1, 6),
		Size = UDim2.fromScale(1, 0.62),
		Parent = parent,
	})
	headline.TextStrokeTransparency = 0.2
	headline.TextStrokeColor3 = Color3.fromRGB(14, 16, 24)
	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = chip
	TweenService:Create(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(6, function()
		if headline.Parent then
			TweenService:Create(headline, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			task.delay(0.7, function()
				headline:Destroy()
			end)
		end
	end)
	return {
		Chip = chip,
		Headline = headline,
		Timer = timer,
		Distance = distance,
		Arrow = arrowHolder,
		Title = title,
		Where = where,
	}
end

local function clearUi()
	if holder then
		for _, c in holder:GetChildren() do
			c:Destroy()
		end
		holder.Visible = false
	end
	ui = nil
end

local function hide()
	info = nil
	pending = false
	labelled = nil
	clearUi()
end

-- ============================================================== the egg in the world
local function findModel(): Model?
	for _, m in CollectionService:GetTagged("WildEgg") do
		if m:IsA("Model") and m.Parent then
			return m
		end
	end
	return nil
end

local function label(model: Model)
	local shell = model.PrimaryPart
	if not shell or not info then
		return
	end
	local color: Color3 = info.Color
	local bb = Instance.new("BillboardGui")
	bb.Name = "WildEggLabel"
	bb.Size = UDim2.fromScale(15, 4.6)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 7.5, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 6000
	bb.LightInfluence = 0
	bb.Parent = shell
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, 0.55)
	name.Font = Enum.Font.GothamBlack
	name.TextScaled = true
	name.Text = info.Name
	name.TextColor3 = color
	name.TextStrokeTransparency = 0.2
	name.Parent = bb
	local luck = Instance.new("TextLabel")
	luck.BackgroundTransparency = 1
	luck.Position = UDim2.fromScale(0, 0.55)
	luck.Size = UDim2.fromScale(1, 0.45)
	luck.Font = Enum.Font.GothamBold
	luck.TextScaled = true
	luck.Text = "x" .. tostring(info.Luck) .. " LUCK"
	luck.TextColor3 = EggConfig.luckColor(info.Luck)
	luck.TextStrokeTransparency = 0.3
	luck.Parent = bb
end

local function myPositions(): ({ Vector3 }, number)
	local out = {}
	local slack = 0
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		table.insert(out, hrp.Position)
	end
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. LocalPlayer.UserId)
	local root = model and model:FindFirstChild("Root") :: BasePart?
	if root then
		table.insert(out, root.Position)
		slack = ((model :: Model):GetAttribute("BodyRadius") or 0) * 0.5
		if (model :: Model):GetAttribute("RiderUserId") == LocalPlayer.UserId then
			slack += 6
		end
	end
	return out, slack
end

local function tryClaim()
	pending = true
	lastClaim = clock
	local data = info
	task.spawn(function()
		local res = Net.request("WildEgg", "Claim", {})
		pending = false
		local uic = registry.UIController
		if res.ok then
			hide()
			local held = registry.HeldEggController
			if held and res.data.Held and data then
				held.flyIn(res.data.Type, data.Position)
			end
			if uic then
				uic.Notify("rare", string.format("You got the %s!  (x%d LUCK)%s", res.data.Name or "EGG", res.data.Luck or 1, res.data.Held and "  -  in your hand" or ""))
			end
			local audio = registry.AudioController
			if audio then
				audio.playUI("LevelUp")
			end
		elseif res.err == "GONE" then
			hide()
		elseif res.err == "EGG_STORAGE_FULL" then
			if clock - lastFull > 6 and uic then
				lastFull = clock
				uic.Notify("warning", res.msg or "Your egg bag is full!")
			end
		end
	end)
end

-- ============================================================== per-frame
local function step(dt: number)
	clock += dt
	if not info or not ui then
		return
	end
	local now = Workspace:GetServerTimeNow()
	local left = info.EndsAt - now
	ui.Timer.Text = mmss(left)
	ui.Timer.TextColor3 = left <= 20 and C.Danger or Color3.new(1, 1, 1)
	-- egg model: bob + spin + label
	local model = findModel()
	if model and model.PrimaryPart then
		if labelled ~= model then
			labelled = model
			label(model)
		end
		local t = clock
		EggVisual.place(model, CFrame.new(info.Position + Vector3.new(0, math.sin(t * 2) * 0.7, 0)) * CFrame.Angles(0, t * 0.9, math.sin(t * 1.3) * 0.08))
	end
	-- distance + arrow
	local positions, slack = myPositions()
	local from = positions[1]
	local camera = Workspace.CurrentCamera
	if from then
		local d = (info.Position - from).Magnitude
		ui.Distance.Text = preview and "634 studs" or (d >= 1000 and string.format("%.1fk studs", d / 1000) or string.format("%d studs", math.floor(d)))
		if camera then
			local look = camera.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			local toEgg = Vector3.new(info.Position.X - from.X, 0, info.Position.Z - from.Z)
			if forward.Magnitude > 0.01 and toEgg.Magnitude > 0.5 then
				forward, toEgg = forward.Unit, toEgg.Unit
				-- clockwise degrees: positive = the egg is to the right
				ui.Arrow.Rotation = math.deg(math.atan2(-forward:Cross(toEgg).Y, forward:Dot(toEgg)))
			end
		end
	end
	-- grabbing it
	if preview or pending or clock - lastClaim < WildEggConfig.ClaimThrottle then
		return
	end
	local range = WildEggConfig.PickupRange * (1 + TreeConfig.bonus(registry.DataController.all(), "EggMagnet")) + slack
	for _, p in positions do
		if (p - info.Position).Magnitude <= range then
			tryClaim()
			break
		end
	end
end

-- ============================================================== events
local function show(data)
	if type(data) ~= "table" or type(data.EndsAt) ~= "number" or typeof(data.Position) ~= "Vector3" then
		return
	end
	hide()
	info = data
	if typeof(info.Color) ~= "Color3" then
		info.Color = Color3.fromRGB(255, 200, 80)
	end
	local parent = getHolder()
	if not parent then
		info = nil
		return
	end
	ui = build(info)
	parent.Visible = true
	local audio = registry.AudioController
	if audio then
		audio.playUI("RareHatch")
	end
end

function WildEggController.current()
	return info
end

-- UILab: a sample tracker (no claiming).
function WildEggController.preview()
	preview = true
	show({
		Id = "W0",
		Tier = "Mythic",
		Name = "MYTHIC EGG",
		Egg = "CelestialEgg",
		Luck = 320,
		Position = Vector3.new(500, 120, -400),
		Region = "Skyreach",
		Area = "Pillar",
		EndsAt = Workspace:GetServerTimeNow() + 102,
		Color = Color3.fromRGB(255, 80, 160),
	})
end

function WildEggController.clear()
	preview = false
	hide()
end

function WildEggController.Init(reg)
	registry = reg
end

function WildEggController.Start()
	Net.onSignal("WildEggSpawn", function(data)
		preview = false
		show(data)
	end)
	Net.onSignal("WildEggClaimed", function(data)
		if type(data) ~= "table" then
			return
		end
		if info and info.Id == data.Id then
			local mine = data.Player == LocalPlayer.DisplayName
			hide()
			local uic = registry.UIController
			if uic and not mine then
				uic.Notify("info", string.format("%s grabbed the %s!", tostring(data.Player), tostring(data.Name)))
			end
		end
	end)
	Net.onSignal("WildEggGone", function(data)
		if info and type(data) == "table" and info.Id == data.Id then
			hide()
			local uic = registry.UIController
			if uic then
				uic.Notify("warning", "The lucky egg vanished...")
			end
		end
	end)
	Responsive.Changed:Connect(layout)
	RunService.Heartbeat:Connect(step)
	-- an egg may already be out when this client starts
	task.spawn(function()
		local res = Net.request("WildEgg", "Sync", {})
		if res.ok and res.data and res.data.Current and not info then
			show(res.data.Current)
		end
	end)
end

return WildEggController

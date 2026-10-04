--[[
	SanctuaryController
	The local player's sanctuary: incubating eggs on the nest (with progress
	timers), "Place Egg" / "Hatch" / "Unlock" prompts, and the owner's
	guidance marker. All visuals are local (built from WorldConfig, so they do
	not depend on the plot having streamed in).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))

local SanctuaryController = {}

local registry
local LocalPlayer = Players.LocalPlayer
local folder: Folder? = nil
local slots: { [number]: any } = {}
local nestPrompt: ProximityPrompt? = nil
local nestAnchor: BasePart? = nil
local plotId: number? = nil
local clock = 0

local SLOT_COUNT = #EggConfig.IncubatorPrices

-- ============================================================== geometry
local function plotFrame(): CFrame?
	local p = plotId and WorldConfig.Plots[plotId]
	if not p then
		return nil
	end
	return CFrame.new(p.Center.X, p.Height, p.Center.Z) * CFrame.Angles(0, p.Facing, 0)
end

function SanctuaryController.nestCFrame(): CFrame?
	local f = plotFrame()
	return f and f * CFrame.new(0, 2.6, -6) or nil
end

local function slotCFrame(i: number): CFrame?
	local nest = SanctuaryController.nestCFrame()
	if not nest then
		return nil
	end
	local a = (i - 1) / SLOT_COUNT * math.pi * 2
	return nest * CFrame.new(math.sin(a) * 4.6, 1.55, math.cos(a) * 4.6)
end
SanctuaryController.slotCFrame = slotCFrame

-- ============================================================== visuals
local function getFolder(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MySanctuary"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

local function anchorPart(name: string, cf: CFrame, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = size
	p.CFrame = cf
	p.Parent = getFolder()
	return p
end

local function billboard(parent: Instance, offsetY: number): (BillboardGui, TextLabel, Frame)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Timer"
	-- sized in studs (like a small sign) so neighbouring slot timers never pile up
	bb.Size = UDim2.fromScale(3.3, 1.25)
	bb.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	bb.AlwaysOnTop = false
	bb.MaxDistance = 70
	bb.LightInfluence = 0
	bb.Parent = parent
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(19, 21, 27)
	bg.BackgroundTransparency = 0.18
	bg.BorderSizePixel = 0
	bg.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(206, 170, 98)
	stroke.Transparency = 0.45
	stroke.Parent = bg
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0.66, 0)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(246, 238, 221)
	label.Text = ""
	label.Parent = bg
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.Parent = label
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.fromScale(0.5, 0.9)
	track.Size = UDim2.fromScale(0.86, 0.14)
	track.BackgroundColor3 = Color3.fromRGB(44, 46, 56)
	track.BorderSizePixel = 0
	track.Parent = bg
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(1, 0)
	tc.Parent = track
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(246, 144, 44)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(1, 0)
	fc.Parent = fill
	return bb, label, fill
end

local function clearSlot(i: number)
	local s = slots[i]
	if s then
		for _, inst in s.Instances do
			inst:Destroy()
		end
	end
	slots[i] = nil
end

local function buildSlot(i: number, state: string, info)
	clearSlot(i)
	local cf = slotCFrame(i)
	if not cf then
		return
	end
	local s = { State = state, Instances = {}, Info = info, Index = i }
	slots[i] = s
	if state == "Egg" then
		local model = EggVisual.build(info.Type, { Beam = false, Scale = 0.95 })
		model.Name = "NestEgg" .. i
		EggVisual.place(model, cf)
		model.Parent = getFolder()
		table.insert(s.Instances, model)
		s.Model = model
		local holder = anchorPart("SlotAnchor" .. i, cf, Vector3.new(2, 3, 2))
		table.insert(s.Instances, holder)
		local bb, label, fill = billboard(holder, 2.9)
		s.Label, s.Fill = label, fill
		local luck = math.max(1, tonumber(info.Luck) or 1)
		if luck > 1 then
			local tag = Instance.new("BillboardGui")
			tag.Name = "LuckTag"
			tag.Size = UDim2.fromScale(3.6, 0.9)
			tag.StudsOffsetWorldSpace = Vector3.new(0, 4.3, 0)
			tag.MaxDistance = 70
			tag.LightInfluence = 0
			tag.Parent = holder
			local t = Instance.new("TextLabel")
			t.BackgroundTransparency = 1
			t.Size = UDim2.fromScale(1, 1)
			t.Font = Enum.Font.GothamBlack
			t.TextScaled = true
			t.Text = "x" .. tostring(luck) .. " LUCK"
			t.TextColor3 = EggConfig.luckColor(luck)
			t.TextStrokeTransparency = 0.3
			t.Parent = tag
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "HatchPrompt"
		prompt.ActionText = "Hatch"
		prompt.ObjectText = (EggConfig.Eggs[info.Type] or EggConfig.Eggs.HavenEgg).Name
		prompt.HoldDuration = 0.35
		prompt.MaxActivationDistance = 16
		prompt.RequiresLineOfSight = false
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.Enabled = false
		prompt.Parent = holder
		prompt.Triggered:Connect(function()
			local hc = registry.HatchController
			if hc then
				hc.hatch(i)
			end
		end)
		s.Prompt = prompt
		local _ = bb
	elseif state == "Free" then
		local ring = Instance.new("Part")
		ring.Name = "FreeSlot" .. i
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.12, 2.6, 2.6)
		ring.CFrame = cf * CFrame.new(0, -1.45, 0) * CFrame.Angles(0, 0, math.rad(90))
		ring.Material = Enum.Material.Neon
		ring.Color = Color3.fromRGB(246, 200, 120)
		ring.Transparency = 0.55
		ring.CastShadow = false
		ring.Parent = getFolder()
		table.insert(s.Instances, ring)
	elseif state == "Buy" then
		local holder = anchorPart("BuySlot" .. i, cf, Vector3.new(2, 2, 2))
		table.insert(s.Instances, holder)
		local lock = Instance.new("Part")
		lock.Name = "LockedSlot" .. i
		lock.Anchored = true
		lock.CanCollide = false
		lock.CanQuery = false
		lock.Size = Vector3.new(1.6, 1.6, 1.6)
		lock.Shape = Enum.PartType.Ball
		lock.Material = Enum.Material.Glass
		lock.Color = Color3.fromRGB(120, 120, 130)
		lock.Transparency = 0.4
		lock.CFrame = cf * CFrame.new(0, -0.7, 0)
		lock.Parent = getFolder()
		table.insert(s.Instances, lock)
		local price = EggConfig.IncubatorPrices[i]
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "UnlockPrompt"
		prompt.ActionText = "Unlock (" .. Format.cash(price) .. ")"
		prompt.ObjectText = "Nest spot " .. i
		prompt.HoldDuration = 0.5
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.Parent = holder
		prompt.Triggered:Connect(function()
			local uic = registry.UIController
			task.spawn(function()
				local res = Net.request("Egg", "BuyIncubator", { Slot = i })
				if uic then
					uic.HandleResult(res, "Nest spot unlocked!")
				end
			end)
		end)
	end
end

-- Rebuilds slot visuals from the data mirror.
local function refresh()
	local D = registry.DataController
	local inc = D and D.get("Incubator")
	if not inc or not plotId then
		return
	end
	for i = 1, SLOT_COUNT do
		local info = inc.Slots and inc.Slots[tostring(i)]
		local state
		if info then
			state = "Egg"
		elseif i <= inc.Unlocked then
			state = "Free"
		elseif i == inc.Unlocked + 1 then
			state = "Buy"
		else
			state = "None"
		end
		local cur = slots[i]
		local same = cur and cur.State == state and (state ~= "Egg" or (cur.Info and cur.Info.Ready == info.Ready and cur.Info.Type == info.Type and cur.Info.Luck == info.Luck))
		if not same then
			if state == "None" then
				clearSlot(i)
			else
				buildSlot(i, state, info)
			end
		end
	end
	SanctuaryController.updatePrompt()
end

function SanctuaryController.updatePrompt()
	if not nestPrompt then
		return
	end
	local D = registry.DataController
	local eggs = D and D.get("Eggs") or {}
	local inc = D and D.get("Incubator")
	local free = 0
	if inc then
		for i = 1, inc.Unlocked do
			if not (inc.Slots and inc.Slots[tostring(i)]) then
				free += 1
			end
		end
	end
	nestPrompt.Enabled = #eggs > 0 and free > 0
	nestPrompt.ObjectText = string.format("Nest  -  %d egg%s in bag", #eggs, #eggs == 1 and "" or "s")
end

local function buildNest()
	local cf = SanctuaryController.nestCFrame()
	if not cf then
		return
	end
	if nestAnchor then
		nestAnchor:Destroy()
	end
	nestAnchor = anchorPart("NestAnchor", cf * CFrame.new(0, 1, 0), Vector3.new(12, 2, 12))
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PlaceEggPrompt"
	prompt.ActionText = "Place Egg"
	prompt.ObjectText = "Nest"
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Parent = nestAnchor
	prompt.Triggered:Connect(function()
		local uic = registry.UIController
		task.spawn(function()
			local res = Net.request("Egg", "Place", {})
			if res.ok then
				local audio = registry.AudioController
				if audio then
					audio.playUI("Click")
				end
			elseif uic then
				uic.HandleResult(res)
			end
		end)
	end)
	nestPrompt = prompt
end

local function step(dt: number)
	clock += dt
	local now = Workspace:GetServerTimeNow()
	for _, s in slots do
		if s.State == "Egg" and s.Info then
			local total = math.max(1, s.Info.Ready - s.Info.Start)
			local left = s.Info.Ready - now
			local ready = left <= 0
			if s.Label then
				if ready then
					s.Label.Text = "READY!"
					s.Label.TextColor3 = Color3.fromRGB(150, 255, 150)
				else
					s.Label.Text = Format.duration(math.ceil(left))
					s.Label.TextColor3 = Color3.fromRGB(246, 238, 221)
				end
			end
			if s.Fill then
				s.Fill.Size = UDim2.fromScale(math.clamp(1 - left / total, 0, 1), 1)
				s.Fill.BackgroundColor3 = ready and Color3.fromRGB(108, 200, 116) or Color3.fromRGB(246, 144, 44)
			end
			if s.Prompt then
				s.Prompt.Enabled = ready
			end
			-- wobble while incubating, excited shake when ready
			if s.Model and s.Model.Parent then
				local base = slotCFrame(s.Index)
				if base then
					local amp = ready and 0.12 or 0.03
					local freq = ready and 9 or 2
					EggVisual.place(s.Model, base * CFrame.Angles(math.sin(clock * freq) * amp, 0, math.cos(clock * freq * 0.8) * amp))
				end
			end
		end
	end
end

function SanctuaryController.plotId(): number?
	return plotId
end

function SanctuaryController.Init(reg)
	registry = reg
end

function SanctuaryController.Start()
	local function onPlot()
		local id = LocalPlayer:GetAttribute("PlotId")
		if type(id) == "number" and id ~= plotId then
			plotId = id
			for i in table.clone(slots) do
				clearSlot(i)
			end
			buildNest()
			refresh()
		end
	end
	LocalPlayer:GetAttributeChangedSignal("PlotId"):Connect(onPlot)
	onPlot()
	local D = registry.DataController
	if D then
		D.observe("Incubator", refresh)
		D.observe("Eggs", function()
			SanctuaryController.updatePrompt()
		end)
	end
	RunService.Heartbeat:Connect(step)
end

return SanctuaryController

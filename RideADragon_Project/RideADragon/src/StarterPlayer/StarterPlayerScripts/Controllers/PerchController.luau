--[[
	PerchController
	Sanctuary perches for every plot, built locally from the replicated
	ReplicatedStorage.SanctuaryState (see SanctuaryService):

	  * resting display dragons on occupied perches (a client-only model with
	    an anchored Root; the AnimationController builds and animates the
	    visual with its distance LOD and the perch mood cycle), with a small
	    nameplate (name, level, mutation, income)
	  * plots far from the camera are not built at all (graphics preset aware)
	  * on the local player's own plot: perch prompts - View / Take back on an
	    occupied perch, Place on a free perch (opens the collection in place
	    mode), Unlock on the next locked perch - and soft markers for free and
	    purchasable perches.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Builder = require(Shared:WaitForChild("Dragons"):WaitForChild("Builder"))
local DragonStats = require(Shared:WaitForChild("DragonStats"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local Odds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Odds"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))

local PerchController = {}

local registry
local LocalPlayer = Players.LocalPlayer
local S = GameConfig.Sanctuary
local PERCHES = WorldConfig.Sanctuary.PerchCount

local stateFolder: Instance? = nil
local dragonFolder: Folder? = nil
local markerFolder: Folder? = nil
local perches: { [string]: any } = {} -- "plot:slot" -> { Model, Fields, Plate }
local plotVisible: { [number]: boolean } = {}
local myMarkers: { [number]: any } = {} -- slot -> { Instances, State }
local clock = 0
local checkTimer = 0

-- ============================================================== helpers
local function parse(value: any)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	local species, mutation, level, odds, name = string.match(value, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
	if not species or not DragonConfig.Species[species] then
		return nil
	end
	return {
		SpeciesId = species,
		Mutation = MutationConfig.Mutations[mutation] and mutation or "None",
		Level = math.clamp(tonumber(level) or 1, 1, DragonConfig.MaxLevel),
		Odds = tonumber(odds) or 0,
		Name = (name ~= "" and name) or DragonConfig.Species[species].Name,
	}
end

local function key(plotId: number, slot: number): string
	return plotId .. ":" .. slot
end

local function viewDistance(): number
	local gc = registry and registry.GraphicsController
	if gc and gc.Preset == "Low" then
		return S.ViewDistanceLow
	end
	return S.ViewDistance
end

local function myPlotId(): number?
	local id = LocalPlayer:GetAttribute("PlotId")
	return type(id) == "number" and id or nil
end

-- ============================================================== nameplate
local function nameplate(root: BasePart, fields, height: number)
	local rarity = DragonConfig.Rarities[DragonConfig.Species[fields.SpeciesId].Rarity] or DragonConfig.Rarities.Common
	local mutation = MutationConfig.Mutations[fields.Mutation]
	local bb = Instance.new("BillboardGui")
	bb.Name = "Nameplate"
	bb.Size = UDim2.fromScale(9, 3.2) -- studs: reads like a sign, never covers the screen
	bb.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	bb.MaxDistance = S.NameplateDistance
	bb.LightInfluence = 0
	bb.Parent = root
	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, 0.36)
	name.Font = Enum.Font.GothamBlack
	name.TextScaled = true
	name.TextColor3 = rarity.Glow
	name.TextStrokeTransparency = 0.45
	name.Text = fields.Name
	name.Parent = bb
	local info = Instance.new("TextLabel")
	info.Name = "Info"
	info.BackgroundTransparency = 1
	info.Position = UDim2.fromScale(0, 0.68)
	info.Size = UDim2.fromScale(1, 0.28)
	info.Font = Enum.Font.GothamBold
	info.TextScaled = true
	info.RichText = true
	info.TextColor3 = Color3.fromRGB(246, 238, 221)
	info.TextStrokeTransparency = 0.5
	info.Parent = bb
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0, 0.37)
	title.Size = UDim2.fromScale(1, 0.3)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextStrokeTransparency = 0.35
	title.Parent = bb
	local function fill(f)
		local exclusive = Odds.isExclusive(f.SpeciesId)
		local n = (f.Odds and f.Odds > 0) and f.Odds or Odds.base(f.SpeciesId, f.Mutation)
		title.Text = Odds.format(n, exclusive)
		title.TextColor3 = exclusive and DragonConfig.Rarities.Exclusive.Glow or Odds.color(n)
		local stats = DragonStats.compute(f.SpeciesId, f.Level, f.Mutation)
		local mut = (f.Mutation ~= "None" and mutation) and string.format('<font color="#%s">%s</font>  ', mutation.Color:ToHex(), string.upper(mutation.Name)) or ""
		info.Text = string.format('%sLV %d   <font color="#F2D086">%s</font>', mut, f.Level, Format.perSecond(stats.IncomePerSecond))
		name.Text = f.Name
	end
	fill(fields)
	return { Gui = bb, Fill = fill }
end

-- ============================================================== perch dragons
local function destroyPerch(k: string)
	local p = perches[k]
	if p then
		perches[k] = nil
		if p.Model then
			p.Model:Destroy()
		end
	end
end

local function buildPerch(plotId: number, slot: number, fields)
	local k = key(plotId, slot)
	destroyPerch(k)
	local cf = WorldConfig.perchWorld(plotId, slot)
	if not cf or not dragonFolder then
		return
	end
	local scale = S.PerchScale
	local info = Builder.mountInfo(fields.SpeciesId, scale)
	local model = Instance.new("Model")
	model.Name = "Perch_" .. k
	model:SetAttribute("Kind", "Perch")
	model:SetAttribute("SpeciesId", fields.SpeciesId)
	model:SetAttribute("Mutation", fields.Mutation)
	model:SetAttribute("DisplayScale", scale)
	model:SetAttribute("Mode", "Rest")
	model:SetAttribute("Anchored", true)
	model:SetAttribute("PlotId", plotId)
	model:SetAttribute("Slot", slot)
	local root = Builder.makeRoot(fields.SpeciesId, scale)
	root.Anchored = true
	root.CFrame = cf * CFrame.new(0, info.HipHeight, 0)
	root.Parent = model
	model.PrimaryPart = root
	local plate = nameplate(root, fields, info.HipHeight * 0.9 + 3.2)
	model.Parent = dragonFolder
	perches[k] = { Model = model, Fields = fields, Plate = plate, Plot = plotId, Slot = slot }
end

-- Applies one perch attribute value (only rebuilds when the look changes).
local function applyPerch(plotId: number, slot: number)
	local k = key(plotId, slot)
	if not plotVisible[plotId] or not stateFolder then
		destroyPerch(k)
		return
	end
	local state = stateFolder:FindFirstChild("Plot" .. plotId)
	local fields = state and parse(state:GetAttribute("Perch" .. slot))
	local cur = perches[k]
	if not fields then
		destroyPerch(k)
		return
	end
	if cur and cur.Fields.SpeciesId == fields.SpeciesId and cur.Fields.Mutation == fields.Mutation then
		cur.Fields = fields
		cur.Plate.Fill(fields)
		return
	end
	buildPerch(plotId, slot, fields)
end

local function refreshPlot(plotId: number)
	for slot = 1, PERCHES do
		applyPerch(plotId, slot)
	end
end

-- Builds / frees whole plots by camera distance (with hysteresis).
local function updateVisibility()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local range = viewDistance()
	for id, plot in WorldConfig.Plots do
		local d = (Vector3.new(plot.Center.X, plot.Height, plot.Center.Z) - camPos).Magnitude
		local want
		if plotVisible[id] then
			want = d < range + 80
		else
			want = d < range
		end
		if want ~= (plotVisible[id] == true) then
			plotVisible[id] = want
			refreshPlot(id)
		end
	end
end

-- ============================================================== own plot prompts
local function data()
	local D = registry.DataController
	return D and D.all()
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
	p.Parent = markerFolder
	return p
end

local function prompt(parent: Instance, name: string, action: string, object: string, keyCode: Enum.KeyCode, hold: number, fn: () -> ())
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = action
	pp.ObjectText = object
	pp.KeyboardKeyCode = keyCode
	pp.HoldDuration = hold
	pp.MaxActivationDistance = S.PromptRange
	pp.RequiresLineOfSight = false
	pp.Parent = parent
	pp.Triggered:Connect(fn)
	return pp
end

local function clearMarker(slot: number)
	local m = myMarkers[slot]
	if m then
		for _, inst in m.Instances do
			inst:Destroy()
		end
	end
	myMarkers[slot] = nil
end

local function request(action: string, payload, okText: string?)
	task.spawn(function()
		local res = Net.request("Dragon", action, payload)
		local uic = registry.UIController
		if uic then
			uic.HandleResult(res, okText)
		end
	end)
end

local function buildMarker(plotId: number, slot: number, stateName: string, uid: string?)
	clearMarker(slot)
	local cf = WorldConfig.perchWorld(plotId, slot)
	if not cf or not markerFolder then
		return
	end
	local m = { State = stateName, Uid = uid, Instances = {} }
	myMarkers[slot] = m
	local anchor = anchorPart("PerchAnchor" .. slot, cf * CFrame.new(0, 2.5, 0), Vector3.new(6, 5, 6))
	table.insert(m.Instances, anchor)
	local uic = registry.UIController
	if stateName == "Occupied" then
		local d = data()
		local record = d and uid and d.Dragons[uid]
		local label = record and record.Name or "Dragon"
		prompt(anchor, "ViewPrompt", "View", label, Enum.KeyCode.E, 0, function()
			if uic then
				uic.Open("Inventory", { SelectId = uid, ShowDetails = true })
			end
		end)
		prompt(anchor, "TakeBackPrompt", "Take back", label, Enum.KeyCode.F, 0.6, function()
			request("TakeBack", { Id = uid }, "Back in your collection")
		end)
	elseif stateName == "Free" then
		local ring = Instance.new("Part")
		ring.Name = "FreePerch" .. slot
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.CastShadow = false
		ring.Shape = Enum.PartType.Cylinder
		ring.Material = Enum.Material.Neon
		ring.Color = Color3.fromRGB(246, 200, 120)
		ring.Transparency = 0.6
		ring.Size = Vector3.new(0.1, 9.8, 9.8)
		ring.CFrame = cf * CFrame.new(0, 0.18, 0) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = markerFolder
		table.insert(m.Instances, ring)
		m.Ring = ring
		prompt(anchor, "PlacePrompt", "Place dragon", "Perch " .. slot, Enum.KeyCode.E, 0, function()
			if uic then
				uic.Open("Inventory", { PlaceSlot = slot })
			end
		end)
	elseif stateName == "Buy" then
		local price = EconomyConfig.NestPrices[slot] or 0
		prompt(anchor, "UnlockPrompt", "Unlock (" .. Format.cash(price) .. ")", "Perch " .. slot, Enum.KeyCode.F, 0.5, function()
			request("BuyPerch", {}, "Perch unlocked!")
		end)
		local bb = Instance.new("BillboardGui")
		bb.Name = "LockSign"
		bb.Size = UDim2.fromScale(7, 1.6)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
		bb.MaxDistance = 90
		bb.LightInfluence = 0
		bb.Parent = anchor
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.TextColor3 = Color3.fromRGB(242, 208, 134)
		t.TextStrokeTransparency = 0.45
		t.Text = "LOCKED  " .. Format.cash(price)
		t.Parent = bb
	end
end

local function refreshMine()
	local plotId = myPlotId()
	local d = data()
	if not plotId or not d or not d.Nests then
		for slot in table.clone(myMarkers) do
			clearMarker(slot)
		end
		return
	end
	local unlocked = math.min(d.Nests.Unlocked or 0, PERCHES)
	for slot = 1, PERCHES do
		local uid = d.Nests.Slots and d.Nests.Slots[tostring(slot)]
		local stateName
		if uid and d.Dragons[uid] then
			stateName = "Occupied"
		elseif slot <= unlocked then
			stateName = "Free"
		elseif slot == unlocked + 1 and EconomyConfig.NestPrices[slot] then
			stateName = "Buy"
		else
			stateName = "None"
		end
		local cur = myMarkers[slot]
		if stateName == "None" then
			clearMarker(slot)
		elseif not cur or cur.State ~= stateName or cur.Uid ~= uid then
			buildMarker(plotId, slot, stateName, uid)
		end
	end
end

-- ============================================================== frame
local function step(dt: number)
	clock += dt
	checkTimer -= dt
	if checkTimer <= 0 then
		checkTimer = 0.5
		updateVisibility()
	end
	-- free perch rings breathe softly
	for _, m in myMarkers do
		if m.Ring then
			m.Ring.Transparency = 0.62 + math.sin(clock * 2.2) * 0.12
		end
	end
end

-- ============================================================== public
function PerchController.get(plotId: number, slot: number)
	return perches[key(plotId, slot)]
end

function PerchController.count(): number
	local n = 0
	for _ in perches do
		n += 1
	end
	return n
end

function PerchController.Init(reg)
	registry = reg
end

function PerchController.Start()
	local f = Instance.new("Folder")
	f.Name = "PerchDragons"
	f.Parent = Workspace
	dragonFolder = f
	local mf = Instance.new("Folder")
	mf.Name = "MyPerches"
	mf.Parent = Workspace
	markerFolder = mf
	local anim = registry.AnimationController
	if anim and anim.watchFolder then
		anim.watchFolder(f)
	end

	stateFolder = ReplicatedStorage:WaitForChild("SanctuaryState", 60)
	if stateFolder then
		for _, state in stateFolder:GetChildren() do
			local plotId = state:GetAttribute("PlotId")
			if type(plotId) == "number" then
				state.AttributeChanged:Connect(function(attr: string)
					local slot = tonumber(string.match(attr, "^Perch(%d+)$"))
					if slot then
						applyPerch(plotId, slot)
					end
				end)
			end
		end
	end

	local D = registry.DataController
	if D then
		D.observe("Nests", refreshMine)
		D.observe("Dragons", refreshMine)
	end
	LocalPlayer:GetAttributeChangedSignal("PlotId"):Connect(refreshMine)
	RunService.Heartbeat:Connect(step)
	updateVisibility()
end

return PerchController

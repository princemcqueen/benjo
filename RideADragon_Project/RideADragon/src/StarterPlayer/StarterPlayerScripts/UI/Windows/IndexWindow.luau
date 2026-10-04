--[[
	IndexWindow
	The Dragon Index (collection book): every species as a card (3D preview when found, a "?" when
	not), how many were found and which mutations, milestone rewards for the number of species found
	(paid by IndexService) and a detail panel per species. Data: data.Index / data.IndexClaims.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local DragonVisual = require(Shared:WaitForChild("Dragons"):WaitForChild("DragonVisual"))
local Animator = require(Shared:WaitForChild("Dragons"):WaitForChild("Animator"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local IndexConfig = require(Configs:WaitForChild("IndexConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors

local IndexWindow = {}
IndexWindow.__index = IndexWindow
setmetatable(IndexWindow, { __index = WindowBase })

local GOLD = Color3.fromRGB(255, 196, 48)
local GREEN = Color3.fromRGB(110, 208, 104)

-- ============================================================== 3D previews
local function buildPreview(speciesId: string)
	local ok, model = pcall(function()
		local m = DragonVisual.build(speciesId, { Saddle = false, Detail = "Medium" })
		local pose = Animator.samplePose(m, "Idle", 0.35)
		DragonVisual.pose(m, pose, CFrame.Angles(0, math.rad(150), 0))
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.CastShadow = false
			end
		end
		return m
	end)
	return ok and model or nil
end

local function frameCamera(cam: Camera, model: Model, tightness: number)
	local cf, size = model:GetBoundingBox()
	local radius = math.max(size.X, size.Y, size.Z) * 0.5 * tightness
	local dist = radius / math.tan(math.rad(cam.FieldOfView) * 0.5)
	cam.CFrame = CFrame.lookAt(cf.Position + Vector3.new(dist * 0.35, size.Y * 0.18 + dist * 0.12, dist), cf.Position + Vector3.new(0, -size.Y * 0.04, 0))
end

-- (a couple of models per frame, so opening the book never stalls)
local queue: { () -> () } = {}
local conn: RBXScriptConnection? = nil
local function enqueue(job: () -> ())
	table.insert(queue, job)
	if not conn then
		conn = RunService.Heartbeat:Connect(function()
			for _ = 1, 2 do
				local next = table.remove(queue, 1)
				if not next then
					break
				end
				next()
			end
			if #queue == 0 and conn then
				conn:Disconnect()
				conn = nil
			end
		end)
	end
end

local function viewport(parent: Instance, size: UDim2, position: UDim2): (ViewportFrame, Camera)
	local vp = Create("ViewportFrame", {
		Name = "Preview",
		BackgroundTransparency = 1,
		Position = position,
		Size = size,
		Ambient = Color3.fromRGB(150, 146, 140),
		LightColor = Color3.fromRGB(255, 244, 226),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
		Parent = parent,
	})
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vp
	vp.CurrentCamera = cam
	return vp, cam
end

local function dateText(t: number?): string
	local ok, text = pcall(os.date, "!%d.%m.%Y", t or 0)
	return ok and text or "?"
end

-- ============================================================== window
function IndexWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Index",
		Title = "Dragon Index",
		Subtitle = "Collect them all",
		Icon = "Book",
		Spec = {
			Desktop = { Width = 0.74, Height = 0.82, Aspect = 1.5 },
			Tablet = { Width = 0.94, Height = 0.86, Aspect = 1.4 },
			Phone = { Width = 0.98, Height = 1 },
			PhonePortrait = { Width = 0.98, Height = 1 },
		},
	})
	setmetatable(self, IndexWindow)
	self.UIC = ui
	self.Registry = registry
	self.Cards = {}
	self.Filter = "All"
	self.DetailOpen = false
	self:Build()
	self.OnBack = function()
		if self.DetailOpen then
			self:CloseDetail()
			return true
		end
		return false
	end
	return self
end

function IndexWindow:Data()
	local dc = self.Registry and self.Registry.DataController
	return dc and dc.all() or nil
end

function IndexWindow:Build()
	local content = self.Content

	-- top: progress and filter
	local top = Kit.frame({ Name = "Top", Size = UDim2.fromScale(1, 0.13), Parent = content })
	self.Top = top
	self.CountText = Kit.text({ Name = "Count", Text = "0 / 0", Role = "Display", Scaled = true, Color = GOLD, Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(0.22, 0.62), Parent = top })
	self.CountCaption = Kit.text({ Name = "CountCaption", Text = "FOUND", Role = "Caption", Scaled = true, Color = C.TextMuted, Position = UDim2.fromScale(0, 0.62), Size = UDim2.fromScale(0.22, 0.3), Parent = top })
	self.Bar = Kit.progress({ Name = "Bar", Color = GOLD, Color2 = GREEN, Position = UDim2.fromScale(0.24, 0.3), Size = UDim2.fromScale(0.38, 0.22), Parent = top })
	self.MutText = Kit.text({ Name = "Mutations", Text = "", Role = "Caption", Scaled = true, Color = C.TextMuted, Position = UDim2.fromScale(0.24, 0.58), Size = UDim2.fromScale(0.38, 0.3), Truncate = true, Parent = top })
	self.Seg = Kit.segmented({ Name = "Filter", Options = { "All", "Found", "Missing" }, Labels = { "ALL", "FOUND", "MISSING" }, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(0.36, 0.7), Parent = top })
	self.Seg.Changed:Connect(function(value)
		self.Filter = value
		self:ApplyFilter()
	end)

	-- milestones
	local miles = Kit.frame({ Name = "Milestones", Position = UDim2.fromScale(0, 0.14), Size = UDim2.fromScale(1, 0.13), Parent = content })
	self.Miles = miles
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = miles
	self.MileCards = {}
	local all = IndexConfig.milestones()
	for i, m in all do
		self:BuildMilestone(i, m, #all)
	end

	-- the book
	local scroll = Kit.scroll({ Name = "Book", Position = UDim2.fromScale(0, 0.29), Size = UDim2.fromScale(1, 0.71), Parent = content })
	self.Scroll = scroll
	Kit.padding(scroll, 2, 6, 6, 2)
	self.GridLayout = Instance.new("UIGridLayout")
	self.GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	self.GridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	self.GridLayout.Parent = scroll
	local order = 0
	for _, id in IndexConfig.collectable() do
		order += 1
		self:BuildCard(id, order, scroll)
	end
	for _, id in IndexConfig.exclusives() do
		order += 1
		self:BuildCard(id, order, scroll)
	end

	-- detail panel (above everything)
	self:BuildDetail()
end

function IndexWindow:BuildMilestone(i: number, m, count: number)
	local card = Kit.surface({ Name = "Mile" .. m.Count, LayoutOrder = i, StrokeColor = GOLD, StrokeTransparency = 0.6, Size = UDim2.new(1 / count, -6, 1, 0), Parent = self.Miles })
	local number = Kit.text({ Name = "Number", Text = tostring(m.Count), Role = "Display", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.04), Size = UDim2.fromScale(0.9, 0.5), Parent = card })
	local label = Kit.text({ Name = "State", Text = "", Role = "Caption", Scaled = true, XAlign = Enum.TextXAlignment.Center, Color = C.TextMuted, Position = UDim2.fromScale(0.04, 0.56), Size = UDim2.fromScale(0.92, 0.38), Truncate = true, Parent = card })
	local button = Create("TextButton", { Name = "Hit", BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = card })
	button.Activated:Connect(function()
		self:ClaimMilestone(m)
	end)
	self.MileCards[m.Count] = { Card = card, Number = number, State = label, Milestone = m }
end

-- What a milestone pays, short enough for a small card (the full list is in IndexConfig).
local function rewardText(m): string
	local kinds = 0
	local last = ""
	if m.Cash then
		kinds += 1
		last = "CASH"
	end
	if m.Spins then
		kinds += 1
		last = "SPINS"
	end
	if m.Boost then
		kinds += 1
		last = "BOOST"
	end
	if m.Egg then
		kinds += 1
		last = "EGG"
	end
	return kinds > 1 and "GIFTS" or last
end

function IndexWindow:BuildCard(id: string, order: number, parent: Instance)
	local def = DragonConfig.Species[id]
	local rarity = DragonConfig.Rarities[def.Rarity]
	local card = Kit.surface({ Name = id, LayoutOrder = order, StrokeColor = rarity.Color, StrokeTransparency = 0.55, Parent = parent })
	local holder = Kit.frame({ Name = "Holder", Position = UDim2.fromScale(0.03, 0.03), Size = UDim2.fromScale(0.94, 0.58), Parent = card })
	local mark = Kit.text({ Name = "Unknown", Text = "?", Role = "Display", Scaled = true, XAlign = Enum.TextXAlignment.Center, Color = C.TextDim, Size = UDim2.fromScale(1, 1), Parent = holder })
	local name = Kit.text({ Name = "Name", Text = "???", Role = "Heading", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.62), Size = UDim2.fromScale(0.92, 0.17), Truncate = true, Parent = card })
	local sub = Kit.text({ Name = "Sub", Text = string.upper(def.Rarity), Role = "Caption", Scaled = true, XAlign = Enum.TextXAlignment.Center, Color = rarity.Color, Position = UDim2.fromScale(0.04, 0.8), Size = UDim2.fromScale(0.92, 0.15), Truncate = true, Parent = card })
	local badge = Kit.badge({ Name = "Mut", Text = "0/16", Color = C.Panel, Transparency = 0.15, Size = UDim2.fromScale(0.42, 0.1), AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.96, 0.04), Parent = card })
	badge.Visible = false
	local hit = Create("TextButton", { Name = "Hit", BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = card })
	hit.Activated:Connect(function()
		self:OpenDetail(id)
	end)
	self.Cards[id] = { Card = card, Holder = holder, Mark = mark, Name = name, Sub = sub, Badge = badge, Species = id, Viewport = nil, Built = false, Found = false }
end

function IndexWindow:BuildDetail()
	local overlay = self.Overlay
	local dim = Create("TextButton", { Name = "DetailDim", BackgroundColor3 = Color3.fromRGB(8, 10, 20), BackgroundTransparency = 0.35, Text = "", AutoButtonColor = false, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 50, Parent = overlay })
	dim.Activated:Connect(function()
		self:CloseDetail()
	end)
	self.Dim = dim
	local panel = Kit.surface({ Name = "DetailPanel", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.86), StrokeColor = GOLD, StrokeTransparency = 0.3, Color = Color3.fromRGB(26, 28, 44), Transparency = 0.02, Parent = dim })
	panel.ZIndex = 51
	self.Panel = panel
	local pv = Kit.frame({ Name = "PreviewBox", Position = UDim2.fromScale(0.02, 0.04), Size = UDim2.fromScale(0.4, 0.92), Parent = panel })
	self.DetailView = { Box = pv }
	self.DetailName = Kit.text({ Name = "Title", Text = "", Role = "Display", Scaled = true, Position = UDim2.fromScale(0.44, 0.04), Size = UDim2.fromScale(0.52, 0.13), Truncate = true, Parent = panel })
	self.DetailSub = Kit.text({ Name = "Sub", Text = "", Role = "Label", Scaled = true, Color = C.TextMuted, Position = UDim2.fromScale(0.44, 0.17), Size = UDim2.fromScale(0.52, 0.07), Truncate = true, Parent = panel })
	self.DetailDesc = Kit.text({ Name = "Desc", Text = "", Role = "Caption", Scaled = true, Wrapped = true, Color = C.Text, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0.44, 0.25), Size = UDim2.fromScale(0.52, 0.17), Parent = panel })
	self.DetailStats = Kit.text({ Name = "Stats", Text = "", Role = "Caption", Scaled = true, Color = C.TextMuted, Position = UDim2.fromScale(0.44, 0.43), Size = UDim2.fromScale(0.52, 0.07), Truncate = true, Parent = panel })
	Kit.text({ Name = "MutTitle", Text = "MUTATIONS", Role = "Heading", Scaled = true, Position = UDim2.fromScale(0.44, 0.52), Size = UDim2.fromScale(0.52, 0.07), Parent = panel })
	local grid = Kit.frame({ Name = "Mutations", Position = UDim2.fromScale(0.44, 0.6), Size = UDim2.fromScale(0.54, 0.38), Parent = panel })
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(4, 4)
	layout.CellSize = UDim2.new(0.25, -4, 0.25, -4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	self.MutChips = {}
	for i, m in IndexConfig.mutations() do
		local chip = Kit.surface({ Name = m, LayoutOrder = i, StrokeColor = MutationConfig.Mutations[m].Color, StrokeTransparency = 0.5, Parent = grid })
		local label = Kit.text({ Name = "Label", Text = "???", Role = "Micro", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.05), Size = UDim2.fromScale(0.92, 0.9), Truncate = true, Parent = chip })
		self.MutChips[m] = { Chip = chip, Label = label }
	end
	local close = Kit.button({ Name = "DetailClose", Text = "BACK", Style = "Primary", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.985, 0.025), Size = UDim2.fromScale(0.14, 0.09), Parent = panel })
	close.Instance.ZIndex = 52
	close.Activated:Connect(function()
		self:CloseDetail()
	end)
end

-- ============================================================== layout
function IndexWindow:ApplyLayout()
	local R = Responsive
	local phone = R.Device == "Phone"
	local portrait = phone and R.Portrait
	local cols = portrait and 3 or (R.Device == "Tablet" and 5 or 6)
	local gap = R.px(8)
	if self.GridLayout then
		local rowH = R.px(portrait and 150 or (phone and 150 or 172))
		self.GridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		self.GridLayout.CellSize = UDim2.new(1 / cols, -math.ceil(gap * (cols - 1) / cols) - 1, 0, rowH)
	end
end

-- ============================================================== data
function IndexWindow:Render()
	local data = self:Data()
	if not data then
		return
	end
	local index = data.Index or {}
	local total = #IndexConfig.collectable()
	local found = IndexConfig.found(index)
	self.CountText.Text = string.format("%d / %d", found, total)
	self.Bar:SetValue(total > 0 and found / total or 0, false)
	self.MutText.Text = string.format("%d MUTATIONS FOUND", IndexConfig.totalMutations(index))
	for id, view in self.Cards do
		local entry = index[id]
		local def = DragonConfig.Species[id]
		view.Found = entry ~= nil
		view.Name.Text = entry and string.upper(def.Name) or "???"
		view.Mark.Visible = entry == nil
		local muts = IndexConfig.mutationsFound(index, id)
		view.Badge.Visible = entry ~= nil and muts > 0
		local label = view.Badge:FindFirstChild("Label")
		if label then
			label.Text = string.format("%d/%d", muts, #IndexConfig.mutations())
		end
		view.Sub.Text = entry and string.format("%s  -  x%d", string.upper(def.Rarity), entry.Count or 1) or string.upper(def.Rarity)
		if entry and not view.Built then
			view.Built = true
			enqueue(function()
				if not view.Holder.Parent then
					return
				end
				local model = buildPreview(id)
				if not model then
					return
				end
				local vp, cam = viewport(view.Holder, UDim2.fromScale(1, 1), UDim2.new())
				model.Parent = vp
				frameCamera(cam, model, 0.66)
				view.Viewport = vp
				view.Mark.Visible = false
			end)
		end
	end
	local claims = data.IndexClaims or {}
	for count, view in self.MileCards do
		local claimed = claims[tostring(count)] == true
		local ready = not claimed and found >= count
		view.State.Text = claimed and "CLAIMED" or (ready and "CLAIM!" or rewardText(view.Milestone))
		view.State.TextColor3 = claimed and GREEN or (ready and GOLD or C.TextMuted)
		view.Number.TextColor3 = claimed and GREEN or (ready and GOLD or C.Text)
		local stroke = view.Card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = ready and GOLD or (claimed and GREEN or C.Gold)
			stroke.Transparency = ready and 0.05 or 0.6
			stroke.Thickness = ready and 3 or 1
		end
	end
	self:ApplyFilter()
end

function IndexWindow:ApplyFilter()
	for _, view in self.Cards do
		local show = self.Filter == "All" or (self.Filter == "Found" and view.Found) or (self.Filter == "Missing" and not view.Found)
		view.Card.Visible = show
	end
end

function IndexWindow:ClaimMilestone(m)
	local data = self:Data()
	if not data then
		return
	end
	local claimed = data.IndexClaims and data.IndexClaims[tostring(m.Count)]
	if claimed or IndexConfig.found(data.Index) < m.Count then
		self.UIC.Notify("info", string.format("Find %d different dragons to take this reward.", m.Count))
		return
	end
	task.spawn(function()
		local res = Net.request("Index", "Claim", { Count = m.Count })
		if not res.ok then
			self.UIC.HandleResult(res)
		end
		task.wait(0.3)
		self:Render()
	end)
end

-- ============================================================== detail
function IndexWindow:OpenDetail(id: string)
	local data = self:Data()
	local index = data and data.Index or {}
	local entry = index[id]
	local def = DragonConfig.Species[id]
	local rarity = DragonConfig.Rarities[def.Rarity]
	self.DetailOpen = true
	self.Dim.Visible = true
	self.DetailName.Text = entry and string.upper(def.Name) or "???"
	self.DetailSub.Text = entry and string.format("%s  -  FOUND x%d  -  FIRST %s", string.upper(def.Rarity), entry.Count or 1, dateText(entry.First)) or (string.upper(def.Rarity) .. "  -  NOT FOUND YET")
	self.DetailSub.TextColor3 = rarity.Color
	self.DetailDesc.Text = entry and def.Description or "Hatch eggs to find this dragon."
	self.DetailStats.Text = entry and string.format("BASE  SPEED %s   FLIGHT %s   INCOME %s", Format.abbreviate(def.Speed), Format.abbreviate(def.FlightSpeed), Format.perSecond(def.Income)) or ""
	for m, chip in self.MutChips do
		local seen = index[id .. ":" .. m] ~= nil
		chip.Label.Text = seen and string.upper(MutationConfig.Mutations[m].Name) or "???"
		chip.Label.TextColor3 = seen and MutationConfig.Mutations[m].Color or C.TextDim
	end
	-- the big preview
	local box = self.DetailView.Box
	if self.DetailView.Viewport then
		self.DetailView.Viewport:Destroy()
		self.DetailView.Viewport = nil
	end
	if entry then
		enqueue(function()
			if not self.DetailOpen then
				return
			end
			local model = buildPreview(id)
			if not model then
				return
			end
			local vp, cam = viewport(box, UDim2.fromScale(1, 1), UDim2.new())
			vp.ZIndex = 52
			model.Parent = vp
			frameCamera(cam, model, 0.62)
			self.DetailView.Viewport = vp
		end)
	end
	self.DetailView.Species = id
end

function IndexWindow:CloseDetail()
	self.DetailOpen = false
	self.Dim.Visible = false
	if self.DetailView.Viewport then
		self.DetailView.Viewport:Destroy()
		self.DetailView.Viewport = nil
	end
end

function IndexWindow:OnOpen()
	self:CloseDetail()
	self:Render()
end

function IndexWindow:OnHidden()
	self:CloseDetail()
end

return IndexWindow

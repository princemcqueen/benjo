--[[
	InventoryWindow ("Dragons")
	The player's dragon collection.

	  * virtualized card grid: only the rows on screen (+1 buffer row) exist;
	    cards are pooled and re-bound while scrolling, 3D previews are built
	    through a small per-frame queue and cached per card
	  * search / rarity filter / sort (InventoryQuery - same rules as server)
	  * details panel: turntable 3D preview, rarity / mutation / state tags,
	    level + XP, stats, and every action:
	      RIDE, EQUIP, FEED, MUTATE, PLACE / TAKE BACK, LOCK, RELEASE
	  * place mode (from a sanctuary perch prompt): pick a dragon for perch n
	  * desktop / tablet: grid + details side by side; phones: the details
	    slide over the grid and the close button becomes "back"

	Open args: { SelectId?, SelectFirst?, ShowDetails?, PlaceSlot? }
	Every action is a server request; the window only renders the mirror.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local InventoryQuery = require(Shared:WaitForChild("InventoryQuery"))
local DragonVisual = require(Shared:WaitForChild("Dragons"):WaitForChild("DragonVisual"))
local Animator = require(Shared:WaitForChild("Dragons"):WaitForChild("Animator"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local Odds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Odds"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))

local C = Theme.Colors

local InventoryWindow = {}
InventoryWindow.__index = InventoryWindow
setmetatable(InventoryWindow, { __index = WindowBase })

local CARD_GAP = 10 -- px at 1080p
local FILTER_LABELS = { "All", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Exclusive" }

-- ============================================================== 3D previews
-- Builds a posed, static dragon for a ViewportFrame. Returns model, bbox cf, size.
local function buildPreview(speciesId: string, mutation: string?, yaw: number)
	local ok, model = pcall(function()
		local m = DragonVisual.build(speciesId, { Mutation = mutation, Saddle = false, Detail = "Medium" })
		local pose = Animator.samplePose(m, "Idle", 0.35)
		DragonVisual.pose(m, pose, CFrame.Angles(0, yaw, 0))
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.CastShadow = false
			end
		end
		return m
	end)
	if not ok then
		warn("[Inventory] preview failed: " .. tostring(model))
		return nil
	end
	return model
end

local function frameCamera(cam: Camera, model: Model, tightness: number, orbit: number?)
	local cf, size = model:GetBoundingBox()
	local center = cf.Position
	local radius = math.max(size.X, size.Y, size.Z) * 0.5 * tightness
	local dist = radius / math.tan(math.rad(cam.FieldOfView) * 0.5)
	local a = orbit or 0
	local offset = Vector3.new(math.sin(a) * dist, size.Y * 0.18 + dist * 0.12, math.cos(a) * dist)
	cam.CFrame = CFrame.lookAt(center + offset, center + Vector3.new(0, -size.Y * 0.04, 0))
	return center, dist, size
end

-- Shared build queue so scrolling never builds more than a couple of models per frame.
local buildQueue: { () -> () } = {}
local queueConn: RBXScriptConnection? = nil
local function enqueue(fn: () -> ())
	table.insert(buildQueue, fn)
	if not queueConn then
		queueConn = RunService.Heartbeat:Connect(function()
			for _ = 1, 2 do
				local job = table.remove(buildQueue, 1)
				if not job then
					break
				end
				job()
			end
			if #buildQueue == 0 and queueConn then
				queueConn:Disconnect()
				queueConn = nil
			end
		end)
	end
end

-- ============================================================== card
local Card = {}
Card.__index = Card

function Card.new(window)
	local self = setmetatable({}, Card)
	self.Window = window
	self.Uid = nil
	self.ModelKey = nil
	self.Token = 0
	local root = Create("TextButton", {
		Name = "Card",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.Surface,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Selectable = true,
		ClipsDescendants = false,
	})
	self.Root = root
	Kit.corner(root, "Card")
	self.Stroke = Kit.stroke(root, C.Gold, Theme.Stroke.Normal, 0.6)
	self.Scale = Create("UIScale", { Parent = root })
	-- rarity backlight
	local glow = Create("Frame", {
		Name = "Glow",
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0.72),
		Parent = root,
	})
	Kit.corner(glow, "Card")
	self.GlowGrad = Create("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = glow,
	})
	self.Glow = glow
	local vp = Create("ViewportFrame", {
		Name = "Preview",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.03, 0.03),
		Size = UDim2.fromScale(0.94, 0.62),
		Ambient = Color3.fromRGB(150, 146, 140),
		LightColor = Color3.fromRGB(255, 244, 226),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
		Parent = root,
	})
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vp
	vp.CurrentCamera = cam
	self.Viewport = vp
	self.Camera = cam
	-- placeholder icon while the 3D model builds
	local ph = Kit.frame({ Name = "Placeholder", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromScale(0.34, 0.34), SizeConstraint = Enum.SizeConstraint.RelativeXX, Parent = root })
	Icons.make("Dragon", { Color = C.TextDim, Accent = C.SurfaceHover, Ink = C.Surface }).Parent = ph
	self.Placeholder = ph
	-- level badge (top-left)
	local lvl, lvlLabel = Kit.badge({ Name = "Level", Text = "LV 1", Color = C.Panel, TextColor = C.Text, Transparency = 0.15, Size = UDim2.fromScale(0.36, 0.11), Position = UDim2.fromScale(0.05, 0.04), Parent = root })
	self.LevelLabel = lvlLabel
	self.LevelBadge = lvl
	-- state icons (top-right): equipped / placed / locked
	local icons = Kit.frame({ Name = "StateIcons", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.95, 0.04), Size = UDim2.fromScale(0.5, 0.11), Parent = root })
	Kit.list(icons, "H", 3, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local function stateIcon(name: string, icon: string, bg: Color3, order: number)
		local f = Create("Frame", {
			Name = name,
			BackgroundColor3 = bg,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			LayoutOrder = order,
			Visible = false,
			Parent = icons,
		})
		Kit.corner(f, "pill")
		local holder = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), Parent = f })
		Icons.make(icon, { Color = C.Ink, Accent = C.Ink, Ink = bg }).Parent = holder
		return f
	end
	self.EquippedIcon = stateIcon("Equipped", "Check", C.Accent, 1)
	self.PlacedIcon = stateIcon("Placed", "Home", C.Blue, 2)
	self.LockedIcon = stateIcon("Locked", "Lock", C.GoldBright, 3)
	-- mutation chip (over the preview, bottom)
	local mut, mutLabel = Kit.badge({ Name = "Mutation", Text = "", Color = C.Gold, Size = UDim2.fromScale(0.5, 0.1), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.645), Parent = root })
	self.MutationBadge = mut
	self.MutationLabel = mutLabel
	-- name + rarity / income
	self.Name = Kit.text({
		Name = "DragonName",
		Text = "",
		Role = "Label",
		Font = Theme.Fonts.Title,
		Truncate = true,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.05, 0.67),
		Size = UDim2.fromScale(0.9, 0.14),
		Parent = root,
	})
	self.Rarity = Kit.text({
		Name = "Rarity",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Position = UDim2.fromScale(0.06, 0.82),
		Size = UDim2.fromScale(0.43, 0.12),
		Truncate = true,
		Parent = root,
	})
	self.Income = Kit.text({
		Name = "Income",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = C.GoldBright,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.94, 0.82),
		Size = UDim2.fromScale(0.43, 0.12),
		Truncate = true,
		Parent = root,
	})
	root.MouseEnter:Connect(function()
		if self.Uid ~= window.SelectedId then
			self.Stroke.Transparency = 0.25
		end
		Kit.tween(self.Scale, Theme.Motion.Hover, { Scale = 1.025 })
	end)
	root.MouseLeave:Connect(function()
		self:PaintSelection()
		Kit.tween(self.Scale, Theme.Motion.Hover, { Scale = 1 })
	end)
	root.Activated:Connect(function()
		if self.Uid then
			Kit.hooks.Click()
			window:Select(self.Uid, true)
		end
	end)
	return self
end

function Card:PaintSelection()
	local selected = self.Uid ~= nil and self.Uid == self.Window.SelectedId
	local rarity = self.Record and DragonConfig.Rarities[self.Record.Rarity] or DragonConfig.Rarities.Common
	if selected then
		self.Stroke.Color = C.Accent
		self.Stroke.Transparency = 0
		self.Stroke.Thickness = math.max(2, Responsive.pxf(Theme.Stroke.Bold))
	else
		self.Stroke.Color = rarity.Color
		self.Stroke.Transparency = 0.55
		self.Stroke.Thickness = math.max(1, Responsive.pxf(Theme.Stroke.Normal))
	end
end

function Card:SetModel(record)
	local mkey = record.SpeciesId .. "|" .. (record.Mutation or "None")
	if self.ModelKey == mkey and self.Model then
		return
	end
	self.ModelKey = mkey
	if self.Model then
		self.Model:Destroy()
		self.Model = nil
	end
	self.Placeholder.Visible = true
	self.Token += 1
	local token = self.Token
	enqueue(function()
		if self.Token ~= token or not self.Root.Parent then
			return
		end
		local model = buildPreview(record.SpeciesId, record.Mutation, math.rad(180 - 32))
		if not model then
			return
		end
		if self.Token ~= token then
			model:Destroy()
			return
		end
		model.Parent = self.Viewport
		frameCamera(self.Camera, model, 0.78, 0)
		self.Model = model
		self.Placeholder.Visible = false
	end)
end

function Card:Bind(record, state)
	self.Uid = record.UniqueId
	self.Record = record
	local rarity = DragonConfig.Rarities[record.Rarity] or DragonConfig.Rarities.Common
	self.Glow.BackgroundColor3 = rarity.Color
	self.Name.Text = record.Name
	self.Rarity.Text = string.upper(record.Rarity)
	self.Rarity.TextColor3 = rarity.Glow
	self.Income.Text = "$" .. Format.abbreviate(record.IncomePerSecond, record.IncomePerSecond >= 1000 and 0 or 1) .. "/s"
	self.LevelLabel.Text = "LV " .. tostring(record.Level)
	local mutation = MutationConfig.Mutations[record.Mutation]
	if mutation and record.Mutation ~= "None" then
		self.MutationBadge.Visible = true
		self.MutationBadge.BackgroundColor3 = mutation.Color
		self.MutationLabel.Text = string.upper(mutation.Name)
	else
		self.MutationBadge.Visible = false
	end
	self.EquippedIcon.Visible = state.Equipped
	self.PlacedIcon.Visible = record.PlacedNestId ~= ""
	self.LockedIcon.Visible = record.Locked == true
	self.Root.Name = "Card_" .. record.UniqueId
	self:PaintSelection()
	self:SetModel(record)
end

function Card:Unbind()
	self.Uid = nil
	self.Record = nil
	self.Root.Visible = false
end

function Card:Destroy()
	self.Token += 1
	self.Root:Destroy()
end

-- ============================================================== window
function InventoryWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Inventory",
		Title = "Dragons",
		Icon = "Dragon",
		Spec = {
			Desktop = { Width = 0.76, Height = 0.82, Aspect = 1.72 },
			Tablet = { Width = 0.95, Height = 0.88, Aspect = 1.58 },
			Phone = { Width = 0.97, Height = 1 },
			PhonePortrait = { Width = 0.97, Height = 1 },
		},
	})
	setmetatable(self, InventoryWindow)
	self.UIC = ui
	self.Registry = registry
	self.Data = registry.DataController
	self.Query = { Search = "", Filter = "All", Sort = "Best" }
	self.List = {} -- ordered uids
	self.Cards = {} -- index -> Card (bound)
	self.Pool = {} -- free Card objects
	self.SelectedId = nil
	self.PlaceSlot = nil
	self.ShowingDetails = false
	self.Busy = false
	self:Build()
	self.OnBack = function()
		if self.Compact and self.ShowingDetails then
			self:ShowDetails(false)
			return true
		end
		return false
	end
	return self
end

-- ============================================================== build
function InventoryWindow:Build()
	local content = self.Content

	-- left: list pane
	local listPane = Kit.frame({ Name = "ListPane", Parent = content })
	self.ListPane = listPane

	local toolbar = Kit.frame({ Name = "Toolbar", Parent = listPane })
	self.Toolbar = toolbar
	self.Search = Kit.searchBox({ Name = "Search", Placeholder = "Search dragons...", Parent = toolbar })
	self.Search.Changed:Connect(function(text)
		self.Query.Search = text
		self:Rebuild(true)
	end)
	self.Filter = Kit.dropdown({
		Name = "Filter",
		Options = FILTER_LABELS,
		Value = "All",
		OverlayParent = self.Overlay,
		Parent = toolbar,
	})
	self.Filter.Changed:Connect(function(v)
		self.Query.Filter = v
		self:Rebuild(true)
	end)
	self.Sort = Kit.dropdown({
		Name = "Sort",
		Options = InventoryQuery.Sorts,
		Value = "Best",
		Prefix = "SORT: ",
		OverlayParent = self.Overlay,
		Parent = toolbar,
	})
	self.Sort.Changed:Connect(function(v)
		self.Query.Sort = v
		self:Rebuild(true)
	end)

	-- virtualized grid
	local grid = Kit.scroll({ Name = "Grid", AutoCanvas = false, Parent = listPane })
	grid.ClipsDescendants = true
	self.Grid = grid
	self.Canvas = Kit.frame({ Name = "Canvas", Size = UDim2.fromScale(1, 1), Parent = grid })
	grid:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:UpdateVisible()
	end)
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:Relayout()
	end)
	self.Empty = Kit.text({
		Name = "Empty",
		Text = "",
		Role = "Body",
		Color = C.TextMuted,
		Wrapped = true,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromScale(0.8, 0.3),
		Visible = false,
		Parent = listPane,
	})

	-- footer: capacity, perches, auto place / place mode banner
	local footer = Kit.surface({ Name = "Footer", Parent = listPane })
	self.Footer = footer
	local fpad = Kit.frame({ Name = "Pad", Size = UDim2.fromScale(1, 1), Parent = footer })
	Kit.scalePadding(fpad, 0.14, 0.015, 0.14, 0.025)
	self.CapacityText = Kit.text({ Name = "Capacity", Text = "", Role = "Label", Font = Theme.Fonts.Label, Size = UDim2.fromScale(0.3, 1), Truncate = true, Parent = fpad })
	self.PerchText = Kit.text({ Name = "Perches", Text = "", Role = "Label", Font = Theme.Fonts.Label, Color = C.TextMuted, Position = UDim2.fromScale(0.3, 0), Size = UDim2.fromScale(0.34, 1), Truncate = true, Parent = fpad })
	self.AutoPlace = Kit.button({
		Name = "AutoPlace",
		Text = "FILL PERCHES",
		Icon = "Home",
		Style = "Secondary",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromScale(0.34, 1),
		Tooltip = "Rest your best free dragons on every empty perch",
		Parent = fpad,
	})
	self.AutoPlace.Activated:Connect(function()
		self:Request("AutoPlace", {}, function(res)
			self.UIC.Notify("success", string.format("%d dragon%s now resting in your sanctuary", res.data.Placed, res.data.Placed == 1 and " is" or "s are"))
		end)
	end)
	-- place mode banner (replaces the footer contents)
	local banner = Kit.frame({ Name = "PlaceBanner", Size = UDim2.fromScale(1, 1), Visible = false, Parent = fpad })
	self.PlaceBanner = banner
	self.PlaceText = Kit.text({ Name = "Text", Text = "", Role = "Label", Font = Theme.Fonts.Label, Color = C.Accent, Size = UDim2.fromScale(0.64, 1), Truncate = true, Parent = banner })
	local cancel = Kit.button({ Name = "CancelPlace", Text = "CANCEL", Style = "Ghost", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(0.3, 1), Parent = banner })
	cancel.Activated:Connect(function()
		self:SetPlaceSlot(nil)
	end)

	self:BuildDetails()
end

function InventoryWindow:BuildDetails()
	local details = Kit.surface({ Name = "Details", Color = C.PanelLight, Transparency = 0.1, Parent = self.Content })
	self.Details = details
	-- preview
	local pv = Kit.frame({ Name = "PreviewBox", Parent = details })
	self.PreviewBox = pv
	local glow = Create("Frame", { Name = "Glow", BackgroundColor3 = C.Gold, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = pv })
	Kit.corner(glow, "Card")
	Create("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.55, 0.62),
			NumberSequenceKeypoint.new(1, 0.9),
		}),
		Parent = glow,
	})
	self.PreviewGlow = glow
	local vp = Create("ViewportFrame", {
		Name = "Preview",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Ambient = Color3.fromRGB(150, 146, 140),
		LightColor = Color3.fromRGB(255, 244, 226),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
		Parent = pv,
	})
	local cam = Instance.new("Camera")
	cam.FieldOfView = 32
	cam.Parent = vp
	vp.CurrentCamera = cam
	self.Preview = vp
	self.PreviewCam = cam
	self.Orbit = 0
	self.OrbitVel = 0.35
	-- drag to spin
	local dragging = false
	local lastX = 0
	vp.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lastX = input.Position.X
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - lastX
			lastX = input.Position.X
			self.Orbit -= dx * 0.012
			self.OrbitVel = 0
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				dragging = false
				self.OrbitVel = 0.35
			end
		end
	end)
	-- tags over the preview
	local tags = Kit.frame({ Name = "Tags", Position = UDim2.fromScale(0.04, 0.04), Size = UDim2.fromScale(0.92, 0.1), Parent = pv })
	Kit.list(tags, "H", 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	-- RNG title ("1 in 12,500,000") along the bottom of the preview
	self.OddsTitle = Kit.text({
		Name = "OddsTitle",
		Text = "",
		Role = "Title",
		Scaled = true,
		XAlign = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.04, 0.85),
		Size = UDim2.fromScale(0.92, 0.11),
		ZIndex = 3,
		Parent = pv,
	})
	self.OddsTitle.TextStrokeTransparency = 0.4
	local rb, rl = Kit.badge({ Name = "RarityTag", Text = "COMMON", LayoutOrder = 1, Parent = tags })
	rb.Size = UDim2.fromScale(0, 1)
	self.RarityTag, self.RarityTagLabel = rb, rl
	local mb, ml = Kit.badge({ Name = "MutationTag", Text = "", LayoutOrder = 2, Parent = tags })
	mb.Size = UDim2.fromScale(0, 1)
	self.MutationTag, self.MutationTagLabel = mb, ml
	local sb, sl = Kit.badge({ Name = "StateTag", Text = "", Color = C.Panel, TextColor = C.Text, Transparency = 0.2, LayoutOrder = 3, Parent = tags })
	sb.Size = UDim2.fromScale(0, 1)
	self.StateTag, self.StateTagLabel = sb, sl

	-- info
	local info = Kit.frame({ Name = "InfoBox", Parent = details })
	self.InfoBox = info
	self.DName = Kit.text({ Name = "DragonName", Text = "", Role = "Title", Truncate = true, Size = UDim2.fromScale(1, 0.1), Parent = info })
	self.DSpecies = Kit.text({ Name = "Species", Text = "", Role = "Caption", Font = Theme.Fonts.Caption, Color = C.TextMuted, Truncate = true, Position = UDim2.fromScale(0, 0.1), Size = UDim2.fromScale(1, 0.065), Parent = info })
	-- level row
	local lvlRow = Kit.frame({ Name = "LevelRow", Position = UDim2.fromScale(0, 0.18), Size = UDim2.fromScale(1, 0.075), Parent = info })
	self.LevelRow = lvlRow
	local lb, ll = Kit.badge({ Name = "LevelBadge", Text = "LV 1", Color = C.Gold, Size = UDim2.fromScale(0.2, 1), Parent = lvlRow })
	self.DLevelBadge, self.DLevel = lb, ll
	self.DXPBar = Kit.progress({ Name = "XPBar", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.23, 0.5), Size = UDim2.fromScale(0.45, 0.42), Color = C.Accent, Color2 = C.GoldBright, Parent = lvlRow })
	self.DXPText = Kit.text({ Name = "XP", Text = "", Role = "Micro", Font = Theme.Fonts.Micro, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.3, 1), Truncate = true, Parent = lvlRow })
	-- stats
	local stats = Kit.frame({ Name = "Stats", Position = UDim2.fromScale(0, 0.28), Size = UDim2.fromScale(1, 0.27), Parent = info })
	self.StatsBox = stats
	local _, sv = Kit.statRow({ Name = "SpeedStat", Icon = "Speed", Label = "SPEED", Value = "0", Size = UDim2.fromScale(1, 0.333), Parent = stats })
	local fRow, fv = Kit.statRow({ Name = "FlightStat", Icon = "Wing", Label = "FLIGHT", Value = "0", Size = UDim2.fromScale(1, 0.333), Parent = stats })
	fRow.Position = UDim2.fromScale(0, 0.333)
	local iRow, iv = Kit.statRow({ Name = "IncomeStat", Icon = "Income", Label = "INCOME", Value = "0", ValueColor = C.GoldBright, Size = UDim2.fromScale(1, 0.333), Parent = stats })
	iRow.Position = UDim2.fromScale(0, 0.666)
	self.DSpeed, self.DFlight, self.DIncome = sv, fv, iv
	for _, t in { sv, fv, iv } do
		t.TextScaled = true
		local tsc = Instance.new("UITextSizeConstraint")
		Responsive.bind(tsc, "MaxTextSize", function(R)
			return R.text("Heading")
		end)
		tsc.MinTextSize = 9
		tsc.Parent = t
	end

	-- actions
	local actions = Kit.frame({ Name = "Actions", Position = UDim2.fromScale(0, 0.58), Size = UDim2.fromScale(1, 0.42), Parent = info })
	self.Actions = actions
	local function row(y: number)
		local r = Kit.frame({ Position = UDim2.fromScale(0, y), Size = UDim2.fromScale(1, 0.3), Parent = actions })
		return r
	end
	local r1, r2, r3 = row(0), row(0.35), row(0.7)
	r1.Name, r2.Name, r3.Name = "Row1", "Row2", "Row3"
	local function btn(parent, name, text, icon, style, x, w)
		return Kit.button({ Name = name, Text = text, Icon = icon, Style = style, Position = UDim2.fromScale(x, 0), Size = UDim2.fromScale(w, 1), Parent = parent })
	end
	self.RideBtn = btn(r1, "Ride", "RIDE", "Wing", "Primary", 0, 0.49)
	self.EquipBtn = btn(r1, "Equip", "EQUIP", "Check", "Secondary", 0.51, 0.49)
	self.FeedBtn = btn(r2, "Feed", "FEED", "Food", "Secondary", 0, 0.49)
	self.MutateBtn = btn(r2, "Mutate", "MUTATE", "Sparkle", "Secondary", 0.51, 0.49)
	self.PlaceBtn = btn(r3, "Place", "PLACE", "Home", "Blue", 0, 0.38)
	self.LockBtn = btn(r3, "Lock", "", "Lock", "Secondary", 0.4, 0.2)
	self.ReleaseBtn = btn(r3, "Release", "RELEASE", "Release", "Danger", 0.62, 0.38)
	local lockHolder = self.LockBtn.IconHolder
	if lockHolder then
		self.LockIcon = lockHolder:FindFirstChildWhichIsA("Frame")
		self.UnlockIcon = Icons.make("Unlock", { Color = C.Text, Accent = C.Accent, Ink = C.Panel })
		self.UnlockIcon.Parent = lockHolder
		self.UnlockIcon.Visible = false
	end
	self.RideBtn.Activated:Connect(function()
		self:DoRide()
	end)
	self.EquipBtn.Activated:Connect(function()
		self:DoEquip()
	end)
	self.FeedBtn.Activated:Connect(function()
		self:DoFeed()
	end)
	self.MutateBtn.Activated:Connect(function()
		self:DoMutate()
	end)
	self.PlaceBtn.Activated:Connect(function()
		self:DoPlace()
	end)
	self.LockBtn.Activated:Connect(function()
		self:DoLock()
	end)
	self.ReleaseBtn.Activated:Connect(function()
		self:DoRelease()
	end)

	-- nothing selected
	self.NoSelection = Kit.text({
		Name = "NoSelection",
		Text = "Select a dragon to see its details.",
		Role = "Body",
		Color = C.TextMuted,
		Wrapped = true,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.2),
		Visible = false,
		Parent = details,
	})
end

-- ============================================================== layout
function InventoryWindow:ApplyLayout()
	if not self.ListPane then
		return
	end
	local R = Responsive
	local phone = R.Device == "Phone"
	local portrait = phone and R.Portrait
	self.Compact = phone
	-- panes
	if phone then
		self.ListPane.Position = UDim2.fromScale(0, 0)
		self.ListPane.Size = UDim2.fromScale(1, 1)
		self.Details.Position = UDim2.fromScale(0, 0)
		self.Details.Size = UDim2.fromScale(1, 1)
		self.Details.ZIndex = 5
		self.Details.Visible = self.ShowingDetails
		self.ListPane.Visible = not self.ShowingDetails
	else
		self.ListPane.Position = UDim2.fromScale(0, 0)
		self.ListPane.Size = UDim2.fromScale(0.615, 1)
		self.Details.Position = UDim2.fromScale(0.635, 0)
		self.Details.Size = UDim2.fromScale(0.365, 1)
		self.Details.Visible = true
		self.ListPane.Visible = true
	end
	-- toolbar
	local tbH = portrait and 0.12 or (phone and 0.15 or 0.075)
	self.Toolbar.Size = UDim2.fromScale(1, tbH)
	local search, filter, sort = self.Search.Instance, self.Filter.Instance, self.Sort.Instance
	if portrait then
		search.Position = UDim2.fromScale(0, 0)
		search.Size = UDim2.fromScale(1, 0.46)
		filter.Position = UDim2.fromScale(0, 0.54)
		filter.Size = UDim2.fromScale(0.43, 0.46)
		sort.Position = UDim2.fromScale(0.45, 0.54)
		sort.Size = UDim2.fromScale(0.55, 0.46)
	else
		search.Position = UDim2.fromScale(0, 0)
		search.Size = UDim2.fromScale(0.4, 1)
		filter.Position = UDim2.fromScale(0.42, 0)
		filter.Size = UDim2.fromScale(0.26, 1)
		sort.Position = UDim2.fromScale(0.7, 0)
		sort.Size = UDim2.fromScale(0.3, 1)
	end
	-- footer + grid
	local footH = portrait and 0.075 or (phone and 0.18 or 0.085)
	self.CapacityText.Visible = not phone and self.PlaceSlot == nil
	self.PerchText.Position = phone and UDim2.fromScale(0, 0) or UDim2.fromScale(0.3, 0)
	self.PerchText.Size = phone and UDim2.fromScale(0.6, 1) or UDim2.fromScale(0.34, 1)
	local fpad = self.Footer:FindFirstChild("Pad")
	local padding = fpad and fpad:FindFirstChildOfClass("UIPadding")
	if padding then
		local v = (phone and not portrait) and 0.08 or 0.14
		padding.PaddingTop = UDim.new(v, 0)
		padding.PaddingBottom = UDim.new(v, 0)
	end
	self.Footer.AnchorPoint = Vector2.new(0, 1)
	self.Footer.Position = UDim2.fromScale(0, 1)
	self.Footer.Size = UDim2.fromScale(1, footH)
	local gap = portrait and 0.015 or 0.02
	self.Grid.Position = UDim2.fromScale(0, tbH + gap)
	self.Grid.Size = UDim2.fromScale(1, 1 - tbH - footH - gap * 2)
	-- grid metrics
	if portrait then
		self.Cols, self.CardAspect = 3, 0.78
	elseif phone then
		self.Cols, self.CardAspect = 5, 0.95
	elseif R.Device == "Tablet" then
		self.Cols, self.CardAspect = 4, 0.8
	else
		self.Cols, self.CardAspect = 4, 0.8
	end
	-- details inner layout
	local function info(nameH, speciesH, levelY, levelH, statsY, statsH, actionsY, actionsH)
		self.DName.Size = UDim2.fromScale(1, nameH)
		self.DSpecies.Visible = speciesH > 0
		self.DSpecies.Position = UDim2.fromScale(0, nameH)
		self.DSpecies.Size = UDim2.fromScale(1, math.max(speciesH, 0.01))
		self.LevelRow.Position = UDim2.fromScale(0, levelY)
		self.LevelRow.Size = UDim2.fromScale(1, levelH)
		self.StatsBox.Position = UDim2.fromScale(0, statsY)
		self.StatsBox.Size = UDim2.fromScale(1, statsH)
		self.Actions.Position = UDim2.fromScale(0, actionsY)
		self.Actions.Size = UDim2.fromScale(1, actionsH)
	end
	if phone and not portrait then
		info(0.1, 0, 0.11, 0.07, 0.2, 0.24, 0.46, 0.54)
	else
		info(0.1, 0.065, 0.18, 0.075, 0.28, 0.27, 0.58, 0.42)
	end
	if phone and not portrait then
		self.PreviewBox.Position = UDim2.fromScale(0.02, 0.04)
		self.PreviewBox.Size = UDim2.fromScale(0.4, 0.92)
		self.InfoBox.Position = UDim2.fromScale(0.45, 0.04)
		self.InfoBox.Size = UDim2.fromScale(0.53, 0.92)
	elseif portrait then
		self.PreviewBox.Position = UDim2.fromScale(0.03, 0.02)
		self.PreviewBox.Size = UDim2.fromScale(0.94, 0.36)
		self.InfoBox.Position = UDim2.fromScale(0.05, 0.4)
		self.InfoBox.Size = UDim2.fromScale(0.9, 0.58)
	else
		self.PreviewBox.Position = UDim2.fromScale(0.03, 0.02)
		self.PreviewBox.Size = UDim2.fromScale(0.94, 0.4)
		self.InfoBox.Position = UDim2.fromScale(0.06, 0.44)
		self.InfoBox.Size = UDim2.fromScale(0.88, 0.54)
	end
	self:Relayout()
end

-- Recomputes card size / canvas height and rebinds visible cards.
function InventoryWindow:Relayout()
	local grid = self.Grid
	if not grid or not self.Cols then
		return
	end
	local width = grid.AbsoluteSize.X - grid.ScrollBarThickness - 2
	if width <= 0 then
		return
	end
	local gap = Responsive.px(CARD_GAP)
	local cols = self.Cols
	local cw = (width - gap * (cols - 1)) / cols
	local ch = math.floor(cw / self.CardAspect + 0.5)
	self.CellW, self.CellH, self.Gap = cw, ch, gap
	local rows = math.ceil(#self.List / cols)
	local total = math.max(0, rows * (ch + gap) - gap) + gap
	grid.CanvasSize = UDim2.fromOffset(0, total)
	self.Canvas.Size = UDim2.new(1, -(grid.ScrollBarThickness + 2), 0, total)
	-- force full rebind (positions changed)
	for i, card in self.Cards do
		self.Cards[i] = nil
		card:Unbind()
		table.insert(self.Pool, card)
	end
	self:UpdateVisible()
end

function InventoryWindow:UpdateVisible()
	if not self.CellH then
		return
	end
	local grid = self.Grid
	local stride = self.CellH + self.Gap
	local maxScroll = math.max(0, grid.CanvasSize.Y.Offset - grid.AbsoluteSize.Y)
	local y0 = math.clamp(grid.CanvasPosition.Y, 0, maxScroll)
	local y1 = y0 + grid.AbsoluteSize.Y
	local cols = self.Cols
	local firstRow = math.max(0, math.floor(y0 / stride) - 1)
	local lastRow = math.floor(y1 / stride) + 1
	local first = firstRow * cols + 1
	local last = math.min(#self.List, (lastRow + 1) * cols)
	-- recycle cards leaving the window
	for i, card in self.Cards do
		if i < first or i > last or self.List[i] ~= card.Uid then
			self.Cards[i] = nil
			card:Unbind()
			table.insert(self.Pool, card)
		end
	end
	local data = self.Data.all()
	if not data then
		return
	end
	for i = first, last do
		local uid = self.List[i]
		local record = uid and data.Dragons[uid]
		if record then
			local card = self.Cards[i]
			if not card then
				card = table.remove(self.Pool) or Card.new(self)
				self.Cards[i] = card
			end
			local idx = i - 1
			local row, col = idx // cols, idx % cols
			local root = card.Root
			root.Size = UDim2.new(1 / cols, -self.Gap * (cols - 1) / cols, 0, self.CellH)
			root.Position = UDim2.new(col / cols, col * self.Gap / cols, 0, row * stride)
			root.LayoutOrder = i
			root.Visible = true
			root.Parent = self.Canvas
			card:Bind(record, { Equipped = data.EquippedDragon == uid })
		end
	end
end

-- ============================================================== data
function InventoryWindow:Rebuild(resetScroll: boolean?)
	local data = self.Data.all()
	if not data then
		return
	end
	local dragons = data.Dragons
	if self.PlaceSlot then
		-- place mode: only dragons that can go to a perch
		local free = {}
		for uid, rec in dragons do
			if rec.PlacedNestId == "" then
				free[uid] = rec
			end
		end
		dragons = free
	end
	self.List = InventoryQuery.run(dragons, self.Query)
	if resetScroll then
		self.Grid.CanvasPosition = Vector2.zero
	end
	-- keep a valid selection
	if self.SelectedId and not data.Dragons[self.SelectedId] then
		self.SelectedId = nil
	end
	if not self.SelectedId and not self.Compact and #self.List > 0 then
		self.SelectedId = self.List[1]
	end
	local cap = EconomyConfig.upgradeValue("DragonStorage", data.Upgrades and data.Upgrades.DragonStorage or 0)
	local count = 0
	for _ in data.Dragons do
		count += 1
	end
	self.CapacityText.Text = string.format("DRAGONS  %d / %d", count, cap)
	self.CapacityText.TextColor3 = count >= cap and C.Warning or C.Text
	local unlocked = data.Nests and data.Nests.Unlocked or 0
	local used = 0
	for _ in (data.Nests and data.Nests.Slots or {}) do
		used += 1
	end
	self.PerchText.Text = string.format("PERCHES  %d / %d", used, unlocked)
	self.AutoPlace:SetEnabled(used < unlocked and count > 1)
	self:SetSubtitle(string.format("%d / %d", count, cap))
	if #self.List == 0 then
		self.Empty.Visible = true
		if count == 0 then
			self.Empty.Text = "No dragons yet. Hatch eggs in your sanctuary nest!"
		elseif self.PlaceSlot then
			self.Empty.Text = "Every dragon is already resting on a perch."
		else
			self.Empty.Text = "No dragons match your search."
		end
	else
		self.Empty.Visible = false
	end
	self:Relayout()
	self:RefreshDetails()
end

-- ============================================================== selection / details
function InventoryWindow:Select(uid: string?, fromUser: boolean?)
	self.SelectedId = uid
	for _, card in self.Cards do
		card:PaintSelection()
	end
	self:RefreshDetails()
	if self.Compact and uid and fromUser then
		self:ShowDetails(true)
	end
end

function InventoryWindow:ShowDetails(show: boolean)
	self.ShowingDetails = show
	if self.Compact then
		self.Details.Visible = show
		self.ListPane.Visible = not show
	end
end

function InventoryWindow:SetPreview(record)
	local key = record and (record.SpeciesId .. "|" .. record.Mutation) or nil
	if key == self.PreviewKey then
		return
	end
	self.PreviewKey = key
	if self.PreviewModel then
		self.PreviewModel:Destroy()
		self.PreviewModel = nil
	end
	if not record then
		return
	end
	self.PreviewToken = (self.PreviewToken or 0) + 1
	local token = self.PreviewToken
	enqueue(function()
		if self.PreviewToken ~= token then
			return
		end
		local model = buildPreview(record.SpeciesId, record.Mutation, math.rad(180 - 30))
		if not model then
			return
		end
		if self.PreviewToken ~= token then
			model:Destroy()
			return
		end
		model.Parent = self.Preview
		self.PreviewModel = model
		self.PreviewFocus, self.PreviewDist, self.PreviewSize = frameCamera(self.PreviewCam, model, 0.66, self.Orbit)
	end)
end

local function setCost(button, base: string, cost: number?, affordable: boolean)
	if cost then
		button:SetText(base .. "  " .. Format.cash(cost))
	else
		button:SetText(base)
	end
	local _ = affordable
end

function InventoryWindow:RefreshDetails()
	local data = self.Data.all()
	local record = data and self.SelectedId and data.Dragons[self.SelectedId] or nil
	local hasRecord = record ~= nil
	self.PreviewBox.Visible = hasRecord
	self.InfoBox.Visible = hasRecord
	self.NoSelection.Visible = not hasRecord
	if not record then
		self:SetPreview(nil)
		return
	end
	local rarity = DragonConfig.Rarities[record.Rarity] or DragonConfig.Rarities.Common
	local species = DragonConfig.Species[record.SpeciesId]
	local mutation = MutationConfig.Mutations[record.Mutation] or MutationConfig.Mutations.None
	local equipped = data.EquippedDragon == record.UniqueId
	local placed = record.PlacedNestId ~= ""
	local riding = Players.LocalPlayer:GetAttribute("Riding") == true and equipped

	self:SetPreview(record)
	self.PreviewGlow.BackgroundColor3 = rarity.Color
	self.RarityTag.BackgroundColor3 = rarity.Color
	self.RarityTagLabel.Text = string.upper(record.Rarity)
	local odds = Odds.ofRecord(record)
	local exclusive = Odds.isExclusive(record.SpeciesId)
	self.OddsTitle.Text = Odds.format(odds, exclusive)
	self.OddsTitle.TextColor3 = exclusive and rarity.Glow or Odds.color(odds)
	if record.Mutation ~= "None" then
		self.MutationTag.Visible = true
		self.MutationTag.BackgroundColor3 = mutation.Color
		self.MutationTagLabel.Text = string.upper(mutation.Name) .. "  x" .. tostring(mutation.Multiplier)
	else
		self.MutationTag.Visible = false
	end
	local stateText = nil
	if riding then
		stateText = "RIDING"
	elseif equipped then
		stateText = "EQUIPPED"
	elseif placed then
		stateText = "ON PERCH " .. record.PlacedNestId
	end
	self.StateTag.Visible = stateText ~= nil
	self.StateTagLabel.Text = stateText or ""

	self.DName.Text = record.Name
	self.DName.TextColor3 = C.Text
	self.DSpecies.Text = species and species.Description or ""
	self.DLevel.Text = "LV " .. record.Level
	local maxed = record.Level >= DragonConfig.MaxLevel
	if maxed then
		self.DXPBar:SetValue(1)
		self.DXPText.Text = "MAX LEVEL"
	else
		local need = DragonConfig.xpToNext(record.Level)
		self.DXPBar:SetValue(record.XP / need, true)
		self.DXPText.Text = Format.abbreviate(record.XP) .. " / " .. Format.abbreviate(need) .. " XP"
	end
	self.DSpeed.Text = Format.abbreviate(record.Speed)
	self.DFlight.Text = Format.abbreviate(record.FlightSpeed)
	self.DIncome.Text = Format.perSecond(record.IncomePerSecond)

	local cash = data.Cash or 0
	-- ride / equip
	self.RideBtn:SetText(riding and "RIDING" or "RIDE")
	self.RideBtn:SetEnabled(not riding)
	self.EquipBtn:SetText(equipped and "EQUIPPED" or "EQUIP")
	self.EquipBtn:SetEnabled(not equipped)
	-- feed
	local feedCost = not maxed and EconomyConfig.feedCost(species.FeedCost, record.Level) or nil
	setCost(self.FeedBtn, maxed and "MAX LEVEL" or "FEED", feedCost, feedCost ~= nil and cash >= feedCost)
	self.FeedBtn:SetEnabled(feedCost ~= nil and cash >= feedCost)
	-- mutate
	local maxMut = MutationConfig.rank(record.Mutation) >= MutationConfig.MaxRank
	local mutCost = not maxMut and MutationConfig.cost(species.Income, record.Mutation) or nil
	setCost(self.MutateBtn, maxMut and "MAX MUTATION" or "MUTATE", mutCost, mutCost ~= nil and cash >= mutCost)
	self.MutateBtn:SetEnabled(mutCost ~= nil and cash >= mutCost)
	-- place / take back
	if placed then
		self.PlaceBtn:SetText("TAKE BACK")
		self.PlaceBtn:SetStyle("Secondary")
	elseif self.PlaceSlot then
		self.PlaceBtn:SetText("PLACE HERE")
		self.PlaceBtn:SetStyle("Gold")
	else
		self.PlaceBtn:SetText("PLACE")
		self.PlaceBtn:SetStyle("Blue")
	end
	self.PlaceBtn:SetEnabled(not riding)
	-- lock / release
	self.LockBtn:SetStyle(record.Locked and "Gold" or "Secondary")
	if self.LockIcon and self.UnlockIcon then
		self.LockIcon.Visible = record.Locked == true
		self.UnlockIcon.Visible = record.Locked ~= true
	end
	self.ReleaseBtn:SetEnabled(not record.Locked and not riding)
end

-- ============================================================== actions
-- Sends a Dragon request with busy handling; onOk(res) runs on success.
function InventoryWindow:Request(action: string, payload, onOk: ((any) -> ())?, domain: string?)
	if self.Busy then
		return
	end
	self.Busy = true
	task.spawn(function()
		local res = Net.request(domain or "Dragon", action, payload)
		self.Busy = false
		if self.UIC.HandleResult(res) and onOk then
			onOk(res)
		end
		self:RefreshDetails()
	end)
end

function InventoryWindow:Selected()
	local data = self.Data.all()
	return data and self.SelectedId and data.Dragons[self.SelectedId] or nil, data
end

function InventoryWindow:DoEquip()
	local record = self:Selected()
	if not record then
		return
	end
	local uid = record.UniqueId
	if record.PlacedNestId ~= "" then
		self:Request("TakeBack", { Id = uid }, function()
			self:Request("Equip", { Id = uid }, function()
				self.UIC.Notify("success", record.Name .. " equipped")
			end)
		end)
		return
	end
	self:Request("Equip", { Id = uid }, function()
		self.UIC.Notify("success", record.Name .. " equipped")
	end)
end

function InventoryWindow:DoRide()
	local record, data = self:Selected()
	if not record then
		return
	end
	local uid = record.UniqueId
	local function ride()
		self:Request("Ride", {}, function()
			self.UIC.Close()
		end, "Mount")
	end
	local function equipThenRide()
		if data.EquippedDragon == uid then
			ride()
		else
			self:Request("Equip", { Id = uid }, ride)
		end
	end
	if record.PlacedNestId ~= "" then
		self:Request("TakeBack", { Id = uid }, equipThenRide)
	else
		equipThenRide()
	end
end

function InventoryWindow:DoFeed()
	local record = self:Selected()
	if not record then
		return
	end
	self:Request("Feed", { Id = record.UniqueId }, function(res)
		local audio = self.Registry.AudioController
		if audio then
			audio.playUI("Click")
		end
		if res.data and res.data.Levels and res.data.Levels > 0 then
			self.UIC.Notify("rare", string.format("%s reached level %d!", record.Name, res.data.Level))
			self.DLevelBadge.Size = UDim2.fromScale(0.24, 1.2)
			Kit.tween(self.DLevelBadge, 0.35, { Size = UDim2.fromScale(0.2, 1) }, Enum.EasingStyle.Back)
		end
	end)
end

function InventoryWindow:DoMutate()
	local record, data = self:Selected()
	if not record then
		return
	end
	local species = DragonConfig.Species[record.SpeciesId]
	local cost = MutationConfig.cost(species.Income, record.Mutation)
	local chance = MutationConfig.improveChance(record.Mutation)
	local uid = record.UniqueId
	task.spawn(function()
		if cost >= EconomyConfig.ConfirmMinimum and cost >= (data.Cash or 0) * EconomyConfig.ConfirmFraction then
			local yes = self.UIC.Confirm({
				Title = "Mutate " .. record.Name .. "?",
				Body = string.format("Costs %s. %s chance of a better mutation - it can never get worse.", Format.cash(cost), Format.percent(chance)),
				ConfirmText = "Mutate",
			})
			if not yes then
				return
			end
		end
		self:Request("Mutate", { Id = uid }, function(res)
			local d = res.data or {}
			if d.Improved then
				local m = MutationConfig.Mutations[d.Mutation]
				self.UIC.Notify("rare", string.format("%s mutation! %s is now x%s", m and m.Name or d.Mutation, record.Name, tostring(m and m.Multiplier or 1)))
			else
				self.UIC.Notify("info", "No new mutation this time - try again!")
			end
		end)
	end)
end

function InventoryWindow:DoPlace()
	local record = self:Selected()
	if not record then
		return
	end
	if record.PlacedNestId ~= "" then
		self:Request("TakeBack", { Id = record.UniqueId }, function()
			self.UIC.Notify("success", record.Name .. " is back in your collection")
		end)
		return
	end
	local payload = { Id = record.UniqueId, Slot = self.PlaceSlot }
	self:Request("Place", payload, function(res)
		local slot = res.data and res.data.Slot
		self.UIC.Notify("success", string.format("%s is resting on perch %s", record.Name, tostring(slot or "")))
		if self.PlaceSlot then
			self:SetPlaceSlot(nil)
			self.UIC.Close()
		end
	end)
end

function InventoryWindow:DoLock()
	local record = self:Selected()
	if not record then
		return
	end
	self:Request("Lock", { Id = record.UniqueId, Locked = not record.Locked })
end

function InventoryWindow:DoRelease()
	local record = self:Selected()
	if not record then
		return
	end
	local refund = math.floor(record.IncomePerSecond * EconomyConfig.ReleaseRefundSeconds + 0.5)
	local uid = record.UniqueId
	task.spawn(function()
		local yes = self.UIC.Confirm({
			Title = "Release " .. record.Name .. "?",
			Body = string.format("It flies back to the wild for good. You receive %s.", Format.cash(refund)),
			ConfirmText = "Release",
			Danger = true,
		})
		if yes then
			self:Request("Release", { Id = uid }, function(res)
				self.UIC.Notify("info", string.format("%s flew away  (+%s)", record.Name, Format.cash(res.data and res.data.Refund or 0)))
			end)
		end
	end)
end

function InventoryWindow:SetPlaceSlot(slot: number?)
	self.PlaceSlot = slot
	self.PlaceBanner.Visible = slot ~= nil
	self.CapacityText.Visible = slot == nil and not self.Compact
	self.PerchText.Visible = slot == nil
	self.AutoPlace:SetVisible(slot == nil)
	if slot then
		self.PlaceText.Text = string.format("CHOOSE A DRAGON FOR PERCH %d", slot)
	end
	self:Rebuild(true)
end

-- ============================================================== lifecycle
function InventoryWindow:ApplyArgs(args)
	args = args or {}
	self:SetPlaceSlot(args.PlaceSlot)
	if args.SelectId then
		self.SelectedId = args.SelectId
	elseif args.SelectFirst then
		self.SelectedId = self.List[1]
	end
	self:Rebuild(false)
	if args.SelectId then
		-- scroll the selected card into view
		local idx = table.find(self.List, args.SelectId)
		if idx and self.CellH then
			local row = (idx - 1) // self.Cols
			self.Grid.CanvasPosition = Vector2.new(0, math.max(0, row * (self.CellH + self.Gap) - self.Gap))
		end
	end
	self:Select(self.SelectedId, false)
	self:ShowDetails(self.Compact and args.ShowDetails == true and self.SelectedId ~= nil)
	if not self.Compact then
		self:ShowDetails(false)
	end
end

function InventoryWindow:OnOpen(args)
	self:ApplyLayout()
	self:ApplyArgs(args)
	task.defer(function()
		if self.Root.Visible then
			self:Relayout()
		end
	end)
	if not self._observing then
		self._observing = true
		local D = self.Data
		local pending = false
		local function changed()
			if pending or not self.Root.Visible then
				return
			end
			pending = true
			task.defer(function()
				pending = false
				if self.Root.Visible then
					self:Rebuild(false)
				end
			end)
		end
		for _, k in { "Dragons", "EquippedDragon", "Nests", "Cash", "Upgrades" } do
			D.changed(k):Connect(changed)
		end
		Players.LocalPlayer:GetAttributeChangedSignal("Riding"):Connect(function()
			if self.Root.Visible then
				self:RefreshDetails()
			end
		end)
		-- turntable
		RunService.RenderStepped:Connect(function(dt)
			if not self.Root.Visible or not self.PreviewModel or not self.PreviewFocus then
				return
			end
			if not self.Details.Visible then
				return
			end
			self.Orbit += self.OrbitVel * dt
			local cam = self.PreviewCam
			local d = self.PreviewDist
			local size = self.PreviewSize
			local a = self.Orbit
			cam.CFrame = CFrame.lookAt(self.PreviewFocus + Vector3.new(math.sin(a) * d, size.Y * 0.18 + d * 0.12, math.cos(a) * d), self.PreviewFocus + Vector3.new(0, -size.Y * 0.04, 0))
		end)
	end
end

function InventoryWindow:OnReopen(args)
	self:ApplyArgs(args)
end

function InventoryWindow:OnHidden()
	for _, d in { self.Filter, self.Sort } do
		d.Close()
	end
end

return InventoryWindow

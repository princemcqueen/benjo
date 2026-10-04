--[[
	Hud
	Minimal HUD:
	  TOP LEFT      level badge + XP bar
	  TOP CENTER    cash (+ egg storage and income rate)
	  LEFT          Dragons / Index / Quests       (desktop)
	  RIGHT         Shop / Daily / Settings        (desktop)
	  BOTTOM CENTER current dragon (name, level, speed) + ride button
	                (above it: the egg in your hand, with a "put away" button)
	  BOTTOM RIGHT  boost meter + speed while riding
	  TOP RIGHT     objective tracker (tutorial / quest)

	Phones get a different layout: fewer side buttons (Dragons, Shop, More)
	stacked on the right edge away from the thumbstick, bigger touch targets.

	All clusters are sized relative to the SHORT side of the screen
	(SizeConstraint RelativeYY in landscape / RelativeXX in portrait) so the
	HUD keeps the same physical proportion on 720p, ultrawide and 4K.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local MobileControls = require(script.Parent:WaitForChild("MobileControls"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Format = require(Shared.Util.Format)
local MathUtil = require(Shared.Util.MathUtil)
local DragonConfig = require(Configs.DragonConfig)
local EconomyConfig = require(Configs.EconomyConfig)
local MonetizationConfig = require(Configs.MonetizationConfig)
local TreeConfig = require(Configs.TreeConfig)
local BondConfig = require(Configs.BondConfig)

local C = Theme.Colors
local H = Theme.Hud

local Hud = {}
Hud.__index = Hud

local LEFT_BUTTONS = {
	{ Id = "Inventory", Text = "DRAGONS", Icon = "Dragon", Key = "G" },
	{ Id = "Index", Text = "INDEX", Icon = "Book", Key = "X" },
	{ Id = "Quests", Text = "QUESTS", Icon = "Scroll", Key = "Q" },
	{ Id = "Teleport", Text = "TELEPORT", Icon = "Map", Key = "T" },
}
local RIGHT_BUTTONS = {
	{ Id = "Shop", Text = "SHOP", Icon = "Bag", Key = "B" },
	{ Id = "Daily", Text = "DAILY", Icon = "Gift", Key = "J" },
	{ Id = "Settings", Text = "SETTINGS", Icon = "Gear", Key = "P" },
}
-- Dragon Bond ability chips (desktop bond bar)
local ABILITY_CHIPS = {
	{ Id = "Dash", Key = "Q", Name = "DASH" },
	{ Id = "Fire", Key = "E", Name = "FIRE" },
	{ Id = "Flourish", Key = "Z", Name = "DANCE" },
}
local PHONE_BUTTONS = { "Inventory", "Shop", "More" }
local MORE_ITEMS = { "Teleport", "Index", "Quests", "Daily", "Settings" }

local function short(): number
	return math.min(Responsive.Width, Responsive.Height)
end

-- Size relative to the short side of the screen.
local function shortSize(inst: GuiObject, w: number, h: number)
	inst.SizeConstraint = Responsive.Portrait and Enum.SizeConstraint.RelativeXX or Enum.SizeConstraint.RelativeYY
	inst.Size = UDim2.fromScale(w, h)
end

function Hud.new(ui, registry)
	local self = setmetatable({}, Hud)
	self.UI = ui
	self.Registry = registry
	self.Data = registry.DataController
	self.Root = ui.Layers.GameHUD.Root
	self.Buttons = {}
	self.DisplayedCash = 0
	self.TargetCash = 0

	self:BuildLevel()
	self:BuildCash()
	self:BuildSideButtons()
	self:BuildCurrentDragon()
	self:BuildHeldEgg()
	self:BuildRidePanel()
	self:BuildBondBar()
	self:BuildObjective()
	self.Mobile = MobileControls.new(self.Root, registry)
	self:Layout()

	Responsive.Changed:Connect(function()
		self:Layout()
	end)
	ui.WindowOpened:Connect(function(name)
		self:SetActiveButton(name)
	end)
	ui.WindowClosed:Connect(function()
		self:SetActiveButton(nil)
	end)
	self:BindData()
	return self
end

-- ============================================================== level
function Hud:BuildLevel()
	local root = Kit.frame({ Name = "Level", Parent = self.Root })
	root:SetAttribute("QARegion", "HudLevel")
	self.LevelRoot = root
	local capsule = Create("Frame", {
		Name = "Capsule",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.1, 0.5),
		Size = UDim2.fromScale(0.9, 0.78),
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(capsule, "pill")
	Kit.stroke(capsule, H.Stroke, Theme.Stroke.Hairline, H.StrokeTransparency)
	local badge = Create("Frame", {
		Name = "Badge",
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = root,
	})
	Kit.corner(badge, "pill")
	Kit.stroke(badge, H.Stroke, Theme.Stroke.Bold, H.StrokeTransparency)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), H.Shade), Parent = badge })
	self.LevelText = Kit.text({
		Color = H.Text,
		Name = "Value",
		Text = "1",
		Role = "Heading",
		Font = Theme.Fonts.Number,
		XAlign = Enum.TextXAlignment.Center,
		Parent = badge,
	})
	local info = Kit.frame({ Name = "Info", Position = UDim2.fromScale(0.29, 0.16), Size = UDim2.fromScale(0.64, 0.68), Parent = root })
	self.LevelLabel = Kit.text({
		Name = "Label",
		Text = "LEVEL 1",
		Role = "Label",
		Font = Theme.Fonts.Label,
		Color = H.Text,
		Size = UDim2.fromScale(0.6, 0.5),
		Parent = info,
	})
	self.XPText = Kit.text({
		Name = "XP",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = H.TextMuted,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.4, 0.5),
		Parent = info,
	})
	self.XPBar = Kit.progress({
		Name = "XPBar",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.32),
		Color = C.Accent,
		Color2 = C.GoldBright,
		Track = H.Track,
		Parent = info,
	})
end

-- ============================================================== cash
function Hud:BuildCash()
	local root = Kit.frame({ Name = "Cash", AnchorPoint = Vector2.new(0.5, 0), Parent = self.Root })
	root:SetAttribute("QARegion", "HudCash")
	self.CashRoot = root
	local pill = Create("Frame", {
		Name = "Pill",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0, 0.62),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(pill, "pill")
	Kit.stroke(pill, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), H.Shade), Parent = pill })
	Kit.padding(pill, 0, 22, 0, 8)
	Kit.list(pill, "H", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local coinBox = Kit.frame({ Name = "Coin", Size = UDim2.fromScale(0.78, 0.78), SizeConstraint = Enum.SizeConstraint.RelativeYY, LayoutOrder = 1, Parent = pill })
	Icons.make("Coin").Parent = coinBox
	self.CashText = Kit.text({
		Name = "Amount",
		Text = "$0",
		Role = "Number",
		Font = Theme.Fonts.Number,
		Color = H.Text,
		Size = UDim2.fromScale(0, 0.86),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = pill,
	})
	self.CashPill = pill
	self.CashScale = Create("UIScale", { Parent = pill })

	-- secondary row: eggs + income
	local row = Kit.frame({ Name = "Secondary", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(1, 0.32), Parent = root })
	Kit.list(row, "H", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	self.PillRow = row
	self.PillScale = Create("UIScale", { Parent = row }) -- shrinks the row on phones when many pills are lit
	local function smallPill(name: string, icon: string, order: number)
		local p = Create("TextButton", {
			Name = name,
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = H.Panel,
			BackgroundTransparency = H.Transparency,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = row,
		})
		Kit.corner(p, "pill")
		Kit.stroke(p, H.Stroke, Theme.Stroke.Hairline, H.StrokeTransparency)
		Kit.padding(p, 0, 12, 0, 6)
		Kit.list(p, "H", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		local ib = Kit.frame({ Size = UDim2.fromScale(0.72, 0.72), SizeConstraint = Enum.SizeConstraint.RelativeYY, LayoutOrder = 1, Parent = p })
		Icons.make(icon, { Color = H.Icon, Accent = C.Success }).Parent = ib
		local t = Kit.text({ Color = H.Text, Text = "", Role = "Label", Font = Theme.Fonts.Label, Size = UDim2.fromScale(0, 1), AutoSize = Enum.AutomaticSize.X, LayoutOrder = 2, Parent = p })
		return p, t
	end
	self.EggPill, self.EggText = smallPill("Eggs", "Egg", 1)
	self.IncomePill, self.IncomeText = smallPill("Income", "Income", 2)
	self.EggPill.Activated:Connect(function()
		Kit.hooks.Click()
		self.UI.Toggle("EggStorage")
	end)
	-- active boosts (Owner pass luck, potions): tap to open the shop
	self.LuckPill, self.LuckText = smallPill("Luck", "Clover", 3)
	self.CashBoostPill, self.CashBoostText = smallPill("CashBoost", "Coin", 4)
	-- egg hunting perks (Egg Magnet / Fast Hatch potions, the Egg Hunter pass): one pill
	self.HuntPill, self.HuntText = smallPill("Hunt", "Magnet", 5)
	self.LuckText.TextColor3 = Color3.fromRGB(46, 150, 70)
	self.CashBoostText.TextColor3 = C.AccentDeep
	self.HuntText.TextColor3 = Color3.fromRGB(214, 112, 40)
	self.LuckPill.Visible = false
	self.CashBoostPill.Visible = false
	self.HuntPill.Visible = false
	for _, pill in { self.LuckPill, self.CashBoostPill, self.HuntPill } do
		pill.Activated:Connect(function()
			Kit.hooks.Click()
			self.UI.Open("Shop")
		end)
	end
end

local function mmss(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
	end
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Phones have little width: the icon already says "luck" / "cash", so the word is dropped there.
local function boostText(value: string, word: string, left: number): string
	local text = Responsive.Device == "Phone" and value or (value .. " " .. word)
	return left < math.huge and (text .. "  " .. mmss(left)) or text
end

-- "HUNTER + FAST HATCH + MAGNET" on a wide screen, "HUNTER +2" on a phone with three perks.
local function huntText(names: { string }, left: number): string
	local text
	if Responsive.Device == "Phone" then
		if #names > 2 then
			text = names[1] .. " +" .. tostring(#names - 1)
		else
			text = table.concat(names, " + "):gsub("FAST HATCH", "HATCH")
		end
	else
		text = table.concat(names, " + ")
	end
	return left < math.huge and (text .. "  " .. mmss(left)) or text
end

-- Many lit pills do not fit on a phone: the row shrinks a little instead of running off the screen.
local PILL_FIT = { 1, 1, 1, 0.9, 0.8, 0.72 }
function Hud:FitPills()
	local lit = 0
	for _, pill in { self.EggPill, self.IncomePill, self.LuckPill, self.CashBoostPill, self.HuntPill } do
		if pill.Visible then
			lit += 1
		end
	end
	self.PillScale.Scale = Responsive.Device == "Phone" and PILL_FIT[math.clamp(lit, 1, #PILL_FIT)] or 1
end

-- UI Lab: every boost pill with sample text (the longest case), whatever the data says.
function Hud:PreviewBoosts(on: boolean)
	self._previewBoosts = on
	self:RefreshBoosts()
	if not on then
		self:RefreshIncome()
	end
end

function Hud:RefreshBoosts()
	if self._previewBoosts then
		self.LuckPill.Visible = true
		self.LuckText.Text = boostText("x6", "LUCK", 842)
		self.CashBoostPill.Visible = true
		self.CashBoostText.Text = boostText("x2", "CASH", 581)
		self.HuntPill.Visible = true
		self.HuntText.Text = huntText({ "HUNTER", "FAST HATCH", "MAGNET" }, 860)
		self.IncomePill.Visible = true
		self:FitPills()
		return
	end
	local data = self.Data.all()
	if not data then
		return
	end
	local now = workspace:GetServerTimeNow()
	local luck, luckLeft = 1, math.huge
	local cash, cashLeft = 1, math.huge
	luck *= MonetizationConfig.passLuck(data)
	luck *= 1 + TreeConfig.bonus(data, "RollLuck") -- Great Tree: Roll Luck
	for id, t in data.Boosts or {} do
		local def = MonetizationConfig.Boosts[id]
		local left = (tonumber(t) or 0) - now
		if def and left > 0 then
			if def.Luck then
				luck *= def.Luck
				luckLeft = math.min(luckLeft, left)
			end
			if def.Cash then
				cash *= def.Cash
				cashLeft = math.min(cashLeft, left)
			end
		end
	end
	self.LuckPill.Visible = luck > 1
	if luck > 1 then
		self.LuckText.Text = boostText("x" .. tostring(math.floor(luck * 10 + 0.5) / 10), "LUCK", luckLeft)
	end
	self.CashBoostPill.Visible = cash > 1
	if cash > 1 then
		self.CashBoostText.Text = boostText("x" .. tostring(cash), "CASH", cashLeft)
	end
	-- egg hunting: what is running (the radar has its own chip), the shortest timer
	local hunt, huntLeft = {}, math.huge
	for id, t in data.Boosts or {} do
		local def = MonetizationConfig.Boosts[id]
		local left = (tonumber(t) or 0) - now
		if def and left > 0 and (def.Magnet or def.HatchFactor) then
			table.insert(hunt, def.Magnet and "MAGNET" or "FAST HATCH")
			huntLeft = math.min(huntLeft, left)
		end
	end
	table.sort(hunt)
	for id, pass in MonetizationConfig.GamePasses do
		if pass.Kind == "Tool" and MonetizationConfig.ownsPass(data, id) then
			table.insert(hunt, 1, "HUNTER")
		end
	end
	self.HuntPill.Visible = #hunt > 0
	if #hunt > 0 then
		self.HuntText.Text = huntText(hunt, huntLeft)
	end
	self:FitPills()
end

function Hud:PopCash(delta: number)
	if delta <= 0 then
		return
	end
	local label = Kit.text({
		Name = "Pop",
		Text = "+" .. Format.cash(delta),
		Role = "Heading",
		Font = Theme.Fonts.Number,
		Color = C.GoldBright,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromScale(1, 0.4),
		Parent = self.CashRoot,
	})
	label.TextStrokeTransparency = 0.6
	local start = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local a = (os.clock() - start) / 0.9
		if a >= 1 then
			conn:Disconnect()
			label:Destroy()
			return
		end
		label.Position = UDim2.fromScale(0.5, 0.62 + 0.55 * MathUtil.smoothstep(a))
		label.TextTransparency = a < 0.6 and 0 or (a - 0.6) / 0.4
		label.TextStrokeTransparency = 0.6 + 0.4 * a
	end)
end

-- ============================================================== side buttons
function Hud:BuildSideButtons()
	self.LeftColumn = Kit.frame({ Name = "LeftButtons", AnchorPoint = Vector2.new(0, 0.5), Parent = self.Root })
	self.LeftColumn:SetAttribute("QARegion", "HudLeft")
	self.RightColumn = Kit.frame({ Name = "RightButtons", AnchorPoint = Vector2.new(1, 0.5), Parent = self.Root })
	self.RightColumn:SetAttribute("QARegion", "HudRight")
	self.LeftList = Kit.list(self.LeftColumn, "V", 12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	self.RightList = Kit.list(self.RightColumn, "V", 12, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)

	local function make(def, order)
		local b = Kit.hudButton({
			Name = def.Id,
			Text = def.Text,
			Icon = def.Icon,
			Tooltip = def.Key and (def.Text .. "  [" .. def.Key .. "]") or nil,
			Size = UDim2.fromScale(1, 1 / 3.6),
			LayoutOrder = order,
		})
		b.Activated:Connect(function()
			if def.Id == "More" then
				self:ToggleMore()
			else
				self:HideMore()
				self.UI.Toggle(def.Id)
			end
		end)
		self.Buttons[def.Id] = b
		return b
	end
	for i, def in LEFT_BUTTONS do
		make(def, i).Instance.Parent = self.LeftColumn
	end
	for i, def in RIGHT_BUTTONS do
		make(def, i).Instance.Parent = self.RightColumn
	end
	make({ Id = "More", Text = "MORE", Icon = "Plus" }, 9)

	-- phone "More" popover
	local more = Create("Frame", {
		Name = "MorePopover",
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Visible = false,
		Parent = self.Root,
	})
	Kit.corner(more, 14)
	Kit.stroke(more, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Kit.padding(more, 8)
	Kit.list(more, "H", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	self.MorePopover = more
	self.MoreButtons = {}
	for i, id in MORE_ITEMS do
		local def
		for _, d in LEFT_BUTTONS do
			if d.Id == id then
				def = d
			end
		end
		for _, d in RIGHT_BUTTONS do
			if d.Id == id then
				def = d
			end
		end
		local b = Kit.hudButton({ Name = "More" .. id, Text = def.Text, Icon = def.Icon, Size = UDim2.fromScale(1, 1), LayoutOrder = i, Parent = more })
		b.Activated:Connect(function()
			self:HideMore()
			self.UI.Toggle(id)
		end)
		self.MoreButtons[id] = b
	end
end

function Hud:ToggleMore()
	self.MorePopover.Visible = not self.MorePopover.Visible
end

function Hud:HideMore()
	self.MorePopover.Visible = false
end

function Hud:SetActiveButton(name: string?)
	for id, b in self.Buttons do
		b:SetActive(id == name)
	end
end

function Hud:SetBadge(id: string, count: number?)
	local b = self.Buttons[id]
	if b then
		b:SetBadge(count)
	end
	local mb = self.MoreButtons and self.MoreButtons[id]
	if mb then
		mb:SetBadge(count)
	end
	-- "More" shows the sum of hidden badges on phones
	if self.MoreButtons and self.MoreButtons[id] then
		self._moreBadges = self._moreBadges or {}
		self._moreBadges[id] = count or 0
		local total = 0
		for _, v in self._moreBadges do
			total += v
		end
		if self.Buttons.More then
			self.Buttons.More:SetBadge(total)
		end
	end
end

-- ============================================================== current dragon
function Hud:BuildCurrentDragon()
	local root = Create("Frame", {
		Name = "CurrentDragon",
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Parent = self.Root,
	})
	root:SetAttribute("QARegion", "HudDragon")
	Kit.corner(root, 16)
	Kit.stroke(root, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), H.Shade), Parent = root })
	self.DragonCard = root

	local portrait = Create("Frame", {
		Name = "Portrait",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.03, 0.5),
		Size = UDim2.fromScale(0.74, 0.74),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = H.Track,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(portrait, "pill")
	self.PortraitStroke = Kit.stroke(portrait, H.Stroke, Theme.Stroke.Bold, H.StrokeTransparency)
	self.Portrait = portrait
	local pIcon = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), Parent = portrait })
	self.PortraitIcon = Icons.make("Dragon")
	self.PortraitIcon.Parent = pIcon

	local info = Kit.frame({ Name = "Info", Position = UDim2.fromScale(0.25, 0.14), Size = UDim2.fromScale(0.43, 0.72), Parent = root })
	self.DragonName = Kit.text({
		Color = H.Text,
		Name = "Name",
		Text = "No dragon",
		Role = "Heading",
		Truncate = true,
		Size = UDim2.fromScale(1, 0.55),
		Parent = info,
	})
	local meta = Kit.frame({ Name = "Meta", Position = UDim2.fromScale(0, 0.58), Size = UDim2.fromScale(1, 0.42), Parent = info })
	Kit.list(meta, "H", 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local lvl, lvlLabel = Kit.badge({ Name = "LevelBadge", Text = "LV 1", Color = C.Gold, Size = nil, LayoutOrder = 1, Parent = meta })
	lvl.Size = UDim2.fromScale(0, 0.95)
	self.DragonLevel = lvlLabel
	local speedBox = Kit.frame({ Name = "Speed", Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Parent = meta })
	Kit.list(speedBox, "H", 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local sIcon = Kit.frame({ Size = UDim2.fromScale(0.8, 0.8), SizeConstraint = Enum.SizeConstraint.RelativeYY, LayoutOrder = 1, Parent = speedBox })
	Icons.make("Speed", { Color = H.Icon, Accent = C.Accent }).Parent = sIcon
	self.DragonSpeed = Kit.text({ Text = "0", Role = "Label", Font = Theme.Fonts.Number, Color = H.Text, Size = UDim2.fromScale(0, 1), AutoSize = Enum.AutomaticSize.X, LayoutOrder = 2, Parent = speedBox })

	self.RideButton = Kit.button({
		Name = "Ride",
		Text = "RIDE",
		Style = "Primary",
		Icon = "Wing",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.965, 0.5),
		Size = UDim2.fromScale(0.28, 0.62),
		Tooltip = "Ride / Dismount  [R]",
		Parent = root,
	})
	self.RideKey = Kit.keycap({
		Key = "R",
		Role = "Micro",
		Size = UDim2.fromScale(0.5, 0.5),
		LayoutOrder = 0,
		ZIndex = 3,
		Parent = self.RideButton.Instance:FindFirstChild("Content"),
	})
	self.RideButton.Activated:Connect(function()
		local dc = self.Registry.DragonController
		if dc then
			dc.toggleRide()
		end
	end)
end

-- ============================================================== egg in hand
-- Chip above the dragon card while an egg is carried: which egg, and a button that puts
-- it back into the bag (HeldEggController owns the state).
function Hud:BuildHeldEgg()
	local root = Create("Frame", {
		Name = "HeldEgg",
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Visible = false,
		Parent = self.Root,
	})
	root:SetAttribute("QARegion", "HudHeldEgg")
	Kit.corner(root, 16)
	self.HeldStroke = Kit.stroke(root, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	self.HeldCard = root
	local disc = Create("Frame", {
		Name = "Disc",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.035, 0.5),
		Size = UDim2.fromScale(0.74, 0.74),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = H.Track,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(disc, "pill")
	self.HeldDisc = disc
	local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.64, 0.64), Parent = disc })
	Icons.make("Egg", { Color = H.Icon, Accent = C.Accent }).Parent = iconBox
	local info = Kit.frame({ Name = "Info", Position = UDim2.fromScale(0.24, 0.1), Size = UDim2.fromScale(0.46, 0.8), Parent = root })
	Kit.text({ Name = "Title", Text = "IN YOUR HAND", Role = "Micro", Font = Theme.Fonts.Micro, Color = H.TextMuted, Size = UDim2.fromScale(1, 0.28), Truncate = true, Parent = info })
	self.HeldName = Kit.text({ Name = "Name", Text = "", Role = "Heading", Color = H.Text, Position = UDim2.fromScale(0, 0.28), Size = UDim2.fromScale(1, 0.42), Truncate = true, Parent = info })
	self.HeldHint = Kit.text({
		Name = "Hint",
		Text = "Carry it to your nest",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = H.TextMuted,
		Position = UDim2.fromScale(0, 0.72),
		Size = UDim2.fromScale(1, 0.28),
		Truncate = true,
		Parent = info,
	})
	self.HeldButton = Kit.button({
		Name = "PutAway",
		Text = "PUT AWAY",
		TextRole = "Micro",
		Style = "Secondary",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.97, 0.5),
		Size = UDim2.fromScale(0.26, 0.62),
		Parent = root,
	})
	self.HeldButton.Activated:Connect(function()
		local hc = self.Registry.HeldEggController
		if hc then
			hc.putAway()
		end
	end)
end

-- info = { Id, Type, Name, Luck, Glow } or nil (empty hand).
function Hud:SetHeldEgg(info)
	self.HeldInfo = info
	if info then
		self.HeldName.Text = info.Luck > 1 and string.format("%s  x%d", info.Name, info.Luck) or info.Name
		self.HeldDisc.BackgroundColor3 = info.Glow:Lerp(Color3.new(1, 1, 1), 0.6)
		self.HeldStroke.Color = info.Glow:Lerp(H.Stroke, 0.45)
	end
	self.HeldCard.Visible = info ~= nil and not self.Riding
end

-- ============================================================== ride panel (speed + boost)
function Hud:BuildRidePanel()
	local root = Create("Frame", {
		Name = "RidePanel",
		AnchorPoint = Vector2.new(1, 1),
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Visible = false,
		Parent = self.Root,
	})
	root:SetAttribute("QARegion", "HudRide")
	Kit.corner(root, 16)
	Kit.stroke(root, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Kit.padding(root, 10, 16, 12, 16)
	self.RidePanel = root
	self.SpeedValue = Kit.text({
		Color = H.Text,
		Name = "Speed",
		Text = "0",
		Role = "Display",
		Font = Theme.Fonts.Number,
		XAlign = Enum.TextXAlignment.Right,
		Size = UDim2.fromScale(0.68, 0.56),
		Parent = root,
	})
	Kit.text({
		Name = "Unit",
		Text = "KM/H",
		Role = "Label",
		Font = Theme.Fonts.Label,
		Color = H.TextMuted,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0.14),
		Size = UDim2.fromScale(0.29, 0.4),
		Parent = root,
	})
	local boostRow = Kit.frame({ Name = "BoostRow", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.34), Parent = root })
	local bIcon = Kit.frame({ Size = UDim2.fromScale(1, 1), SizeConstraint = Enum.SizeConstraint.RelativeYY, Parent = boostRow })
	Icons.make("Wind", { Color = C.BlueDeep, Accent = H.Icon }).Parent = bIcon
	self.BoostBar = Kit.progress({
		Name = "Boost",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromScale(0.8, 0.5),
		Color = C.BlueDeep,
		Color2 = C.Blue,
		Track = H.Track,
		Parent = boostRow,
	})
	self.BoostBar:SetValue(1)
end

-- Dragon Bond bar (desktop, above the ride panel): bond level, progress to the next
-- level / perk, and the three ability chips with their cooldowns.
function Hud:BuildBondBar()
	local root = Create("Frame", {
		Name = "BondBar",
		AnchorPoint = Vector2.new(1, 1),
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Visible = false,
		Parent = self.Root,
	})
	root:SetAttribute("QARegion", "HudBond")
	Kit.corner(root, 16)
	Kit.stroke(root, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Kit.padding(root, 8, 14, 8, 14)
	self.BondBar = root
	self.BondTitle = Kit.text({ Name = "Title", Text = "BOND LV 0", Role = "Label", Font = Theme.Fonts.Number, Color = H.Text, Size = UDim2.fromScale(0.42, 0.3), Truncate = true, Parent = root })
	self.BondNext = Kit.text({
		Name = "Next",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = H.TextMuted,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.58, 0.3),
		Truncate = true,
		Parent = root,
	})
	self.BondProgress = Kit.progress({ Name = "Progress", Position = UDim2.fromScale(0, 0.36), Size = UDim2.fromScale(1, 0.13), Color = C.Accent, Color2 = C.GoldBright, Track = H.Track, Parent = root })
	self.BondChips = {}
	for i, def in ABILITY_CHIPS do
		local chip = Create("Frame", {
			Name = "Chip" .. def.Id,
			BackgroundColor3 = H.Track,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Position = UDim2.fromScale((i - 1) * 0.345, 0.58),
			Size = UDim2.fromScale(0.31, 0.42),
			ClipsDescendants = true,
			Parent = root,
		})
		Kit.corner(chip, 10)
		local cool = Create("Frame", {
			Name = "Cooldown",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0),
			BackgroundColor3 = C.Blue,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			Parent = chip,
		})
		local label = Kit.text({ Name = "Label", Text = def.Key .. "  " .. def.Name, Role = "Micro", Font = Theme.Fonts.Micro, Color = H.Text, XAlign = Enum.TextXAlignment.Center, Scaled = true, ZIndex = 2, Parent = chip })
		self.BondChips[def.Id] = { Frame = chip, Cooldown = cool, Label = label, Def = def }
	end
end

-- info = BondController.info(); called ~10x/s while riding.
function Hud:SetBond(info)
	self.BondInfo = info
	if not self.BondBar then
		return
	end
	self.BondTitle.Text = string.format("BOND LV %d", info.Level)
	self.BondProgress:SetValue(info.Need > 0 and info.Into / info.Need or 1)
	if info.NextPerk then
		self.BondNext.Text = string.format("%s  LV %d", info.NextPerk.Name, info.NextPerk.Level)
	else
		self.BondNext.Text = "ALL PERKS"
	end
	for id, chip in self.BondChips do
		local unlocked = info.Unlocked[id]
		chip.Label.Text = unlocked and (chip.Def.Key .. "  " .. chip.Def.Name) or ("LV " .. tostring(BondConfig.PerkById[id].Level))
		chip.Label.TextColor3 = unlocked and H.Text or H.TextMuted
		chip.Frame.BackgroundTransparency = unlocked and 0.1 or 0.55
		chip.Cooldown.Size = UDim2.fromScale(1, unlocked and (info.Cooldown[id] or 0) or 0)
	end
	if self.Mobile then
		self.Mobile:SetPerks(info)
	end
end

-- Arena duels (CombatController): touch buttons + their cooldown fills.
function Hud:SetArena(on: boolean)
	self.InArena = on
	if self.Mobile then
		self.Mobile:SetArena(on)
	end
end

function Hud:SetArenaCooldowns(strike01: number, blast01: number)
	if self.Mobile then
		self.Mobile:SetCooldowns(strike01, blast01)
	end
end

function Hud:SetRiding(riding: boolean)
	self.RidePanel.Visible = riding and Responsive.Device == "Desktop"
	self.Mobile:SetVisible(riding)
	if riding then
		self.RideButton:SetText("DISMOUNT")
		self.RideButton:SetStyle("Secondary")
	else
		self.RideButton:SetText("RIDE")
		self.RideButton:SetStyle("Primary")
	end
	self.Riding = riding
	self:Layout()
end

-- Riding mode label for touch controls (Ground | Air | Takeoff | Fly | Landing).
function Hud:SetRideMode(mode: string)
	self.Mobile:SetMode(mode)
end

function Hud:SetFlightStats(speedStudsPerSecond: number, boost01: number, boosting: boolean)
	self.Mobile:SetStats(speedStudsPerSecond, boost01, boosting)
	self.SpeedValue.Text = tostring(Format.kmh(speedStudsPerSecond))
	self.BoostBar:SetValue(boost01)
	if boosting ~= self._boosting then
		self._boosting = boosting
		if boosting then
			self.BoostBar:SetColors(C.Accent, C.GoldBright)
		else
			self.BoostBar:SetColors(C.BlueDeep, C.Blue)
		end
	end
end

-- ============================================================== objective tracker
function Hud:BuildObjective()
	local root = Create("Frame", {
		Name = "Objective",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
		Visible = false,
		Parent = self.Root,
	})
	root:SetAttribute("QARegion", "HudObjective")
	Kit.corner(root, 14)
	local stroke = Kit.stroke(root, C.Accent, Theme.Stroke.Normal, 0.3)
	self.ObjectiveStroke = stroke
	Kit.padding(root, 8, 14, 8, 12)
	local bar = Create("Frame", {
		Name = "Accent",
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 3, 1, 0),
		Parent = root,
	})
	Kit.corner(bar, "pill")
	self.ObjectiveCaption = Kit.text({
		Name = "Caption",
		Text = "OBJECTIVE",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = C.Accent,
		Position = UDim2.fromScale(0.05, 0),
		Size = UDim2.fromScale(0.7, 0.3),
		Parent = root,
	})
	self.ObjectiveDistance = Kit.text({
		Name = "Distance",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = H.TextMuted,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.3, 0.3),
		Parent = root,
	})
	self.ObjectiveText = Kit.text({
		Color = H.Text,
		Name = "Text",
		Text = "",
		Role = "Label",
		Font = Theme.Fonts.Label,
		Position = UDim2.fromScale(0.05, 0.3),
		Size = UDim2.fromScale(0.95, 0.38),
		Truncate = true,
		Parent = root,
	})
	self.ObjectiveHint = Kit.text({
		Name = "Hint",
		Text = "",
		Role = "Micro",
		Font = Theme.Fonts.Caption,
		Color = H.TextMuted,
		Position = UDim2.fromScale(0.05, 0.7),
		Size = UDim2.fromScale(0.95, 0.3),
		Truncate = true,
		Parent = root,
	})
	self.Objective = root
end

function Hud:SetObjective(text: string?, hint: string?, caption: string?)
	if not text or text == "" then
		self.Objective.Visible = false
		return
	end
	self.Objective.Visible = true
	self.ObjectiveText.Text = text
	self.ObjectiveHint.Text = hint or ""
	self.ObjectiveCaption.Text = caption or "OBJECTIVE"
end

function Hud:SetObjectiveDistance(studs: number?)
	if studs then
		self.ObjectiveDistance.Text = tostring(math.floor(studs * 0.28 + 0.5)) .. " M"
	else
		self.ObjectiveDistance.Text = ""
	end
end

-- ============================================================== layout
function Hud:Layout()
	local R = Responsive
	local S = short()
	local margin = math.floor(S * (R.Device == "Phone" and 0.03 or 0.022) + 0.5)
	local top = R.TopInset + math.floor(S * 0.012)
	local phone = R.Device == "Phone"
	local portrait = R.Portrait

	-- level (top-left, below the Roblox top bar)
	self.LevelRoot.Position = UDim2.new(0, margin, 0, top)
	shortSize(self.LevelRoot, phone and 0.36 or 0.235, phone and 0.095 or 0.058)

	-- cash (top-center)
	self.CashRoot.Position = UDim2.new(0.5, 0, 0, phone and (portrait and top + math.floor(S * 0.12) or math.floor(S * 0.03)) or math.floor(S * 0.022))
	shortSize(self.CashRoot, phone and 0.6 or 0.5, phone and 0.15 or 0.105)

	-- pills under the cash: on a portrait phone nothing else is at that height, so they may use the full width
	self.PillRow.Size = (phone and portrait) and UDim2.new(0, R.Width - 2 * margin, 0.32, 0) or UDim2.fromScale(1, 0.32)
	self:FitPills()

	-- side buttons
	local btnH = phone and 0.15 or 0.074
	local gap = math.floor(S * (phone and 0.02 or 0.012))
	self.LeftList.Padding = UDim.new(0, gap)
	self.RightList.Padding = UDim.new(0, gap)
	for _, b in self.Buttons do
		-- square-ish button filling the column width (column is sized from the short side)
		b.Instance.SizeConstraint = Enum.SizeConstraint.RelativeXX
		b.Instance.Size = UDim2.fromScale(1, 1)
	end
	for _, b in self.MoreButtons do
		b.Instance.SizeConstraint = Enum.SizeConstraint.RelativeYY
		b.Instance.Size = UDim2.fromScale(1, 1)
	end
	if phone then
		-- right edge, upper half: Dragons, Shop, More (hidden while riding:
		-- the thumb area belongs to the riding controls)
		self.LeftColumn.Visible = false
		self.RightColumn.Visible = not self.Riding
		for _, def in LEFT_BUTTONS do
			self.Buttons[def.Id].Instance.Visible = def.Id == "Inventory"
		end
		for _, def in RIGHT_BUTTONS do
			self.Buttons[def.Id].Instance.Visible = def.Id == "Shop"
		end
		for i, id in PHONE_BUTTONS do
			local b = self.Buttons[id].Instance
			b.Parent = self.RightColumn
			b.LayoutOrder = i
			b.Visible = true
		end
		self.RightColumn.AnchorPoint = Vector2.new(1, 0)
		self.RightColumn.Position = UDim2.new(1, -margin, 0, portrait and top + math.floor(S * 0.35) or top + math.floor(S * 0.04))
		self.RightList.VerticalAlignment = Enum.VerticalAlignment.Top
		shortSize(self.RightColumn, btnH * 0.95, btnH * 3 + 0.06)
		-- More popover sits to the left of the column
		self.MorePopover.Position = UDim2.new(1, -(margin + math.floor(S * btnH * 0.92) + gap), 0, self.RightColumn.Position.Y.Offset + math.floor(S * (btnH * 2 + 0.04)))
		shortSize(self.MorePopover, btnH * #MORE_ITEMS + 0.02 * #MORE_ITEMS, btnH + 0.035)
	else
		self.LeftColumn.Visible = true
		self.RightColumn.Visible = true
		for _, def in LEFT_BUTTONS do
			local b = self.Buttons[def.Id].Instance
			b.Parent = self.LeftColumn
			b.Visible = true
		end
		for i, def in RIGHT_BUTTONS do
			local b = self.Buttons[def.Id].Instance
			b.Parent = self.RightColumn
			b.LayoutOrder = i
			b.Visible = true
		end
		self.Buttons.Inventory.Instance.LayoutOrder = 1
		self.Buttons.Shop.Instance.LayoutOrder = 1
		self.Buttons.More.Instance.Visible = false
		self.MorePopover.Visible = false
		self.LeftColumn.AnchorPoint = Vector2.new(0, 0.5)
		self.LeftColumn.Position = UDim2.new(0, margin, 0.5, 0)
		self.RightColumn.AnchorPoint = Vector2.new(1, 0.5)
		self.RightColumn.Position = UDim2.new(1, -margin, 0.5, 0)
		self.RightList.VerticalAlignment = Enum.VerticalAlignment.Center
		shortSize(self.LeftColumn, btnH * 0.95, btnH * #LEFT_BUTTONS + 0.017 * #LEFT_BUTTONS)
		shortSize(self.RightColumn, btnH * 0.95, btnH * 3 + 0.05)
	end

	-- current dragon (bottom-center)
	if phone then
		self.DragonCard.AnchorPoint = Vector2.new(0.5, 0)
		if portrait then
			self.DragonCard.Position = UDim2.new(0.5, 0, 0, top + math.floor(S * 0.27))
		else
			self.DragonCard.Position = UDim2.new(0.5, 0, 0, math.floor(S * 0.03) + math.floor(S * 0.17))
		end
		shortSize(self.DragonCard, 0.62, 0.115)
		self.DragonCard.Visible = not self.Riding
	else
		self.DragonCard.AnchorPoint = Vector2.new(0.5, 1)
		self.DragonCard.Position = UDim2.new(0.5, 0, 1, -margin)
		shortSize(self.DragonCard, 0.44, 0.082)
		-- touch devices ride with the touch cluster bottom-right instead
		self.DragonCard.Visible = not (self.Riding and R.isMobile())
	end

	-- egg in hand: above the dragon card (phones: right below it)
	if phone then
		self.HeldCard.AnchorPoint = Vector2.new(0.5, 0)
		self.HeldCard.Position = UDim2.new(0.5, 0, 0, self.DragonCard.Position.Y.Offset + math.floor(S * 0.115) + math.floor(S * 0.012))
		shortSize(self.HeldCard, 0.62, 0.1)
	else
		self.HeldCard.AnchorPoint = Vector2.new(0.5, 1)
		self.HeldCard.Position = UDim2.new(0.5, 0, 1, -(margin + math.floor(S * 0.082) + math.floor(S * 0.012)))
		shortSize(self.HeldCard, 0.4, 0.07)
	end
	self.HeldCard.Visible = self.HeldInfo ~= nil and not self.Riding

	self.RideKey.Visible = not R.isMobile()
	self.XPText.Visible = not phone
	local iconHolder = self.RideButton.IconHolder
	if iconHolder then
		iconHolder.Visible = R.isMobile()
	end

	-- ride panel (bottom-right)
	self.RidePanel.Position = UDim2.new(1, -margin, 1, -margin)
	shortSize(self.RidePanel, 0.22, 0.105)
	self.RidePanel.Visible = (self.Riding == true) and not R.isMobile()
	-- bond bar: right above the ride panel (desktop)
	self.BondBar.AnchorPoint = Vector2.new(1, 1)
	self.BondBar.Position = UDim2.new(1, -margin, 1, -(margin + math.floor(S * 0.105) + math.floor(S * 0.012)))
	shortSize(self.BondBar, 0.26, 0.092)
	self.BondBar.Visible = (self.Riding == true) and not R.isMobile()
	self.Mobile:Layout()
	self.Mobile:SetVisible(self.Riding == true)

	-- objective tracker
	if phone then
		self.Objective.AnchorPoint = Vector2.new(0, 0)
		self.Objective.Position = UDim2.new(0, margin, 0, top + math.floor(S * (portrait and 0.11 or 0.11)))
		shortSize(self.Objective, portrait and 0.6 or 0.5, 0.13)
	else
		self.Objective.AnchorPoint = Vector2.new(1, 0)
		self.Objective.Position = UDim2.new(1, -margin, 0, top)
		shortSize(self.Objective, 0.33, 0.082)
	end
end

-- ============================================================== data
function Hud:RefreshEquipped()
	local data = self.Data.all()
	if not data then
		return
	end
	local uid = data.EquippedDragon
	local record = uid ~= "" and data.Dragons[uid] or nil
	if record then
		local rarity = DragonConfig.Rarities[record.Rarity]
		self.DragonName.Text = record.Name
		self.DragonLevel.Text = Format.level(record.Level)
		self.DragonSpeed.Text = Format.abbreviate(record.FlightSpeed)
		self.PortraitStroke.Color = rarity and rarity.Color or C.Gold
		self.DragonName.TextColor3 = H.Text
		self.RideButton:SetEnabled(true)
	else
		-- every dragon rests on a perch: RIDE brings the strongest one down
		local owned = next(data.Dragons or {}) ~= nil
		self.DragonName.Text = owned and "No dragon out" or "No dragon equipped"
		self.DragonName.TextColor3 = H.TextMuted
		self.DragonLevel.Text = "-"
		self.DragonSpeed.Text = "0"
		self.RideButton:SetEnabled(owned)
	end
end

function Hud:RefreshIncome()
	local data = self.Data.all()
	if not data then
		return
	end
	local total = 0
	for _, uid in data.Nests.Slots do
		local record = data.Dragons[uid]
		if record then
			total += record.IncomePerSecond
		end
	end
	self.IncomeText.Text = Format.perSecond(total)
	self.IncomePill.Visible = total > 0
	self:FitPills()
end

function Hud:RefreshEggs()
	local data = self.Data.all()
	if not data then
		return
	end
	local cap = TreeConfig.eggCapacity(data)
	local n = #data.Eggs
	self.EggText.Text = string.format("EGGS %d/%d", n, cap)
	self.EggText.TextColor3 = n >= cap and C.Danger or H.Text
end

function Hud:RefreshLevel()
	local data = self.Data.all()
	if not data then
		return
	end
	local need = EconomyConfig.playerXPToNext(data.Level)
	self.LevelText.Text = tostring(data.Level)
	self.LevelLabel.Text = "LEVEL " .. tostring(data.Level)
	self.XPText.Text = Format.abbreviate(data.XP) .. " / " .. Format.abbreviate(need) .. " XP"
	self.XPBar:SetValue(math.clamp(data.XP / need, 0, 1), true)
end

function Hud:SetCashTarget(value: number, animate: boolean)
	local delta = value - self.TargetCash
	self.TargetCash = value
	if not animate then
		self.DisplayedCash = value
		self.CashText.Text = Format.cash(value)
		return
	end
	if delta > 0 then
		self:PopCash(delta)
		self.CashScale.Scale = 1.06
	end
	if self._cashConn then
		return
	end
	self._cashConn = RunService.RenderStepped:Connect(function(dt)
		self.DisplayedCash = MathUtil.expDecay(self.DisplayedCash, self.TargetCash, 12, dt)
		self.CashScale.Scale = MathUtil.expDecay(self.CashScale.Scale, 1, 10, dt)
		if math.abs(self.DisplayedCash - self.TargetCash) < math.max(0.5, math.abs(self.TargetCash) * 0.0005) then
			self.DisplayedCash = self.TargetCash
			self.CashScale.Scale = 1
			self._cashConn:Disconnect()
			self._cashConn = nil
		end
		self.CashText.Text = Format.cash(self.DisplayedCash)
	end)
end

function Hud:BindData()
	local D = self.Data
	D.observe("Cash", function(cash)
		self:SetCashTarget(cash or 0, self._cashInit == true)
		self._cashInit = true
	end)
	D.observe("Level", function()
		self:RefreshLevel()
	end)
	D.observe("XP", function()
		self:RefreshLevel()
	end)
	D.observe("EquippedDragon", function()
		self:RefreshEquipped()
	end)
	D.observe("Dragons", function()
		self:RefreshEquipped()
		self:RefreshIncome()
	end)
	D.observe("Nests", function()
		self:RefreshIncome()
	end)
	D.observe("Eggs", function()
		self:RefreshEggs()
	end)
	D.observe("Upgrades", function()
		self:RefreshEggs()
	end)
	D.observe("Boosts", function()
		self:RefreshBoosts()
	end)
	D.observe("Flags", function()
		self:RefreshBoosts()
	end)
	task.spawn(function()
		while self.Root and self.Root.Parent do
			pcall(function()
				self:RefreshBoosts()
			end)
			task.wait(1)
		end
	end)
	-- the egg in hand may already exist when the HUD appears
	local held = self.Registry.HeldEggController
	if held and held.updateHud then
		held.updateHud()
	end
end

return Hud

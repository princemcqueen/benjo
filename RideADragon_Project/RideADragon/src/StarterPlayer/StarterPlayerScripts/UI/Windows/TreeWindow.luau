--[[
	TreeWindow (the Great Tree skill tree)
	Five categories (tabs: Luck, Wealth, Flight, Nest, Bond) with 3-5 branches each.
	Every branch is a row: its icon, name and current bonus, then a scrolling strip
	of 8-12 level nodes joined by a vine. Levels are bought strictly in order:
	owned nodes are filled with the branch colour and a check, the next node pulses
	when you can afford it, later nodes are locked. Tap a node to inspect it; the
	strip at the bottom shows what it gives and buys it. All prices and bonuses
	come from TreeConfig; the server validates every purchase (TreeService).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors

local TreeWindow = {}
TreeWindow.__index = TreeWindow
setmetatable(TreeWindow, { __index = WindowBase })

local SPEC = {
	Desktop = { Width = 0.7, Height = 0.8, Aspect = 1.55 },
	Tablet = { Width = 0.92, Height = 0.86, Aspect = 1.5 },
	Phone = { Width = 0.98, Height = 1 },
	PhonePortrait = { Width = 0.98, Height = 1 },
}

local WHITE = Color3.new(1, 1, 1)
local CELL = 84 -- design px of one level cell
local ROW = 104 -- design px of one branch row
local HEAD = 214 -- design px of the branch head (icon + name)

local function px(n: number)
	return Responsive.px(n)
end

local function iconDisc(parent: Instance, icon: string, color: Color3, props)
	local disc = Kit.frame({
		Name = "IconDisc",
		BackgroundTransparency = 0,
		BackgroundColor3 = color,
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = parent,
	})
	for k, v in props do
		(disc :: any)[k] = v
	end
	Kit.corner(disc, 999)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(color:Lerp(WHITE, 0.25), color:Lerp(Color3.new(0, 0, 0), 0.2)), Parent = disc })
	local box = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), Parent = disc })
	Icons.make(icon, { Color = C.Ink, Accent = C.Text, Ink = color }).Parent = box
	return disc
end

function TreeWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Tree",
		Title = "Great Tree",
		Subtitle = "Permanent upgrades",
		Icon = "Clover",
		Spec = SPEC,
	})
	setmetatable(self, TreeWindow)
	self.UIC = ui
	self.Registry = registry
	self.Data = registry.DataController
	self.Rows = {} -- [branchId] = { Row, Strip, Nodes, Now, Next, Branch }
	self.Category = TreeConfig.Categories[1].Id
	self.Selected = nil -- { Id, Level }
	self.Busy = false
	self:Build()
	return self
end

-- ============================================================== build
function TreeWindow:Build()
	local content = self.Content

	-- top strip: category tabs + progress + cash
	local top = Kit.frame({ Name = "Top", Parent = content })
	Responsive.bind(top, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(34))
	end)
	local ids, labels = {}, {}
	for _, cat in TreeConfig.Categories do
		table.insert(ids, cat.Id)
		table.insert(labels, string.upper(cat.Name))
	end
	self.Tabs = Kit.segmented({
		Name = "Tabs",
		Options = ids,
		Labels = labels,
		Position = UDim2.fromScale(0, 0),
		Size = UDim2.fromScale(0.56, 1),
		Parent = top,
	})
	self.Tabs.Changed:Connect(function(v)
		self:ShowCategory(v)
	end)
	self.TotalText = Kit.text({
		Name = "Total",
		Text = "",
		Role = "Caption",
		Color = C.TextMuted,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.77, 0),
		Size = UDim2.fromScale(0.2, 1),
		Truncate = true,
		Parent = top,
	})
	self.CashText = Kit.text({
		Name = "Cash",
		Text = "$0",
		Role = "Heading",
		Color = C.GoldBright,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.22, 1),
		Truncate = true,
		Parent = top,
	})

	-- branch rows (vertical scroll when the window is short, e.g. phones)
	local scroll = Kit.scroll({ Name = "Branches", Parent = content })
	self.Scroll = scroll
	Kit.list(scroll, "V", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	Responsive.bind(scroll, "Position", function(R)
		return UDim2.new(0, 0, 0, R.px(42))
	end)
	Responsive.bind(scroll, "Size", function(R)
		return UDim2.new(1, 0, 1, -(R.px(42) + R.px(86)))
	end)
	for _, cat in TreeConfig.Categories do
		for i, branch in cat.Branches do
			self:BuildRow(scroll, branch, i)
		end
	end

	-- detail strip
	local detail = Kit.surface({ Name = "Detail", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Parent = content })
	self.Detail = detail
	Responsive.bind(detail, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(78))
	end)
	self.DetailDisc = iconDisc(detail, "Clover", C.Gold, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromScale(0.62, 0.62) })
	self.DetailTitle = Kit.text({ Name = "Title", Text = "", Role = "Heading", Position = UDim2.fromScale(0.085, 0.12), Size = UDim2.fromScale(0.56, 0.36), Truncate = true, Parent = detail })
	self.DetailBody = Kit.text({ Name = "Body", Text = "", Role = "Caption", Color = C.TextMuted, Position = UDim2.fromScale(0.085, 0.5), Size = UDim2.fromScale(0.56, 0.36), Truncate = true, Parent = detail })
	self.BuyButton = Kit.button({
		Name = "Buy",
		Text = "BUY",
		Style = "Gold",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromScale(0.3, 0.64),
		Parent = detail,
	})
	self.BuyButton.Activated:Connect(function()
		self:Buy()
	end)

	-- the node of the next purchasable level pulses while you can afford it
	RunService.RenderStepped:Connect(function()
		if not self.Root.Visible then
			return
		end
		local k = 0.5 + 0.5 * math.sin(os.clock() * 4)
		for _, row in self.Rows do
			local node = row.Next
			if node and node.Pulse and row.Row.Visible then
				node.Stroke.Thickness = px(3) + px(2.2) * k
			end
		end
	end)
end

function TreeWindow:BuildRow(parent: Instance, branch, order: number)
	local row = Kit.surface({ Name = branch.Id, LayoutOrder = order, StrokeColor = branch.Color, StrokeTransparency = 0.55, Parent = parent })
	row.Visible = false
	Responsive.bind(row, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(ROW))
	end)
	local info = { Row = row, Nodes = {}, Branch = branch }
	self.Rows[branch.Id] = info

	-- head: icon + name + current bonus
	local head = Kit.frame({ Name = "Head", Position = UDim2.fromOffset(8, 0), Parent = row })
	Responsive.bind(head, "Size", function(R)
		return UDim2.new(0, R.px(HEAD), 1, 0)
	end)
	iconDisc(head, branch.Icon, branch.Color, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(0.56, 0.56) })
	local text = Kit.frame({ Name = "Text", Position = UDim2.fromScale(0.3, 0), Size = UDim2.fromScale(0.7, 1), Parent = head })
	Kit.text({ Name = "Name", Text = string.upper(branch.Name), Role = "Label", Font = Theme.Fonts.Heading, Wrapped = true, YAlign = Enum.TextYAlignment.Bottom, Position = UDim2.fromScale(0, 0.04), Size = UDim2.fromScale(1, 0.5), Parent = text })
	info.Now = Kit.text({ Name = "Now", Text = "", Role = "Caption", Color = branch.Color, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0, 0.55), Size = UDim2.fromScale(1, 0.3), Truncate = true, Parent = text })

	-- level strip (scrolls sideways when the levels do not fit)
	local strip = Create("ScrollingFrame", {
		Name = "Strip",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		ScrollBarImageColor3 = branch.Color,
		ScrollBarImageTransparency = 0.3,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		Selectable = false,
		Parent = row,
	})
	info.Strip = strip
	local n = #branch.Levels
	Responsive.bind(strip, "Position", function(R)
		return UDim2.new(0, R.px(HEAD) + 12, 0, 0)
	end)
	Responsive.bind(strip, "Size", function(R)
		return UDim2.new(1, -(R.px(HEAD) + 18), 1, 0)
	end)
	Responsive.bind(strip, "CanvasSize", function(R)
		return UDim2.fromOffset(R.px(CELL) * n, 0)
	end)
	Responsive.bind(strip, "ScrollBarThickness", function(R)
		return math.max(3, R.px(4))
	end)
	Kit.list(strip, "H", 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)

	for k, entry in branch.Levels do
		local cell = Kit.frame({ Name = "Level" .. k, LayoutOrder = k, Parent = strip })
		Responsive.bind(cell, "Size", function(R)
			return UDim2.new(0, R.px(CELL), 1, 0)
		end)
		-- vine halves (left joins the previous node, right joins the next)
		local halves = {}
		for _, side in { "L", "R" } do
			if (side == "L" and k > 1) or (side == "R" and k < n) then
				local h = Kit.frame({ Name = "Vine" .. side, BackgroundTransparency = 0, BackgroundColor3 = C.Disabled, AnchorPoint = Vector2.new(0, 0.5), Parent = cell })
				Responsive.bind(h, "Size", function(R)
					return UDim2.new(0.5, 0, 0, R.px(5))
				end)
				Responsive.bind(h, "Position", function(R)
					return UDim2.new(side == "L" and 0 or 0.5, 0, 0, R.px(33))
				end)
				halves[side] = h
			end
		end
		local btn = Create("TextButton", {
			Name = "Node",
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = C.Surface,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 3,
			Parent = cell,
		})
		Responsive.bind(btn, "Size", function(R)
			return UDim2.fromOffset(R.px(46), R.px(46))
		end)
		Responsive.bind(btn, "Position", function(R)
			return UDim2.new(0.5, 0, 0, R.px(10))
		end)
		Kit.corner(btn, 999)
		local stroke = Kit.stroke(btn, branch.Color, 3, 0)
		local scale = Create("UIScale", { Parent = btn })
		local numeral = Kit.text({ Name = "Numeral", Text = tostring(k), Role = "Heading", Font = Theme.Fonts.Number, Color = branch.Color, XAlign = Enum.TextXAlignment.Center, ZIndex = 4, Parent = btn })
		local checkBox = Kit.frame({ Name = "Check", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.58, 0.58), ZIndex = 4, Visible = false, Parent = btn })
		Icons.make("Check", { Color = C.Ink, Accent = C.Ink, Ink = branch.Color }).Parent = checkBox
		local lockBox = Kit.frame({ Name = "Lock", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.5, 0.5), ZIndex = 4, Visible = false, Parent = btn })
		Icons.make("Lock", { Color = C.TextDim, Accent = C.TextDim, Ink = C.Surface }).Parent = lockBox
		local bonus = Kit.text({ Name = "Bonus", Text = TreeConfig.formatBonus(branch, entry.Bonus), Role = "Label", XAlign = Enum.TextXAlignment.Center, Truncate = true, Parent = cell })
		Responsive.bind(bonus, "Position", function(R)
			return UDim2.new(0, 0, 0, R.px(62))
		end)
		Responsive.bind(bonus, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(18))
		end)
		local price = Kit.text({ Name = "Price", Text = Format.cash(entry.Price), Role = "Caption", XAlign = Enum.TextXAlignment.Center, Truncate = true, Parent = cell })
		Responsive.bind(price, "Position", function(R)
			return UDim2.new(0, 0, 0, R.px(80))
		end)
		Responsive.bind(price, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(16))
		end)
		local node = { Button = btn, Stroke = stroke, Scale = scale, Numeral = numeral, Check = checkBox, Lock = lockBox, Bonus = bonus, Price = price, Halves = halves, Level = k, Id = branch.Id }
		info.Nodes[k] = node
		btn.Activated:Connect(function()
			self.UIC.sound("Click")
			self:Select(branch.Id, k)
		end)
	end
end

-- ============================================================== state
function TreeWindow:Snapshot()
	local data = self.Data and self.Data.all()
	return data, data and (tonumber(data.Cash) or 0) or 0
end

function TreeWindow:LevelOf(id: string): number
	local data = self:Snapshot()
	return TreeConfig.level(data, id)
end

function TreeWindow:Select(id: string, level: number)
	self.Selected = { Id = id, Level = level }
	self:Refresh()
end

-- default selection in a category: an affordable next level, else the first open next level
function TreeWindow:PickDefault(categoryId: string)
	local data, cash = self:Snapshot()
	local cat = TreeConfig.CategoryById[categoryId]
	local firstOpen
	for _, branch in cat.Branches do
		local lvl = TreeConfig.level(data, branch.Id)
		local nxt = branch.Levels[lvl + 1]
		if nxt then
			firstOpen = firstOpen or { Id = branch.Id, Level = lvl + 1 }
			if cash >= nxt.Price then
				return { Id = branch.Id, Level = lvl + 1 }
			end
		end
	end
	local b = cat.Branches[1]
	return firstOpen or { Id = b.Id, Level = #b.Levels }
end

-- Scrolls every visible strip so its next purchasable node is in the middle.
function TreeWindow:ScrollToNext()
	local data = self:Snapshot()
	for id, info in self.Rows do
		if info.Row.Visible then
			local nextIndex = math.min(TreeConfig.level(data, id) + 1, #info.Branch.Levels)
			local cell = px(CELL)
			local view = info.Strip.AbsoluteSize.X
			info.Strip.CanvasPosition = Vector2.new(math.max(0, (nextIndex - 0.5) * cell - view / 2), 0)
		end
	end
end

function TreeWindow:ShowCategory(categoryId: string)
	if not TreeConfig.CategoryById[categoryId] then
		return
	end
	self.Category = categoryId
	self.Tabs:Set(categoryId)
	for _, info in self.Rows do
		info.Row.Visible = info.Branch.Category == categoryId
	end
	self.Scroll.CanvasPosition = Vector2.zero
	if not self.Selected or TreeConfig.ById[self.Selected.Id].Category ~= categoryId then
		self.Selected = self:PickDefault(categoryId)
	end
	self:Refresh()
	task.defer(function()
		self:ScrollToNext()
	end)
end

function TreeWindow:Refresh()
	local data, cash = self:Snapshot()
	if not data then
		return
	end
	self.CashText.Text = Format.cash(cash)
	local have, total = TreeConfig.totals(data)
	self.TotalText.Text = string.format("%d / %d LEVELS", have, total)
	for _, branch in TreeConfig.Branches do
		local info = self.Rows[branch.Id]
		local cur = TreeConfig.level(data, branch.Id)
		info.Next = nil
		if cur > 0 then
			info.Now.Text = TreeConfig.formatBonus(branch, TreeConfig.bonus(data, branch.Id)) .. string.format("   LV %d/%d", cur, #branch.Levels)
		else
			info.Now.Text = string.format("NOT GROWN   LV 0/%d", #branch.Levels)
		end
		for k, node in info.Nodes do
			local entry = branch.Levels[k]
			local owned = k <= cur
			local isNext = k == cur + 1
			local affordable = isNext and cash >= entry.Price
			local selected = self.Selected and self.Selected.Id == branch.Id and self.Selected.Level == k
			node.Pulse = affordable
			if owned then
				node.Button.BackgroundColor3 = branch.Color
				node.Stroke.Color = WHITE
				node.Stroke.Thickness = px(2)
				node.Numeral.Visible = false
				node.Check.Visible = true
				node.Lock.Visible = false
				node.Bonus.TextColor3 = C.Text
				node.Price.Text = "OWNED"
				node.Price.TextColor3 = C.Success
			elseif isNext then
				node.Button.BackgroundColor3 = C.Surface
				node.Stroke.Color = branch.Color
				node.Stroke.Thickness = px(3)
				node.Numeral.Visible = true
				node.Check.Visible = false
				node.Lock.Visible = false
				node.Bonus.TextColor3 = branch.Color
				node.Price.Text = Format.cash(entry.Price)
				node.Price.TextColor3 = affordable and C.GoldBright or C.Danger
				info.Next = node
			else
				node.Button.BackgroundColor3 = C.SurfaceDeep
				node.Stroke.Color = C.Disabled
				node.Stroke.Thickness = px(2)
				node.Numeral.Visible = false
				node.Check.Visible = false
				node.Lock.Visible = true
				node.Bonus.TextColor3 = C.TextDim
				node.Price.Text = Format.cash(entry.Price)
				node.Price.TextColor3 = C.TextDim
			end
			if selected then
				node.Stroke.Color = WHITE
				node.Stroke.Thickness = px(4)
				node.Pulse = false
			end
			if node.Halves.L then
				node.Halves.L.BackgroundColor3 = (cur >= k) and branch.Color or C.Disabled
			end
			if node.Halves.R then
				node.Halves.R.BackgroundColor3 = (cur >= k + 1) and branch.Color or C.Disabled
			end
		end
	end
	self:UpdateDetail()
end

function TreeWindow:UpdateDetail()
	local sel = self.Selected
	local data, cash = self:Snapshot()
	local branch = sel and TreeConfig.ById[sel.Id]
	if not branch or not data then
		return
	end
	local cur = TreeConfig.level(data, sel.Id)
	local entry = branch.Levels[sel.Level]
	self.DetailDisc.BackgroundColor3 = branch.Color
	self.DetailTitle.Text = string.format("%s  -  LEVEL %d / %d", string.upper(branch.Name), sel.Level, #branch.Levels)
	local after = TreeConfig.formatBonus(branch, entry.Bonus)
	local body = branch.Description .. "  "
	if cur > 0 and sel.Level > cur then
		body ..= TreeConfig.formatBonus(branch, TreeConfig.bonus(data, sel.Id)) .. " > " .. after
	else
		body ..= after
	end
	self.DetailBody.Text = body
	if sel.Level <= cur then
		self.BuyButton:SetText("OWNED")
		self.BuyButton:SetStyle("Secondary")
		self.BuyButton:SetEnabled(false)
	elseif sel.Level == cur + 1 then
		self.BuyButton:SetText("BUY  " .. Format.cash(entry.Price))
		self.BuyButton:SetStyle("Gold")
		self.BuyButton:SetEnabled(cash >= entry.Price)
	else
		self.BuyButton:SetText("LOCKED")
		self.BuyButton:SetStyle("Secondary")
		self.BuyButton:SetEnabled(false)
	end
end

-- ============================================================== buying
function TreeWindow:Buy()
	local sel = self.Selected
	if not sel or self.Busy then
		return
	end
	self.Busy = true
	self.BuyButton:SetBusy(true)
	task.spawn(function()
		local res = Net.request("Tree", "Buy", { Id = sel.Id })
		self.Busy = false
		self.BuyButton:SetBusy(false)
		local branch = TreeConfig.ById[sel.Id]
		if self.UIC.HandleResult(res, branch.Name .. " level " .. tostring(res.data and res.data.Level or "") .. "!") then
			self.UIC.sound("Purchase")
			local level = res.data and res.data.Level or sel.Level
			local node = self.Rows[sel.Id].Nodes[level]
			if node then
				TweenService:Create(node.Scale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.4 }):Play()
				task.delay(0.18, function()
					TweenService:Create(node.Scale, TweenInfo.new(0.22, Enum.EasingStyle.Quad), { Scale = 1 }):Play()
				end)
			end
			-- move on to the next level of this branch
			local nextLevel = math.min(level + 1, #branch.Levels)
			self.Selected = { Id = sel.Id, Level = nextLevel }
			self:Refresh()
		end
	end)
end

-- ============================================================== lifecycle
function TreeWindow:OnOpen(args)
	local branchId = args and args.Branch
	if branchId and TreeConfig.ById[branchId] then
		local branch = TreeConfig.ById[branchId]
		self.Category = branch.Category
		self.Selected = { Id = branchId, Level = math.min(self:LevelOf(branchId) + 1, #branch.Levels) }
	elseif args and args.Category and TreeConfig.CategoryById[args.Category] then
		self.Category = args.Category
		self.Selected = nil
	end
	self:ShowCategory(self.Category)
	if not self._observing and self.Data then
		self._observing = true
		for _, key in { "Tree", "Cash" } do
			self.Data.changed(key):Connect(function()
				if self.Root.Visible then
					self:Refresh()
				end
			end)
		end
	end
end

return TreeWindow

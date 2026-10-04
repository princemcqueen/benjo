--[[
	TreeWindow (the Great Tree skill tree)
	Five branches (rows), five levels each (nodes joined by a vine). Levels are
	bought strictly in order: owned nodes are filled with the branch colour and a
	check, the next node pulses when you can afford it, later nodes are locked.
	Tap a node to inspect it; the strip at the bottom shows what it gives and
	buys it. All prices and bonuses come from TreeConfig; the server validates
	every purchase (TreeService).
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

local function px(n: number)
	return Responsive.px(n)
end

-- Re-applies fn(R) -> value to inst[prop] whenever the screen metrics change.
local function bind(inst: Instance, prop: string, fn)
	Responsive.bind(inst, prop, fn)
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
	self.Rows = {} -- [branchId] = { Nodes = {...}, Segments = {...}, Now = TextLabel }
	self.Selected = nil -- { Id, Level }
	self.Busy = false
	self:Build()
	return self
end

-- ============================================================== build
function TreeWindow:Build()
	local content = self.Content
	-- top strip: hint + cash
	local top = Kit.frame({ Name = "Top", Size = UDim2.new(1, 0, 0, px(30)), Parent = content })
	bind(top, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(30))
	end)
	Kit.text({ Name = "Hint", Text = "Grow each branch from the left. Upgrades are permanent.", Role = "Label", Color = C.TextMuted, Size = UDim2.fromScale(0.62, 1), Truncate = true, Parent = top })
	self.CashText = Kit.text({
		Name = "Cash",
		Text = "$0",
		Role = "Heading",
		Color = C.GoldBright,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.36, 1),
		Parent = top,
	})

	-- branch rows (scrolls when the window is short, e.g. phones)
	local scroll = Kit.scroll({ Name = "Branches", Parent = content })
	self.Scroll = scroll
	Kit.list(scroll, "V", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	bind(scroll, "Position", function(R)
		return UDim2.new(0, 0, 0, R.px(36))
	end)
	bind(scroll, "Size", function(R)
		return UDim2.new(1, 0, 1, -(R.px(36) + R.px(86)))
	end)
	for i, branch in TreeConfig.Branches do
		self:BuildRow(scroll, branch, i)
	end

	-- detail strip
	local detail = Kit.surface({ Name = "Detail", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Parent = content })
	self.Detail = detail
	bind(detail, "Size", function(R)
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

	-- the nodes of the next purchasable level pulse while you can afford them
	RunService.RenderStepped:Connect(function()
		if not self.Root.Visible then
			return
		end
		local k = 0.5 + 0.5 * math.sin(os.clock() * 4)
		for _, row in self.Rows do
			local node = row.Next
			if node and node.Pulse then
				node.Stroke.Thickness = px(3) + px(2.2) * k
			end
		end
	end)
end

function TreeWindow:BuildRow(parent: Instance, branch, order: number)
	local row = Kit.surface({ Name = branch.Id, LayoutOrder = order, StrokeColor = branch.Color, StrokeTransparency = 0.55, Parent = parent })
	bind(row, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and 104 or 118))
	end)
	local info = { Nodes = {}, Segments = {}, Branch = branch }
	self.Rows[branch.Id] = info

	-- head: icon + name + current bonus
	local head = Kit.frame({ Name = "Head", Position = UDim2.fromScale(0.012, 0), Size = UDim2.fromScale(0.23, 1), Parent = row })
	iconDisc(head, branch.Icon, branch.Color, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(0.55, 0.55) })
	Kit.text({ Name = "Name", Text = string.upper(branch.Name), Role = "Label", Font = Theme.Fonts.Heading, Wrapped = true, YAlign = Enum.TextYAlignment.Bottom, Position = UDim2.fromScale(0.36, 0.04), Size = UDim2.fromScale(0.64, 0.5), Parent = head })
	info.Now = Kit.text({ Name = "Now", Text = "", Role = "Caption", Color = branch.Color, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0.36, 0.55), Size = UDim2.fromScale(0.64, 0.3), Truncate = true, Parent = head })

	-- nodes block
	local outer = Kit.frame({ Name = "Levels", Position = UDim2.fromScale(0.25, 0), Size = UDim2.fromScale(0.74, 1), Parent = row })
	-- fixed-height strip centred in the row, so taller rows keep the nodes tight
	local block = Kit.frame({ Name = "Inner", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Parent = outer })
	bind(block, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(98))
	end)
	-- vine segments behind the nodes (between node centres)
	for k = 1, #branch.Levels - 1 do
		local seg = Kit.frame({
			Name = "Vine" .. k,
			BackgroundTransparency = 0,
			BackgroundColor3 = C.Disabled,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0.1 + (k - 1) * 0.2, 0, 0, px(33)),
			Parent = block,
		})
		bind(seg, "Size", function(R)
			return UDim2.new(0.2, 0, 0, R.px(5))
		end)
		bind(seg, "Position", function(R)
			return UDim2.new(0.1 + (k - 1) * 0.2, 0, 0, R.px(33))
		end)
		Kit.corner(seg, 999)
		info.Segments[k] = seg
	end
	for k, entry in branch.Levels do
		local cell = Kit.frame({ Name = "Level" .. k, Position = UDim2.fromScale((k - 1) * 0.2, 0), Size = UDim2.fromScale(0.2, 1), Parent = block })
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
		bind(btn, "Size", function(R)
			return UDim2.fromOffset(R.px(46), R.px(46))
		end)
		bind(btn, "Position", function(R)
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
		bind(bonus, "Position", function(R)
			return UDim2.new(0, 0, 0, R.px(62))
		end)
		bind(bonus, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(18))
		end)
		local price = Kit.text({ Name = "Price", Text = Format.cash(entry.Price), Role = "Caption", XAlign = Enum.TextXAlignment.Center, Truncate = true, Parent = cell })
		bind(price, "Position", function(R)
			return UDim2.new(0, 0, 0, R.px(80))
		end)
		bind(price, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(16))
		end)
		local node = { Button = btn, Stroke = stroke, Scale = scale, Numeral = numeral, Check = checkBox, Lock = lockBox, Bonus = bonus, Price = price, Level = k, Id = branch.Id }
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

-- default selection: an affordable next level, else the first next level, else the first branch
function TreeWindow:PickDefault()
	local data, cash = self:Snapshot()
	local firstOpen
	for _, branch in TreeConfig.Branches do
		local lvl = TreeConfig.level(data, branch.Id)
		local nxt = branch.Levels[lvl + 1]
		if nxt then
			firstOpen = firstOpen or { Id = branch.Id, Level = lvl + 1 }
			if cash >= nxt.Price then
				return { Id = branch.Id, Level = lvl + 1 }
			end
		end
	end
	return firstOpen or { Id = TreeConfig.Branches[1].Id, Level = #TreeConfig.Branches[1].Levels }
end

function TreeWindow:Refresh()
	local data, cash = self:Snapshot()
	if not data then
		return
	end
	self.CashText.Text = Format.cash(cash)
	for _, branch in TreeConfig.Branches do
		local info = self.Rows[branch.Id]
		local cur = TreeConfig.level(data, branch.Id)
		info.Next = nil
		info.Now.Text = cur > 0 and ("NOW " .. TreeConfig.formatBonus(branch, TreeConfig.bonus(data, branch.Id))) or "NOT GROWN YET"
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
		end
		for k, seg in info.Segments do
			seg.BackgroundColor3 = (cur >= k + 1) and branch.Color or C.Disabled
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
	self.DetailTitle.Text = string.format("%s  -  LEVEL %d", string.upper(branch.Name), sel.Level)
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
		local lvl = self:LevelOf(branchId)
		self.Selected = { Id = branchId, Level = math.min(lvl + 1, #TreeConfig.ById[branchId].Levels) }
	else
		self.Selected = self:PickDefault()
	end
	self.Scroll.CanvasPosition = Vector2.zero
	self:Refresh()
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

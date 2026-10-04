--[[
	QuestsWindow  (Elder Rowan's quests, key Q, the QUESTS button)
	GETTING STARTED goals for a new player and the active quests (QuestService / QuestConfig): every row has
	its progress and a CLAIM button that lights up when the goal is done. The server decides everything.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors

local QuestsWindow = {}
QuestsWindow.__index = QuestsWindow
setmetatable(QuestsWindow, { __index = WindowBase })

local PURPLE = Color3.fromRGB(205, 164, 222)
local GREEN = Color3.fromRGB(110, 208, 104)
local GOLD = Color3.fromRGB(255, 196, 48)

function QuestsWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Quests",
		Title = "Quests",
		Subtitle = "Elder Rowan's tasks",
		Icon = "Scroll",
		Spec = {
			Desktop = { Width = 0.46, Height = 0.8, Aspect = 0.9 },
			Tablet = { Width = 0.74, Height = 0.88, Aspect = 0.95 },
			Phone = { Width = 0.72, Height = 1 },
			PhonePortrait = { Width = 0.97, Height = 1 },
		},
	})
	setmetatable(self, QuestsWindow)
	self.UIC = ui
	self.Registry = registry
	self.State = nil
	self.Busy = false
	self.Rows = {}
	self:Build()
	return self
end

function QuestsWindow:Build()
	local content = self.Content
	local scroll = Kit.scroll({ Name = "List", Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 0.9), Parent = content })
	self.List = scroll
	Kit.padding(scroll, 2, 8, 2, 2)
	Kit.list(scroll, "V", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self.Footer = Kit.text({ Name = "Footer", Text = "", Role = "Caption", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.915), Size = UDim2.fromScale(1, 0.075), Parent = content })
	self.Empty = Kit.text({ Name = "Empty", Text = "Loading...", Role = "Label", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.1, 0.45), Size = UDim2.fromScale(0.8, 0.08), Parent = content })
end

function QuestsWindow:Clear()
	for _, r in self.Rows do
		r:Destroy()
	end
	table.clear(self.Rows)
end

local function rowSize(row, tall: boolean)
	Responsive.bind(row, "Size", function(R)
		local phone = R.Device == "Phone"
		return UDim2.new(1, 0, 0, R.px(tall and (phone and 92 or 86) or (phone and 68 or 62)))
	end)
end

function QuestsWindow:Section(order: number, text: string, color: Color3?)
	local h = Kit.text({ Name = "Header" .. order, Text = text, Role = "Heading", Color = color or C.Gold, LayoutOrder = order, Truncate = true, Parent = self.List })
	Responsive.bind(h, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(34))
	end)
	table.insert(self.Rows, h)
	return h
end

local function disc(row, color: Color3, icon: string)
	local d = Kit.frame({ Name = "Disc", BackgroundTransparency = 0, BackgroundColor3 = color, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.025, 0.5), Size = UDim2.fromScale(0.64, 0.64), SizeConstraint = Enum.SizeConstraint.RelativeYY, Parent = row })
	Kit.corner(d, 999)
	local box = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), Parent = d })
	Icons.make(icon, { Color = C.Ink, Accent = C.Text, Ink = color }).Parent = box
end

function QuestsWindow:StarterRow(order: number, s)
	local color = s.Claimed and GREEN or (s.Done and GOLD or PURPLE)
	local row = Kit.surface({ Name = "Starter_" .. s.Id, LayoutOrder = order, StrokeColor = color, StrokeTransparency = s.Done and not s.Claimed and 0.2 or 0.6, Parent = self.List })
	rowSize(row, false)
	disc(row, color, s.Claimed and "Check" or "Star")
	Kit.text({ Name = "Title", Text = s.Text, Role = "Label", Color = s.Claimed and C.TextMuted or C.Text, Position = UDim2.fromScale(0.15, 0.1), Size = UDim2.fromScale(0.5, 0.42), Truncate = true, Parent = row })
	local reward = Format.cash(s.Reward) .. (s.Spins > 0 and string.format("  +  %d SPINS", s.Spins) or "")
	Kit.text({ Name = "Sub", Text = s.Claimed and "DONE" or (s.Done and reward or s.Hint), Role = "Caption", Color = s.Done and not s.Claimed and C.GoldBright or C.TextMuted, Position = UDim2.fromScale(0.15, 0.55), Size = UDim2.fromScale(0.5, 0.34), Truncate = true, Parent = row })
	if not s.Claimed then
		local go = Kit.button({ Name = "Claim", Text = "CLAIM", Style = s.Done and "Success" or "Secondary", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.975, 0.5), Size = UDim2.fromScale(0.26, 0.66), Parent = row })
		go:SetEnabled(s.Done)
		go.Activated:Connect(function()
			self:Claim("s:" .. s.Id, go)
		end)
	end
	table.insert(self.Rows, row)
end

function QuestsWindow:QuestRow(order: number, i: number, q)
	local color = q.Ready and GOLD or PURPLE
	local row = Kit.surface({ Name = "Quest" .. i, LayoutOrder = order, StrokeColor = color, StrokeTransparency = q.Ready and 0.15 or 0.5, Parent = self.List })
	rowSize(row, true)
	disc(row, color, "Scroll")
	Kit.text({ Name = "Title", Text = q.Text, Role = "Heading", Position = UDim2.fromScale(0.15, 0.08), Size = UDim2.fromScale(0.55, 0.34), Truncate = true, Parent = row })
	local bar = Kit.progress({ Name = "Bar", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.15, 0.55), Size = UDim2.fromScale(0.55, 0.14), Color = C.Accent, Color2 = C.GoldBright, Parent = row })
	bar:SetValue(q.Goal > 0 and q.Progress / q.Goal or 0)
	local progressText = q.Fmt == "cash" and string.format("%s / %s", Format.cash(q.Progress), Format.cash(q.Goal)) or string.format("%s / %s", Format.abbreviate(q.Progress), Format.abbreviate(q.Goal))
	Kit.text({ Name = "Progress", Text = progressText, Role = "Caption", Color = C.TextMuted, Position = UDim2.fromScale(0.15, 0.7), Size = UDim2.fromScale(0.3, 0.24), Truncate = true, Parent = row })
	Kit.text({ Name = "Reward", Text = string.format("%s  +  %d XP", Format.cash(q.Cash), q.XP), Role = "Caption", Color = C.GoldBright, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.3, 0.7), Size = UDim2.fromScale(0.4, 0.24), Truncate = true, Parent = row })
	local go = Kit.button({ Name = "Claim", Text = "CLAIM", Style = q.Ready and "Success" or "Secondary", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.975, 0.5), Size = UDim2.fromScale(0.24, 0.6), Parent = row })
	go:SetEnabled(q.Ready)
	go.Activated:Connect(function()
		self:Claim(q.Id, go)
	end)
	table.insert(self.Rows, row)
end

function QuestsWindow:Render()
	local st = self.State
	self:Clear()
	self.Empty.Visible = st == nil
	if not st then
		return
	end
	local order = 0
	if #st.Starter > 0 then
		order += 1
		self:Section(order, string.format("GETTING STARTED   %d / %d", st.StarterTotal - st.StarterLeft, st.StarterTotal), PURPLE)
		for _, s in st.Starter do
			order += 1
			self:StarterRow(order, s)
		end
	end
	order += 1
	self:Section(order, "ACTIVE QUESTS", C.Gold)
	for i, q in st.Active do
		order += 1
		self:QuestRow(order, i, q)
	end
	self.Footer.Text = string.format("QUESTS DONE: %d   -   FREE SPIN IN %d MORE", st.Completed, st.SpinIn)
	local controller = self.Registry and self.Registry.QuestController
	if controller then
		controller.setCount(st.Claimable or 0)
	end
end

function QuestsWindow:Refresh()
	local res = Net.request("Quests", "State", {})
	if res.ok and res.data then
		self.State = res.data
		self:Render()
	end
end

function QuestsWindow:Claim(id: string, button)
	if self.Busy then
		return
	end
	self.Busy = true
	button:SetBusy(true)
	task.spawn(function()
		local res = Net.request("Quests", "Claim", { Id = id })
		self.Busy = false
		if not res.ok then
			self.UIC.HandleResult(res)
		end
		self:Refresh()
	end)
end

function QuestsWindow:OnOpen()
	self:Render()
	task.spawn(function()
		self:Refresh()
	end)
end

return QuestsWindow

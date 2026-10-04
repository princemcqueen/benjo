--[[
	DuelWindow  (the Battle Hall)
	Pick a duel: an NPC trainer (their level follows your equipped dragon) or challenge another player
	of the server. Starting a duel closes the window and hands the screen to the DuelController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local DuelConfig = require(Configs:WaitForChild("DuelConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors
local LocalPlayer = Players.LocalPlayer

local DuelWindow = {}
DuelWindow.__index = DuelWindow
setmetatable(DuelWindow, { __index = WindowBase })

function DuelWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Duel",
		Title = "Battle Hall",
		Subtitle = "Turn-based dragon duels",
		Icon = "Sword",
		Spec = {
			Desktop = { Width = 0.56, Height = 0.78, Aspect = 1.15 },
			Tablet = { Width = 0.8, Height = 0.86, Aspect = 1.1 },
			Phone = { Width = 0.9, Height = 1 },
			PhonePortrait = { Width = 0.97, Height = 1 },
		},
	})
	setmetatable(self, DuelWindow)
	self.UIC = ui
	self.Registry = registry
	self.Tab = "Trainers"
	self.Rows = {}
	self.Busy = false
	self:Build()
	return self
end

function DuelWindow:Build()
	local content = self.Content
	-- your dragon
	local you = Kit.surface({ Name = "You", StrokeColor = C.Gold, StrokeTransparency = 0.6, Size = UDim2.fromScale(1, 0.13), Parent = content })
	self.YouName = Kit.text({ Name = "Name", Text = "", Role = "Heading", Scaled = true, Position = UDim2.fromScale(0.03, 0.08), Size = UDim2.fromScale(0.62, 0.46), Truncate = true, Parent = you })
	self.YouSub = Kit.text({ Name = "Sub", Text = "", Role = "Caption", Scaled = true, Color = C.TextMuted, Position = UDim2.fromScale(0.03, 0.54), Size = UDim2.fromScale(0.62, 0.34), Truncate = true, Parent = you })
	self.YouElement = Kit.text({ Name = "Element", Text = "", Role = "Heading", Scaled = true, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.62, 0.08), Size = UDim2.fromScale(0.35, 0.46), Parent = you })
	self.YouHint = Kit.text({ Name = "Hint", Text = "", Role = "Caption", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.5, 0.54), Size = UDim2.fromScale(0.47, 0.34), Truncate = true, Parent = you })

	self.Seg = Kit.segmented({ Name = "Tabs", Options = { "Trainers", "Players" }, Labels = { "TRAINERS", "PLAYERS" }, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.15), Size = UDim2.fromScale(0.5, 0.075), Parent = content })
	self.Seg.Changed:Connect(function(value)
		self.Tab = value
		self:Render()
	end)

	local scroll = Kit.scroll({ Name = "List", Position = UDim2.fromScale(0, 0.25), Size = UDim2.fromScale(1, 0.75), Parent = content })
	self.List = scroll
	Kit.padding(scroll, 2, 8, 2, 2)
	Kit.list(scroll, "V", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self.Empty = Kit.text({ Name = "Empty", Text = "", Role = "Label", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.1, 0.5), Size = UDim2.fromScale(0.8, 0.1), Parent = content })
	self.Empty.Visible = false
end

function DuelWindow:Row(i: number, color: Color3)
	local row = Kit.surface({ Name = "Row" .. i, LayoutOrder = i, StrokeColor = color, StrokeTransparency = 0.45, Parent = self.List })
	Responsive.bind(row, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and 84 or 78))
	end)
	return row
end

function DuelWindow:Clear()
	for _, r in self.Rows do
		r:Destroy()
	end
	table.clear(self.Rows)
end

local function costText(entry): string
	return string.format("%s  +  %d XP", Format.cash(entry.Cash), entry.XP)
end

function DuelWindow:RenderTrainers()
	local data = self.Trainers
	if not data then
		return
	end
	for i, t in data.List do
		local def = DuelConfig.trainer(t.Id)
		local color = def and def.Color or C.Gold
		local row = self:Row(i, color)
		table.insert(self.Rows, row)
		local disc = Kit.frame({ Name = "Disc", BackgroundTransparency = 0, BackgroundColor3 = color, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.025, 0.5), Size = UDim2.fromScale(0.7, 0.7), SizeConstraint = Enum.SizeConstraint.RelativeYY, Parent = row })
		Kit.corner(disc, 999)
		local box = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), Parent = disc })
		Icons.make("Sword", { Color = C.Ink, Accent = C.Text, Ink = color }).Parent = box
		Kit.text({ Name = "Title", Text = string.upper(t.Name), Role = "Heading", Position = UDim2.fromScale(0.2, 0.1), Size = UDim2.fromScale(0.5, 0.4), Truncate = true, Parent = row })
		Kit.text({ Name = "Sub", Text = string.format("%s  -  dragon Lv %d", t.Title, t.Level), Role = "Caption", Color = C.TextMuted, Position = UDim2.fromScale(0.2, 0.5), Size = UDim2.fromScale(0.5, 0.2), Truncate = true, Parent = row })
		local reward = t.Cooldown > 0 and string.format("REMATCH pays less (%ds)", t.Cooldown) or costText(t)
		Kit.text({ Name = "Reward", Text = reward, Role = "Caption", Color = t.Cooldown > 0 and C.TextDim or C.GoldBright, Position = UDim2.fromScale(0.2, 0.72), Size = UDim2.fromScale(0.5, 0.2), Truncate = true, Parent = row })
		local go = Kit.button({ Name = "Fight", Text = "FIGHT", Style = "Primary", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.975, 0.5), Size = UDim2.fromScale(0.22, 0.66), Parent = row })
		go.Activated:Connect(function()
			self:Fight(t.Id, go)
		end)
	end
end

function DuelWindow:RenderPlayers()
	local others = {}
	for _, p in Players:GetPlayers() do
		if p ~= LocalPlayer then
			table.insert(others, p)
		end
	end
	table.sort(others, function(a, b)
		return a.DisplayName < b.DisplayName
	end)
	self.Empty.Visible = #others == 0
	self.Empty.Text = "Nobody else is here right now."
	for i, p in others do
		local color = Color3.fromRGB(255, 110, 90)
		local row = self:Row(i, color)
		table.insert(self.Rows, row)
		Kit.text({ Name = "Title", Text = string.upper(p.DisplayName), Role = "Heading", Position = UDim2.fromScale(0.04, 0.14), Size = UDim2.fromScale(0.62, 0.42), Truncate = true, Parent = row })
		Kit.text({ Name = "Sub", Text = "@" .. p.Name, Role = "Caption", Color = C.TextMuted, Position = UDim2.fromScale(0.04, 0.58), Size = UDim2.fromScale(0.62, 0.28), Truncate = true, Parent = row })
		local go = Kit.button({ Name = "Challenge", Text = "CHALLENGE", Style = "Primary", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.975, 0.5), Size = UDim2.fromScale(0.3, 0.66), Parent = row })
		go.Activated:Connect(function()
			self:Challenge(p, go)
		end)
	end
end

function DuelWindow:Render()
	self:Clear()
	self.Empty.Visible = false
	if self.Tab == "Trainers" then
		self:RenderTrainers()
	else
		self:RenderPlayers()
	end
	local d = self.Trainers and self.Trainers.Dragon
	if d then
		self.YouName.Text = string.upper((d.Mutation ~= "None" and (d.Mutation .. " ") or "") .. d.Name)
		self.YouSub.Text = string.format("Your equipped dragon  -  Lv %d  -  %s", d.Level, d.Rarity)
		self.YouElement.Text = string.upper(d.Element)
		self.YouElement.TextColor3 = DuelConfig.Colors[d.Element] or C.Text
		self.YouHint.Text = "Change it in DRAGONS"
	else
		self.YouName.Text = "NO DRAGON EQUIPPED"
		self.YouSub.Text = "Open DRAGONS and equip one to duel."
		self.YouElement.Text = ""
		self.YouHint.Text = ""
	end
end

function DuelWindow:Refresh()
	local res = Net.request("Duel", "Trainers", {})
	if res.ok then
		self.Trainers = res.data
		self:Render()
	end
end

function DuelWindow:Fight(id: string, button)
	if self.Busy then
		return
	end
	local controller = self.Registry and self.Registry.DuelController
	if not controller then
		return
	end
	self.Busy = true
	button:SetBusy(true)
	task.spawn(function()
		local ok, msg = controller.startTrainer(id)
		self.Busy = false
		button:SetBusy(false)
		if ok then
			self.UIC.Close()
		else
			self.UIC.Notify("warning", msg or "You cannot duel right now.")
		end
	end)
end

function DuelWindow:Challenge(player: Player, button)
	if self.Busy then
		return
	end
	local controller = self.Registry and self.Registry.DuelController
	if not controller then
		return
	end
	self.Busy = true
	button:SetBusy(true)
	task.spawn(function()
		local ok, msg = controller.challenge(player.UserId)
		self.Busy = false
		button:SetBusy(false)
		if ok then
			self.UIC.Notify("success", string.format("Challenge sent to %s. Waiting for an answer...", player.DisplayName))
		else
			self.UIC.Notify("warning", msg or "You cannot challenge that player now.")
		end
	end)
end

function DuelWindow:OnOpen(args)
	self.Tab = "Trainers"
	self.Seg:Set("Trainers")
	self:Render()
	task.spawn(function()
		self:Refresh()
	end)
end

return DuelWindow

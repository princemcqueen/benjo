--[[
	RaceWindow
	Opened by the join pad on the Race Island (and from the Teleport menu's neighbour): the race
	desk. Four tabs, one column each so it reads the same on a phone and on a monitor:

	  RACE      the monthly prize, the JOIN button (or the way to the island), your records, the rules
	  MONTHLY   this month's fastest racers + the champions of the past months
	  ALL-TIME  the fastest racers ever
	  ARENA     duel knockouts + how to fight

	Server: Race.State / Join / Leave / Top (RaceService), Travel.To (TravelService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors
local LocalPlayer = Players.LocalPlayer

local RaceWindow = {}
RaceWindow.__index = RaceWindow
setmetatable(RaceWindow, { __index = WindowBase })

local MEDALS = { Color3.fromRGB(255, 205, 60), Color3.fromRGB(205, 214, 224), Color3.fromRGB(222, 140, 80) }
local PRIZE_BG = Color3.fromRGB(58, 46, 18)
local TABS = { "Race", "Monthly", "AllTime", "Arena" }
local TAB_LABELS = { "RACE", "MONTHLY", "ALL-TIME", "ARENA" }
local BOARD_OF = { Monthly = "RaceMonthly", AllTime = "RaceBest", Arena = "ArenaKills" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

function RaceWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Race",
		Title = "Race Island",
		Subtitle = "Races and duels",
		Icon = "Trophy",
		Spec = {
			Desktop = { Width = 0.5, Height = 0.84, Aspect = 1.0 },
			Tablet = { Width = 0.72, Height = 0.88, Aspect = 1.0 },
			Phone = { Width = 0.8, Height = 1 },
			PhonePortrait = { Width = 0.98, Height = 1 },
		},
	})
	setmetatable(self, RaceWindow)
	self.UIC = ui
	self.Registry = registry
	self.Snap = nil
	self.SnapAt = 0
	self.Busy = false
	self.Boards = {}
	self.Pages = {}
	self.Rows = {}
	self:Build()
	return self
end

-- ============================================================== helpers
-- phoneFactor: text cards need more height on a phone (the same text wraps into more lines)
local function card(parent: Instance, name: string, order: number, heightPx: number, stroke: Color3?, phoneFactor: number?): Frame
	local f = Kit.surface({ Name = name, LayoutOrder = order, StrokeColor = stroke or C.Gold, StrokeTransparency = stroke and 0.35 or 0.72, Parent = parent })
	Responsive.bind(f, "Size", function(R)
		local factor = (R.Device == "Phone" and phoneFactor) or 1
		return UDim2.new(1, 0, 0, R.px(heightPx * factor))
	end)
	return f
end

local function medal(i: number): Color3
	return MEDALS[i] or C.TextMuted
end

-- "12d 04h" for long spans, otherwise "3h 20m" / "4m 10s"
local function span(seconds: number): string
	local days = math.floor(seconds / 86400)
	if days > 0 then
		return string.format("%dd %02dh", days, math.floor(seconds % 86400 / 3600))
	end
	return Format.duration(seconds)
end

local function monthName(key: string): string
	local month = tonumber(string.sub(key, 5, 6)) or 1
	return (MONTHS[month] or "?") .. " " .. string.sub(key, 1, 4)
end

local function clearRows(scroll: Instance)
	for _, c in scroll:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function note(parent: Instance, text: string, order: number)
	local t = Kit.text({ Name = "Note", Text = text, Role = "Label", Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Wrapped = true, LayoutOrder = order, Parent = parent })
	Responsive.bind(t, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(54))
	end)
	return t
end

local function listRow(parent: Instance, i: number, rank: number, name: string, value: string, mine: boolean)
	local row = Kit.surface({
		Name = "Row" .. i,
		LayoutOrder = i,
		Color = mine and PRIZE_BG or C.Surface,
		Transparency = mine and 0.05 or 0.35,
		StrokeColor = mine and C.GoldBright or C.Gold,
		StrokeTransparency = mine and 0.2 or 0.88,
		Parent = parent,
	})
	Responsive.bind(row, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and 40 or 38))
	end)
	Kit.text({ Name = "Rank", Text = tostring(rank), Role = "Heading", Font = Theme.Fonts.Number, Color = medal(rank), XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.01, 0), Size = UDim2.fromScale(0.1, 1), Parent = row })
	Kit.text({ Name = "Name", Text = name .. (mine and "  (you)" or ""), Role = "Label", Color = mine and C.GoldBright or C.Text, Truncate = true, Position = UDim2.fromScale(0.13, 0), Size = UDim2.fromScale(0.5, 1), Parent = row })
	Kit.text({ Name = "Value", Text = value, Role = "Heading", Font = Theme.Fonts.Number, Color = C.GoldBright, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.6, 0), Size = UDim2.fromScale(0.38, 1), Parent = row })
	return row
end

-- ============================================================== build
function RaceWindow:Build()
	local content = self.Content
	local top = Kit.frame({ Name = "Top", Parent = content })
	Responsive.bind(top, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(34))
	end)
	self.Tabs = Kit.segmented({ Name = "Tabs", Options = TABS, Labels = TAB_LABELS, Size = UDim2.fromScale(1, 1), Parent = top })
	self.Tabs.Changed:Connect(function(v)
		self:ShowTab(v)
	end)
	local body = Kit.frame({ Name = "Body", Position = UDim2.new(0, 0, 0, 0), Size = UDim2.fromScale(1, 1), Parent = content })
	self.BodyFrame = body
	Responsive.bind(body, "Position", function(R)
		return UDim2.new(0, 0, 0, R.px(34 + 10))
	end)
	Responsive.bind(body, "Size", function(R)
		return UDim2.new(1, 0, 1, -R.px(34 + 10))
	end)
	for _, id in TABS do
		local scroll = Kit.scroll({ Name = id, Size = UDim2.fromScale(1, 1), Parent = body })
		scroll.Visible = false
		Kit.padding(scroll, 2, 6, 6, 2)
		Kit.list(scroll, "V", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
		self.Pages[id] = scroll
	end
	self:BuildRacePage(self.Pages.Race)
	self:BuildMonthlyPage(self.Pages.Monthly)
	self:BuildBoardPage(self.Pages.AllTime, "AllTime")
	self:BuildArenaPage(self.Pages.Arena)
end

function RaceWindow:BuildRacePage(page: Instance)
	-- the prize
	local prize = card(page, "Prize", 1, 92, C.GoldBright)
	prize.BackgroundColor3 = PRIZE_BG
	Kit.text({ Name = "Caption", Text = "MONTHLY PRIZE", Role = "Micro", Color = C.GoldBright, Position = UDim2.fromScale(0.04, 0.08), Size = UDim2.fromScale(0.5, 0.2), Parent = prize })
	self.PrizeText = Kit.text({ Name = "Prize", Text = RaceConfig.Monthly.PrizeText, Role = "Display", Scaled = true, Font = Theme.Fonts.Number, Color = C.GoldBright, Position = UDim2.fromScale(0.04, 0.28), Size = UDim2.fromScale(0.5, 0.36), Parent = prize })
	self.PrizeSub = Kit.text({ Name = "Sub", Text = RaceConfig.Monthly.Headline, Role = "Caption", Color = C.Text, Wrapped = true, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0.04, 0.66), Size = UDim2.fromScale(0.92, 0.3), Parent = prize })
	self.PrizeLeft = Kit.text({ Name = "Left", Text = "", Role = "Heading", Font = Theme.Fonts.Number, Color = C.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.5, 0.08), Size = UDim2.fromScale(0.46, 0.3), Parent = prize })
	self.PrizeLeftCaption = Kit.text({ Name = "LeftCaption", Text = "MONTH ENDS IN", Role = "Micro", Color = C.TextMuted, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromScale(0.46, 0.2), Parent = prize })

	-- join
	local join = card(page, "Join", 2, 128)
	self.Status = Kit.text({ Name = "Status", Text = "Looking for the race...", Role = "Label", Color = C.Text, Wrapped = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.06), Size = UDim2.fromScale(0.9, 0.36), Parent = join })
	self.JoinButton = Kit.button({ Name = "JoinButton", Text = "JOIN RACE", Style = "Primary", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.92), Size = UDim2.fromScale(0.8, 0.44), Parent = join })
	self.JoinButton.Activated:Connect(function()
		self:OnJoin()
	end)

	-- your records
	local stats = card(page, "Stats", 3, 76)
	self.StatCells = {}
	local labels = { "BEST", "THIS MONTH", "RACES", "WINS" }
	for i, label in labels do
		local cell = Kit.frame({ Name = "Cell" .. i, Position = UDim2.fromScale((i - 1) * 0.25, 0), Size = UDim2.fromScale(0.25, 1), Parent = stats })
		Kit.text({ Name = "Caption", Text = label, Role = "Micro", Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.12), Size = UDim2.fromScale(1, 0.26), Parent = cell })
		self.StatCells[i] = Kit.text({ Name = "Value", Text = "-", Role = "Heading", Scaled = true, Font = Theme.Fonts.Number, Color = C.Text, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.4), Size = UDim2.fromScale(0.92, 0.42), Parent = cell })
	end

	-- the rules
	local rules = card(page, "Rules", 4, 188, nil, 1.7)
	Kit.text({ Name = "Caption", Text = "HOW IT WORKS", Role = "Micro", Color = C.GoldBright, Position = UDim2.fromScale(0.04, 0.05), Size = UDim2.fromScale(0.6, 0.1), Parent = rules })
	local lines = {
		string.format("%d laps of the sky circuit, %d rings a lap. Fly through every ring, in order.", RaceConfig.Laps, RaceConfig.GateCount),
		"Everybody races on the same standard dragon: lines and boost rings decide, not coins.",
		"Cyan rings give you a dash. Your bond perks are switched off in a race.",
		"A lone racer can start at once; with other racers the lobby counts down.",
		"The fastest racer of the month wins the prize and the RACE CHAMPION title.",
	}
	local text = Kit.text({ Name = "Rules", Text = "- " .. table.concat(lines, "\n- "), Role = "Label", Color = C.Text, Wrapped = true, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0.04, 0.17), Size = UDim2.fromScale(0.92, 0.78), Parent = rules })
	text.LineHeight = 1.15
end

function RaceWindow:BuildMonthlyPage(page: Instance)
	local prize = card(page, "Prize", 1, 74, C.GoldBright)
	prize.BackgroundColor3 = PRIZE_BG
	self.MonthTitle = Kit.text({ Name = "Title", Text = "THIS MONTH", Role = "Heading", Color = C.GoldBright, Position = UDim2.fromScale(0.04, 0.1), Size = UDim2.fromScale(0.6, 0.4), Parent = prize })
	self.MonthSub = Kit.text({ Name = "Sub", Text = RaceConfig.Monthly.Headline, Role = "Caption", Color = C.Text, Wrapped = true, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0.04, 0.5), Size = UDim2.fromScale(0.62, 0.44), Parent = prize })
	self.MonthLeft = Kit.text({ Name = "Left", Text = "", Role = "Heading", Font = Theme.Fonts.Number, Color = C.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.6, 0.1), Size = UDim2.fromScale(0.36, 0.4), Parent = prize })
	Kit.text({ Name = "LeftCaption", Text = "MONTH ENDS IN", Role = "Micro", Color = C.TextMuted, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.6, 0.52), Size = UDim2.fromScale(0.36, 0.3), Parent = prize })
	local list = Kit.frame({ Name = "List", AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1, 0), LayoutOrder = 2, Parent = page })
	Kit.list(list, "V", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self.Rows.Monthly = list
	local past = Kit.frame({ Name = "Past", AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1, 0), LayoutOrder = 3, Parent = page })
	Kit.list(past, "V", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self.Rows.Past = past
end

function RaceWindow:BuildBoardPage(page: Instance, id: string)
	local list = Kit.frame({ Name = "List", AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1, 0), LayoutOrder = 1, Parent = page })
	Kit.list(list, "V", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self.Rows[id] = list
end

function RaceWindow:BuildArenaPage(page: Instance)
	local how = card(page, "How", 1, 204, C.Danger, 1.8)
	Kit.text({ Name = "Caption", Text = "DUEL ARENA", Role = "Heading", Color = C.GoldBright, Position = UDim2.fromScale(0.04, 0.04), Size = UDim2.fromScale(0.6, 0.12), Parent = how })
	local touch = Responsive.isMobile()
	local lines = {
		"Fly into the arena on your dragon: from there on other riders can hit you, and you can hit them.",
		touch and "STRIKE (button): a bite and tail slam right in front of you." or "STRIKE (F or left click): a bite and tail slam right in front of you.",
		touch and "BLAST (button): a fireball you aim, slower to recharge." or "BLAST (G): a fireball in the direction you look, slower to recharge.",
		"Your hit points come from the dragon's level and rarity.",
		"A knockout pays cash and XP. You wake on a respawn pad, protected for a few seconds.",
		"Fly out of the arena to leave the fight at any time.",
	}
	local text = Kit.text({ Name = "Rules", Text = "- " .. table.concat(lines, "\n- "), Role = "Label", Color = C.Text, Wrapped = true, YAlign = Enum.TextYAlignment.Top, Position = UDim2.fromScale(0.04, 0.17), Size = UDim2.fromScale(0.92, 0.8), Parent = how })
	text.LineHeight = 1.15
	local mine = card(page, "Mine", 2, 56)
	self.ArenaMine = Kit.text({ Name = "Mine", Text = "", Role = "Heading", Color = C.Text, XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = mine })
	local list = Kit.frame({ Name = "List", AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1, 0), LayoutOrder = 3, Parent = page })
	Kit.list(list, "V", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self.Rows.Arena = list
end

-- ============================================================== data
function RaceWindow:Fetch()
	local res = Net.request("Race", "State")
	if res.ok then
		self.Snap = res.data
		self.SnapAt = os.clock()
		self:RefreshRace()
	end
end

function RaceWindow:LoadBoard(tab: string)
	local board = BOARD_OF[tab]
	if not board then
		return
	end
	local res = Net.request("Race", "Top", { Board = board })
	local holder = self.Rows[tab]
	if not holder then
		return
	end
	clearRows(holder)
	if not res.ok then
		note(holder, "The board could not be loaded.", 1)
		return
	end
	local list = res.data.List or {}
	if #list == 0 then
		note(holder, tab == "Arena" and "No knockouts yet - be the first!" or "Nobody has a time yet - be the first!", 1)
	end
	for i, e in list do
		listRow(holder, i, e.Rank or i, e.Name, e.Text, e.UserId == LocalPlayer.UserId)
	end
end

function RaceWindow:RefreshPast()
	local holder = self.Rows.Past
	if not holder then
		return
	end
	local winners = self.Snap and self.Snap.Winners or {}
	local key = #winners .. ":" .. (winners[1] and winners[1].Month or "")
	if key == self.PastKey then
		return
	end
	self.PastKey = key
	clearRows(holder)
	local header = Kit.text({ Name = "PastCaption", Text = "PAST CHAMPIONS", Role = "Micro", Color = C.GoldBright, LayoutOrder = 0, Parent = holder })
	Responsive.bind(header, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(22))
	end)
	if #winners == 0 then
		note(holder, "The first champion is crowned when the month ends.", 1)
		return
	end
	for i, w in winners do
		if i > RaceConfig.Monthly.HistoryCount then
			break
		end
		local row = listRow(holder, i, i, w.Name, RaceConfig.formatTime(w.Ms), w.UserId == LocalPlayer.UserId)
		local rank = row:FindFirstChild("Rank") :: TextLabel?
		if rank then
			rank.Text = ""
		end
		local name = row:FindFirstChild("Name") :: TextLabel?
		if name then
			name.Position = UDim2.fromScale(0.04, 0)
			name.Text = monthName(w.Month) .. "   " .. w.Name
		end
	end
end

function RaceWindow:RefreshRace()
	local s = self.Snap
	if not s then
		return
	end
	local left = math.max(0, (s.MonthLeft or 0) - (os.clock() - self.SnapAt))
	local leftText = span(left)
	self.PrizeLeft.Text = leftText
	self.PrizeText.Text = s.Prize or RaceConfig.Monthly.PrizeText
	self.PrizeSub.Text = s.Headline or RaceConfig.Monthly.Headline
	self.MonthLeft.Text = leftText
	self.MonthTitle.Text = monthName(s.Month or RaceConfig.monthKey()):upper()
	self.MonthSub.Text = s.Headline or RaceConfig.Monthly.Headline
	-- the join button follows where you are and what the race is doing
	local status, label, style
	if s.Joined then
		if s.Queued then
			status = "You are in line for the next race."
		elseif s.State == "Lobby" then
			status = string.format("Lobby open: %d racer%s, starts in %ds.", #s.Racers, #s.Racers == 1 and "" or "s", math.ceil(s.Left or 0))
		else
			status = "The race is about to start!"
		end
		label, style = "LEAVE LOBBY", "Danger"
	elseif not s.OnIsland then
		status = "You are away from the island. Fly there first - it floats north-east of the valley."
		label, style = "FLY TO RACE ISLAND", "Blue"
	elseif s.Running then
		status = "A race is running. Join and you start in the next one."
		label, style = "JOIN NEXT RACE", "Primary"
	elseif s.State == "Lobby" then
		status = string.format("Lobby open: %d racer%s waiting.", #s.Racers, #s.Racers == 1 and "" or "s")
		label, style = "JOIN RACE", "Primary"
	else
		status = "No race right now. Join to open a lobby - you can start alone for a time trial."
		label, style = "JOIN RACE", "Primary"
	end
	self.Status.Text = status
	self.JoinButton:SetText(label)
	self.JoinButton:SetStyle(style)
	self.JoinMode = s.Joined and "Leave" or (not s.OnIsland and "Travel" or "Join")
	local function t(ms: number?): string
		return ms and ms > 0 and RaceConfig.formatTime(ms) or "-"
	end
	self.StatCells[1].Text = t(s.Best)
	self.StatCells[2].Text = t(s.MonthBest)
	self.StatCells[3].Text = Format.commas(s.Runs or 0)
	self.StatCells[4].Text = Format.commas(s.Wins or 0)
	self:RefreshPast()
	local data = self.Registry.DataController and self.Registry.DataController.all()
	local stats = data and data.Stats or {}
	if self.ArenaMine then
		self.ArenaMine.Text = string.format("YOU  -  %s knockouts   %s defeats", Format.commas(stats.ArenaKills or 0), Format.commas(stats.ArenaDeaths or 0))
	end
end

-- ============================================================== actions
function RaceWindow:OnJoin()
	if self.Busy then
		return
	end
	self.Busy = true
	self.JoinButton:SetBusy(true)
	task.spawn(function()
		local mode = self.JoinMode
		local res
		if mode == "Travel" then
			res = Net.request("Travel", "To", { Place = "RaceIsland" })
			if res.ok then
				self.UIC.Notify("success", "Welcome to the Race Island!")
				self.UIC.Close()
			end
		elseif mode == "Leave" then
			res = Net.request("Race", "Leave")
			if res.ok then
				self.UIC.Notify("info", "You left the lobby.")
			end
		else
			res = Net.request("Race", "Join")
			if res.ok then
				self.UIC.Notify("success", "You joined the race lobby - get ready!")
				self.UIC.Close()
			end
		end
		self.JoinButton:SetBusy(false)
		self.Busy = false
		if not res.ok then
			self.UIC.HandleResult(res)
		end
		self:Fetch()
	end)
end

function RaceWindow:ShowTab(tab: string)
	for id, page in self.Pages do
		page.Visible = id == tab
	end
	self.Tabs:Set(tab)
	self.Tab = tab
	if BOARD_OF[tab] then
		task.spawn(function()
			self:LoadBoard(tab)
		end)
	end
end

function RaceWindow:OnOpen(args)
	local tab = type(args) == "table" and args.Tab or "Race"
	if not self.Pages[tab] then
		tab = "Race"
	end
	self:ShowTab(tab)
	task.spawn(function()
		self:Fetch()
	end)
	if not self._ticking then
		self._ticking = true
		task.spawn(function()
			while true do
				task.wait(1)
				if self.Root.Visible then
					pcall(function()
						self:RefreshRace()
					end)
				end
			end
		end)
		task.spawn(function()
			while true do
				task.wait(4)
				if self.Root.Visible then
					pcall(function()
						self:Fetch()
					end)
				end
			end
		end)
	end
end

return RaceWindow

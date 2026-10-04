--[[
	DailyWindow
	The daily reward calendar (DailyService / DailyConfig): seven day cards, the streak, a CLAIM
	button for today's reward and a countdown to the next one. Server decides everything.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors

local DailyWindow = {}
DailyWindow.__index = DailyWindow
setmetatable(DailyWindow, { __index = WindowBase })

local GOLD = Color3.fromRGB(255, 196, 48)
local GREEN = Color3.fromRGB(110, 208, 104)

function DailyWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Daily",
		Title = "Daily Reward",
		Subtitle = "Come back every day",
		Icon = "Gift",
		Spec = {
			Desktop = { Width = 0.7, Height = 0.66, Aspect = 2.0 },
			Tablet = { Width = 0.92, Height = 0.78, Aspect = 1.7 },
			Phone = { Width = 0.96, Height = 1 },
			PhonePortrait = { Width = 0.96, Height = 1 },
		},
	})
	setmetatable(self, DailyWindow)
	self.UIC = ui
	self.Registry = registry
	self.Cards = {}
	self.State = nil
	self.Busy = false
	self.SnapshotAt = 0
	self:Build()
	return self
end

-- ============================================================== build
function DailyWindow:Build()
	local content = self.Content

	-- streak banner
	local banner = Kit.surface({ Name = "Banner", StrokeColor = GOLD, StrokeTransparency = 0.5, Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 0.17), Parent = content })
	self.Banner = banner
	self.StreakNumber = Kit.text({ Name = "Streak", Text = "0", Role = "Display", Scaled = true, Color = GOLD, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.02, 0.08), Size = UDim2.fromScale(0.1, 0.84), Parent = banner })
	self.StreakCaption = Kit.text({ Name = "StreakCaption", Text = "DAY STREAK", Role = "Heading", Scaled = true, Position = UDim2.fromScale(0.13, 0.12), Size = UDim2.fromScale(0.34, 0.42), Parent = banner })
	self.StreakHint = Kit.text({ Name = "StreakHint", Text = "", Role = "Caption", Scaled = true, Color = C.TextMuted, Position = UDim2.fromScale(0.13, 0.55), Size = UDim2.fromScale(0.5, 0.34), Truncate = true, Parent = banner })
	self.BonusBadge = Kit.badge({ Name = "Bonus", Text = "+0% CASH", Color = GREEN, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.98, 0.5), Size = UDim2.fromScale(0.22, 0.52), Parent = banner })

	-- the seven days
	local grid = Kit.frame({ Name = "Days", Position = UDim2.fromScale(0, 0.2), Size = UDim2.fromScale(1, 0.62), Parent = content })
	self.Grid = grid
	self.GridLayout = Instance.new("UIGridLayout")
	self.GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	self.GridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	self.GridLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	self.GridLayout.Parent = grid
	for i = 1, 7 do
		self:BuildCard(i, grid)
	end

	-- claim / countdown
	local bottom = Kit.frame({ Name = "Bottom", Position = UDim2.fromScale(0, 0.85), Size = UDim2.fromScale(1, 0.15), Parent = content })
	self.ClaimButton = Kit.button({ Name = "Claim", Text = "CLAIM", Style = "Success", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.34, 0.9), Parent = bottom })
	self.Countdown = Kit.text({ Name = "Countdown", Text = "", Role = "Heading", Scaled = true, XAlign = Enum.TextXAlignment.Center, Color = C.TextMuted, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.7, 0.8), Parent = bottom })
	self.Countdown.Visible = false
	self.ClaimButton.Activated:Connect(function()
		self:Claim()
	end)
end

function DailyWindow:BuildCard(i: number, parent: Instance)
	local card = Kit.surface({ Name = "Day" .. i, LayoutOrder = i, StrokeColor = GOLD, StrokeTransparency = 0.7, Parent = parent })
	local day = Kit.text({ Name = "DayLabel", Text = "DAY " .. i, Role = "Heading", Scaled = true, XAlign = Enum.TextXAlignment.Center, Color = C.TextMuted, Position = UDim2.fromScale(0.05, 0.05), Size = UDim2.fromScale(0.9, 0.15), Parent = card })
	local disc = Kit.frame({ Name = "IconDisc", BackgroundTransparency = 0, BackgroundColor3 = GOLD, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.22), Size = UDim2.fromScale(0.44, 0.44), SizeConstraint = Enum.SizeConstraint.RelativeXX, Parent = card })
	Kit.corner(disc, 999)
	local iconBox = Kit.frame({ Name = "IconBox", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.64, 0.64), Parent = disc })
	local text = Kit.text({ Name = "Reward", Text = "", Role = "Label", Scaled = true, Wrapped = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.64), Size = UDim2.fromScale(0.92, 0.32), Parent = card })
	local mark = Kit.frame({ Name = "DoneMark", BackgroundTransparency = 0.35, BackgroundColor3 = Color3.fromRGB(20, 40, 24), Size = UDim2.fromScale(1, 1), ZIndex = 5, Visible = false, Parent = card })
	Kit.corner(mark, "Card")
	local check = Kit.text({ Name = "Check", Text = "CLAIMED", Role = "Heading", Scaled = true, XAlign = Enum.TextXAlignment.Center, Color = GREEN, Position = UDim2.fromScale(0.05, 0.4), Size = UDim2.fromScale(0.9, 0.2), ZIndex = 6, Parent = mark })
	self.Cards[i] = { Card = card, Day = day, Disc = disc, IconBox = iconBox, Text = text, Mark = mark, Check = check, Icon = nil, IconName = "" }
end

-- ============================================================== layout
function DailyWindow:ApplyLayout()
	local R = Responsive
	local phone = R.Device == "Phone"
	local portrait = phone and R.Portrait
	local cols = portrait and 4 or 7
	local rows = math.ceil(7 / cols)
	local gap = R.px(portrait and 6 or 8)
	if self.GridLayout then
		self.GridLayout.CellPadding = UDim2.fromOffset(gap, gap)
		self.GridLayout.CellSize = UDim2.new(1 / cols, -math.ceil(gap * (cols - 1) / cols) - 1, 1 / rows, -math.ceil(gap * (rows - 1) / rows) - 1)
	end
	if self.Banner then
		self.Banner.Size = UDim2.fromScale(1, portrait and 0.15 or 0.17)
		self.Grid.Position = UDim2.fromScale(0, portrait and 0.18 or 0.2)
		self.Grid.Size = UDim2.fromScale(1, portrait and 0.64 or 0.62)
	end
end

-- ============================================================== data
local function icon(entry): string
	if entry.Egg then
		return "Egg"
	elseif entry.Boost then
		local b = MonetizationConfig.Boosts[entry.Boost.Id]
		return b and b.Icon or "Clover"
	elseif entry.Spins then
		return "Star"
	end
	return "Coin"
end

local function lines(entry): string
	local out = {}
	if entry.Cash then
		table.insert(out, Format.cash(entry.Cash))
	end
	if entry.Spins then
		table.insert(out, string.format("%d SPIN%s", entry.Spins, entry.Spins == 1 and "" or "S"))
	end
	if entry.Boost then
		local b = MonetizationConfig.Boosts[entry.Boost.Id]
		table.insert(out, string.format("%s %dM", b and b.Name or "BOOST", entry.Boost.Seconds // 60))
	end
	if entry.Egg then
		local def = EggConfig.Eggs[entry.Egg.Type]
		table.insert(out, string.format("%s x%d", string.upper(def and def.Name or "EGG"), entry.Egg.Luck))
	end
	return table.concat(out, "\n")
end

local function clockText(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", seconds // 3600, seconds % 3600 // 60, seconds % 60)
end

function DailyWindow:Render()
	local st = self.State
	if not st then
		return
	end
	self.StreakNumber.Text = tostring(st.Streak)
	self.StreakCaption.Text = st.Streak == 1 and "DAY STREAK" or "DAYS STREAK"
	self.StreakHint.Text = st.CanClaim and "Take today's reward to keep it going!" or "Streak is safe. Come back tomorrow."
	local bonus = math.floor((st.Bonus - 1) * 100 + 0.5)
	local badgeLabel = self.BonusBadge:FindFirstChild("Label")
	if badgeLabel then
		badgeLabel.Text = string.format("+%d%% CASH", bonus)
	end
	for i, view in self.Cards do
		local entry = st.Days[i]
		if entry then
			view.Text.Text = lines(entry)
			local name = icon(entry)
			if view.IconName ~= name then
				if view.Icon then
					view.Icon:Destroy()
				end
				view.Icon = Icons.make(name, { Color = C.Ink, Accent = C.Text, Ink = GOLD })
				view.Icon.Parent = view.IconBox
				view.IconName = name
			end
			local today = entry.State == "Today"
			local done = entry.State == "Done"
			view.Mark.Visible = done
			view.Day.TextColor3 = today and GOLD or C.TextMuted
			view.Card.BackgroundColor3 = today and Color3.fromRGB(70, 56, 24) or C.Surface
			local stroke = view.Card:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = today and GOLD or C.Gold
				stroke.Transparency = today and 0.05 or 0.72
				stroke.Thickness = today and 3 or 1
			end
			view.Disc.BackgroundColor3 = (done or entry.State == "Later") and Color3.fromRGB(150, 140, 120) or GOLD
		end
	end
	self.ClaimButton:SetVisible(st.CanClaim)
	self.Countdown.Visible = not st.CanClaim
	self:Tick()
end

function DailyWindow:Tick()
	local st = self.State
	if not st or st.CanClaim then
		return
	end
	local left = st.SecondsLeft - (os.clock() - self.SnapshotAt)
	self.Countdown.Text = "NEXT REWARD IN  " .. clockText(left)
end

function DailyWindow:Refresh()
	local res = Net.request("Daily", "State", {})
	if res.ok and res.data then
		self.State = res.data
		self.SnapshotAt = os.clock()
		self:Render()
	end
end

function DailyWindow:Claim()
	if self.Busy or not self.State or not self.State.CanClaim then
		return
	end
	self.Busy = true
	self.ClaimButton:SetBusy(true)
	task.spawn(function()
		local res = Net.request("Daily", "Claim", {})
		self.Busy = false
		self.ClaimButton:SetBusy(false)
		if res.ok then
			local controller = self.Registry and self.Registry.DailyController
			if controller then
				controller.clear()
			end
			self:Refresh()
		else
			self.UIC.HandleResult(res)
			self:Refresh()
		end
	end)
end

function DailyWindow:OnOpen()
	self.Shown = true
	task.spawn(function()
		self:Refresh()
	end)
	task.spawn(function()
		-- the countdown runs while the window is open
		while self.Shown and self.Root.Parent do
			self:Tick()
			task.wait(0.5)
		end
	end)
end

function DailyWindow:OnHidden()
	self.Shown = false
end

return DailyWindow

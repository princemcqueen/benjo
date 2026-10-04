--[[
	SpinWindow (Spin Island panel)
	Opening it frames the giant 3D wheel with the camera (no dark window
	over it). UI: a white bar at the bottom (spins left, free spin timer,
	big SPIN button, x5 auto spin, buy spins, close) and a slim prize card
	on the side with your current odds (luck applied).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local SpinConfig = require(Configs:WaitForChild("SpinConfig"))
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)

local C = Theme.Colors
local H = Theme.Hud
local LocalPlayer = Players.LocalPlayer

local SpinWindow = {}
SpinWindow.__index = SpinWindow

local function whitePanel(props): Frame
	local f = Create("Frame", {
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
	})
	for k, v in props do
		if k ~= "Parent" then
			(f :: any)[k] = v
		end
	end
	Kit.corner(f, 18)
	Kit.stroke(f, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), H.Shade), Parent = f })
	f.Parent = props.Parent
	return f :: Frame
end

local function segmentText(seg): string
	return seg.Label .. (seg.Jackpot and "  JACKPOT" or "")
end

function SpinWindow.new(ui, registry)
	local self = setmetatable({}, SpinWindow)
	self.UIC = ui
	self.Registry = registry
	self.Data = registry.DataController
	self.Name = "Spin"
	self.NoBackdrop = true
	self.Rows = {}
	self.Busy = false
	self.Auto = 0
	self.Root = Kit.frame({ Name = "SpinPanel", Size = UDim2.fromScale(1, 1) })
	self.Scale = Create("UIScale", { Parent = self.Root })
	self:Build()
	return self
end

function SpinWindow:Build()
	local root = self.Root
	-- ======================== bottom bar
	local bar = whitePanel({ Name = "Bar", AnchorPoint = Vector2.new(0.5, 1), Parent = root })
	self.Bar = bar
	-- spins block (left)
	local left = Kit.frame({ Name = "Spins", Position = UDim2.fromScale(0.03, 0.12), Size = UDim2.fromScale(0.27, 0.76), Parent = bar })
	Kit.text({ Name = "Caption", Text = "SPINS", Role = "Micro", Scaled = true, Color = H.TextMuted, Size = UDim2.fromScale(1, 0.24), Parent = left })
	self.SpinsText = Kit.text({ Name = "Count", Text = "0", Role = "Display", Scaled = true, Font = Theme.Fonts.Number, Color = H.Text, Position = UDim2.fromScale(0, 0.22), Size = UDim2.fromScale(1, 0.48), Parent = left })
	self.FreeText = Kit.text({ Name = "Free", Text = "", Role = "Label", Scaled = true, Color = H.TextMuted, Position = UDim2.fromScale(0, 0.72), Size = UDim2.fromScale(1, 0.26), Parent = left })
	-- SPIN (centre)
	local spin = Kit.button({ Name = "SpinButton", Text = "SPIN!", Icon = "Star", Style = "Primary", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.34, 0.72), Parent = bar })
	spin.Activated:Connect(function()
		self.Auto = 0
		self:Spin()
	end)
	self.SpinButton = spin
	self.SpinScale = Create("UIScale", { Parent = spin.Instance })
	-- right: auto x5, buy, close
	local right = Kit.frame({ Name = "Actions", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.975, 0.5), Size = UDim2.fromScale(0.28, 0.76), Parent = bar })
	Kit.list(right, "V", 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local auto = Kit.button({ Name = "Auto", Text = "AUTO x5", Style = "Blue", Size = UDim2.fromScale(1, 0.46), LayoutOrder = 1, Parent = right })
	auto.Activated:Connect(function()
		self.Auto = 5
		self:Spin()
	end)
	self.AutoButton = auto
	local buy = Kit.button({ Name = "Buy", Text = "BUY SPINS", Style = "Success", Size = UDim2.fromScale(1, 0.46), LayoutOrder = 2, Parent = right })
	buy.Activated:Connect(function()
		self.Packs.Visible = not self.Packs.Visible
	end)
	-- close (top-right corner of the bar)
	local close = Kit.closeButton({ Parent = root })
	close.Instance.AnchorPoint = Vector2.new(1, 0)
	close.Instance.SizeConstraint = Enum.SizeConstraint.RelativeYY
	close.Instance.Size = UDim2.fromScale(0.075, 0.075)
	self.CloseButton = close.Instance
	close.Activated:Connect(function()
		self.Auto = 0
		self.UIC.Close()
	end)
	-- buy popover (above the bar, right side)
	local packs = whitePanel({ Name = "Packs", AnchorPoint = Vector2.new(1, 1), Visible = false, Parent = root })
	self.Packs = packs
	Kit.padding(packs, 8)
	Kit.list(packs, "V", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	for i, id in { "SpinPack", "SpinPackBig" } do
		local def = MonetizationConfig.Products[id]
		local b = Kit.button({ Name = id, Text = def.Name .. "   R$ " .. def.Price, Style = "Success", Size = UDim2.fromScale(1, 0.46), LayoutOrder = i, Parent = packs })
		b.Activated:Connect(function()
			packs.Visible = false
			local shop = self.UIC.GetWindow and self.UIC.GetWindow("Shop")
			if shop and shop.Buy then
				shop:Buy(id)
				task.delay(0.8, function()
					self:Refresh()
				end)
			end
		end)
	end
	-- ======================== prize card (side)
	local card = whitePanel({ Name = "Prizes", AnchorPoint = Vector2.new(1, 0.5), Parent = root })
	self.Card = card
	local title = Kit.text({ Name = "Title", Text = "PRIZES", Role = "Heading", Scaled = true, Color = H.Text, Position = UDim2.fromScale(0.08, 0.02), Size = UDim2.fromScale(0.5, 0.07), Parent = card })
	local _ = title
	self.LuckTag = Kit.text({ Name = "Luck", Text = "", Role = "Label", Scaled = true, Color = Color3.fromRGB(46, 150, 70), XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.5, 0.025), Size = UDim2.fromScale(0.42, 0.06), Parent = card })
	local list = Kit.frame({ Name = "List", Position = UDim2.fromScale(0.05, 0.11), Size = UDim2.fromScale(0.9, 0.86), Parent = card })
	Kit.list(list, "V", 3, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local n = #SpinConfig.Segments
	for i, seg in SpinConfig.Segments do
		local row = Kit.frame({ Name = "Prize" .. i, Size = UDim2.new(1, 0, 1 / n, -3), LayoutOrder = i, Parent = list })
		local dot = Kit.frame({ BackgroundTransparency = 0, BackgroundColor3 = seg.Color, Position = UDim2.fromScale(0, 0.18), Size = UDim2.fromScale(0.64, 0.64), SizeConstraint = Enum.SizeConstraint.RelativeYY, Parent = row })
		Kit.corner(dot, 999)
		Kit.text({ Text = segmentText(seg), Role = "Label", Scaled = true, Color = seg.Jackpot and C.AccentDeep or H.Text, Position = UDim2.fromScale(0.14, 0.14), Size = UDim2.fromScale(0.6, 0.72), Parent = row })
		self.Rows[i] = Kit.text({ Text = "", Role = "Label", Scaled = true, Color = H.TextMuted, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.72, 0.14), Size = UDim2.fromScale(0.28, 0.72), Parent = row })
	end
	-- ======================== pulse the SPIN button while a spin is ready
	RunService.RenderStepped:Connect(function()
		if not self.Root.Visible then
			return
		end
		local ready = self.Ready and not self.Busy
		local s = ready and (1 + 0.04 * math.sin(os.clock() * 5)) or 1
		self.SpinScale.Scale = s
	end)
end

function SpinWindow:ApplySize()
	local R = Responsive
	local phone = R.Device == "Phone"
	local margin = R.px(phone and 10 or 18)
	if phone then
		self.Bar.Size = UDim2.new(0.96, 0, 0.22, 0)
		self.Bar.Position = UDim2.new(0.5, 0, 1, -margin)
		self.Card.Visible = not R.Portrait
		self.Card.Size = UDim2.fromScale(0.26, 0.56)
		self.Card.Position = UDim2.new(1, -margin, 0.36, 0)
		self.Packs.Size = UDim2.fromScale(0.5, 0.18)
	else
		self.Bar.Size = UDim2.new(0.56, 0, 0.13, 0)
		self.Bar.Position = UDim2.new(0.5, 0, 1, -margin)
		self.Card.Visible = true
		self.Card.Size = UDim2.fromScale(0.2, 0.52)
		self.Card.Position = UDim2.new(1, -margin, 0.42, 0)
		self.Packs.Size = UDim2.fromScale(0.2, 0.13)
	end
	self.Packs.Position = UDim2.new(0.5 + self.Bar.Size.X.Scale / 2, 0, 1, -(margin * 2 + math.floor(self.Root.AbsoluteSize.Y * self.Bar.Size.Y.Scale)))
	self.CloseButton.Position = UDim2.new(1, -margin, 0, R.TopInset + margin)
end

function SpinWindow:Refresh()
	local data = self.Data and self.Data.all()
	if not data then
		return
	end
	local s = data.Spin or { NextFree = 0, Tickets = 0 }
	local left = (tonumber(s.NextFree) or 0) - workspace:GetServerTimeNow()
	local tickets = tonumber(s.Tickets) or 0
	local freeReady = left <= 0
	local total = tickets + (freeReady and 1 or 0)
	self.SpinsText.Text = Format.commas(total)
	self.FreeText.Text = freeReady and "FREE SPIN READY!" or ("Free spin in " .. Format.duration(left))
	self.FreeText.TextColor3 = freeReady and Color3.fromRGB(46, 150, 70) or H.TextMuted
	self.Ready = total > 0
	self.SpinButton:SetEnabled(total > 0 and not self.Busy)
	self.AutoButton:SetEnabled(total > 1 and not self.Busy)
	local luck = (tonumber(LocalPlayer:GetAttribute("Luck")) or 1) * (1 + TreeConfig.bonus(data, "SpinLuck"))
	luck = math.floor(luck * 100 + 0.5) / 100
	for i, p in SpinConfig.odds(luck) do
		self.Rows[i].Text = Format.percent(p)
	end
	self.LuckTag.Text = luck > 1 and string.format("x%s LUCK", tostring(luck)) or ""
end

-- Result card: a white HUD card that sits just above the bottom bar (never over the wheel or
-- its sign), pops in, holds and shrinks away. Replaces the old giant text over the scene.
function SpinWindow:ShowPrize(text: string, color: Color3, jackpot: boolean?)
	if self.PrizeCard then
		self.PrizeCard:Destroy()
		self.PrizeCard = nil
	end
	local phone = Responsive.Device == "Phone"
	local margin = Responsive.px(phone and 10 or 18)
	local barH = math.floor(self.Root.AbsoluteSize.Y * self.Bar.Size.Y.Scale)
	local card = whitePanel({
		Name = "PrizeResult",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(margin * 2 + barH)),
		Size = phone and UDim2.fromScale(0.62, 0.17) or UDim2.fromScale(0.3, 0.115),
		ZIndex = 5,
		Parent = self.Root,
	})
	self.PrizeCard = card
	if jackpot then
		Kit.stroke(card, C.Accent, Theme.Stroke.Bold, 0)
	end
	local dot = Kit.frame({
		Name = "Dot",
		BackgroundTransparency = 0,
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.05, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = card,
	})
	Kit.corner(dot, 999)
	Kit.text({ Name = "Caption", Text = jackpot and "JACKPOT!" or "YOU WON", Role = "Micro", Scaled = true, Color = jackpot and C.AccentDeep or H.TextMuted, Position = UDim2.fromScale(0.27, 0.12), Size = UDim2.fromScale(0.68, 0.24), Parent = card })
	Kit.text({ Name = "Prize", Text = text, Role = "Display", Scaled = true, Font = Theme.Fonts.Number, Color = H.Text, Position = UDim2.fromScale(0.27, 0.36), Size = UDim2.fromScale(0.68, 0.52), Parent = card })
	local scale = Create("UIScale", { Scale = 0.6, Parent = card })
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(2.8, function()
		if self.PrizeCard == card then
			TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0 }):Play()
			task.delay(0.22, function()
				card:Destroy()
				if self.PrizeCard == card then
					self.PrizeCard = nil
				end
			end)
		end
	end)
end

function SpinWindow:Spin()
	if self.Busy then
		return
	end
	local spinner = self.Registry.SpinController
	if spinner and spinner.isSpinning() then
		return
	end
	self.Busy = true
	self.Packs.Visible = false
	self:Refresh()
	task.spawn(function()
		local res = Net.request("Spin", "Roll", {})
		if not res.ok then
			self.Busy = false
			self.Auto = 0
			self:Refresh()
			self.UIC.HandleResult(res)
			return
		end
		if spinner then
			spinner.play(res.data)
		end
		self.Busy = false
		self:Refresh()
		if self.Auto > 1 and self.Root.Visible and self.Ready then
			self.Auto -= 1
			self:Spin()
		else
			self.Auto = 0
		end
	end)
end

function SpinWindow:OnOpen()
	local spinner = self.Registry.SpinController
	if spinner then
		spinner.enterView()
	end
	-- entrance: bar slides up
	self.Bar.Position = UDim2.new(0.5, 0, 1.3, 0)
	self:ApplySize()
	local target = self.Bar.Position
	self.Bar.Position = UDim2.new(target.X.Scale, target.X.Offset, 1.3, 0)
	TweenService:Create(self.Bar, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = target }):Play()
	self:Refresh()
	if not self._ticking then
		self._ticking = true
		task.spawn(function()
			while true do
				task.wait(1)
				if self.Root.Visible then
					pcall(function()
						self:Refresh()
					end)
				end
			end
		end)
	end
end

function SpinWindow:OnHidden()
	self.Auto = 0
	local spinner = self.Registry.SpinController
	if spinner then
		spinner.exitView()
	end
end

return SpinWindow

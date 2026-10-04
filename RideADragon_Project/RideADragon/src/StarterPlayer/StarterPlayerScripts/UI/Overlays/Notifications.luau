--[[
	Notifications
	Centralized toast stack (top-center, below the cash display).
	- max 4 visible, extra ones queue
	- identical messages within a short window merge into "x2", "x3"
	- slide + fade in/out, never overlapping (UIListLayout stack)

	Kinds: "success" | "info" | "warning" | "error" | "rare"
]]

local TweenService = game:GetService("TweenService")

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)

local C = Theme.Colors

local Notifications = {}
Notifications.__index = Notifications

local MAX_VISIBLE = 4
local LIFETIME = 2.8
local MERGE_WINDOW = 1.5

local KINDS = {
	success = { Icon = "Check", Color = C.Success },
	info = { Icon = "Info", Color = C.Blue },
	warning = { Icon = "Warning", Color = C.Warning },
	error = { Icon = "Close", Color = C.Danger },
	rare = { Icon = "Sparkle", Color = C.GoldBright },
	cash = { Icon = "Coin", Color = C.GoldBright },
	egg = { Icon = "Egg", Color = C.Success },
}

function Notifications.new(layerRoot: Frame, onSound: ((string) -> ())?)
	local self = setmetatable({}, Notifications)
	self.OnSound = onSound
	self.Active = {} -- { { text, frame, count, born, countLabel } }
	self.Queue = {}
	self.Holder = Kit.frame({
		Name = "Notifications",
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.5, 0.3),
		Parent = layerRoot,
	})
	Kit.list(self.Holder, "V", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	self:Layout()
	Responsive.Changed:Connect(function()
		self:Layout()
	end)
	return self
end

function Notifications:Layout()
	-- Sits below the cash row on every device.
	local R = Responsive
	local short = math.min(R.Width, R.Height)
	local top
	if R.Device == "Phone" then
		top = R.TopInset + short * 0.2
		self.Holder.Size = UDim2.fromScale(R.Portrait and 0.92 or 0.6, 0.3)
	else
		top = R.TopInset + short * 0.145
		self.Holder.Size = UDim2.fromScale(0.5, 0.3)
	end
	self.Holder.Position = UDim2.new(0.5, 0, 0, math.floor(top))
end

function Notifications:Push(kind: string, text: string, extra: { [string]: any }?)
	local now = os.clock()
	for _, entry in self.Active do
		if entry.text == text and now - entry.born < MERGE_WINDOW + entry.count then
			entry.count += 1
			entry.countLabel.Text = "x" .. entry.count
			entry.countLabel.Visible = true
			entry.born = now
			return
		end
	end
	if #self.Active >= MAX_VISIBLE then
		table.insert(self.Queue, { kind, text, extra })
		if #self.Queue > 12 then
			table.remove(self.Queue, 1)
		end
		return
	end
	self:_show(kind, text, extra)
end

function Notifications:_show(kind: string, text: string, extra: { [string]: any }?)
	local spec = KINDS[kind] or KINDS.info
	local accent = (extra and extra.Color) or spec.Color
	local toast = Create("Frame", {
		Name = "Toast",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = math.floor(os.clock() * 1000) % 1000000,
		Parent = self.Holder,
	})
	Responsive.bind(toast, "Size", function(R)
		return UDim2.fromOffset(0, R.px(R.Device == "Phone" and 34 or 42))
	end)
	Kit.corner(toast, "pill")
	local stroke = Kit.stroke(toast, accent, Theme.Stroke.Normal, 0.35)
	Kit.padding(toast, 0, 18, 0, 8)
	Kit.list(toast, "H", 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local iconBg = Create("Frame", {
		Name = "IconBg",
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0.72, 0.72),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		LayoutOrder = 1,
		Parent = toast,
	})
	Kit.corner(iconBg, "pill")
	local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), Parent = iconBg })
	Icons.make(spec.Icon, { Color = C.Ink, Accent = C.Ink, Ink = accent }).Parent = iconBox
	local label = Kit.text({
		Name = "Message",
		Text = string.upper(text),
		Role = "Label",
		Font = Theme.Fonts.Label,
		Color = kind == "rare" and C.GoldBright or C.Text,
		Size = UDim2.fromScale(0, 1),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = toast,
	})
	local countLabel = Kit.text({
		Name = "Count",
		Text = "x2",
		Role = "Label",
		Font = Theme.Fonts.Number,
		Color = accent,
		Size = UDim2.fromScale(0, 1),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Parent = toast,
	})
	countLabel.Visible = false
	local scale = Create("UIScale", { Scale = 0.9, Parent = toast })

	local entry = { text = text, frame = toast, count = 1, born = os.clock(), countLabel = countLabel }
	table.insert(self.Active, entry)
	if self.OnSound then
		self.OnSound(kind == "error" and "Error" or "Notify")
	end

	-- entrance
	toast.BackgroundTransparency = 1
	label.TextTransparency = 1
	stroke.Transparency = 1
	iconBg.BackgroundTransparency = 1
	local info = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(scale, info, { Scale = 1 }):Play()
	TweenService:Create(toast, info, { BackgroundTransparency = 0.08 }):Play()
	TweenService:Create(label, info, { TextTransparency = 0 }):Play()
	TweenService:Create(stroke, info, { Transparency = 0.35 }):Play()
	TweenService:Create(iconBg, info, { BackgroundTransparency = 0 }):Play()

	task.spawn(function()
		while os.clock() - entry.born < LIFETIME do
			task.wait(0.1)
		end
		local outInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(toast, outInfo, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(label, outInfo, { TextTransparency = 1 }):Play()
		TweenService:Create(countLabel, outInfo, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, outInfo, { Transparency = 1 }):Play()
		TweenService:Create(iconBg, outInfo, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(scale, outInfo, { Scale = 0.92 }):Play()
		task.wait(0.17)
		local i = table.find(self.Active, entry)
		if i then
			table.remove(self.Active, i)
		end
		toast:Destroy()
		if #self.Queue > 0 then
			local nxt = table.remove(self.Queue, 1)
			self:_show(nxt[1], nxt[2], nxt[3])
		end
	end)
end

function Notifications:Clear()
	for _, entry in self.Active do
		entry.frame:Destroy()
	end
	self.Active = {}
	self.Queue = {}
end

return Notifications

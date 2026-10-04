--[[
	WindowBase
	Shared frame for every major window: glass panel, header (icon, title,
	subtitle, close/back button), content area, responsive sizing per device.

	Spec per device: { Width, Height, Aspect? } as fractions of the screen.
	Desktop windows keep their aspect ratio (FitWithinMaxSize) so the inner
	Scale layout never stretches on ultrawide / 16:10 / 4K.
]]

local UI = script.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)

local C = Theme.Colors

local WindowBase = {}
WindowBase.__index = WindowBase

local DEFAULT_SPEC = {
	Desktop = { Width = 0.66, Height = 0.78, Aspect = 1.6 },
	Tablet = { Width = 0.9, Height = 0.84, Aspect = 1.5 },
	Phone = { Width = 0.96, Height = 1, Aspect = nil },
	PhonePortrait = { Width = 0.96, Height = 1, Aspect = nil },
}

function WindowBase.new(opts: { [string]: any })
	local self = setmetatable({}, WindowBase)
	self.Name = opts.Name
	self.Spec = opts.Spec or DEFAULT_SPEC
	self.OnClose = nil -- set by UIController
	self.OnBack = nil -- window may override (mobile sub-panels)

	local win = Kit.window({ Name = opts.Name .. "Window" })
	self.Root = win.Root
	self.Body = win.Body
	self.Scale = Create("UIScale", { Parent = self.Root })
	self.Aspect = Create("UIAspectRatioConstraint", { AspectRatio = 1.6, Parent = self.Root })

	-- header
	local header = Kit.frame({ Name = "Header", Size = UDim2.fromScale(1, 0.1), Parent = self.Body })
	self.Header = header
	local headerPad = Kit.frame({ Name = "HeaderPad", Size = UDim2.fromScale(1, 1), Parent = header })
	Kit.padding(headerPad, 0, 18, 0, 22)
	self.HeaderPad = headerPad

	local titleRow = Kit.frame({ Name = "TitleRow", Size = UDim2.fromScale(0.86, 1), Parent = headerPad })
	Kit.list(titleRow, "H", 14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local iconBg = Create("Frame", {
		Name = "IconBg",
		Size = UDim2.fromScale(0.6, 0.6),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Parent = titleRow,
	})
	Kit.corner(iconBg, 9)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(C.AccentHover, C.AccentDeep), Parent = iconBg })
	local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.64, 0.64), Parent = iconBg })
	Icons.make(opts.Icon or "Dragon", { Color = C.Ink, Accent = C.Text, Ink = C.Accent }).Parent = iconBox
	self.IconBg = iconBg

	self.Title = Kit.text({
		Name = "Title",
		Text = string.upper(opts.Title or opts.Name),
		Role = "Title",
		Size = UDim2.fromScale(0, 0.6),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = titleRow,
	})
	self.Subtitle = Kit.text({
		Name = "Subtitle",
		Text = opts.Subtitle or "",
		Role = "Label",
		Font = Theme.Fonts.Label,
		Color = C.TextMuted,
		Size = UDim2.fromScale(0, 0.5),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Parent = titleRow,
	})

	self.Close = Kit.closeButton({ Parent = headerPad })
	self.Close.Activated:Connect(function()
		if self.OnBack and self.OnBack() then
			return
		end
		if self.OnClose then
			self.OnClose()
		end
	end)
	self.BackIcon = nil

	Kit.divider(self.Body, {
		Name = "HeaderDivider",
		Position = UDim2.fromScale(0.5, 0.1),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.new(0.96, 0, 0, 1),
	})

	-- content area under the header
	self.Content = Kit.frame({
		Name = "Content",
		Position = UDim2.fromScale(0, 0.1),
		Size = UDim2.fromScale(1, 0.9),
		Parent = self.Body,
	})
	self.ContentPad = Kit.padding(self.Content, 14, 22, 20, 22)

	-- overlay for popovers (always above content)
	self.Overlay = Kit.frame({ Name = "Overlay", Size = UDim2.fromScale(1, 1), ZIndex = 40, Parent = self.Body })

	self:ApplySize()
	return self
end

function WindowBase:SetSubtitle(text: string)
	self.Subtitle.Text = text
end

function WindowBase:DeviceSpec()
	local R = Responsive
	local key = R.Device
	if key == "Phone" and R.Portrait then
		key = "PhonePortrait"
	end
	return self.Spec[key] or self.Spec[R.Device] or DEFAULT_SPEC[key] or DEFAULT_SPEC.Desktop
end

function WindowBase:ApplySize()
	local R = Responsive
	local spec = self:DeviceSpec()
	local root = self.Root
	if R.Device == "Phone" then
		-- fill the safe area below the Roblox top bar
		local margin = R.px(8)
		root.AnchorPoint = Vector2.new(0.5, 1)
		root.Position = UDim2.new(0.5, 0, 1, -margin)
		root.Size = UDim2.new(spec.Width, 0, spec.Height, -(R.TopInset + margin * 2))
	else
		root.AnchorPoint = Vector2.new(0.5, 0.5)
		root.Position = UDim2.fromScale(0.5, 0.52)
		root.Size = UDim2.fromScale(spec.Width, spec.Height)
	end
	if spec.Aspect then
		self.Aspect.AspectRatio = spec.Aspect
		self.Aspect.Parent = root
	else
		self.Aspect.Parent = nil
	end
	-- header proportions
	local headerScale = R.Device == "Phone" and (R.Portrait and 0.075 or 0.14) or 0.1
	self.Header.Size = UDim2.fromScale(1, headerScale)
	self.Content.Position = UDim2.fromScale(0, headerScale)
	self.Content.Size = UDim2.fromScale(1, 1 - headerScale)
	local divider = self.Body:FindFirstChild("HeaderDivider")
	if divider then
		divider.Position = UDim2.fromScale(0.5, headerScale)
	end
	if self.ApplyLayout then
		self:ApplyLayout()
	end
end

return WindowBase

--[[
	Kit
	The component library every menu is built from. One look, one behaviour:
	consistent radii, strokes, typography, hover/press feedback.

	All primary geometry is Scale/AnchorPoint based. Offsets are only used for
	padding, corner radius, stroke width and text size - and those are bound
	to the Responsive unit so they keep their relative size from 720p to 4K.
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local UI = script.Parent
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Create = require(UI:WaitForChild("Create"))
local Icons = require(UI:WaitForChild("Icons"))

local C = Theme.Colors
local T = Theme.Transparency

local Kit = {}

-- Hooks set by UIController (sounds, tooltips).
Kit.hooks = {
	Click = function() end,
	Hover = function() end,
	ShowTooltip = function(_text: string, _anchor: GuiObject) end,
	HideTooltip = function() end,
}

-- ============================================================== helpers
local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end
Kit.tween = tween

function Kit.corner(parent: Instance, radius: number | string)
	local c = Instance.new("UICorner")
	if radius == "pill" then
		c.CornerRadius = UDim.new(0.5, 0)
	else
		local px = type(radius) == "number" and radius or Theme.Radius[radius] or Theme.Radius.Button
		Responsive.bind(c, "CornerRadius", function(R)
			return UDim.new(0, R.px(px))
		end)
	end
	c.Parent = parent
	return c
end

function Kit.stroke(parent: Instance, color: Color3, thickness: number?, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	local th = thickness or Theme.Stroke.Normal
	Responsive.bind(s, "Thickness", function(R)
		return math.max(1, R.pxf(th))
	end)
	s.Parent = parent
	return s
end

function Kit.padding(parent: Instance, top: number, right: number?, bottom: number?, left: number?)
	local p = Instance.new("UIPadding")
	local r, b, l = right or top, bottom or top, left or right or top
	Responsive.bind(p, "PaddingTop", function(R)
		return UDim.new(0, R.px(top))
	end)
	Responsive.bind(p, "PaddingRight", function(R)
		return UDim.new(0, R.px(r))
	end)
	Responsive.bind(p, "PaddingBottom", function(R)
		return UDim.new(0, R.px(b))
	end)
	Responsive.bind(p, "PaddingLeft", function(R)
		return UDim.new(0, R.px(l))
	end)
	p.Parent = parent
	return p
end

-- Padding as a fraction of the parent's size (pure scale).
function Kit.scalePadding(parent: Instance, top: number, right: number?, bottom: number?, left: number?)
	return Create("UIPadding", {
		PaddingTop = UDim.new(top, 0),
		PaddingRight = UDim.new(right or top, 0),
		PaddingBottom = UDim.new(bottom or top, 0),
		PaddingLeft = UDim.new(left or right or top, 0),
		Parent = parent,
	})
end

function Kit.list(parent: Instance, direction: "H" | "V", gapPx: number?, hAlign: Enum.HorizontalAlignment?, vAlign: Enum.VerticalAlignment?)
	local l = Instance.new("UIListLayout")
	l.FillDirection = direction == "H" and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left
	l.VerticalAlignment = vAlign or Enum.VerticalAlignment.Top
	if gapPx then
		Responsive.bind(l, "Padding", function(R)
			return UDim.new(0, R.px(gapPx))
		end)
	end
	l.Parent = parent
	return l
end

function Kit.aspect(parent: Instance, ratio: number)
	return Create("UIAspectRatioConstraint", { AspectRatio = ratio, Parent = parent })
end

function Kit.frame(props: { [any]: any }?)
	local p = props or {}
	local f = Create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	for k, v in p do
		if k ~= "Parent" then
			(f :: any)[k] = v
		end
	end
	if p.Parent then
		f.Parent = p.Parent
	end
	return f
end

-- ============================================================== text
function Kit.text(opts: { [string]: any })
	local role = opts.Role or "Body"
	local label = Create("TextLabel", {
		Name = opts.Name or "Text",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = opts.Text or "",
		Font = opts.Font or Theme.Fonts[role] or Theme.Fonts.Body,
		TextColor3 = opts.Color or C.Text,
		TextXAlignment = opts.XAlign or Enum.TextXAlignment.Left,
		TextYAlignment = opts.YAlign or Enum.TextYAlignment.Center,
		TextWrapped = opts.Wrapped == true,
		RichText = opts.RichText == true,
		TextTruncate = opts.Truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		AutomaticSize = opts.AutoSize or Enum.AutomaticSize.None,
		LayoutOrder = opts.LayoutOrder or 0,
		TextTransparency = opts.Transparency or 0,
		ZIndex = opts.ZIndex or 1,
	})
	if opts.Scaled then
		label.TextScaled = true
		local maxSize = opts.MaxRole or role
		local tsc = Instance.new("UITextSizeConstraint")
		Responsive.bind(tsc, "MaxTextSize", function(R)
			return R.text(maxSize)
		end)
		tsc.MinTextSize = opts.MinTextSize or 8
		tsc.Parent = label
	else
		Responsive.bind(label, "TextSize", function(R)
			return R.text(role)
		end)
	end
	if opts.Parent then
		label.Parent = opts.Parent
	end
	return label
end

-- ============================================================== panels
-- Glass window: returns { Root, Body } (Root holds soft shadow layers).
function Kit.window(opts: { [string]: any })
	local root = Kit.frame({
		Name = opts.Name or "Window",
		AnchorPoint = opts.AnchorPoint or Vector2.new(0.5, 0.5),
		Position = opts.Position or UDim2.fromScale(0.5, 0.5),
		Size = opts.Size or UDim2.fromScale(0.66, 0.76),
	})
	-- soft shadow: three expanding layers
	for i, spread in { 8, 18, 34 } do
		local sh = Kit.frame({
			Name = "Shadow" .. i,
			-- decorative; allowed to bleed past the screen edge

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			BackgroundColor3 = C.Black,
			BackgroundTransparency = ({ 0.8, 0.88, 0.94 })[i],
			ZIndex = 0,
			Parent = root,
		})
		sh:SetAttribute("QAAllowOffscreen", true)
		Responsive.bind(sh, "Size", function(R)
			return UDim2.new(1, R.px(spread), 1, R.px(spread))
		end)
		Responsive.bind(sh, "Position", function(R)
			return UDim2.new(0.5, 0, 0.5, R.px(spread * 0.25))
		end)
		Kit.corner(sh, Theme.Radius.Window + spread * 0.5)
	end
	local body = Create("Frame", {
		Name = "Body",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = T.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = false,
		ZIndex = 1,
		Parent = root,
	})
	Kit.corner(body, "Window")
	Kit.stroke(body, C.Gold, Theme.Stroke.Normal, 0.45)
	Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(196, 200, 210)),
		}),
		Parent = body,
	})
	-- top inner highlight for the glass look
	local hl = Kit.frame({
		Name = "Highlight",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(0.92, 0, 0, 1),
		BackgroundColor3 = C.GoldBright,
		BackgroundTransparency = 0.55,
		Parent = body,
	})
	Create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = hl,
	})
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return { Root = root, Body = body }
end

-- Card surface (no shadow).
function Kit.surface(opts: { [string]: any })
	local f = Create("Frame", {
		Name = opts.Name or "Surface",
		BackgroundColor3 = opts.Color or C.Surface,
		BackgroundTransparency = opts.Transparency or T.Surface,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		ZIndex = opts.ZIndex or 1,
	})
	Kit.corner(f, opts.Radius or "Card")
	if opts.Stroke ~= false then
		Kit.stroke(f, opts.StrokeColor or C.Gold, Theme.Stroke.Hairline, opts.StrokeTransparency or 0.72)
	end
	if opts.Parent then
		f.Parent = opts.Parent
	end
	return f
end

function Kit.divider(parent: Instance, props: { [string]: any }?)
	local p = props or {}
	local d = Kit.frame({
		Name = "Divider",
		BackgroundColor3 = p.Color or C.Gold,
		BackgroundTransparency = p.Transparency or 0.55,
		Size = p.Size or UDim2.new(1, 0, 0, 1),
		Position = p.Position or UDim2.new(),
		AnchorPoint = p.AnchorPoint or Vector2.zero,
		LayoutOrder = p.LayoutOrder or 0,
		Parent = parent,
	})
	Create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0),
			NumberSequenceKeypoint.new(0.85, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = d,
	})
	return d
end

-- ============================================================== buttons
local STYLES = {
	Primary = { Bg = C.Accent, Hover = C.AccentHover, Text = C.Ink, Stroke = nil, Grad = true },
	Gold = { Bg = C.Gold, Hover = C.GoldBright, Text = C.Ink, Stroke = nil, Grad = true },
	Secondary = { Bg = C.Surface, Hover = C.SurfaceHover, Text = C.Text, Stroke = C.Gold, StrokeT = 0.55 },
	Danger = { Bg = C.Danger, Hover = C.DangerHover, Text = C.Text, Stroke = nil, Grad = true },
	Success = { Bg = C.Success, Hover = Color3.fromRGB(130, 220, 136), Text = C.Ink, Grad = true },
	Ghost = { Bg = C.Surface, Hover = C.SurfaceHover, Text = C.TextMuted, Stroke = nil, BgT = 0.6 },
	Blue = { Bg = C.BlueDeep, Hover = C.Blue, Text = C.Text, Grad = true },
}
Kit.ButtonStyles = STYLES

function Kit.button(opts: { [string]: any })
	local self = {}
	self.Activated = Signal.new()
	self.Style = opts.Style or "Primary"
	self.Enabled = opts.Enabled ~= false
	self.Busy = false

	local root = Create("TextButton", {
		Name = opts.Name or "Button",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		ZIndex = opts.ZIndex or 1,
		Selectable = true,
	})
	self.Instance = root
	Kit.corner(root, opts.Radius or "Button")
	local stroke = Kit.stroke(root, C.Gold, Theme.Stroke.Hairline, 1)
	local grad = Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(214, 214, 214)),
		Parent = root,
	})
	local scale = Create("UIScale", { Parent = root })

	local content = Kit.frame({ Name = "Content", Size = UDim2.fromScale(1, 1), Parent = root })
	Kit.list(content, "H", 7, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	local icon: Frame? = nil
	if opts.Icon then
		local holder = Kit.frame({ Name = "IconHolder", Size = UDim2.fromScale(0.5, 0.5), SizeConstraint = Enum.SizeConstraint.RelativeYY, LayoutOrder = 1, Parent = content })
		icon = Icons.make(opts.Icon, { Color = C.Text, Accent = C.Accent, Ink = C.Panel })
		icon.Parent = holder
		self.IconHolder = holder
	end
	local label = Kit.text({
		Name = "Label",
		Text = opts.Text or "",
		Role = opts.TextRole or "Label",
		Font = Theme.Fonts.Title,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(0, 0.7),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = content,
	})
	self.Label = label
	if (opts.Text or "") == "" then
		label.Visible = false
	end

	local hovering = false
	local function paint(animated: boolean)
		local st = STYLES[self.Style] or STYLES.Primary
		local bg, txt
		if not self.Enabled then
			bg, txt = C.Disabled, C.TextDim
		else
			bg = hovering and st.Hover or st.Bg
			txt = st.Text
		end
		local bgT = self.Enabled and (st.BgT or 0) or 0.2
		if animated then
			tween(root, Theme.Motion.Hover, { BackgroundColor3 = bg, BackgroundTransparency = bgT })
		else
			root.BackgroundColor3 = bg
			root.BackgroundTransparency = bgT
		end
		label.TextColor3 = txt
		grad.Enabled = st.Grad == true and self.Enabled
		if st.Stroke and self.Enabled then
			stroke.Color = st.Stroke
			stroke.Transparency = hovering and 0.2 or (st.StrokeT or 0.5)
		else
			stroke.Transparency = 1
		end
		if icon then
			local ic = self.Enabled and txt or C.TextDim
			if self._iconColor ~= ic then
				local prev = self._iconColor or C.Text
				Icons.recolor(icon, prev, ic)
				self._iconColor = ic
			end
		end
	end
	self._paint = paint

	root.MouseEnter:Connect(function()
		hovering = true
		if self.Enabled and not self.Busy then
			Kit.hooks.Hover()
		end
		paint(true)
		if opts.Tooltip then
			Kit.hooks.ShowTooltip(opts.Tooltip, root)
		end
	end)
	root.MouseLeave:Connect(function()
		hovering = false
		paint(true)
		tween(scale, Theme.Motion.Press, { Scale = 1 })
		if opts.Tooltip then
			Kit.hooks.HideTooltip()
		end
	end)
	root.MouseButton1Down:Connect(function()
		if self.Enabled and not self.Busy then
			tween(scale, Theme.Motion.Press, { Scale = Theme.Motion.PressScale })
		end
	end)
	root.MouseButton1Up:Connect(function()
		tween(scale, Theme.Motion.Press * 1.6, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	root.Activated:Connect(function()
		if not self.Enabled or self.Busy then
			return
		end
		Kit.hooks.Click()
		self.Activated:Fire()
	end)

	function self:SetText(text: string)
		label.Text = text
		label.Visible = text ~= ""
	end
	function self:SetStyle(style: string)
		self.Style = style
		paint(false)
	end
	function self:SetEnabled(enabled: boolean)
		self.Enabled = enabled
		paint(false)
	end
	function self:SetBusy(busy: boolean)
		self.Busy = busy
		root.Active = not busy
		label.TextTransparency = busy and 0.45 or 0
	end
	function self:SetVisible(v: boolean)
		root.Visible = v
	end
	function self:Destroy()
		self.Activated:Destroy()
		root:Destroy()
	end

	paint(false)
	if opts.OnClick then
		self.Activated:Connect(opts.OnClick)
	end
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

-- Square glass icon button with a caption (HUD).
function Kit.hudButton(opts: { [string]: any })
	local self = {}
	self.Activated = Signal.new()
	local root = Create("TextButton", {
		Name = opts.Name or "HudButton",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Theme.Hud.Panel,
		BackgroundTransparency = Theme.Hud.Transparency,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		LayoutOrder = opts.LayoutOrder or 0,
		Selectable = true,
	})
	self.Instance = root
	Kit.aspect(root, opts.Aspect or 0.92)
	Kit.corner(root, 14)
	local stroke = Kit.stroke(root, Theme.Hud.Stroke, Theme.Stroke.Normal, Theme.Hud.StrokeTransparency)
	Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Theme.Hud.Shade),
		Parent = root,
	})
	local scale = Create("UIScale", { Parent = root })
	local iconHolder = Kit.frame({
		Name = "IconHolder",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.13),
		Size = UDim2.fromScale(0.5, 0.5),
		Parent = root,
	})
	Kit.aspect(iconHolder, 1)
	local icon = Icons.make(opts.Icon, { Color = Theme.Hud.Icon, Accent = C.Accent, Ink = Theme.Hud.Panel })
	icon.Parent = iconHolder
	local caption = Kit.text({
		Name = "Caption",
		Text = opts.Text or "",
		Role = "Micro",
		Font = Theme.Fonts.Micro,
		Color = Theme.Hud.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.93),
		Size = UDim2.fromScale(0.96, 0.24),
		Parent = root,
	})
	self.Caption = caption
	-- notification badge
	local badge = Create("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.9, 0.1),
		Size = UDim2.fromScale(0.3, 0.3),
		BackgroundColor3 = C.Danger,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = root,
	})
	Kit.aspect(badge, 1)
	Kit.corner(badge, "pill")
	Kit.stroke(badge, Theme.Hud.Panel, 2, 0)
	local badgeText = Kit.text({
		Text = "",
		Role = "Micro",
		XAlign = Enum.TextXAlignment.Center,
		ZIndex = 4,
		Parent = badge,
	})

	local hovering = false
	root.MouseEnter:Connect(function()
		hovering = true
		Kit.hooks.Hover()
		tween(stroke, Theme.Motion.Hover, { Transparency = 0 })
		tween(root, Theme.Motion.Hover, { BackgroundTransparency = 0 })
		caption.TextColor3 = Theme.Hud.Text
		if opts.Tooltip then
			Kit.hooks.ShowTooltip(opts.Tooltip, root)
		end
	end)
	root.MouseLeave:Connect(function()
		hovering = false
		tween(stroke, Theme.Motion.Hover, { Transparency = self.Active and 0 or Theme.Hud.StrokeTransparency })
		tween(root, Theme.Motion.Hover, { BackgroundTransparency = Theme.Hud.Transparency })
		tween(scale, Theme.Motion.Press, { Scale = 1 })
		caption.TextColor3 = self.Active and C.AccentDeep or Theme.Hud.TextMuted
		Kit.hooks.HideTooltip()
	end)
	root.MouseButton1Down:Connect(function()
		tween(scale, Theme.Motion.Press, { Scale = 0.93 })
	end)
	root.MouseButton1Up:Connect(function()
		tween(scale, 0.1, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	root.Activated:Connect(function()
		Kit.hooks.Click()
		self.Activated:Fire()
	end)

	function self:SetActive(active: boolean)
		self.Active = active
		stroke.Color = active and C.Accent or Theme.Hud.Stroke
		stroke.Transparency = active and 0.05 or (hovering and 0.1 or 0.62)
		caption.TextColor3 = active and C.AccentDeep or (hovering and Theme.Hud.Text or Theme.Hud.TextMuted)
	end
	function self:SetBadge(count: number?)
		if count and count > 0 then
			badge.Visible = true
			badgeText.Text = count > 9 and "9+" or tostring(count)
		else
			badge.Visible = false
		end
	end
	if opts.OnClick then
		self.Activated:Connect(opts.OnClick)
	end
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

function Kit.closeButton(opts: { [string]: any })
	local self = {}
	self.Activated = Signal.new()
	local root = Create("TextButton", {
		Name = "Close",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.Surface,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		AnchorPoint = opts.AnchorPoint or Vector2.new(1, 0.5),
		Position = opts.Position or UDim2.fromScale(1, 0.5),
		Size = opts.Size or UDim2.fromScale(0.62, 0.62),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		ZIndex = opts.ZIndex or 2,
		Selectable = true,
	})
	self.Instance = root
	Kit.corner(root, "pill")
	local stroke = Kit.stroke(root, C.Gold, Theme.Stroke.Hairline, 0.55)
	local holder = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.42, 0.42), Parent = root })
	local icon = Icons.make("Close", { Color = C.TextMuted })
	icon.Parent = holder
	local scale = Create("UIScale", { Parent = root })
	root.MouseEnter:Connect(function()
		Kit.hooks.Hover()
		tween(root, Theme.Motion.Hover, { BackgroundColor3 = C.Accent })
		Icons.recolor(icon, C.TextMuted, C.Ink)
		stroke.Transparency = 1
	end)
	root.MouseLeave:Connect(function()
		tween(root, Theme.Motion.Hover, { BackgroundColor3 = C.Surface })
		Icons.recolor(icon, C.Ink, C.TextMuted)
		stroke.Transparency = 0.55
		tween(scale, Theme.Motion.Press, { Scale = 1 })
	end)
	root.MouseButton1Down:Connect(function()
		tween(scale, Theme.Motion.Press, { Scale = 0.9 })
	end)
	root.Activated:Connect(function()
		Kit.hooks.Click()
		self.Activated:Fire()
	end)
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

-- ============================================================== chips / segmented
function Kit.chip(opts: { [string]: any })
	local self = {}
	self.Activated = Signal.new()
	self.ActiveState = false
	local root = Create("TextButton", {
		Name = opts.Name or "Chip",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.SurfaceDeep,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(0, 1),
		AutomaticSize = opts.Size and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		LayoutOrder = opts.LayoutOrder or 0,
		Selectable = true,
	})
	self.Instance = root
	Kit.corner(root, "pill")
	local stroke = Kit.stroke(root, C.Gold, Theme.Stroke.Hairline, 0.75)
	local content = Kit.frame({ Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, Parent = root })
	if not opts.Size then
		Kit.padding(content, 0, 14, 0, 14)
	else
		content.Size = UDim2.fromScale(1, 1)
		content.AutomaticSize = Enum.AutomaticSize.None
	end
	Kit.list(content, "H", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	if opts.Dot then
		local dot = Create("Frame", {
			Name = "Dot",
			BackgroundColor3 = opts.Dot,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0.28, 0.28),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			LayoutOrder = 1,
			Parent = content,
		})
		Kit.corner(dot, "pill")
	end
	local label = Kit.text({
		Text = opts.Text or "",
		Role = opts.Role or "Micro",
		Font = Theme.Fonts.Label,
		Color = C.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(0, 1),
		AutoSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = content,
	})
	self.Label = label
	local function paint()
		if self.ActiveState then
			root.BackgroundColor3 = C.Accent
			root.BackgroundTransparency = 0
			label.TextColor3 = C.Ink
			stroke.Transparency = 1
		else
			root.BackgroundColor3 = C.SurfaceDeep
			root.BackgroundTransparency = 0.25
			label.TextColor3 = C.TextMuted
			stroke.Transparency = 0.75
		end
	end
	root.MouseEnter:Connect(function()
		if not self.ActiveState then
			label.TextColor3 = C.Text
			stroke.Transparency = 0.35
		end
	end)
	root.MouseLeave:Connect(paint)
	root.Activated:Connect(function()
		Kit.hooks.Click()
		self.Activated:Fire()
	end)
	function self:SetActive(active: boolean)
		self.ActiveState = active
		paint()
	end
	paint()
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

function Kit.segmented(opts: { [string]: any })
	local self = {}
	self.Changed = Signal.new()
	self.Value = opts.Value or opts.Options[1]
	local root = Create("Frame", {
		Name = opts.Name or "Segmented",
		BackgroundColor3 = C.SurfaceDeep,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
	})
	self.Instance = root
	Kit.corner(root, "pill")
	Kit.padding(root, 3)
	Kit.list(root, "H", 3, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local n = #opts.Options
	local chips = {}
	for i, option in opts.Options do
		local chip = Kit.chip({
			Text = (opts.Labels and opts.Labels[i]) or string.upper(option),
			Size = UDim2.new(1 / n, -4, 1, 0),
			LayoutOrder = i,
			Parent = root,
		})
		chips[option] = chip
		chip.Activated:Connect(function()
			if self.Value ~= option then
				self:Set(option)
				self.Changed:Fire(option)
			end
		end)
	end
	function self:Set(value: string)
		self.Value = value
		for opt, chip in chips do
			chip:SetActive(opt == value)
		end
	end
	self:Set(self.Value)
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

-- ============================================================== progress / toggle / slider
function Kit.progress(opts: { [string]: any })
	local self = {}
	local track = Create("Frame", {
		Name = opts.Name or "Progress",
		BackgroundColor3 = opts.Track or C.SurfaceDeep,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		ClipsDescendants = true,
	})
	self.Instance = track
	Kit.corner(track, "pill")
	local fill = Create("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.White,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	Kit.corner(fill, "pill")
	local c0 = opts.Color or C.Accent
	local c1 = opts.Color2 or C.GoldBright
	local grad = Create("UIGradient", { Color = ColorSequence.new(c0, c1), Parent = fill })
	self.Fill = fill
	self.Value = 0
	function self:SetValue(v: number, animated: boolean?)
		v = math.clamp(v, 0, 1)
		self.Value = v
		local target = UDim2.fromScale(v, 1)
		if animated then
			tween(fill, 0.25, { Size = target })
		else
			fill.Size = target
		end
	end
	function self:SetColors(a: Color3, b: Color3?)
		grad.Color = ColorSequence.new(a, b or a)
	end
	if opts.Parent then
		track.Parent = opts.Parent
	end
	return self
end

function Kit.toggle(opts: { [string]: any })
	local self = {}
	self.Changed = Signal.new()
	self.Value = opts.Value == true
	local root = Create("TextButton", {
		Name = opts.Name or "Toggle",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = C.SurfaceDeep,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		Selectable = true,
	})
	self.Instance = root
	Kit.aspect(root, 1.9)
	Kit.corner(root, "pill")
	Kit.stroke(root, C.Gold, Theme.Stroke.Hairline, 0.6)
	local knob = Create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromScale(0.42, 0.8),
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(knob, "pill")
	local function paint(animated)
		local pos = self.Value and UDim2.fromScale(0.54, 0.5) or UDim2.fromScale(0.04, 0.5)
		local bg = self.Value and C.Accent or C.SurfaceDeep
		if animated then
			tween(knob, 0.12, { Position = pos })
			tween(root, 0.12, { BackgroundColor3 = bg })
		else
			knob.Position = pos
			root.BackgroundColor3 = bg
		end
		knob.BackgroundColor3 = self.Value and C.Ink or C.TextMuted
	end
	root.Activated:Connect(function()
		Kit.hooks.Click()
		self.Value = not self.Value
		paint(true)
		self.Changed:Fire(self.Value)
	end)
	function self:Set(v: boolean)
		self.Value = v
		paint(false)
	end
	paint(false)
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

function Kit.slider(opts: { [string]: any })
	local UserInputService = game:GetService("UserInputService")
	local self = {}
	self.Changed = Signal.new()
	self.Value = opts.Value or 0.5
	local min, max, step = opts.Min or 0, opts.Max or 1, opts.Step or 0.05
	local root = Create("TextButton", {
		Name = opts.Name or "Slider",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		Selectable = true,
	})
	self.Instance = root
	local track = Create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromScale(1, 0.22),
		BackgroundColor3 = C.SurfaceDeep,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(track, "pill")
	local fill = Create("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	Kit.corner(fill, "pill")
	local knob = Create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromScale(0.7, 0.7),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Parent = root,
	})
	Kit.corner(knob, "pill")
	Kit.stroke(knob, C.Accent, Theme.Stroke.Normal, 0)
	local function render()
		local a = (self.Value - min) / (max - min)
		fill.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.fromScale(a, 0.5)
	end
	local function setFromX(x: number)
		local abs = track.AbsolutePosition.X
		local w = math.max(1, track.AbsoluteSize.X)
		local a = math.clamp((x - abs) / w, 0, 1)
		local v = min + (max - min) * a
		v = math.floor(v / step + 0.5) * step
		v = math.clamp(v, min, max)
		if v ~= self.Value then
			self.Value = v
			render()
			self.Changed:Fire(v)
		end
	end
	local dragging = false
	root.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	function self:Set(v: number)
		self.Value = math.clamp(v, min, max)
		render()
	end
	render()
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return self
end

-- ============================================================== badges / stats
function Kit.badge(opts: { [string]: any })
	local root = Create("Frame", {
		Name = opts.Name or "Badge",
		BackgroundColor3 = opts.Color or C.Accent,
		BackgroundTransparency = opts.Transparency or 0,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(0, 1),
		AutomaticSize = opts.Size and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		ZIndex = opts.ZIndex or 1,
	})
	Kit.corner(root, opts.Radius or "pill")
	if not opts.Size then
		Kit.padding(root, 0, 8, 0, 8)
	end
	local label = Kit.text({
		Name = "Label",
		Text = opts.Text or "",
		Role = opts.Role or "Micro",
		Font = Theme.Fonts.Label,
		Color = opts.TextColor or C.Ink,
		XAlign = Enum.TextXAlignment.Center,
		Size = opts.Size and UDim2.fromScale(1, 1) or UDim2.fromScale(0, 1),
		AutoSize = opts.Size and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		ZIndex = (opts.ZIndex or 1) + 1,
		Parent = root,
	})
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return root, label
end

-- icon + label (muted) ........ value (bright)
function Kit.statRow(opts: { [string]: any })
	local root = Kit.frame({
		Name = opts.Name or "Stat",
		Size = opts.Size or UDim2.fromScale(1, 0.1),
		LayoutOrder = opts.LayoutOrder or 0,
	})
	local iconBox = Kit.frame({
		Name = "IconBox",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = root,
	})
	if opts.Icon then
		local icon = Icons.make(opts.Icon, { Color = opts.IconColor or C.TextMuted, Accent = C.Accent, Ink = C.Panel })
		icon.Parent = iconBox
	end
	local label = Kit.text({
		Name = "Label",
		Text = opts.Label or "",
		Role = opts.LabelRole or "Label",
		Font = Theme.Fonts.Label,
		Color = C.TextMuted,
		Position = UDim2.fromScale(0.11, 0),
		Size = UDim2.fromScale(0.5, 1),
		Parent = root,
	})
	local value = Kit.text({
		Name = "Value",
		Text = opts.Value or "",
		Role = opts.ValueRole or "Heading",
		Font = Theme.Fonts.Number,
		Color = opts.ValueColor or C.Text,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.5, 1),
		Parent = root,
	})
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return root, value, label
end

-- ============================================================== inputs
function Kit.searchBox(opts: { [string]: any })
	local self = {}
	self.Changed = Signal.new()
	local field = Create("Frame", {
		Name = opts.Name or "Search",
		BackgroundColor3 = C.SurfaceDeep,
		BackgroundTransparency = T.Field,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
	})
	self.Instance = field
	Kit.corner(field, "pill")
	local stroke = Kit.stroke(field, C.Gold, Theme.Stroke.Hairline, 0.7)
	local iconBox = Kit.frame({
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromScale(0.46, 0.46),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = field,
	})
	Responsive.bind(iconBox, "Position", function(R)
		return UDim2.new(0, R.px(14), 0.5, 0)
	end)
	Icons.make("Search", { Color = C.TextMuted }).Parent = iconBox
	local box = Create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = opts.Placeholder or "Search...",
		PlaceholderColor3 = C.TextDim,
		TextColor3 = C.Text,
		Font = Theme.Fonts.Body,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = field,
	})
	Responsive.bind(box, "TextSize", function(R)
		return R.text("Body")
	end)
	Responsive.bind(box, "Position", function(R)
		return UDim2.new(0, R.px(40), 0, 0)
	end)
	Responsive.bind(box, "Size", function(R)
		return UDim2.new(1, -R.px(40 + 36), 1, 0)
	end)
	local clear = Create("TextButton", {
		Name = "Clear",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromScale(0.5, 0.5),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Visible = false,
		Parent = field,
	})
	Responsive.bind(clear, "Position", function(R)
		return UDim2.new(1, -R.px(12), 0.5, 0)
	end)
	Icons.make("Close", { Color = C.TextMuted }).Parent = clear
	self.TextBox = box
	local pendingThread = nil
	box:GetPropertyChangedSignal("Text"):Connect(function()
		clear.Visible = box.Text ~= ""
		if pendingThread then
			task.cancel(pendingThread)
		end
		pendingThread = task.delay(0.12, function()
			pendingThread = nil
			self.Changed:Fire(box.Text)
		end)
	end)
	box.Focused:Connect(function()
		stroke.Transparency = 0.15
		stroke.Color = C.Accent
	end)
	box.FocusLost:Connect(function()
		stroke.Transparency = 0.7
		stroke.Color = C.Gold
	end)
	clear.Activated:Connect(function()
		box.Text = ""
	end)
	function self:Get(): string
		return box.Text
	end
	function self:Set(text: string)
		box.Text = text
	end
	if opts.Parent then
		field.Parent = opts.Parent
	end
	return self
end

-- Dropdown: overlayParent must be a top-level frame of the window so the
-- popover is never covered by siblings.
function Kit.dropdown(opts: { [string]: any })
	local self = {}
	self.Changed = Signal.new()
	self.Value = opts.Value or opts.Options[1]
	local button = Kit.button({
		Name = opts.Name or "Dropdown",
		Text = (opts.Prefix or "") .. string.upper(self.Value),
		Style = "Secondary",
		Icon = nil,
		Size = opts.Size,
		Position = opts.Position,
		AnchorPoint = opts.AnchorPoint,
		LayoutOrder = opts.LayoutOrder,
		Radius = "pill",
	})
	self.Instance = button.Instance
	local chevBox = Kit.frame({ Size = UDim2.fromScale(0.34, 0.34), SizeConstraint = Enum.SizeConstraint.RelativeYY, LayoutOrder = 3, Parent = button.Instance.Content })
	Icons.make("ChevronDown", { Color = C.TextMuted }).Parent = chevBox

	local popover: Frame? = nil
	local function close()
		if popover then
			popover:Destroy()
			popover = nil
		end
	end
	self.Close = close
	local function open()
		close()
		local overlay: GuiObject = opts.OverlayParent
		local b = button.Instance
		local rel = b.AbsolutePosition - overlay.AbsolutePosition
		local n = #opts.Options
		local pop = Create("Frame", {
			Name = "Popover",
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(rel.X / math.max(1, overlay.AbsoluteSize.X), (rel.Y + b.AbsoluteSize.Y) / math.max(1, overlay.AbsoluteSize.Y)),
			Size = UDim2.fromScale(b.AbsoluteSize.X / math.max(1, overlay.AbsoluteSize.X), (b.AbsoluteSize.Y * 0.95 * n) / math.max(1, overlay.AbsoluteSize.Y)),
			ZIndex = 50,
			Parent = overlay,
		})
		Kit.corner(pop, "Button")
		Kit.stroke(pop, C.Gold, Theme.Stroke.Hairline, 0.4)
		Kit.list(pop, "V", 0)
		for i, option in opts.Options do
			local item = Create("TextButton", {
				Name = option,
				AutoButtonColor = false,
				Text = "",
				BackgroundColor3 = C.Surface,
				BackgroundTransparency = option == self.Value and 0 or 1,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(1, 1 / n),
				LayoutOrder = i,
				ZIndex = 51,
				Parent = pop,
			})
			Kit.corner(item, "Small")
			Kit.text({
				Text = string.upper(option),
				Role = "Label",
				Font = Theme.Fonts.Label,
				Color = option == self.Value and C.Accent or C.Text,
				Position = UDim2.fromScale(0.1, 0),
				Size = UDim2.fromScale(0.85, 1),
				ZIndex = 52,
				Parent = item,
			})
			item.MouseEnter:Connect(function()
				item.BackgroundTransparency = 0.2
			end)
			item.MouseLeave:Connect(function()
				item.BackgroundTransparency = option == self.Value and 0 or 1
			end)
			item.Activated:Connect(function()
				Kit.hooks.Click()
				close()
				if option ~= self.Value then
					self:Set(option)
					self.Changed:Fire(option)
				end
			end)
		end
		popover = pop
	end
	button.Activated:Connect(function()
		if popover then
			close()
		else
			open()
		end
	end)
	function self:Set(value: string)
		self.Value = value
		button:SetText((opts.Prefix or "") .. string.upper(value))
	end
	function self:IsOpen()
		return popover ~= nil
	end
	if opts.Parent then
		button.Instance.Parent = opts.Parent
	end
	return self
end

-- Styled vertical scrolling frame.
function Kit.scroll(opts: { [string]: any })
	local sf = Create("ScrollingFrame", {
		Name = opts.Name or "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = opts.AutoCanvas == false and Enum.AutomaticSize.None or Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarImageColor3 = C.Gold,
		ScrollBarImageTransparency = 0.35,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		VerticalScrollBarInset = Enum.ScrollBarInset.None,
		LayoutOrder = opts.LayoutOrder or 0,
		Selectable = false,
	})
	Responsive.bind(sf, "ScrollBarThickness", function(R)
		return math.max(3, R.px(5))
	end)
	if opts.Parent then
		sf.Parent = opts.Parent
	end
	return sf
end

-- Keyboard key cap ("G", "E") used in hints and prompts.
function Kit.keycap(opts: { [string]: any })
	local root = Create("Frame", {
		Name = "Keycap",
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		ZIndex = opts.ZIndex or 1,
	})
	Kit.corner(root, 6)
	Kit.text({
		Text = opts.Key or "E",
		Role = opts.Role or "Label",
		Font = Theme.Fonts.Title,
		Color = C.Ink,
		XAlign = Enum.TextXAlignment.Center,
		ZIndex = (opts.ZIndex or 1) + 1,
		Parent = root,
	})
	if opts.Parent then
		root.Parent = opts.Parent
	end
	return root
end

return Kit

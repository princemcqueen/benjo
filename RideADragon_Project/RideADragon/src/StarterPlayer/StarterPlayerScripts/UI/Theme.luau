--[[
	Theme
	The single visual system for every menu: colors, type scale, radii,
	strokes, layering and motion. Nothing in the UI hardcodes its own colors.
]]

local Theme = {}

Theme.Colors = {
	-- glass panels
	Panel = Color3.fromRGB(19, 21, 27),
	PanelLight = Color3.fromRGB(30, 33, 41),
	Surface = Color3.fromRGB(29, 32, 40),
	SurfaceHover = Color3.fromRGB(38, 42, 52),
	SurfaceDeep = Color3.fromRGB(12, 14, 18),
	Divider = Color3.fromRGB(64, 58, 46),

	-- brand
	Gold = Color3.fromRGB(206, 170, 98),
	GoldBright = Color3.fromRGB(242, 208, 134),
	GoldDeep = Color3.fromRGB(140, 108, 52),
	Accent = Color3.fromRGB(246, 144, 44),
	AccentHover = Color3.fromRGB(255, 170, 80),
	AccentDeep = Color3.fromRGB(200, 102, 22),
	Blue = Color3.fromRGB(96, 178, 240),
	BlueDeep = Color3.fromRGB(46, 112, 176),

	-- text
	Text = Color3.fromRGB(246, 238, 221),
	TextMuted = Color3.fromRGB(180, 172, 156),
	TextDim = Color3.fromRGB(124, 119, 108),
	Ink = Color3.fromRGB(36, 22, 8), -- dark text on bright buttons

	-- states
	Danger = Color3.fromRGB(212, 72, 56),
	DangerHover = Color3.fromRGB(232, 96, 78),
	Success = Color3.fromRGB(108, 200, 116),
	Warning = Color3.fromRGB(240, 196, 76),
	Disabled = Color3.fromRGB(58, 61, 70),

	Black = Color3.new(0, 0, 0),
	White = Color3.new(1, 1, 1),
}

-- HUD (always-on-screen elements): white toy-like panels with dark text.
Theme.Hud = {
	Panel = Color3.fromRGB(255, 255, 255),
	Shade = Color3.fromRGB(228, 232, 240), -- bottom of the panel gradient
	Transparency = 0.04,
	Stroke = Color3.fromRGB(176, 184, 202),
	StrokeTransparency = 0.25,
	Text = Color3.fromRGB(32, 36, 52),
	TextMuted = Color3.fromRGB(98, 104, 124),
	Icon = Color3.fromRGB(40, 44, 62),
	Track = Color3.fromRGB(214, 219, 230),
}

Theme.Transparency = {
	Panel = 0.06,
	Surface = 0.12,
	Field = 0.25,
	Backdrop = 0.55,
	Stroke = 0.5,
	StrokeStrong = 0.15,
}

-- Design sizes in px at 1920x1080. Multiplied by the responsive unit.
Theme.Radius = {
	Window = 18,
	Card = 12,
	Button = 10,
	Small = 7,
}

Theme.Stroke = {
	Hairline = 1,
	Normal = 1.5,
	Bold = 2.5,
}

Theme.Fonts = {
	Display = Enum.Font.GothamBlack,
	Title = Enum.Font.GothamBlack,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Label = Enum.Font.GothamBold,
	Caption = Enum.Font.GothamMedium,
	Number = Enum.Font.GothamBlack,
	Micro = Enum.Font.GothamBold,
}

-- Type scale at 1080p (px) and the minimum readable size on any screen.
Theme.TextSizes = {
	Display = { 36, 20 },
	Title = { 25, 16 },
	Heading = { 18, 13 },
	Body = { 15, 12 },
	Label = { 13, 11 },
	Caption = { 12, 10 },
	Micro = { 10.5, 9 },
	Number = { 30, 18 },
}

-- ScreenGui DisplayOrder per layer (deliberate layering, never random ZIndex).
Theme.Layers = {
	World = 5,
	Hud = 10,
	Tooltip = 30,
	Window = 50,
	Notification = 70,
	Modal = 100,
	Loading = 200,
}

Theme.Motion = {
	Open = 0.19,
	Close = 0.14,
	StartScale = 0.96,
	Hover = 0.09,
	Press = 0.06,
	PressScale = 0.95,
}

return Theme

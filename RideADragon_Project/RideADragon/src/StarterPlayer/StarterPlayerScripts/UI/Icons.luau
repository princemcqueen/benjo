--[[
	Icons
	Original vector-style icons built from GUI primitives. Every primitive is
	positioned/sized with Scale inside a square box, so icons stay crisp at any
	resolution. Ring strokes scale with the icon's absolute size.

	Icons.make(name, { Color = Color3, Accent = Color3, Ink = Color3 }) -> Frame
]]

local Theme = require(script.Parent:WaitForChild("Theme"))

local Icons = {}

local C = Theme.Colors

local function box(): Frame
	local f = Instance.new("Frame")
	f.Name = "Icon"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = f
	return f
end

-- Primitive: rectangle in icon space (x, y = center; w, h = size; all 0..1).
local function rect(parent: Instance, x: number, y: number, w: number, h: number, color: Color3, radius: number?, rot: number?): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(w, h)
	f.Rotation = rot or 0
	if radius and radius > 0 then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(radius, 0)
		c.Parent = f
	end
	f.Parent = parent
	return f
end

local function circle(parent: Instance, x: number, y: number, d: number, color: Color3): Frame
	return rect(parent, x, y, d, d, color, 0.5)
end

-- Ring: transparent circle with a stroke whose thickness tracks icon size.
local function ring(parent: Frame, iconRoot: Frame, x: number, y: number, w: number, h: number, thickness: number, color: Color3): Frame
	local f = rect(parent, x, y, w, h, color, 0.5)
	f.BackgroundTransparency = 1
	local s = Instance.new("UIStroke")
	s.Color = color
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	local function update()
		s.Thickness = math.max(1, iconRoot.AbsoluteSize.X * thickness)
	end
	iconRoot:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
	update()
	return f
end

local builders = {}

builders.Dragon = function(root, col, acc, ink)
	-- dragon eye: almond + iris + slit pupil
	rect(root, 0.5, 0.5, 0.94, 0.5, col, 0.5)
	circle(root, 0.5, 0.5, 0.42, acc)
	rect(root, 0.5, 0.5, 0.09, 0.36, ink, 0.5)
	circle(root, 0.6, 0.4, 0.08, col)
end

builders.Book = function(root, col, acc, ink)
	rect(root, 0.29, 0.5, 0.4, 0.66, col, 0.12, -7)
	rect(root, 0.71, 0.5, 0.4, 0.66, col, 0.12, 7)
	rect(root, 0.5, 0.52, 0.08, 0.7, acc, 0.5)
	rect(root, 0.28, 0.4, 0.22, 0.05, ink, 0.5, -7)
	rect(root, 0.28, 0.54, 0.22, 0.05, ink, 0.5, -7)
	rect(root, 0.72, 0.4, 0.22, 0.05, ink, 0.5, 7)
	rect(root, 0.72, 0.54, 0.22, 0.05, ink, 0.5, 7)
end

builders.Scroll = function(root, col, acc, ink)
	rect(root, 0.5, 0.52, 0.64, 0.8, col, 0.14)
	rect(root, 0.5, 0.14, 0.34, 0.12, acc, 0.4)
	rect(root, 0.46, 0.42, 0.36, 0.07, ink, 0.5)
	rect(root, 0.46, 0.57, 0.36, 0.07, ink, 0.5)
	rect(root, 0.4, 0.72, 0.24, 0.07, ink, 0.5)
	rect(root, 0.66, 0.76, 0.1, 0.06, acc, 0.5, 45)
	rect(root, 0.75, 0.71, 0.2, 0.06, acc, 0.5, -50)
end

builders.Bag = function(root, col, acc, ink)
	ring(root, root, 0.5, 0.33, 0.36, 0.4, 0.07, col)
	rect(root, 0.5, 0.64, 0.74, 0.56, col, 0.18)
	rect(root, 0.5, 0.6, 0.3, 0.08, ink, 0.5)
	circle(root, 0.5, 0.6, 0.14, acc)
end

builders.Gift = function(root, col, acc, ink)
	rect(root, 0.5, 0.66, 0.72, 0.5, col, 0.1)
	rect(root, 0.5, 0.4, 0.86, 0.18, col, 0.12)
	rect(root, 0.5, 0.6, 0.13, 0.62, acc, 0)
	rect(root, 0.38, 0.22, 0.24, 0.16, acc, 0.5, -28)
	rect(root, 0.62, 0.22, 0.24, 0.16, acc, 0.5, 28)
	circle(root, 0.5, 0.27, 0.11, acc)
end

builders.Gear = function(root, col, acc, ink)
	for i = 0, 7 do
		local a = i * math.pi / 4
		rect(root, 0.5 + math.cos(a) * 0.37, 0.5 + math.sin(a) * 0.37, 0.2, 0.18, col, 0.25, math.deg(a))
	end
	circle(root, 0.5, 0.5, 0.68, col)
	circle(root, 0.5, 0.5, 0.28, ink)
end

builders.Coin = function(root, col, acc, ink)
	circle(root, 0.5, 0.52, 0.92, Color3.fromRGB(186, 128, 34))
	circle(root, 0.5, 0.48, 0.92, Color3.fromRGB(255, 205, 82))
	ring(root, root, 0.5, 0.48, 0.66, 0.66, 0.05, Color3.fromRGB(255, 236, 160))
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.fromScale(0.5, 0.49)
	t.Size = UDim2.fromScale(0.62, 0.62)
	t.Font = Enum.Font.GothamBlack
	t.Text = "$"
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(150, 92, 18)
	t.Parent = root
end

builders.Egg = function(root, col, acc, ink)
	rect(root, 0.5, 0.56, 0.66, 0.74, col, 0.5)
	rect(root, 0.5, 0.36, 0.5, 0.5, col, 0.5)
	circle(root, 0.4, 0.5, 0.14, acc)
	circle(root, 0.62, 0.66, 0.1, acc)
	circle(root, 0.58, 0.36, 0.08, acc)
end

builders.Speed = function(root, col, acc, ink)
	for i, x in { 0.32, 0.62 } do
		local c = i == 1 and col or acc
		rect(root, x, 0.38, 0.38, 0.13, c, 0.5, 42)
		rect(root, x, 0.62, 0.38, 0.13, c, 0.5, -42)
	end
end

builders.Income = function(root, col, acc, ink)
	local gold = Color3.fromRGB(255, 205, 82)
	local deep = Color3.fromRGB(186, 128, 34)
	for _, y in { 0.74, 0.55, 0.36 } do
		rect(root, 0.5, y + 0.05, 0.76, 0.26, deep, 0.5)
		rect(root, 0.5, y, 0.76, 0.26, gold, 0.5)
	end
end

builders.Lock = function(root, col, acc, ink)
	ring(root, root, 0.5, 0.36, 0.42, 0.5, 0.08, col)
	rect(root, 0.5, 0.67, 0.68, 0.48, col, 0.16)
	circle(root, 0.5, 0.62, 0.13, ink)
	rect(root, 0.5, 0.73, 0.06, 0.14, ink, 0.5)
end

builders.Unlock = function(root, col, acc, ink)
	ring(root, root, 0.66, 0.3, 0.38, 0.46, 0.08, col)
	rect(root, 0.46, 0.67, 0.68, 0.48, col, 0.16)
	circle(root, 0.46, 0.62, 0.13, ink)
end

builders.Close = function(root, col)
	rect(root, 0.5, 0.5, 0.82, 0.13, col, 0.5, 45)
	rect(root, 0.5, 0.5, 0.82, 0.13, col, 0.5, -45)
end

builders.Search = function(root, col)
	ring(root, root, 0.42, 0.42, 0.56, 0.56, 0.1, col)
	rect(root, 0.76, 0.76, 0.34, 0.13, col, 0.5, 45)
end

builders.ChevronDown = function(root, col)
	rect(root, 0.36, 0.5, 0.42, 0.12, col, 0.5, 40)
	rect(root, 0.64, 0.5, 0.42, 0.12, col, 0.5, -40)
end

builders.ChevronUp = function(root, col)
	rect(root, 0.36, 0.5, 0.42, 0.12, col, 0.5, -40)
	rect(root, 0.64, 0.5, 0.42, 0.12, col, 0.5, 40)
end

builders.Ascend = function(root, col, acc)
	rect(root, 0.36, 0.36, 0.42, 0.12, acc, 0.5, -40)
	rect(root, 0.64, 0.36, 0.42, 0.12, acc, 0.5, 40)
	rect(root, 0.36, 0.64, 0.42, 0.12, col, 0.5, -40)
	rect(root, 0.64, 0.64, 0.42, 0.12, col, 0.5, 40)
end

builders.Descend = function(root, col, acc)
	rect(root, 0.36, 0.36, 0.42, 0.12, col, 0.5, 40)
	rect(root, 0.64, 0.36, 0.42, 0.12, col, 0.5, -40)
	rect(root, 0.36, 0.64, 0.42, 0.12, acc, 0.5, 40)
	rect(root, 0.64, 0.64, 0.42, 0.12, acc, 0.5, -40)
end

builders.Roar = function(root, col, acc)
	-- sound burst: bars of rising height
	rect(root, 0.2, 0.5, 0.11, 0.3, col, 0.5)
	rect(root, 0.38, 0.5, 0.11, 0.56, acc, 0.5)
	rect(root, 0.56, 0.5, 0.11, 0.8, col, 0.5)
	rect(root, 0.74, 0.5, 0.11, 0.46, acc, 0.5)
end

builders.Dismount = function(root, col, acc)
	-- arrow stepping down-left out of a saddle bar
	rect(root, 0.58, 0.3, 0.6, 0.13, col, 0.5)
	rect(root, 0.42, 0.62, 0.5, 0.13, acc, 0.5, 45)
	rect(root, 0.28, 0.66, 0.3, 0.13, acc, 0.5, 0)
	rect(root, 0.26, 0.6, 0.13, 0.3, acc, 0.5, 0)
end

builders.ChevronLeft = function(root, col)
	rect(root, 0.46, 0.36, 0.42, 0.12, col, 0.5, -45)
	rect(root, 0.46, 0.64, 0.42, 0.12, col, 0.5, 45)
end

builders.ChevronRight = function(root, col)
	rect(root, 0.54, 0.36, 0.42, 0.12, col, 0.5, 45)
	rect(root, 0.54, 0.64, 0.42, 0.12, col, 0.5, -45)
end

builders.Check = function(root, col)
	rect(root, 0.33, 0.6, 0.36, 0.14, col, 0.5, 45)
	rect(root, 0.6, 0.48, 0.62, 0.14, col, 0.5, -52)
end

builders.Sparkle = function(root, col, acc)
	rect(root, 0.5, 0.5, 0.16, 0.92, col, 0.5)
	rect(root, 0.5, 0.5, 0.92, 0.16, col, 0.5)
	rect(root, 0.5, 0.5, 0.12, 0.5, acc, 0.5, 45)
	rect(root, 0.5, 0.5, 0.12, 0.5, acc, 0.5, -45)
	circle(root, 0.5, 0.5, 0.24, col)
end

builders.Food = function(root, col, acc, ink)
	rect(root, 0.66, 0.66, 0.16, 0.5, col, 0.5, -45)
	circle(root, 0.84, 0.74, 0.18, col)
	circle(root, 0.74, 0.86, 0.18, col)
	circle(root, 0.4, 0.4, 0.62, acc)
	circle(root, 0.32, 0.32, 0.16, Color3.fromRGB(255, 200, 140))
end

builders.Wing = function(root, col, acc)
	rect(root, 0.52, 0.32, 0.84, 0.15, col, 0.5, -22)
	rect(root, 0.46, 0.52, 0.7, 0.15, col, 0.5, -16)
	rect(root, 0.4, 0.71, 0.52, 0.15, acc, 0.5, -10)
end

builders.Pin = function(root, col, acc, ink)
	rect(root, 0.5, 0.56, 0.42, 0.42, col, 0.12, 45)
	circle(root, 0.5, 0.4, 0.6, col)
	circle(root, 0.5, 0.4, 0.24, ink)
end

builders.Release = function(root, col, acc)
	-- open box with an arrow leaving it upward
	rect(root, 0.5, 0.88, 0.8, 0.11, col, 0.5)
	rect(root, 0.15, 0.72, 0.11, 0.38, col, 0.5)
	rect(root, 0.85, 0.72, 0.11, 0.38, col, 0.5)
	rect(root, 0.5, 0.46, 0.12, 0.58, acc, 0.5)
	rect(root, 0.39, 0.25, 0.32, 0.12, acc, 0.5, -45)
	rect(root, 0.61, 0.25, 0.32, 0.12, acc, 0.5, 45)
end

builders.Radar = function(root, col, acc)
	ring(root, root, 0.5, 0.5, 0.9, 0.9, 0.06, col)
	ring(root, root, 0.5, 0.5, 0.56, 0.56, 0.06, col)
	rect(root, 0.66, 0.36, 0.42, 0.08, acc, 0.5, -45)
	circle(root, 0.5, 0.5, 0.16, acc)
	circle(root, 0.32, 0.66, 0.12, acc)
end

builders.Clover = function(root, col, acc)
	-- four heart-ish leaves (two circles each) around a center
	local leaves = { { 0.5, 0.25, 0 }, { 0.75, 0.5, 90 }, { 0.5, 0.75, 180 }, { 0.25, 0.5, 270 } }
	for _, l in leaves do
		local a = math.rad(l[3])
		local ox, oy = math.cos(a) * 0.09, math.sin(a) * 0.09
		circle(root, l[1] - ox, l[2] - oy, 0.27, col)
		circle(root, l[1] + ox, l[2] + oy, 0.27, col)
	end
	circle(root, 0.5, 0.5, 0.16, acc)
	rect(root, 0.7, 0.86, 0.07, 0.26, acc, 0.5, -35)
end

builders.Chest = function(root, col, acc, ink)
	rect(root, 0.5, 0.36, 0.8, 0.3, col, 0.3)
	rect(root, 0.5, 0.64, 0.8, 0.42, col, 0.08)
	rect(root, 0.5, 0.5, 0.8, 0.07, ink, 0)
	rect(root, 0.5, 0.54, 0.16, 0.2, acc, 0.2)
end

builders.Star = function(root, col, acc)
	rect(root, 0.5, 0.5, 0.62, 0.62, col, 0.1)
	rect(root, 0.5, 0.5, 0.62, 0.62, col, 0.1, 45)
	circle(root, 0.5, 0.5, 0.3, acc)
end

builders.Wind = function(root, col, acc)
	rect(root, 0.46, 0.3, 0.72, 0.12, col, 0.5)
	rect(root, 0.56, 0.5, 0.72, 0.12, acc, 0.5)
	rect(root, 0.42, 0.7, 0.56, 0.12, col, 0.5)
end

builders.Home = function(root, col, acc, ink)
	rect(root, 0.33, 0.36, 0.5, 0.13, col, 0.5, -40)
	rect(root, 0.67, 0.36, 0.5, 0.13, col, 0.5, 40)
	rect(root, 0.5, 0.68, 0.6, 0.46, col, 0.08)
	rect(root, 0.5, 0.76, 0.18, 0.3, ink, 0.2)
end

builders.Plus = function(root, col)
	rect(root, 0.5, 0.5, 0.74, 0.15, col, 0.5)
	rect(root, 0.5, 0.5, 0.15, 0.74, col, 0.5)
end

builders.Trophy = function(root, col, acc)
	rect(root, 0.5, 0.36, 0.56, 0.5, col, 0.35)
	ring(root, root, 0.24, 0.34, 0.24, 0.26, 0.06, col)
	ring(root, root, 0.76, 0.34, 0.24, 0.26, 0.06, col)
	rect(root, 0.5, 0.68, 0.12, 0.22, col, 0)
	rect(root, 0.5, 0.84, 0.46, 0.1, acc, 0.3)
end

builders.Info = function(root, col, acc, ink)
	circle(root, 0.5, 0.5, 0.9, col)
	circle(root, 0.5, 0.3, 0.13, ink)
	rect(root, 0.5, 0.62, 0.13, 0.36, ink, 0.4)
end

builders.Warning = function(root, col, acc, ink)
	circle(root, 0.5, 0.5, 0.9, col)
	rect(root, 0.5, 0.42, 0.13, 0.4, ink, 0.4)
	circle(root, 0.5, 0.73, 0.13, ink)
end

builders.Map = function(root, col, acc)
	rect(root, 0.26, 0.5, 0.26, 0.76, col, 0.1, -4)
	rect(root, 0.5, 0.5, 0.26, 0.76, acc, 0.1, 4)
	rect(root, 0.74, 0.5, 0.26, 0.76, col, 0.1, -4)
end

builders.Sword = function(root, col, acc, ink)
	rect(root, 0.58, 0.4, 0.14, 0.64, col, 0.3, 45) -- blade
	rect(root, 0.38, 0.62, 0.38, 0.1, acc, 0.4, -45) -- guard
	rect(root, 0.27, 0.73, 0.1, 0.22, ink, 0.4, 45) -- grip
	circle(root, 0.21, 0.79, 0.14, acc) -- pommel
end

builders.Fireball = function(root, col, acc, ink)
	rect(root, 0.3, 0.7, 0.4, 0.14, acc, 0.5, -42) -- trail
	rect(root, 0.22, 0.56, 0.3, 0.1, col, 0.5, -28)
	circle(root, 0.6, 0.42, 0.54, col)
	circle(root, 0.62, 0.4, 0.32, acc)
	circle(root, 0.64, 0.38, 0.14, ink)
end

builders.Flame = function(root, col, acc)
	rect(root, 0.5, 0.6, 0.62, 0.62, acc, 0.5)
	rect(root, 0.5, 0.42, 0.36, 0.36, acc, 0.15, 45)
	rect(root, 0.5, 0.66, 0.3, 0.36, col, 0.5)
end

function Icons.make(name: string, colors: { Color: Color3?, Accent: Color3?, Ink: Color3? }?): Frame
	local opts = colors or {}
	local root = box()
	root.Name = "Icon_" .. name
	local builder = builders[name] or builders.Info
	builder(root, opts.Color or C.Text, opts.Accent or C.Accent, opts.Ink or C.Panel)
	return root
end

function Icons.has(name: string): boolean
	return builders[name] ~= nil
end

-- Recolors the primary color of an icon (primitives using `from` become `to`).
function Icons.recolor(icon: Frame, from: Color3, to: Color3)
	for _, d in icon:GetDescendants() do
		if d:IsA("Frame") and d.BackgroundColor3 == from then
			d.BackgroundColor3 = to
		elseif d:IsA("UIStroke") and d.Color == from then
			d.Color = to
		end
	end
end

Icons.Names = {}
for name in builders do
	table.insert(Icons.Names, name)
end
table.sort(Icons.Names)

return Icons

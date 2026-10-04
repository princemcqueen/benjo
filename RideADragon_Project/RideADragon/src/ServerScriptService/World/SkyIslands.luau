--[[
	SkyIslands - the floating LEGO islands of the sky (WorldConfig.SkyIslands), one theme each:
	  Crystal  glowing crystal spires and a shimmering pool (Skyreach eggs)
	  Bloom    giant flowers, mushrooms and round trees (Haven eggs)
	  Ember    a small volcano with a lava staircase, charred trees, floating embers (Ember Caldera eggs)
	  Frost    ice spikes, snowy pines, a frozen pond and an igloo (Frostpeak eggs)
	Every island is: a grass / stone plate (the part "Surface" carries the attribute EggSurface, so the
	egg spawner may put eggs on it), dirt and a stack of rock below, studs round the rim, glowing
	stalactites underneath, a landing pad (Travel place = island Id), a floating name sign, and the
	decoration of its theme. Decoration is solid but CanQuery = false, so eggs and the camera never
	bump into it. The model is Persistent (always visible from far away).
	Built by IslandService; the egg areas are registered there.
]]

local Kit = require(script.Parent:WaitForChild("Kit"))

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local C3 = Color3.fromRGB
local M = Kit.M

local SkyIslands = {}

local NO_COLLIDE = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }
local DECOR = { CanQuery = false, CanTouch = false }
local WHITE = C3(242, 243, 242)
local TRUNK = C3(110, 78, 50)

local THEMES = {
	Crystal = { Top = C3(112, 196, 206), Dirt = C3(86, 72, 130), Rock = C3(120, 112, 160), RockDark = C3(88, 82, 128), Glow = C3(150, 230, 255) },
	Bloom = { Top = C3(96, 190, 84), Dirt = C3(124, 80, 46), Rock = C3(163, 162, 165), RockDark = C3(99, 95, 98), Glow = C3(255, 170, 215) },
	Ember = { Top = C3(72, 60, 64), Dirt = C3(52, 40, 40), Rock = C3(96, 72, 66), RockDark = C3(62, 48, 48), Glow = C3(255, 120, 40) },
	Frost = { Top = C3(236, 243, 250), Dirt = C3(150, 185, 215), Rock = C3(188, 214, 236), RockDark = C3(140, 172, 204), Glow = C3(170, 230, 255) },
}

-- ============================================================== shared pieces
local function base(b, r: number, theme)
	local cap = b:cyl(3, r * 2, V(0, -1.5, 0), theme.Top)
	cap.Name = "Surface"
	cap:SetAttribute("EggSurface", true)
	b:cyl(3, r * 2 - 3, V(0, -4.5, 0), theme.Dirt)
	local y = -6
	for i, d in { r * 1.7, r * 1.4, r * 1.05, r * 0.72, r * 0.42, r * 0.18 } do
		local h = 9 + i * 2
		b:cyl(h, d, V(0, y - h / 2, 0), i % 2 == 0 and theme.RockDark or theme.Rock)
		y -= h
	end
	-- studs round the rim
	for i = 0, 35 do
		local a = i / 36 * math.pi * 2
		b:cyl(0.6, 3.2, V(math.sin(a) * (r - 3.2), 0.3, math.cos(a) * (r - 3.2)), theme.Top, nil, NO_COLLIDE)
	end
end

-- glowing stalactites under the island
local function stalactites(b, r: number, theme, rng: Random)
	for i = 1, 9 do
		local a = rng:NextNumber(0, math.pi * 2)
		local rr = rng:NextNumber(r * 0.1, r * 0.55)
		local len = rng:NextNumber(10, 22)
		b:box(V(1.6, len, 1.6), CF(math.sin(a) * rr, -30 - len / 2 - (r - rr) * 0.15, math.cos(a) * rr) * ANG(math.pi + rng:NextNumber(-0.12, 0.12), rng:NextNumber(0, 6), rng:NextNumber(-0.12, 0.12)),
			theme.Glow, M.Neon, NO_COLLIDE)
	end
end

local function landingPad(b, def, theme)
	local at = V(0, 0, def.Radius * 0.55)
	b:roundBrick(1.2, 15, at + V(0, 0.6, 0), theme.RockDark, { Studs = "None" })
	local top = b:roundBrick(0.5, 12.5, at + V(0, 1.45, 0), def.Color, { Studs = "Ring", RingRadius = 5, StudColor = WHITE })
	top.Name = "LandingPad"
	b:cyl(0.3, 5, at + V(0, 1.85, 0), WHITE, M.Neon, NO_COLLIDE)
end

-- the floating name of the island (seen from far away)
local function nameSign(b, def, height: number)
	local anchor = b:box(V(1, 1, 1), V(0, height, 0), WHITE, nil, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	anchor.Name = "NameSign"
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameGui"
	gui.Size = UDim2.fromOffset(320, 78)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 1600
	gui.LightInfluence = 0
	gui.Adornee = anchor
	gui.Parent = anchor
	local function line(name: string, text: string, color: Color3, y: number, h: number, font: Enum.Font)
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Position = UDim2.fromScale(0, y)
		t.Size = UDim2.fromScale(1, h)
		t.Font = font
		t.Text = text
		t.TextScaled = true
		t.TextColor3 = color
		t.Parent = gui
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.5
		stroke.Color = C3(18, 20, 34)
		stroke.Parent = t
	end
	line("Title", string.upper(def.Name), def.Color, 0, 0.62, Enum.Font.GothamBlack)
	line("Sub", def.Sub, WHITE, 0.64, 0.34, Enum.Font.GothamMedium)
end

-- Random point on the plate: not too close to the middle, the landing pad or the rim.
local function scatterPoint(rng: Random, r: number, minR: number, maxR: number, padR: number?): Vector3
	for _ = 1, 20 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(minR, maxR)
		local x, z = math.sin(a) * d, math.cos(a) * d
		local px, pz = 0, r * 0.55
		if (x - px) ^ 2 + (z - pz) ^ 2 > (padR or 14) ^ 2 then
			return V(x, 0, z)
		end
	end
	return V(r * 0.5, 0, -r * 0.5)
end

-- ============================================================== decoration pieces
-- A tall crystal: translucent body, neon core, a diamond point. lean = (rotX, rotZ).
local function crystal(b, pos: Vector3, height: number, width: number, color: Color3, leanX: number, leanZ: number, yaw: number, material: Enum.Material?, alpha: number?)
	local lean = ANG(leanX, yaw, leanZ)
	local at = CF(pos + V(0, height / 2, 0)) * lean
	b:box(V(width, height, width), at, color, material or M.Glass, { Transparency = alpha or 0.28, CanQuery = false })
	b:box(V(width * 0.4, height * 0.86, width * 0.4), at, color, M.Neon, NO_COLLIDE)
	local tip = CF(pos) * lean * CF(0, height, 0) * ANG(math.rad(45), 0, math.rad(45))
	b:box(V(width * 0.72, width * 0.72, width * 0.72), tip, color, M.Neon, NO_COLLIDE)
end

local function mushroom(b, pos: Vector3, h: number, capD: number, capColor: Color3)
	b:cyl(h, capD * 0.28, pos + V(0, h / 2, 0), C3(246, 238, 214), nil, DECOR)
	b:ball(capD, pos + V(0, h, 0), capColor, nil, DECOR)
	for i = 1, 5 do
		local a = i / 5 * math.pi * 2
		b:ball(capD * 0.17, pos + V(math.cos(a) * capD * 0.3, h + capD * 0.4, math.sin(a) * capD * 0.3), WHITE, nil, NO_COLLIDE)
	end
end

local function flower(b, pos: Vector3, h: number, petal: Color3)
	b:cyl(h, 0.6, pos + V(0, h / 2, 0), C3(60, 140, 60), nil, NO_COLLIDE)
	local top = pos + V(0, h, 0)
	b:ball(1.8, top, C3(255, 214, 60), nil, NO_COLLIDE)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		b:ball(1.5, top + V(math.cos(a) * 1.9, 0, math.sin(a) * 1.9), petal, nil, NO_COLLIDE)
	end
end

local function roundTree(b, pos: Vector3, h: number, leaf: Color3)
	b:cyl(h, 2.2, pos + V(0, h / 2, 0), TRUNK, nil, DECOR)
	b:ball(h * 0.95, pos + V(0, h + h * 0.12, 0), leaf, nil, DECOR)
	b:ball(h * 0.6, pos + V(h * 0.34, h * 0.86, h * 0.1), leaf, nil, DECOR)
	b:ball(h * 0.5, pos + V(-h * 0.3, h * 0.82, -h * 0.12), leaf, nil, DECOR)
end

local function pine(b, pos: Vector3, h: number, needles: Color3, snow: Color3)
	b:cyl(h * 0.3, 1.6, pos + V(0, h * 0.15, 0), TRUNK, nil, DECOR)
	local d = h * 0.7
	local y = h * 0.3
	for i = 1, 4 do
		b:cyl(h * 0.17, d, pos + V(0, y + h * 0.085, 0), i % 2 == 0 and snow or needles, nil, DECOR)
		y += h * 0.17
		d *= 0.72
	end
end

local function pointLight(parent: BasePart, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Parent = parent
end

-- ============================================================== themes
local function crystalIsle(b, def, theme, rng: Random)
	local r = def.Radius
	local colors = { C3(150, 230, 255), C3(190, 150, 255), C3(255, 150, 230), C3(130, 255, 220) }
	-- the central spire group
	local heights = { 30, 22, 19, 16 }
	for i, h in heights do
		local a = (i - 1) / #heights * math.pi * 2 + 0.4
		local off = i == 1 and V(0, 0, -r * 0.12) or V(math.sin(a) * 6.5, 0, -r * 0.12 + math.cos(a) * 6.5)
		crystal(b, off, h, 5.2 - i * 0.4, colors[(i - 1) % #colors + 1], (i - 1) * 0.05 * (i % 2 == 0 and 1 or -1), 0.08 * (i - 2), a)
	end
	pointLight(b:ball(3, V(0, 14, -r * 0.12), theme.Glow, M.Neon, NO_COLLIDE), theme.Glow, 60, 2.2)
	-- smaller crystals scattered over the plate
	for _ = 1, 16 do
		local p = scatterPoint(rng, r, r * 0.3, r * 0.82)
		crystal(b, p, rng:NextNumber(7, 15), rng:NextNumber(2, 3.4), colors[rng:NextInteger(1, #colors)], rng:NextNumber(-0.25, 0.25), rng:NextNumber(-0.25, 0.25), rng:NextNumber(0, 6))
	end
	-- the shimmering pool
	local pool = b:cyl(0.4, 22, V(-r * 0.38, 0.2, r * 0.18), C3(120, 230, 255), M.Neon, { Transparency = 0.55, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	pool.Name = "Pool"
	b:cyl(0.7, 25, V(-r * 0.38, 0.1, r * 0.18), theme.RockDark, nil, DECOR)
end

local function bloomIsle(b, def, theme, rng: Random)
	local r = def.Radius
	-- the big flower in the middle: eight petals round a golden heart
	local mid = V(0, 0, -r * 0.1)
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local at = CF(mid + V(math.sin(a) * 11, 0.9, math.cos(a) * 11)) * ANG(0, a, 0)
		b:box(V(6.5, 1.2, 11), at, i % 2 == 0 and C3(255, 150, 200) or C3(255, 190, 220), nil, DECOR)
	end
	b:cyl(2, 9, mid + V(0, 1.2, 0), C3(255, 205, 60), nil, DECOR)
	for i = 0, 11 do
		local a = i / 12 * math.pi * 2
		b:ball(1.1, mid + V(math.sin(a) * 3.2, 2.5, math.cos(a) * 3.2), C3(214, 150, 20), nil, NO_COLLIDE)
	end
	-- mushrooms, flowers, trees
	local caps = { C3(220, 60, 70), C3(255, 140, 190), C3(255, 190, 60), C3(150, 110, 230) }
	for i = 1, 9 do
		local p = scatterPoint(rng, r, r * 0.42, r * 0.84)
		mushroom(b, p, rng:NextNumber(5, 9), rng:NextNumber(6, 11), caps[(i - 1) % #caps + 1])
	end
	local petals = { C3(255, 120, 170), C3(255, 235, 110), C3(255, 255, 255), C3(170, 130, 255), C3(110, 200, 255) }
	for _ = 1, 34 do
		local p = scatterPoint(rng, r, r * 0.2, r * 0.9, 12)
		flower(b, p, rng:NextNumber(2.5, 5), petals[rng:NextInteger(1, #petals)])
	end
	for _ = 1, 6 do
		local p = scatterPoint(rng, r, r * 0.5, r * 0.82)
		roundTree(b, p, rng:NextNumber(8, 12), C3(70 + rng:NextInteger(0, 30), 170 + rng:NextInteger(0, 30), 80))
	end
end

local function emberIsle(b, def, theme, rng: Random)
	local r = def.Radius
	local lava = C3(255, 110, 30)
	local rock = { C3(70, 56, 58), C3(88, 66, 62) }
	-- the volcano: five tiers, a glowing crater, a lava staircase down one side
	local cx, cz = 0, -r * 0.18
	local tiers = { { d = 54, h = 7 }, { d = 43, h = 7 }, { d = 33, h = 7 }, { d = 24, h = 7 }, { d = 16, h = 6 } }
	local y = 0
	local edges = {}
	for i, t in tiers do
		b:cyl(t.h, t.d, V(cx, y + t.h / 2, cz), rock[i % 2 + 1], M.Slate, DECOR)
		y += t.h
		table.insert(edges, { r = t.d / 2, top = y, h = t.h })
	end
	local crater = b:cyl(0.8, 11, V(cx, y + 0.4, cz), lava, M.Neon, NO_COLLIDE)
	crater.Name = "Crater"
	pointLight(crater, lava, 70, 3)
	local theta = math.rad(35)
	for _, flow in { math.rad(35), math.rad(215) } do
		for _, e in edges do
			local px, pz = cx + math.sin(flow) * (e.r - 1.6), cz + math.cos(flow) * (e.r - 1.6)
			b:box(V(3.6, 0.5, 5), CF(px, e.top + 0.3, pz) * ANG(0, flow, 0), lava, M.Neon, NO_COLLIDE)
			local fx, fz = cx + math.sin(flow) * e.r, cz + math.cos(flow) * e.r
			b:box(V(3.6, e.h, 0.6), CF(fx, e.top - e.h / 2, fz) * ANG(0, flow, 0), lava, M.Neon, NO_COLLIDE)
		end
	end
	-- the lava pool at the foot
	local px, pz = cx + math.sin(theta) * (edges[1].r + 8), cz + math.cos(theta) * (edges[1].r + 8)
	local pool = b:cyl(0.5, 18, V(px, 0.25, pz), lava, M.Neon, NO_COLLIDE)
	pool.Name = "LavaPool"
	pointLight(pool, lava, 36, 2)
	-- charred trees and glowing rocks
	for _ = 1, 9 do
		local p = scatterPoint(rng, r, r * 0.48, r * 0.86)
		local h = rng:NextNumber(7, 12)
		b:cyl(h, 1.5, p + V(0, h / 2, 0), C3(34, 28, 30), nil, DECOR)
		b:box(V(0.9, h * 0.5, 0.9), CF(p + V(1.4, h * 0.82, 0)) * ANG(0, 0, -0.7), C3(34, 28, 30), nil, NO_COLLIDE)
		b:box(V(0.9, h * 0.4, 0.9), CF(p + V(-1.2, h * 0.7, 0.5)) * ANG(0.4, 0, 0.6), C3(34, 28, 30), nil, NO_COLLIDE)
	end
	for _ = 1, 12 do
		local p = scatterPoint(rng, r, r * 0.45, r * 0.88)
		local s = rng:NextNumber(2.5, 5)
		b:ball(s, p + V(0, s * 0.3, 0), C3(60, 46, 46), M.Slate, DECOR)
		b:ball(s * 0.5, p + V(s * 0.1, s * 0.5, s * 0.1), lava, M.Neon, NO_COLLIDE)
	end
	-- embers drifting above the crater
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2
		b:ball(rng:NextNumber(0.7, 1.4), V(cx + math.sin(a) * rng:NextNumber(3, 9), y + rng:NextNumber(4, 16), cz + math.cos(a) * rng:NextNumber(3, 9)), C3(255, 170, 70), M.Neon, NO_COLLIDE)
	end
end

local function frostIsle(b, def, theme, rng: Random)
	local r = def.Radius
	local ice = C3(170, 225, 255)
	-- a ring of ice spikes round a tall central one
	crystal(b, V(0, 0, -r * 0.12), 34, 6, ice, 0.04, 0.05, 0.3, M.Ice, 0.2)
	for i = 0, 6 do
		local a = i / 7 * math.pi * 2
		crystal(b, V(math.sin(a) * 10, 0, -r * 0.12 + math.cos(a) * 10), rng:NextNumber(14, 22), rng:NextNumber(3, 4.4), ice, math.sin(a) * 0.22, math.cos(a) * 0.22, a, M.Ice, 0.2)
	end
	for _ = 1, 12 do
		local p = scatterPoint(rng, r, r * 0.4, r * 0.84)
		crystal(b, p, rng:NextNumber(5, 10), rng:NextNumber(1.6, 2.6), ice, rng:NextNumber(-0.25, 0.25), rng:NextNumber(-0.25, 0.25), rng:NextNumber(0, 6), M.Ice, 0.2)
	end
	-- snowy pines
	for _ = 1, 14 do
		local p = scatterPoint(rng, r, r * 0.45, r * 0.86)
		pine(b, p, rng:NextNumber(9, 15), C3(60, 110, 90), WHITE)
	end
	-- the frozen pond
	local pond = b:cyl(0.5, 24, V(-r * 0.34, 0.25, r * 0.16), C3(190, 235, 255), M.Ice, { Transparency = 0.15, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	pond.Name = "Pond"
	b:cyl(0.8, 27, V(-r * 0.34, 0.1, r * 0.16), theme.RockDark, nil, DECOR)
	-- an igloo
	local ig = V(r * 0.4, 0, r * 0.1)
	b:ball(15, ig + V(0, 1, 0), WHITE, nil, DECOR)
	b:box(V(4.2, 5, 4), CF(ig + V(-r * 0.0, 2.5, 7)) , C3(40, 60, 90), nil, DECOR)
end

local THEME_BUILDERS = { Crystal = crystalIsle, Bloom = bloomIsle, Ember = emberIsle, Frost = frostIsle }

-- ============================================================== public
function SkyIslands.build(parent: Instance, def): Model
	local theme = THEMES[def.Theme] or THEMES.Bloom
	local b = Kit.new(parent, CF(def.Center), def.Id)
	pcall(function()
		(b.Model :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	local rng = Random.new(#def.Id * 977 + def.Radius)
	base(b, def.Radius, theme)
	landingPad(b, def, theme)
	local decorate = THEME_BUILDERS[def.Theme]
	if decorate then
		decorate(b, def, theme, rng)
	end
	stalactites(b, def.Radius, theme, rng)
	nameSign(b, def, 62)
	b.Model:SetAttribute("IslandId", def.Id)
	b.Model:SetAttribute("Island", "Sky")
	return b.Model
end

return SkyIslands

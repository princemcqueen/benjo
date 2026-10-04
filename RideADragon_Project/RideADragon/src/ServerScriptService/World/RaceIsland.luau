--[[
	RaceIsland - the floating LEGO island of races and duels (RaceConfig / CombatConfig).

	  * island base: grass plate, dirt, a stack of rock under it, studs round the rim
	  * start grid: 8 numbered pads behind the START / FINISH arch, checkered line, banners
	  * plaza: the neon JOIN pad (prompt opens the Race window), lamp posts, flower beds, the
	    winners podium with a trophy (monthly champions)
	  * arena: a round colosseum with one entrance, four respawn pads, a glowing boundary
	  * the sky circuit: GateCount ring gates per lap (Gate_0 = the arch) and boost rings, all
	    non-colliding so dragons fly straight through
	The leaderboard screens on the plaza are built by LeaderboardService (RaceConfig.Boards).

	Tags: model attributes "Gate" (index) on Gate_k models, "Boost" (index) on boost rings,
	      parts "JoinPad", "Pad1".."Pad8", "ArenaFloor", "RespawnPad1".., "Winners" (SurfaceGui host)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent:WaitForChild("Kit"))
local Configs = ReplicatedStorage:WaitForChild("Configs")
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))
local CombatConfig = require(Configs:WaitForChild("CombatConfig"))

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local M = Kit.M

local RaceIsland = {}

-- LEGO palette
local GRASS = Color3.fromRGB(75, 151, 74)
local DIRT = Color3.fromRGB(124, 80, 46)
local ROCK = Color3.fromRGB(163, 162, 165)
local ROCK_DARK = Color3.fromRGB(99, 95, 98)
local RED = Color3.fromRGB(196, 40, 27)
local YELLOW = Color3.fromRGB(245, 205, 47)
local WHITE = Color3.fromRGB(242, 243, 242)
local BLACK = Color3.fromRGB(27, 42, 52)
local BLUE = Color3.fromRGB(13, 105, 172)
local CYAN = Color3.fromRGB(66, 220, 255)
local TAN = Color3.fromRGB(215, 197, 153)
local NO_COLLIDE = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }

local function sign(part: BasePart, face: Enum.NormalId, text: string, color: Color3, pixels: number?, name: string?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = name or "SignGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixels or 30
	gui.LightInfluence = 0
	gui.Parent = part
	local t = Instance.new("TextLabel")
	t.Name = "Text"
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBlack
	t.Text = text
	t.TextScaled = true
	t.TextColor3 = color
	t.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(20, 24, 40)
	stroke.Parent = t
	return t
end

-- A ring of brick segments standing in the plane perpendicular to `forward`.
local function ring(b, center: Vector3, forward: Vector3, radius: number, thickness: number, depth: number, color: any, material: Enum.Material, segments: number, name: string, props: { [string]: any }?)
	local f = forward.Unit
	local r = f:Cross(Vector3.yAxis)
	r = r.Magnitude < 1e-3 and Vector3.xAxis or r.Unit
	local u = r:Cross(f)
	local arc = 2 * math.pi * radius / segments * 1.08
	local list = {}
	for i = 0, segments - 1 do
		local a = i / segments * math.pi * 2
		local radial = r * math.cos(a) + u * math.sin(a)
		local tangent = -r * math.sin(a) + u * math.cos(a)
		local c = typeof(color) == "function" and color(i) or color
		local seg = b:box(V(arc, thickness, depth), CFrame.fromMatrix(center + radial * radius, tangent, radial), c, material, props)
		seg.Name = name
		table.insert(list, seg)
	end
	return list
end

-- ============================================================== base
local function base(b, r: number)
	b:cyl(3, r * 2, V(0, -1.5, 0), GRASS)
	b:cyl(3, r * 2 - 3, V(0, -4.5, 0), DIRT)
	local y = -6
	for i, d in { r * 1.75, r * 1.4, r * 1.05, r * 0.72, r * 0.42, r * 0.18 } do
		local h = 9 + i * 2
		b:cyl(h, d, V(0, y - h / 2, 0), i % 2 == 0 and ROCK_DARK or ROCK)
		y -= h
	end
	-- studs round the rim
	for i = 0, 39 do
		local a = i / 40 * math.pi * 2
		b:cyl(0.6, 3.2, V(math.sin(a) * (r - 3.2), 0.3, math.cos(a) * (r - 3.2)), GRASS, nil, NO_COLLIDE)
	end
	-- stone path from the arrival point to the start grid and the arena
	for i = 0, 14 do
		b:box(V(10 - (i % 2) * 1.5, 0.3, 6), V(((i % 2) - 0.5) * 1.4, 0.06, 56 - i * 6.2), TAN, M.SmoothPlastic)
	end
end

-- ============================================================== start area
local function startArea(b, model)
	-- pads
	for i, pos in RaceConfig.Pads do
		local color = Color3.fromHSV((i - 1) / #RaceConfig.Pads, 0.7, 0.95)
		b:roundBrick(1.2, 14, pos + V(0, 0.6, 0), ROCK_DARK, { Studs = "None" })
		local top = b:roundBrick(0.5, 12, pos + V(0, 1.45, 0), color, { Studs = "Ring", RingRadius = 5, StudColor = WHITE })
		top.Name = "Pad" .. i
		top:SetAttribute("Slot", i)
		local tile = b:box(V(4, 0.2, 2.4), CF(pos + V(0, 1.8, 6.3)), WHITE, M.SmoothPlastic, NO_COLLIDE)
		sign(tile, Enum.NormalId.Top, tostring(i), BLACK, 40, "PadNumber")
	end
	-- the arch: a big ring (Gate_0 is added by the gates builder) + checkered line + banners
	local arch = RaceConfig.Gates[1]
	local line = V(0, 0.15, arch.Position.Z)
	for i = -10, 9 do
		for j = 0, 1 do
			local dark = (i + j) % 2 == 0
			b:box(V(6, 0.3, 3), line + V(i * 6 + 3, 0, j * 3 - 1.5), dark and BLACK or WHITE, M.SmoothPlastic, NO_COLLIDE)
		end
	end
	for _, sx in { -1, 1 } do
		b:box(V(4, 26, 4), V(sx * 44, 13, arch.Position.Z), RED, M.SmoothPlastic)
		b:box(V(5.2, 1.4, 5.2), V(sx * 44, 26.7, arch.Position.Z), YELLOW, M.SmoothPlastic)
		b:banner(CF(sx * 44, 17, arch.Position.Z + 2.4) * ANG(0, math.pi, 0), 5, 14, BLUE)
	end
	local top = b:box(V(92, 5.5, 3.2), V(0, 31, arch.Position.Z), YELLOW, M.SmoothPlastic)
	sign(top, Enum.NormalId.Front, "START / FINISH", RED, 30, "ArchSign")
	sign(top, Enum.NormalId.Back, "START / FINISH", RED, 30, "ArchSignBack")
end

-- ============================================================== plaza
local function plaza(b, model)
	-- round tiled plaza
	b:roundBrick(1.0, 92, V(0, 0.5, 6), ROCK, { Studs = "None" })
	b:roundBrick(0.5, 84, V(0, 1.2, 6), TAN, { Studs = "Ring", RingRadius = 38, StudColor = WHITE })
	-- the join pad
	local jp = RaceConfig.JoinPad
	b:roundBrick(1.2, 16, jp + V(0, 2.2, 0), RED, { Studs = "None" })
	b:roundBrick(0.6, 12, jp + V(0, 3.1, 0), YELLOW, { Studs = "None" })
	local pad = b:cyl(0.4, 9, jp + V(0, 3.6, 0), WHITE, M.Neon)
	pad.Name = "JoinPad"
	b:prompt(pad, "Join the Race", "Sky Circuit", { Window = "Race" })
	local sg = b:box(V(24, 5, 1), jp + V(0, 12, 8), BLUE, M.SmoothPlastic)
	sign(sg, Enum.NormalId.Front, "DRAGON RACE", YELLOW, 30, "JoinSign")
	sign(sg, Enum.NormalId.Back, "DRAGON RACE", YELLOW, 30, "JoinSignBack")
	for _, sx in { -1, 1 } do
		b:box(V(1.4, 10, 1.4), jp + V(sx * 11, 6.6, 8), ROCK_DARK, M.SmoothPlastic)
	end
	-- lamp posts + flower beds
	local rng = Random.new(77)
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2 + 0.2
		b:lampPost(V(math.sin(a) * 44, 1.4, 6 + math.cos(a) * 44), 10)
	end
	for i = 0, 17 do
		local a = i / 18 * math.pi * 2
		local rr = 52 + (i % 3) * 3
		local col = ({ RED, YELLOW, WHITE, Color3.fromRGB(228, 160, 200), CYAN })[rng:NextInteger(1, 5)]
		b:cyl(0.5, 1.6, V(math.sin(a) * rr, 0.3, 6 + math.cos(a) * rr), col, nil, NO_COLLIDE)
	end
end

-- ============================================================== winners podium
local function podium(b)
	local at = RaceConfig.Podium
	-- the front (-Z of the model) looks at the plaza
	local model = b:sub("Podium", CFrame.lookAt(at, V(0, at.Y, 6)))
	model:box(V(30, 1.2, 16), V(0, 0.6, 0), ROCK_DARK, M.SmoothPlastic)
	local steps = { { x = 0, h = 9, c = YELLOW }, { x = -9, h = 6, c = ROCK }, { x = 9, h = 4, c = Color3.fromRGB(205, 130, 70) } }
	for place, s in steps do
		model:box(V(8, s.h, 8), V(s.x, 1.2 + s.h / 2, 0), s.c, M.SmoothPlastic)
		local face = model:box(V(7, 2.6, 0.3), V(s.x, 1.2 + s.h - 1.6, -4.2), BLACK, M.SmoothPlastic, NO_COLLIDE)
		sign(face, Enum.NormalId.Front, tostring(place), WHITE, 40, "Place")
	end
	-- trophy on the first step
	model:cyl(1.6, 5, V(0, 10.2 + 1, 0), YELLOW, M.Foil)
	model:cyl(3.4, 2.4, V(0, 10.2 + 3.6, 0), YELLOW, M.Foil)
	local cup = model:cyl(4.6, 6.4, V(0, 10.2 + 7.2, 0), YELLOW, M.Foil)
	cup.Name = "Trophy"
	model:ball(3.4, V(0, 10.2 + 11, 0), Color3.fromRGB(255, 240, 150), M.Neon, { CastShadow = false })
	-- winners board behind the podium
	local board = model:box(V(34, 22, 1), V(0, 14, 7), Color3.fromRGB(26, 30, 52), M.SmoothPlastic)
	board.Name = "Winners"
	local gui = Instance.new("SurfaceGui")
	gui.Name = "WinnersGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 36
	gui.LightInfluence = 0
	gui.Parent = board
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(0.92, 0.13)
	title.Position = UDim2.fromScale(0.04, 0.02)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = YELLOW
	title.Text = "MONTHLY CHAMPIONS"
	title.Parent = gui
	local prize = Instance.new("TextLabel")
	prize.Name = "Prize"
	prize.BackgroundTransparency = 1
	prize.Size = UDim2.fromScale(0.92, 0.075)
	prize.Position = UDim2.fromScale(0.04, 0.145)
	prize.Font = Enum.Font.GothamBold
	prize.TextScaled = true
	prize.TextColor3 = Color3.fromRGB(150, 230, 160)
	prize.Text = RaceConfig.Monthly.Headline
	prize.Parent = gui
	for i = 1, RaceConfig.Monthly.HistoryCount do
		local row = Instance.new("TextLabel")
		row.Name = "Row" .. i
		row.BackgroundTransparency = i % 2 == 0 and 0.92 or 0.85
		row.BackgroundColor3 = Color3.new(1, 1, 1)
		row.BorderSizePixel = 0
		row.Size = UDim2.fromScale(0.92, 0.1)
		row.Position = UDim2.fromScale(0.04, 0.25 + (i - 1) * 0.118)
		row.Font = Enum.Font.GothamBold
		row.TextScaled = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = WHITE
		row.Text = "  ---"
		row.Parent = gui
	end
	return model.Model
end

-- Winners list: { { Month = "202609", Name = "Alice", Ms = 41234 }, ... } newest first.
function RaceIsland.setWinners(island: Model, winners: { any })
	local board = island:FindFirstChild("Winners", true)
	local gui = board and board:FindFirstChild("WinnersGui")
	if not gui then
		return
	end
	for i = 1, RaceConfig.Monthly.HistoryCount do
		local row = gui:FindFirstChild("Row" .. i) :: TextLabel?
		local w = winners[i]
		if row then
			if w then
				local year, month = string.sub(w.Month, 1, 4), string.sub(w.Month, 5, 6)
				row.Text = string.format("  %s/%s   %s   %s", month, year, w.Name, RaceConfig.formatTime(w.Ms))
			else
				row.Text = "  ---"
			end
		end
	end
end

-- ============================================================== arena
local function arena(b)
	local a = CombatConfig.Arena
	local c = a.Center
	local r = a.Radius
	local model = b:sub("Arena", CF(c))
	-- floor: concentric tile rings
	local ringColors = { ROCK_DARK, ROCK, TAN, ROCK, ROCK_DARK }
	for i, d in { r * 2, r * 1.6, r * 1.2, r * 0.8, r * 0.4 } do
		local part = model:cyl(1.4 + i * 0.05, d, V(0, 0.7 + i * 0.03, 0), ringColors[i], M.SmoothPlastic)
		if i == 1 then
			part.Name = "ArenaFloor"
		end
	end
	-- the emblem
	model:cyl(0.3, 16, V(0, 1.8, 0), RED, M.SmoothPlastic, NO_COLLIDE)
	model:cyl(0.35, 11, V(0, 1.9, 0), YELLOW, M.SmoothPlastic, NO_COLLIDE)
	model:cyl(0.4, 6, V(0, 2.0, 0), RED, M.SmoothPlastic, NO_COLLIDE)
	-- wall: bricks all round, a gap at the entrance (towards the plaza, local -Z)
	local n = 44
	local entrance = -math.pi / 2
	for i = 0, n - 1 do
		local ang = i / n * math.pi * 2
		local d = math.abs((ang - entrance + math.pi) % (math.pi * 2) - math.pi)
		if d > 0.2 then
			local p = V(math.cos(ang) * (r - 2), 8, math.sin(ang) * (r - 2))
			local color = (i % 2 == 0) and ROCK or ROCK_DARK
			local w = model:box(V(4, 15, 4.4), CF(p) * ANG(0, -ang, 0), color, M.SmoothPlastic)
			w.Name = "ArenaWall"
			model:cyl(0.6, 2.6, p + V(0, 8.1, 0), color, M.SmoothPlastic, NO_COLLIDE)
		end
	end
	-- torches on pillars + neon boundary
	for i = 0, 7 do
		local ang = (i + 0.5) / 8 * math.pi * 2
		local p = V(math.cos(ang) * (r + 3), 0, math.sin(ang) * (r + 3))
		model:roundBrick(18, 5, p + V(0, 9, 0), RED, { Studs = "None" })
		model:roundBrick(2, 6.4, p + V(0, 19, 0), YELLOW, { Studs = "Top" })
		model:ball(3.2, p + V(0, 22, 0), Color3.fromRGB(255, 150, 50), M.Neon, { CastShadow = false })
	end
	for i = 0, 35 do
		local ang = i / 36 * math.pi * 2
		model:box(V(2.6, 0.3, 0.8), CF(V(math.cos(ang) * (r - 0.6), 1.7, math.sin(ang) * (r - 0.6))) * ANG(0, -ang, 0), Color3.fromRGB(255, 70, 60), M.Neon, NO_COLLIDE)
	end
	for i = 0, 11 do
		local ang = i / 12 * math.pi * 2 + 0.13
		model:box(V(1.2, 60, 1.2), V(math.cos(ang) * (r + 0.6), 30, math.sin(ang) * (r + 0.6)), Color3.fromRGB(255, 80, 70), M.Neon, { Transparency = 0.6, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	end
	-- the sign over the entrance side
	local bar = model:box(V(30, 5, 1.6), V(0, 24, -(r - 0.5)), RED, M.SmoothPlastic, NO_COLLIDE)
	sign(bar, Enum.NormalId.Front, "DUEL ARENA", YELLOW, 30, "ArenaSign")
	for _, sx in { -1, 1 } do
		model:box(V(2.4, 24, 2.4), V(sx * 14, 12, -(r - 0.5)), ROCK_DARK, M.SmoothPlastic)
	end
	-- the training dummy: a target on a pole (CombatService keeps its hit points on the model)
	local dd = CombatConfig.Dummy
	local dummy = model:sub("TrainingDummy", CF(dd.Position.X - c.X, 0, dd.Position.Z - c.Z))
	dummy:roundBrick(2.2, 15, V(0, 2.9, 0), ROCK_DARK, { Studs = "Ring", RingRadius = 5.5, StudColor = WHITE })
	dummy:cyl(dd.Height + 2, 2, V(0, 4 + (dd.Height + 2) / 2, 0), DIRT, M.Wood, NO_COLLIDE)
	for turn = 0, 1 do
		local face = CF(0, dd.Height + 1.8, 0) * ANG(0, turn * math.pi / 2, 0)
		local board = dummy:cylX(1, dd.Radius * 2, face, RED, M.SmoothPlastic, NO_COLLIDE)
		if turn == 0 then
			board.Name = "Target"
		end
		dummy:cylX(1.2, dd.Radius * 1.4, face, WHITE, M.SmoothPlastic, NO_COLLIDE)
		dummy:cylX(1.4, dd.Radius * 0.7, face, RED, M.SmoothPlastic, NO_COLLIDE)
	end
	dummy:ball(2.6, V(0, dd.Height + dd.Radius + 4, 0), YELLOW, M.Neon, NO_COLLIDE)
	dummy.Model:SetAttribute("IsDummy", true)
	-- respawn pads (world positions are CombatConfig.Respawns)
	for i, pos in CombatConfig.Respawns do
		local local_ = pos - c
		local pad = model:cyl(0.5, 7, local_ + V(0, 1.6, 0), CYAN, M.Neon, NO_COLLIDE)
		pad.Name = "RespawnPad" .. i
	end
end

-- ============================================================== the sky circuit
local function gates(b)
	local folder = b:sub("Gates")
	local n = RaceConfig.GateCount
	for k = 0, n - 1 do
		local g = RaceConfig.Gates[k + 1]
		local gb = folder:sub("Gate_" .. k)
		gb.Model:SetAttribute("Gate", k)
		local hue = k / n
		local radius = k == 0 and 34 or RaceConfig.GateRadius - 1
		local colors = function(i)
			return i % 2 == 0 and Color3.fromHSV(hue, 0.78, 1) or Color3.fromHSV(hue, 0.35, 1)
		end
		local segs = ring(gb, g.Position, g.Direction, radius, 3.6, 3.2, k == 0 and function(i)
			return i % 2 == 0 and YELLOW or RED
		end or colors, M.SmoothPlastic, 18, "GateRing", NO_COLLIDE)
		for _, s in segs do
			s:SetAttribute("Gate", k)
		end
		-- number plate on the top of the ring
		local f = g.Direction.Unit
		local plate = gb:box(V(5, 3, 0.6), CFrame.lookAt(g.Position + Vector3.yAxis * (radius + 4), g.Position + Vector3.yAxis * (radius + 4) + f), WHITE, M.SmoothPlastic, NO_COLLIDE)
		plate.Name = "GatePlate"
		sign(plate, Enum.NormalId.Front, k == 0 and "S/F" or tostring(k), BLACK, 40, "GateNumber")
		sign(plate, Enum.NormalId.Back, k == 0 and "S/F" or tostring(k), BLACK, 40, "GateNumberBack")
	end
	local boosts = b:sub("Boosts")
	for i, bo in RaceConfig.Boosts do
		local bb = boosts:sub("Boost_" .. i)
		bb.Model:SetAttribute("Boost", i)
		local segs = ring(bb, bo.Position, bo.Direction, RaceConfig.Boost.Radius, 2.4, 2.4, CYAN, M.Neon, 14, "BoostRing", NO_COLLIDE)
		for _, s in segs do
			s:SetAttribute("Boost", i)
		end
		-- a faint disc inside so the ring reads as a portal
		local f = bo.Direction.Unit
		local r = f:Cross(Vector3.yAxis)
		r = r.Magnitude < 1e-3 and Vector3.xAxis or r.Unit
		local disc = bb:cyl(0.3, RaceConfig.Boost.Radius * 2 - 3, CFrame.fromMatrix(bo.Position, f, r:Cross(f)) * ANG(0, 0, 0), CYAN, M.Neon,
			{ Transparency = 0.88, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
		disc.Name = "BoostDisc"
	end
end

-- ============================================================== decoration
local function decor(b, r: number)
	local rng = Random.new(99)
	for i = 1, 16 do
		local a = rng:NextNumber(0, math.pi * 2)
		local rr = rng:NextNumber(r * 0.62, r - 10)
		local x, z = math.sin(a) * rr, math.cos(a) * rr
		-- keep the arena, the start grid and the path free
		if not (math.abs(x) < 70 and z > 40) and not (math.abs(x) < 70 and z < -20) then
			local h = 6 + rng:NextInteger(0, 3)
			b:box(V(1.8, h, 1.8), V(x, h / 2, z), DIRT)
			b:box(V(7, 4, 7), V(x, h + 1.6, z), Color3.fromRGB(39, 112, 62))
			b:box(V(4.4, 3, 4.4), V(x, h + 5, z), GRASS)
		end
	end
	-- spectator stands next to the start grid
	for _, sx in { -1, 1 } do
		for step = 0, 3 do
			b:box(V(10, 1.6 + step * 1.6, 30), V(sx * 78 + sx * step * 4, (1.6 + step * 1.6) / 2, -50), step % 2 == 0 and RED or WHITE, M.SmoothPlastic)
		end
	end
	-- clouds hugging the underside
	for i, p in { V(-60, -22, 40), V(70, -30, -40), V(10, -44, 90), V(-30, -36, -80), V(100, -26, 60) } do
		local c = Kit.new(b.Model, CF(b.Origin.Position + p), "Cloud" .. i)
		c:ball(24, V(0, 0, 0), WHITE, M.SmoothPlastic, NO_COLLIDE)
		c:ball(18, V(14, -2, 3), WHITE, M.SmoothPlastic, NO_COLLIDE)
		c:ball(16, V(-13, -3, -2), WHITE, M.SmoothPlastic, NO_COLLIDE)
	end
end

function RaceIsland.build(parent: Instance): Model
	local center = RaceConfig.Island.Center
	local r = RaceConfig.Island.Radius
	local b = Kit.new(parent, CF(center), "RaceIsland")
	pcall(function()
		(b.Model :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	base(b, r)
	startArea(b, b.Model)
	plaza(b, b.Model)
	podium(b)
	arena(b)
	gates(b)
	decor(b, r)
	b.Model:SetAttribute("Island", "Race")
	return b.Model
end

return RaceIsland

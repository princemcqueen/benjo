--[[
	Village - Dragon Haven hub: plaza, dragon statue, stations (market,
	forge, hall of dragons, elder), cottages, lamps, market details.
	Every recipe builds in a local frame whose -Z faces the street/plaza.
]]


local Kit = require(script.Parent:WaitForChild("Kit"))

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local C = Kit.C
local M = Kit.M

local Village = {}

-- ============================================================== cottage
-- opts: W, D, Stories, Seed, Roof ("Slate" | "Clay" | "Moss")
function Village.cottage(parent: Instance, origin: CFrame, opts: { [string]: any }?)
	local o = opts or {}
	local rng = Random.new(o.Seed or 1)
	local w = o.W or rng:NextInteger(12, 16)
	local d = o.D or rng:NextInteger(11, 15)
	local stories = o.Stories or (rng:NextNumber() < 0.55 and 2 or 1)
	local storyH = 9
	local b = Kit.new(parent, origin, o.Name or "Cottage")
	local plaster = rng:NextNumber() < 0.5 and C.Plaster or C.PlasterWarm
	local roofColor = ({ Slate = C.RoofSlate, Clay = C.RoofClay, Moss = C.RoofMoss })[o.Roof or (rng:NextNumber() < 0.6 and "Slate" or "Clay")]
	-- foundation
	b:box(V(w + 1.2, 2.2, d + 1.2), V(0, 1.1, 0), C.StoneDark, M.Slate)
	b:box(V(w + 1.6, 0.5, d + 1.6), V(0, 2.25, 0), C.Stone, M.Cobblestone)
	local y = 2.4
	for s = 1, stories do
		local jetty = (s == 2) and 0.8 or 0
		local ww, dd = w + jetty * 0.0, d + jetty * 2
		local cy = y + storyH / 2
		-- walls (plaster), 1 stud thick
		b:box(V(ww, storyH, 1), V(0, cy, -dd / 2 + 0.5), plaster, M.Plaster)
		b:box(V(ww, storyH, 1), V(0, cy, dd / 2 - 0.5), plaster, M.Plaster)
		b:box(V(1, storyH, dd - 2), V(-ww / 2 + 0.5, cy, 0), plaster, M.Plaster)
		b:box(V(1, storyH, dd - 2), V(ww / 2 - 0.5, cy, 0), plaster, M.Plaster)
		-- timber frame: corner posts, sill + head beams, braces
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				b:box(V(1.2, storyH, 1.2), V(sx * (ww / 2 - 0.4), cy, sz * (dd / 2 - 0.4)), C.Timber, M.Wood)
			end
		end
		for _, sz in { -1, 1 } do
			b:box(V(ww + 0.4, 0.9, 1.25), V(0, y + 0.45, sz * (dd / 2 - 0.35)), C.Timber, M.Wood)
			b:box(V(ww + 0.4, 0.9, 1.25), V(0, y + storyH - 0.45, sz * (dd / 2 - 0.35)), C.Timber, M.Wood)
		end
		for _, sx in { -1, 1 } do
			b:box(V(1.25, 0.9, dd + 0.4), V(sx * (ww / 2 - 0.35), y + storyH - 0.45, 0), C.Timber, M.Wood)
		end
		-- mid posts on front/back
		for _, sz in { -1, 1 } do
			for _, px in { -w * 0.18, w * 0.18 } do
				b:box(V(0.8, storyH - 1.6, 1.15), V(px, cy, sz * (dd / 2 - 0.35)), C.Timber, M.Wood)
			end
		end
		-- windows
		local wy = y + storyH * 0.55
		if s == 1 then
			b:door(CF(0, y + 3.6, -dd / 2 - 0.05), 3.6, 7.2)
			b:window(CF(-w * 0.34, wy, -dd / 2 - 0.1), 2.6, 3.2)
			b:window(CF(w * 0.34, wy, -dd / 2 - 0.1), 2.6, 3.2)
			-- flower boxes
			for _, px in { -w * 0.34, w * 0.34 } do
				b:box(V(3.2, 0.8, 1.0), V(px, wy - 2.2, -dd / 2 - 0.6), C.Timber, M.Wood)
				for k = -1, 1 do
					local col = rng:NextNumber() < 0.5 and Color3.fromRGB(196, 64, 72) or Color3.fromRGB(232, 196, 84)
					b:ball(0.8, V(px + k * 0.9, wy - 1.6, -dd / 2 - 0.65), col, M.SmoothPlastic, { CastShadow = false, CanCollide = false })
				end
			end
		else
			b:window(CF(-w * 0.26, wy, -dd / 2 - 0.1), 2.6, 3.4)
			b:window(CF(w * 0.26, wy, -dd / 2 - 0.1), 2.6, 3.4)
		end
		b:window(CF(0, wy, dd / 2 + 0.1) * ANG(0, math.pi, 0), 2.6, 3.2)
		for _, sx in { -1, 1 } do
			b:window(CF(sx * (ww / 2 + 0.1), wy, 0) * ANG(0, sx * math.pi / 2, 0), 2.4, 3.0)
		end
		y += storyH
	end
	-- gable walls + roof (ridge along Z)
	local dTop = d + (stories == 2 and 1.6 or 0)
	local rise = w * 0.48
	for _, sz in { -1, 1 } do
		b:gableWall(w, rise, 1, V(0, y, sz * (dTop / 2 - 0.5)), plaster, M.Plaster)
		b:box(V(w + 0.6, 0.8, 1.2), V(0, y + 0.4, sz * (dTop / 2 - 0.4)), C.Timber, M.Wood)
		b:box(V(0.8, rise - 1, 1.15), V(0, y + (rise - 1) / 2, sz * (dTop / 2 - 0.35)), C.Timber, M.Wood)
	end
	b:gableRoof(w, dTop, rise, 1.6, V(0, y, 0), roofColor, M.RoofShingles, 0.9)
	-- chimney
	local cs = rng:NextNumber() < 0.5 and -1 or 1
	local chx = cs * w * 0.24
	local chTop = y + rise * 0.9 + 3
	b:box(V(2.4, chTop - 2, 2.4), V(chx, (chTop + 2) / 2, d * 0.18), C.Stone, M.Cobblestone)
	b:box(V(2.9, 0.6, 2.9), V(chx, chTop, d * 0.18), C.StoneDark, M.Slate)
	b:box(V(1.4, 0.2, 1.4), V(chx, chTop + 0.35, d * 0.18), Color3.fromRGB(30, 26, 24), M.Slate)
	-- doorstep + lantern
	b:box(V(5, 0.6, 2.4), V(0, 0.3, -d / 2 - 1.6), C.Stone, M.Slate)
	local lamp = b:box(V(0.9, 1.2, 0.9), V(2.8, 7.6, -d / 2 - 0.9), C.Window, M.Neon, { Transparency = 0.2, CastShadow = false })
	b:box(V(0.3, 0.3, 1.2), V(2.8, 8.4, -d / 2 - 0.5), C.Iron, M.Metal)
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 186, 118)
	pl.Range = 16
	pl.Brightness = 1.2
	pl.Parent = lamp
	return b.Model
end

-- ============================================================== signs
local function signBoard(b, at: CFrame, w: number, h: number, text: string)
	local board = b:box(V(w, h, 0.5), at, C.Planks, M.WoodPlanks)
	b:box(V(w + 0.6, 0.4, 0.7), at * CF(0, h / 2 + 0.2, 0), C.Timber, M.Wood)
	b:box(V(w + 0.6, 0.4, 0.7), at * CF(0, -h / 2 - 0.2, 0), C.Timber, M.Wood)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 1
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.Fondamento
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(248, 222, 160)
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(40, 26, 14)
	stroke.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.PaddingTop = UDim.new(0.12, 0)
	pad.PaddingBottom = UDim.new(0.12, 0)
	pad.Parent = label
	label.Parent = gui
	return board
end
Village.signBoard = signBoard

local function stationPrompt(b, part: BasePart, station: { [string]: any }, id: string)
	local p = b:prompt(part, station.Prompt or "Open", station.Name, { Station = id, Window = station.Window, Tab = station.Tab })
	p.MaxActivationDistance = 18
	p.Name = "StationPrompt"
	return p
end

-- ============================================================== market hall (Shop)
function Village.market(parent: Instance, origin: CFrame, station)
	local b = Kit.new(parent, origin, "DragonMarket")
	local w, d, h = 34, 24, 13
	b:box(V(w + 2, 1.6, d + 2), V(0, 0.8, 0), C.StoneDark, M.Slate)
	b:box(V(w, 0.4, d), V(0, 1.8, 0), C.Cobble, M.Cobblestone)
	-- timber posts (open hall) + stone corner piers
	for ix = -2, 2 do
		for _, sz in { -1, 1 } do
			local x = ix * (w / 4 - 0.5)
			if math.abs(ix) == 2 then
				b:box(V(2.6, h, 2.6), V(x, 2 + h / 2, sz * (d / 2 - 1)), C.Stone, M.Cobblestone)
			else
				b:box(V(1.4, h, 1.4), V(x, 2 + h / 2, sz * (d / 2 - 1)), C.Timber, M.Wood)
				b:beam(V(x, 2 + h - 3.5, sz * (d / 2 - 1)), V(x + 3, 2 + h - 0.6, sz * (d / 2 - 1)), 0.8, C.Timber, M.Wood)
				b:beam(V(x, 2 + h - 3.5, sz * (d / 2 - 1)), V(x - 3, 2 + h - 0.6, sz * (d / 2 - 1)), 0.8, C.Timber, M.Wood)
			end
		end
	end
	-- back wall (stone) with windows
	b:box(V(w - 2, h, 1.2), V(0, 2 + h / 2, d / 2 - 1), C.StoneWarm, M.Cobblestone)
	for _, x in { -10, 0, 10 } do
		b:window(CF(x, 2 + h * 0.6, d / 2 - 1.7) * ANG(0, math.pi, 0), 3, 4)
	end
	b:box(V(w + 1, 1.2, 1.6), V(0, 2 + h + 0.4, -d / 2 + 1), C.Timber, M.Wood)
	b:box(V(w + 1, 1.2, 1.6), V(0, 2 + h + 0.4, d / 2 - 1), C.Timber, M.Wood)
	for _, sx in { -1, 1 } do
		b:box(V(1.6, 1.2, d + 1), V(sx * (w / 2 - 1), 2 + h + 0.4, 0), C.Timber, M.Wood)
	end
	-- big roof: ridge along X (long hall) -> build in a rotated sub-frame
	local roof = b:sub("Roof", CF(0, 2 + h + 1, 0) * ANG(0, math.pi / 2, 0))
	roof:gableRoof(d + 1, w + 1, 10, 2.4, V(0, 0, 0), C.RoofClay, M.ClayRoofTiles, 1.1)
	for _, sz in { -1, 1 } do
		roof:gableWall(d + 1, 10, 1.2, V(0, 0, sz * (w / 2)), C.Plaster, M.Plaster)
	end
	-- dragon weathervane
	b:cyl(5, 0.4, V(0, 2 + h + 13, 0), C.Iron, M.Metal)
	b:wedge(V(0.3, 1.6, 3), CF(0, 2 + h + 15.5, 0) * ANG(0, math.pi / 2, 0), C.Gold, M.Foil)
	-- stalls inside: tables with goods
	local rng = Random.new(42)
	for i, x in { -11, 0, 11 } do
		b:box(V(8, 0.6, 3.6), V(x, 5, -2), C.Planks, M.WoodPlanks)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				b:box(V(0.5, 3, 0.5), V(x + sx * 3.6, 3.5, -2 + sz * 1.5), C.Timber, M.Wood)
			end
		end
		-- awning
		local col = ({ C.BannerRed, C.BannerBlue, C.BannerGreen })[i]
		b:box(V(9, 0.25, 5), CF(x, 10.2, -3.2) * ANG(math.rad(-16), 0, 0), col, M.Fabric)
		-- goods: dragon eggs on cushions / fruit / crystals
		for k = -1, 1 do
			local px = x + k * 2.4
			if i == 2 then
				b:box(V(1.8, 0.4, 1.8), V(px, 5.5, -2), C.BannerRed, M.Fabric)
				local egg = b:ball(1.6, CF(px, 6.6, -2), Color3.fromHSV(rng:NextNumber(), 0.45, 0.85), M.SmoothPlastic)
				egg.Size = V(1.5, 2.0, 1.5)
			elseif i == 1 then
				b:crate(CF(px, 6.0, -2), 1.6)
			else
				local gem = b:box(V(0.8, 1.6, 0.8), CF(px, 6.2, -2) * ANG(0, math.rad(45), math.rad(12)),
					Color3.fromRGB(110, 200, 255), M.Neon, { Transparency = 0.15 })
				gem.CastShadow = false
			end
		end
	end
	for _, p in { V(-15, 2, 8), V(15, 2, 7.5), V(13, 2, 9) } do
		b:barrel(p, 1)
	end
	b:crate(CF(-13.5, 3.5, 9), 3)
	b:crate(CF(-13.5, 6.5, 9) * ANG(0, 0.4, 0), 2.4)
	-- sign + prompt
	local sign = signBoard(b, CF(0, 2 + h - 1.6, -d / 2 - 0.2), 14, 3.4, station and station.Name or "Dragon Market")
	if station then
		stationPrompt(b, b:box(V(8, 4, 3), V(0, 4, -4), C.Planks, M.WoodPlanks, { Transparency = 1, CanCollide = false }), station, "Shop")
	end
	b:banner(CF(-w / 2 + 1, 2 + h - 4.5, -d / 2 - 0.4), 3.2, 7, C.BannerRed)
	b:banner(CF(w / 2 - 1, 2 + h - 4.5, -d / 2 - 0.4), 3.2, 7, C.BannerRed)
	return b.Model, sign
end

-- ============================================================== forge (Upgrades)
function Village.forge(parent: Instance, origin: CFrame, station)
	local b = Kit.new(parent, origin, "DragonsmithForge")
	local w, d, h = 22, 18, 11
	b:box(V(w + 2, 1.6, d + 2), V(0, 0.8, 0), C.StoneDark, M.Slate)
	-- three stone walls, open front with a big arch beam
	b:box(V(w, h, 1.6), V(0, 1.6 + h / 2, d / 2 - 0.8), C.Stone, M.Cobblestone)
	for _, sx in { -1, 1 } do
		b:box(V(1.6, h, d), V(sx * (w / 2 - 0.8), 1.6 + h / 2, 0), C.Stone, M.Cobblestone)
		b:box(V(2.4, h + 1, 2.4), V(sx * (w / 2 - 0.8), 1.6 + (h + 1) / 2, -d / 2 + 1.2), C.StoneDark, M.Slate)
	end
	b:box(V(w + 1, 2, 2), V(0, 1.6 + h, -d / 2 + 1.2), C.Timber, M.Wood)
	local roof = b:sub("Roof", CF(0, 1.6 + h + 1, 0) * ANG(0, math.pi / 2, 0))
	roof:gableRoof(d, w + 1, 7, 1.8, V(0, 0, 0), C.RoofSlateDark, M.Slate, 1.0)
	for _, sz in { -1, 1 } do
		roof:gableWall(d, 7, 1.2, V(0, 0, sz * (w / 2)), C.Stone, M.Cobblestone)
	end
	-- massive chimney with ember glow
	b:box(V(5, h + 14, 5), V(w / 2 - 3.5, 1.6 + (h + 14) / 2, d / 2 - 3), C.StoneDark, M.Cobblestone)
	b:box(V(6, 1, 6), V(w / 2 - 3.5, 1.6 + h + 14, d / 2 - 3), C.Stone, M.Slate)
	local smokePart = b:box(V(3, 0.3, 3), V(w / 2 - 3.5, 1.6 + h + 14.6, d / 2 - 3), Color3.fromRGB(25, 20, 18), M.Slate)
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(90, 86, 84)
	smoke.Opacity = 0.12
	smoke.RiseVelocity = 6
	smoke.Size = 4
	smoke.Parent = smokePart
	-- hearth
	b:box(V(8, 4, 4), V(w / 2 - 6, 3.6, d / 2 - 3.2), C.StoneDark, M.Slate)
	local coals = b:box(V(6, 0.6, 2.6), V(w / 2 - 6, 5.8, d / 2 - 3.2), Color3.fromRGB(255, 120, 40), M.Neon, { CastShadow = false })
	local fire = Instance.new("Fire")
	fire.Heat = 6
	fire.Size = 4
	fire.Color = Color3.fromRGB(255, 140, 50)
	fire.SecondaryColor = Color3.fromRGB(255, 220, 120)
	fire.Parent = coals
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 140, 60)
	glow.Range = 26
	glow.Brightness = 2.2
	glow.Parent = coals
	-- anvil + tools
	b:box(V(2.4, 2.6, 2.4), V(-2, 2.9, -1), C.Timber, M.Wood)
	b:box(V(4.2, 1.1, 1.6), V(-2, 4.7, -1), C.Iron, M.Metal)
	b:wedge(V(1.6, 1.1, 1.6), CF(-4.9, 4.7, -1) * ANG(0, math.rad(90), 0), C.Iron, M.Metal)
	b:box(V(0.35, 0.35, 3), CF(-1.2, 5.6, -1) * ANG(0, 0.6, 0), C.Timber, M.Wood)
	b:box(V(1.0, 0.8, 0.8), CF(-0.2, 5.7, -1.6) * ANG(0, 0.6, 0), C.Iron, M.Metal)
	-- weapon rack + armor stand
	for i = -1, 1 do
		b:box(V(0.3, 7, 0.3), CF(-w / 2 + 2.2, 5.5, i * 2.2) * ANG(0, 0, math.rad(8)), Color3.fromRGB(176, 180, 186), M.Metal)
	end
	b:box(V(0.6, 6, 6), V(-w / 2 + 1.8, 5, 0), C.Timber, M.Wood, { Transparency = 0 })
	b:barrel(V(5, 1.6, -5), 1.1)
	b:crate(CF(7.5, 3.1, -5.5), 3)
	local sign = signBoard(b, CF(0, 1.6 + h - 1.2, -d / 2 + 0.1), 12, 3, station and station.Name or "Dragonsmith Forge")
	if station then
		stationPrompt(b, b:box(V(6, 4, 3), V(-2, 4, -3), C.Planks, M.WoodPlanks, { Transparency = 1, CanCollide = false }), station, "Forge")
	end
	return b.Model, sign
end

-- ============================================================== hall of dragons (Index)
function Village.hall(parent: Instance, origin: CFrame, station)
	local b = Kit.new(parent, origin, "HallOfDragons")
	local w, d, h = 30, 26, 18
	local marble = Color3.fromRGB(214, 206, 190)
	-- stepped plinth
	for i = 0, 2 do
		b:box(V(w + 8 - i * 2, 1, d + 8 - i * 2), V(0, 0.5 + i, -i * 0.5), C.Stone, M.Limestone)
	end
	local base = 3
	-- cella walls
	b:box(V(w - 6, h, 1.4), V(0, base + h / 2, d / 2 - 2), marble, M.Limestone)
	for _, sx in { -1, 1 } do
		b:box(V(1.4, h, d - 6), V(sx * (w / 2 - 3), base + h / 2, 1), marble, M.Limestone)
	end
	b:box(V(w - 6, h, 1.4), V(0, base + h / 2, -d / 2 + 4), marble, M.Limestone, { Transparency = 0 })
	-- grand doorway (dark opening + gold frame)
	b:box(V(7, 11, 0.4), V(0, base + 5.5, -d / 2 + 3.25), Color3.fromRGB(28, 22, 20), M.Slate)
	b:box(V(8.2, 0.8, 0.6), V(0, base + 11.3, -d / 2 + 3.1), C.Gold, M.Foil)
	-- portico columns
	for i = -3, 3 do
		local x = i * (w / 6.6)
		b:cyl(h, 2.2, V(x, base + h / 2, -d / 2 + 0.5), marble, M.Marble)
		b:box(V(3, 0.8, 3), V(x, base + 0.4, -d / 2 + 0.5), marble, M.Limestone)
		b:box(V(3, 0.8, 3), V(x, base + h - 0.4, -d / 2 + 0.5), marble, M.Limestone)
	end
	-- entablature + pediment
	b:box(V(w + 2, 2, d + 2), V(0, base + h + 1, 0), marble, M.Limestone)
	b:box(V(w + 2.6, 0.6, d + 2.6), V(0, base + h + 2.3, 0), C.Gold, M.Foil)
	local roof = b:sub("Roof", CF(0, base + h + 2.6, 0))
	roof:gableRoof(w + 2, d + 2, 7, 1.2, V(0, 0, 0), C.RoofSlate, M.Slate, 1.0)
	roof:gableWall(w + 2, 7, 1, V(0, 0, -d / 2 - 0.6), marble, M.Limestone)
	roof:gableWall(w + 2, 7, 1, V(0, 0, d / 2 + 0.6), marble, M.Limestone)
	-- dragon crest disc on the pediment
	b:cylX(0.5, 4.5, CF(0, base + h + 5.4, -d / 2 - 1.2) * ANG(0, math.pi / 2, 0), C.Gold, M.Foil)
	-- banners between columns
	for _, x in { -w / 3.3, w / 3.3 } do
		b:banner(CF(x, base + h - 6, -d / 2 + 3.0), 3.4, 9, C.BannerBlue)
	end
	-- braziers flanking the stairs
	for _, sx in { -1, 1 } do
		local p = V(sx * (w / 2 + 2), 3, -d / 2 - 2)
		b:cyl(4, 1.2, p + V(0, 2, 0), C.Iron, M.Metal)
		local bowl = b:cyl(1.2, 3, p + V(0, 4.6, 0), C.Iron, M.Metal)
		local flame = b:box(V(1.6, 0.4, 1.6), p + V(0, 5.3, 0), Color3.fromRGB(255, 160, 60), M.Neon, { CastShadow = false })
		local f = Instance.new("Fire")
		f.Heat = 8
		f.Size = 3
		f.Parent = flame
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 160, 80)
		l.Range = 18
		l.Brightness = 1.6
		l.Parent = flame
		local _ = bowl
	end
	local sign = signBoard(b, CF(0, base + h - 1.5, -d / 2 - 0.2), 15, 2.6, station and station.Name or "Hall of Dragons")
	if station then
		stationPrompt(b, b:box(V(8, 8, 2), V(0, base + 4, -d / 2 + 2), C.Planks, M.WoodPlanks, { Transparency = 1, CanCollide = false }), station, "Library")
	end
	return b.Model, sign
end

-- ============================================================== elder's tower (Quests)
function Village.elder(parent: Instance, origin: CFrame, station)
	local b = Kit.new(parent, origin, "EldersTower")
	local r = 7
	b:cyl(2, r * 2 + 2, V(0, 1, 2), C.StoneDark, M.Slate)
	b:cyl(16, r * 2, V(0, 10, 2), C.StoneWarm, M.Cobblestone)
	b:cyl(1.2, r * 2 + 1.2, V(0, 18.6, 2), C.Timber, M.Wood)
	-- conical roof from stacked shrinking cylinders
	for i = 0, 6 do
		local k = 1 - i / 7
		b:cyl(1.6, (r * 2 + 3) * k + 0.6, V(0, 19.8 + i * 1.5, 2), C.RoofSlate:Lerp(C.RoofSlateDark, i / 7), M.Slate)
	end
	b:cyl(3, 0.4, V(0, 31.5, 2), C.Gold, M.Metal)
	b:door(CF(0, 5.6, 2 - r - 0.05), 3.4, 7.2)
	b:window(CF(0, 13, 2 - r - 0.1), 2.2, 3.2)
	for _, a in { -1.1, 1.1 } do
		b:window(CF(math.sin(a) * (r + 0.1), 12, 2 - math.cos(a) * (r + 0.1)) * ANG(0, -a, 0), 2, 3)
	end
	-- quest board
	b:box(V(0.6, 7, 0.6), V(-9, 3.5, -4), C.Timber, M.Wood)
	b:box(V(0.6, 7, 0.6), V(-4, 3.5, -4), C.Timber, M.Wood)
	local board = b:box(V(5.6, 3.6, 0.4), V(-6.5, 5.6, -4.1), C.Planks, M.WoodPlanks)
	local rng = Random.new(7)
	for i = 1, 5 do
		b:box(V(1.1, 1.3, 0.1), CF(-8.6 + i * 0.85, 5.4 + rng:NextNumber(-0.8, 0.8), -4.35) * ANG(0, 0, rng:NextNumber(-0.2, 0.2)),
			Color3.fromRGB(236, 222, 190), M.Fabric, { CastShadow = false })
	end
	b:box(V(6.4, 0.5, 1.2), V(-6.5, 7.6, -4.1), C.RoofClay, M.ClayRoofTiles)
	-- the elder (simple robed figure; replaced by a humanoid model at runtime when possible)
	local elder = b:sub("ElderRowan")
	elder:box(V(2.6, 4.6, 1.8), V(4.5, 4.6, -4), Color3.fromRGB(70, 52, 96), M.Fabric)
	elder:box(V(2.9, 1.2, 2.0), V(4.5, 2.6, -4), Color3.fromRGB(60, 44, 84), M.Fabric)
	elder:ball(1.9, V(4.5, 7.8, -4), Color3.fromRGB(226, 186, 150), M.SmoothPlastic)
	elder:wedge(V(1.4, 1.6, 0.6), CF(4.5, 6.8, -4.85) * ANG(0, math.pi, math.pi), Color3.fromRGB(236, 236, 236), M.Fabric)
	elder:box(V(0.3, 8, 0.3), CF(6.2, 5, -4.2) * ANG(0, 0, math.rad(-5)), C.Timber, M.Wood)
	local orb = elder:ball(0.9, V(6.55, 9.1, -4.2), Color3.fromRGB(120, 220, 255), M.Neon, { CastShadow = false })
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(140, 220, 255)
	l.Range = 10
	l.Parent = orb
	local sign = signBoard(b, CF(0, 9.6, 2 - r - 0.4), 8, 1.8, station and station.Name or "Elder Rowan")
	if station then
		stationPrompt(b, board, station, "Quests")
	end
	return b.Model, sign
end

-- ============================================================== battle hall (Duels)
-- A little arena ring with banners, two pedestals (a dragon on each side, like the duel scene),
-- a trainer and a sign: Window "Duel" (trainers and challenges).
function Village.duel(parent: Instance, origin: CFrame, station)
	local b = Kit.new(parent, origin, "BattleHall")
	local red, blue = Color3.fromRGB(214, 70, 60), Color3.fromRGB(70, 120, 214)
	-- the ring
	b:cyl(1.4, 26, V(0, 0.7, 0), C.StoneDark, M.Slate)
	b:cyl(0.5, 22, V(0, 1.55, 0), C.StoneWarm, M.Cobblestone)
	b:cyl(0.2, 8, V(0, 1.85, 0), C.Gold, M.Metal)
	for i = 1, 16 do
		local a = i / 16 * math.pi * 2
		b:box(V(2.2, 1.0, 0.6), CF(math.cos(a) * 12.2, 1.6, math.sin(a) * 12.2) * ANG(0, -a + math.pi / 2, 0), i % 2 == 0 and red or blue, M.SmoothPlastic)
	end
	-- two pedestals facing each other
	b:cyl(1.6, 7, V(-6, 2.6, 2), C.Stone, M.Slate)
	b:cyl(1.6, 7, V(6, 2.6, -2), C.Stone, M.Slate)
	b:cyl(0.4, 6, V(-6, 3.6, 2), red, M.SmoothPlastic)
	b:cyl(0.4, 6, V(6, 3.6, -2), blue, M.SmoothPlastic)
	-- banners
	for _, side in { -1, 1 } do
		local color = side < 0 and red or blue
		b:box(V(0.6, 14, 0.6), V(side * 15, 7, -3), C.Timber, M.Wood)
		b:box(V(0.5, 7, 3.2), V(side * 15, 9.5, -3), color, M.Fabric)
		b:wedge(V(0.5, 1.6, 3.2), CF(side * 15, 5.2, -3) * ANG(0, 0, math.pi), color, M.Fabric)
		local l = b:ball(1.6, V(side * 15, 14.4, -3), Color3.fromRGB(255, 220, 120), M.Neon, { CastShadow = false })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 220, 140)
		light.Range = 14
		light.Parent = l
	end
	-- the trainer (a simple figure at the rim)
	local npc = b:sub("Trainer")
	npc:box(V(2.4, 4.2, 1.6), V(11, 3.9, -8), Color3.fromRGB(150, 50, 44), M.Fabric)
	npc:box(V(2.6, 1.0, 1.8), V(11, 2.4, -8), Color3.fromRGB(120, 40, 36), M.Fabric)
	npc:ball(1.8, V(11, 6.9, -8), Color3.fromRGB(226, 186, 150), M.SmoothPlastic)
	npc:box(V(2.2, 0.5, 2.2), V(11, 7.9, -8), Color3.fromRGB(50, 50, 60), M.Fabric)
	local sign = signBoard(b, CF(0, 14.5, -14), 12, 2.2, station and station.Name or "Battle Hall")
	if station then
		stationPrompt(b, b:box(V(8, 4, 4), V(0, 4, -3), C.Planks, M.WoodPlanks, { Transparency = 1, CanCollide = false }), station, "Duel")
	end
	return b.Model, sign
end

return Village

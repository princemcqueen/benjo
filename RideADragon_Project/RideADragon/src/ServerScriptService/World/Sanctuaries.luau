--[[
	Sanctuaries - the 8 personal dragon sanctuaries (plots) around the hub.
	Each plot: stone-walled terrace, gate arch with the owner's banner and
	sign, central nest (eggs), eight dragon perches, income shrine, lanterns.

	Logic-bearing pieces are tagged with attributes so services can find them:
	  plot model attributes: PlotId, OwnerUserId (0 = free)
	  "Nest" part, "Perch1".."Perch8" parts (dragon display slots, layout in
	  WorldConfig.Sanctuary), "PerchGem1".."PerchGem8" (lit when unlocked),
	  "Shrine" part (income collector), "Sign" part (SurfaceGui text),
	  "BannerCloth" parts (tinted with the owner's colour).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent:WaitForChild("Kit"))
local WorldConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("WorldConfig"))

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local C = Kit.C
local M = Kit.M

local Sanctuaries = {}

local W, D = 124, 104 -- matches WorldConfig.PlotSize

local function signGui(part: BasePart, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 36
	gui.LightInfluence = 0.8
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.Fondamento
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(250, 228, 170)
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(36, 24, 14)
	stroke.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.05, 0)
	pad.PaddingRight = UDim.new(0.05, 0)
	pad.PaddingTop = UDim.new(0.1, 0)
	pad.PaddingBottom = UDim.new(0.1, 0)
	pad.Parent = label
	label.Parent = gui
	return label
end

-- Big floating name plate above the gate (BillboardGui, constant pixel size) so
-- every player can see from the hub whose sanctuary this is.
local TAG_FREE = Color3.fromRGB(150, 160, 178)
local TAG_HEIGHT = 44 -- above the plot floor; the gate arch tops out at ~22

local function nameGui(part: BasePart, plotId: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameGui"
	gui.Size = UDim2.fromOffset(300, 74)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 1600
	gui.LightInfluence = 0
	gui.Adornee = part
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
	pill.BackgroundTransparency = 0.1
	pill.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.28, 0)
	corner.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Thickness = 3
	stroke.Color = TAG_FREE
	stroke.Parent = pill
	local name = Instance.new("TextLabel")
	name.Name = "OwnerLabel"
	name.BackgroundTransparency = 1
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.fromScale(0.5, 0.08)
	name.Size = UDim2.fromScale(0.9, 0.54)
	name.Font = Enum.Font.GothamBlack
	name.TextScaled = true
	name.TextColor3 = Color3.fromRGB(190, 198, 212)
	name.Text = "FREE"
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 34
	limit.MinTextSize = 10
	limit.Parent = name
	name.Parent = pill
	local sub = Instance.new("TextLabel")
	sub.Name = "PlotLabel"
	sub.BackgroundTransparency = 1
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.fromScale(0.5, 0.64)
	sub.Size = UDim2.fromScale(0.9, 0.24)
	sub.Font = Enum.Font.GothamBold
	sub.TextScaled = true
	sub.TextColor3 = TAG_FREE
	sub.Text = "SANCTUARY " .. plotId
	local subLimit = Instance.new("UITextSizeConstraint")
	subLimit.MaxTextSize = 15
	subLimit.MinTextSize = 8
	subLimit.Parent = sub
	sub.Parent = pill
	pill.Parent = gui
	gui.Parent = part
	return gui
end

local function nest(b, at: Vector3)
	-- stone dais + woven twig ring + soft bedding
	b:cyl(1.6, 22, at + V(0, 0.8, 0), C.StoneDark, M.Slate)
	b:cyl(0.6, 23, at + V(0, 1.7, 0), C.Stone, M.Cobblestone)
	local n = 22
	for i = 0, n - 1 do
		local a = i / n * math.pi * 2
		local r = 8.2
		local p = at + V(math.cos(a) * r, 3.0, math.sin(a) * r)
		local seg = b:box(V(1.6, 1.4, 3.0), CF(p) * ANG(0, -a, 0) * ANG(math.rad(10 * ((i % 2) * 2 - 1)), 0, 0),
			(i % 3 == 0) and C.TimberLight or C.Timber, M.Wood)
		seg.Name = "Twig"
		local p2 = at + V(math.cos(a + 0.14) * (r - 1.2), 2.4, math.sin(a + 0.14) * (r - 1.2))
		b:box(V(1.2, 1.0, 2.6), CF(p2) * ANG(0, -a - 0.14, 0), C.TimberLight, M.Wood)
	end
	local bed = b:cyl(0.8, 15, at + V(0, 2.2, 0), Color3.fromRGB(176, 150, 104), M.Fabric)
	bed.Name = "Nest"
	return bed
end

-- Gem colours: lit when the owner has unlocked the perch, dark glass otherwise
-- (SanctuaryService.setPerchGem).
local GEM_LIT = Color3.fromRGB(120, 210, 255)
local GEM_DARK = Color3.fromRGB(70, 74, 86)

-- cf: plot-local perch frame at the standing surface (-Z faces the nest).
local function perch(b, cf: CFrame, i: number)
	local at = Vector3.new(cf.Position.X, 0, cf.Position.Z)
	local surface = cf.Position.Y
	b:cyl(surface - 0.6, 13.5, at + V(0, (surface - 0.6) / 2, 0), C.StoneDark, M.Slate)
	b:cyl(0.6, 12.4, at + V(0, surface - 0.3, 0), C.Stone, M.Cobblestone)
	-- soft bedding ring the dragon rests on
	b:cyl(0.22, 9.6, at + V(0, surface + 0.02, 0), Color3.fromRGB(146, 122, 82), M.Fabric, { CanCollide = false })
	local top = b:box(V(10, 0.4, 10), CF(at + V(0, surface - 0.2, 0)) * cf.Rotation, C.StoneWarm, M.Limestone,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	top.Name = "Perch" .. i
	top:SetAttribute("Slot", i)
	-- rune crystal on the outer rim (beside the tail, never under it)
	local out = -cf.LookVector
	local right = cf.RightVector
	local rim = at + (out * 0.55 + right * 0.83).Unit * 6.0
	b:box(V(1.7, 0.9, 1.7), CF(rim + V(0, surface + 0.35, 0)) * cf.Rotation, C.StoneDark, M.Slate)
	local gem = b:box(V(0.9, 2.4, 0.9), CF(rim + V(0, surface + 1.9, 0)) * cf.Rotation * ANG(0, 0.6, 0.18),
		GEM_DARK, M.Glass, { CastShadow = false, Transparency = 0.15 })
	gem.Name = "PerchGem" .. i
	gem:SetAttribute("Slot", i)
end

-- Lights or dims a perch crystal (unlocked / locked).
function Sanctuaries.setPerchGem(model: Model, i: number, lit: boolean)
	local gem = model:FindFirstChild("PerchGem" .. i, true)
	if gem and gem:IsA("BasePart") then
		gem.Color = lit and GEM_LIT or GEM_DARK
		gem.Material = lit and M.Neon or M.Glass
		gem.Transparency = lit and 0.1 or 0.15
	end
end

function Sanctuaries.build(parent: Instance, plot: { [string]: any })
	local cx, cz = plot.Center.X, plot.Center.Z
	local y = plot.Height
	local origin = CF(cx, y, cz) * ANG(0, plot.Facing, 0)
	local b = Kit.new(parent, origin, "Plot" .. plot.Id)
	b.Model:SetAttribute("PlotId", plot.Id)
	b.Model:SetAttribute("OwnerUserId", 0)
	-- low stone wall around the terrace with a gate gap at the front
	local hw, hd = W / 2, D / 2
	local wallH = 3.6
	local corners = { V(-hw, 0, -hd), V(hw, 0, -hd), V(hw, 0, hd), V(-hw, 0, hd) }
	b:stoneWall(V(-hw, 0, -hd), V(-11, 0, -hd), wallH, 2.2)
	b:stoneWall(V(11, 0, -hd), V(hw, 0, -hd), wallH, 2.2)
	b:stoneWall(corners[2], corners[3], wallH, 2.2)
	b:stoneWall(corners[3], corners[4], wallH, 2.2)
	b:stoneWall(corners[4], corners[1], wallH, 2.2)
	for _, p in corners do
		b:box(V(4, wallH + 2.4, 4), p + V(0, (wallH + 2.4) / 2, 0), C.StoneDark, M.Cobblestone)
		b:lampPost(p + V(p.X > 0 and -5 or 5, 0, p.Z > 0 and -5 or 5), 8)
	end
	-- gate arch with banners and the owner sign
	for _, sx in { -1, 1 } do
		b:box(V(4.4, 18, 4.4), V(sx * 11, 9, -hd), C.Stone, M.Cobblestone)
		b:box(V(5.2, 1.2, 5.2), V(sx * 11, 18.6, -hd), C.StoneDark, M.Slate)
		local banner = b:sub("Banner")
		banner:banner(CF(sx * 11, 10, -hd - 2.4), 3.6, 9, C.BannerBlue)
		for _, d in banner.Model:GetDescendants() do
			if d:IsA("BasePart") and d.Material == Enum.Material.Fabric then
				d.Name = "BannerCloth"
			end
		end
	end
	b:box(V(26, 2.6, 4.6), V(0, 19.8, -hd), C.StoneWarm, M.Cobblestone)
	b:box(V(27, 0.8, 5.2), V(0, 21.5, -hd), C.StoneDark, M.Slate)
	local sign = b:box(V(16, 3.2, 0.6), V(0, 15.4, -hd - 2.1), C.Planks, M.WoodPlanks)
	sign.Name = "Sign"
	b:box(V(16.8, 0.4, 0.8), V(0, 17.2, -hd - 2.1), C.Gold, M.Foil)
	b:box(V(16.8, 0.4, 0.8), V(0, 13.6, -hd - 2.1), C.Gold, M.Foil)
	b:box(V(0.4, 3.2, 0.4), V(-4, 18.6, -hd - 2.1), C.Iron, M.Metal)
	b:box(V(0.4, 3.2, 0.4), V(4, 18.6, -hd - 2.1), C.Iron, M.Metal)
	signGui(sign, "Free Sanctuary")
	local tag = b:box(V(1, 1, 1), V(0, TAG_HEIGHT, -hd), C.Stone, M.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	tag.Name = "NameTag"
	nameGui(tag, plot.Id)
	-- path from the gate to the nest
	for i = 0, 6 do
		b:box(V(9 - (i % 2) * 1.5, 0.4, 5), V(((i % 2) - 0.5) * 1.2, 0.05, -hd + 6 + i * 6.4), C.Stone, M.Slate)
	end
	-- nest (centre) and the horseshoe of dragon perches around it
	local layout = WorldConfig.Sanctuary
	nest(b, layout.Nest)
	for i = 1, layout.PerchCount do
		perch(b, WorldConfig.perchLocal(i), i)
	end
	-- income shrine (front-right, beside the gate path)
	local shrineAt = layout.Shrine
	b:cyl(1.2, 10, shrineAt + V(0, 0.6, 0), C.StoneDark, M.Slate)
	b:box(V(4.6, 6, 4.6), shrineAt + V(0, 4.2, 0), C.StoneWarm, M.Limestone)
	b:box(V(5.6, 0.8, 5.6), shrineAt + V(0, 7.6, 0), C.Gold, M.Foil)
	local orb = b:ball(3.2, shrineAt + V(0, 9.8, 0), Color3.fromRGB(255, 214, 110), M.Neon, { CastShadow = false })
	orb.Name = "Shrine"
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 210, 120)
	pl.Range = 18
	pl.Brightness = 1.4
	pl.Parent = orb
	-- flower beds along the side walls
	local rng = Random.new(plot.Id * 31)
	for _, sx in { -1, 1 } do
		for i = 0, 5 do
			local p = V(sx * (hw - 6), 0.4, -hd + 14 + i * 14)
			b:box(V(4, 0.8, 9), p, C.Timber, M.Wood)
			for k = 0, 4 do
				local col = ({ Color3.fromRGB(214, 70, 90), Color3.fromRGB(240, 200, 80), Color3.fromRGB(150, 110, 220) })[rng:NextInteger(1, 3)]
				b:ball(1.1, p + V(rng:NextNumber(-1.2, 1.2), 0.9, -3.6 + k * 1.8), col, M.SmoothPlastic, { CanCollide = false, CastShadow = false })
			end
		end
	end
	return b.Model
end

-- Owner visuals: gate sign, floating name plate and banner colour (called by SanctuaryService).
function Sanctuaries.setOwner(model: Model, ownerName: string?, color: Color3?)
	local sign = model:FindFirstChild("Sign", true)
	local label = sign and sign:FindFirstChild("SignGui") and (sign :: any).SignGui:FindFirstChild("Text")
	if label then
		label.Text = ownerName and (ownerName .. "'s Sanctuary") or "Free Sanctuary"
	end
	local tag = model:FindFirstChild("NameTag", true)
	local pill = tag and tag:FindFirstChild("NameGui") and (tag :: any).NameGui:FindFirstChild("Pill")
	if pill then
		local accent = color and color:Lerp(Color3.new(1, 1, 1), 0.35) or TAG_FREE
		local ownerLabel = pill:FindFirstChild("OwnerLabel") :: TextLabel
		local plotLabel = pill:FindFirstChild("PlotLabel") :: TextLabel
		local stroke = pill:FindFirstChild("Stroke") :: UIStroke
		ownerLabel.Text = ownerName or "FREE"
		ownerLabel.TextColor3 = ownerName and Color3.new(1, 1, 1) or Color3.fromRGB(190, 198, 212)
		plotLabel.TextColor3 = accent
		stroke.Color = accent
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "BannerCloth" then
			d.Color = color or C.BannerBlue
		end
	end
end

return Sanctuaries

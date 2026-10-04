--[[
	EggController
	Shows the local player's personal world eggs (glowing shells with a light
	pillar visible from the air), animates them, and picks them up when the
	player walks or flies through them (server validates range + capacity).

	EGG GUARDIANS (EggConfig.Guardians): an egg that comes with a Guard lies in a NEST of twigs and stones and a
	dragon guards it. You cannot take it by flying through it: come close, press CHALLENGE (the button or the key X)
	and win the duel (DuelController.startGuardian). The nest is always built; the guardian's model is built only
	while you are near (ShowRange), it wakes up, turns to you and roars when you come closer (WakeRange), and its
	label tells how dangerous it is for YOUR dragon. When the duel is won the egg jumps into your hand and the
	guardian fades away. EggController.challenge(key) is the same as the button (tools and tests).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local DuelConfig = require(Configs:WaitForChild("DuelConfig"))
local EggReach = require(Shared:WaitForChild("EggReach"))
local DragonVisual = require(Shared:WaitForChild("Dragons"):WaitForChild("DragonVisual"))
local Animator = require(Shared:WaitForChild("Dragons"):WaitForChild("Animator"))
local Builder = require(Shared:WaitForChild("Dragons"):WaitForChild("Builder"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Kit = require(UI:WaitForChild("Kit"))

local C = Theme.Colors

local EggController = {}

local registry
local LocalPlayer = Players.LocalPlayer
local folder: Folder? = nil
local eggs: { [string]: any } = {} -- key -> { Key, Type, Position, Model, Pending, Guard?, Nest?, GuardDragon? }
local lastFullWarning = 0
local lastGuardHint = 0
local clock = 0

local MAX_GUARDIANS = 5 -- guardian models alive at the same time
local GUARD_KEY = Enum.KeyCode.X
local WOOD = Color3.fromRGB(112, 80, 50)
local WOOD_DARK = Color3.fromRGB(74, 52, 34)
local STRAW = Color3.fromRGB(214, 184, 118)

local function getFolder(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MyEggs"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

-- ============================================================== nest
local function nestPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

-- A nest of twigs and stones on the ground, a straw bed and a ring of light in the egg's colour.
local function buildNest(ground: Vector3, glow: Color3, seed: number): Model
	local rng = Random.new(seed)
	local nest = Instance.new("Model")
	nest.Name = "Nest"
	local turn = CFrame.Angles(0, 0, math.rad(90)) -- (a cylinder part lies along X: stand it up)
	nestPart(nest, "Bed", Vector3.new(0.9, 10, 10), CFrame.new(ground + Vector3.new(0, 0.45, 0)) * turn, STRAW, Enum.Material.Fabric, Enum.PartType.Cylinder)
	local ring = nestPart(nest, "Glow", Vector3.new(0.14, 7.4, 7.4), CFrame.new(ground + Vector3.new(0, 0.98, 0)) * turn, glow, Enum.Material.Neon, Enum.PartType.Cylinder)
	ring.Transparency = 0.55
	local function twigs(count: number, radius: number, y: number, length: number, thick: number, lean: number)
		for i = 1, count do
			local a = (i - 1) / count * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
			local pos = ground + Vector3.new(math.cos(a) * radius, y + rng:NextNumber(-0.1, 0.1), math.sin(a) * radius)
			-- a twig lies along the ring (its long side follows the tangent) and leans a little
			local cf = CFrame.new(pos) * CFrame.Angles(0, -a + rng:NextNumber(-0.2, 0.2), 0) * CFrame.Angles(rng:NextNumber(-lean, lean), 0, rng:NextNumber(-lean, lean))
			nestPart(nest, "Twig", Vector3.new(thick, thick, length), cf, WOOD:Lerp(WOOD_DARK, rng:NextNumber()), Enum.Material.Wood)
		end
	end
	twigs(12, 5.2, 1.0, 5.6, 0.8, 0.22)
	twigs(8, 4.5, 1.7, 5.0, 0.7, 0.3)
	for i = 1, 6 do
		local a = (i - 1) / 6 * math.pi * 2 + rng:NextNumber(-0.25, 0.25)
		local r = rng:NextNumber(6.6, 7.8)
		local size = rng:NextNumber(1.5, 2.6)
		nestPart(nest, "Stone", Vector3.new(size * 1.3, size, size * 1.1), CFrame.new(ground + Vector3.new(math.cos(a) * r, size * 0.35, math.sin(a) * r)) * CFrame.Angles(rng:NextNumber(0, 3), rng:NextNumber(0, 3), 0), Color3.fromRGB(122, 120, 116):Lerp(Color3.fromRGB(160, 156, 148), rng:NextNumber()), Enum.Material.Slate, Enum.PartType.Ball)
	end
	return nest
end

-- ============================================================== guardian model
local function seedOf(key: string): number
	local h = 17
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 100003
	end
	return h
end

-- Strength of a fighter (the way a duel counts it): hit points x damage.
local function strength(level: number, rank: number): number
	return DuelConfig.maxHP(level, rank) * DuelConfig.baseDamage(level, rank)
end

-- How dangerous the guardian is for your equipped dragon: threat row { Name, Color }, the guardian's level.
local function threatOf(guard)
	local cfg = EggConfig.Guardians
	local data = registry and registry.DataController and registry.DataController.all()
	local mine = data and data.Dragons and data.Dragons[data.EquippedDragon]
	local myLevel = mine and mine.Level or 1
	local myRank = mine and DragonConfig.rarityRank(mine.Rarity) or 1
	local species = DragonConfig.Species[guard.Species]
	local level = EggConfig.guardianLevel(guard, myLevel)
	local rank = species and DragonConfig.rarityRank(species.Rarity) or 1
	local soften = guard.Scale or 1
	local ratio = strength(level, rank) * soften * soften / math.max(1, strength(myLevel, myRank))
	for _, row in cfg.Threat do
		if ratio <= row.Max then
			return row, level
		end
	end
	return cfg.Threat[#cfg.Threat], level
end

local function guardianName(guard): string
	local species = DragonConfig.Species[guard.Species]
	local name = species and species.Name or guard.Species
	local mut = guard.Mutation ~= "None" and MutationConfig.Mutations[guard.Mutation]
	return (mut and (mut.Name .. " ") or "") .. name
end

local function setGuardLabel(e)
	local g = e.GuardDragon
	if not g or not g.Name1 then
		return
	end
	local threat, level = threatOf(e.Guard)
	g.Name1.Text = string.upper(guardianName(e.Guard))
	g.Name2.Text = string.format("GUARDIAN  Lv %d  -  %s", level, threat.Name)
	g.Name2.TextColor3 = threat.Color
end

-- The guardian dragon of an egg as a living model standing next to its nest. nil when it cannot be built.
local function buildGuardian(e)
	local guard = e.Guard
	local ok, result = pcall(function()
		local holder = Instance.new("Model")
		holder.Name = "Guardian_" .. e.Key
		local root = Builder.makeRoot(guard.Species, nil)
		root.Anchored = true
		local info = Builder.mountInfo(guard.Species, nil)
		local hip = info and info.HipHeight or 3
		-- next to the nest, on the ground (found with a ray), looking at the egg
		local a = seedOf(e.Key) / 100003 * math.pi * 2
		local ground = e.Position - Vector3.new(0, 2.6, 0)
		local spot = ground + Vector3.new(math.cos(a) * 9, 0, math.sin(a) * 9)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { getFolder() }
		local hit = Workspace:Raycast(spot + Vector3.new(0, 40, 0), Vector3.new(0, -90, 0), params)
		if hit and (hit.Instance == Workspace.Terrain or hit.Instance:GetAttribute("EggSurface") == true) and math.abs(hit.Position.Y - ground.Y) < 18 then
			spot = hit.Position
		end
		root.CFrame = CFrame.lookAt(spot + Vector3.new(0, hip, 0), Vector3.new(e.Position.X, spot.Y + hip, e.Position.Z))
		root.Parent = holder
		holder.PrimaryPart = root
		local visual = DragonVisual.build(guard.Species, { Root = root, Mutation = guard.Mutation, Detail = "Medium", Saddle = false })
		visual.Name = "Visual"
		-- a stronger guardian is a bigger one (about 9 studs wide for the weakest, 20 for the strongest)
		local size = visual:GetExtentsSize()
		local k = math.clamp((8 + guard.Power * 1.4) / math.max(size.X, size.Z, 1), 0.4, 2.6)
		if math.abs(k - 1) > 0.04 then
			pcall(function()
				visual:ScaleTo(visual:GetScale() * k)
			end)
		end
		root.CFrame = root.CFrame + Vector3.new(0, hip * (k - 1), 0)
		local fade = {}
		for _, d in visual:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				fade[d] = d.Transparency
			end
		end
		visual.Parent = holder
		-- the label above its head: name, level and how dangerous it is for your dragon
		local bb = Instance.new("BillboardGui")
		bb.Name = "GuardLabel"
		bb.Size = UDim2.fromScale(11, 3.4)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 10 + guard.Power * 1.2, 0)
		bb.MaxDistance = 210
		bb.LightInfluence = 0
		bb.Adornee = root
		bb.Parent = root
		local rarity = DragonConfig.Species[guard.Species] and DragonConfig.Rarities[DragonConfig.Species[guard.Species].Rarity]
		local name1 = Instance.new("TextLabel")
		name1.Name = "Name"
		name1.BackgroundTransparency = 1
		name1.Size = UDim2.fromScale(1, 0.56)
		name1.Font = Enum.Font.GothamBlack
		name1.TextScaled = true
		name1.TextColor3 = rarity and rarity.Color or Color3.new(1, 1, 1)
		name1.TextStrokeTransparency = 0.2
		name1.Parent = bb
		local name2 = Instance.new("TextLabel")
		name2.Name = "Danger"
		name2.BackgroundTransparency = 1
		name2.Position = UDim2.fromScale(0, 0.58)
		name2.Size = UDim2.fromScale(1, 0.4)
		name2.Font = Enum.Font.GothamBold
		name2.TextScaled = true
		name2.TextColor3 = Color3.new(1, 1, 1)
		name2.TextStrokeTransparency = 0.3
		name2.Parent = bb
		holder.Parent = getFolder()
		local anim = Animator.new(visual)
		anim:Snap("Idle")
		return { Model = holder, Root = root, Visual = visual, Anim = anim, Fade = fade, Pos = root.Position, Look = (root.CFrame.LookVector * Vector3.new(1, 0, 1)).Unit, Awake = false, Name1 = name1, Name2 = name2 }
	end)
	if ok then
		return result
	end
	warn("[Eggs] guardian failed: " .. tostring(result))
	return nil
end

-- Drops the guardian's model (it is built again when you come back). A beaten guardian fades away instead.
local function destroyGuardian(e, dissolve: boolean?)
	local g = e.GuardDragon
	e.GuardDragon = nil
	if not g then
		return
	end
	local model = g.Model
	if dissolve and model and model.Parent then
		for part in g.Fade do
			if part.Parent then
				TweenService:Create(part, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1 }):Play()
			end
		end
		for _, d in model:GetDescendants() do
			if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Light") then
				(d :: any).Enabled = false
			elseif d:IsA("BillboardGui") then
				d.Enabled = false
			end
		end
		task.delay(1, function()
			model:Destroy()
		end)
	elseif model then
		model:Destroy()
	end
end

-- ============================================================== eggs
local function removeEgg(key: string, collected: boolean)
	local e = eggs[key]
	if not e then
		return
	end
	eggs[key] = nil
	destroyGuardian(e, collected)
	if e.Nest then
		e.Nest:Destroy()
	end
	local model = e.Model
	if not model then
		return
	end
	if collected then
		-- collect burst: shell pops, glow flashes outward, then fades
		local shell = model.PrimaryPart
		local def = EggConfig.Eggs[e.Type] or EggConfig.Eggs.HavenEgg
		local burst = Instance.new("Part")
		burst.Anchored = true
		burst.CanCollide = false
		burst.CanQuery = false
		burst.CanTouch = false
		burst.Shape = Enum.PartType.Ball
		burst.Material = Enum.Material.Neon
		burst.Color = def.Glow
		burst.Size = Vector3.new(2, 2, 2)
		burst.CFrame = shell and shell.CFrame or CFrame.new(e.Position)
		burst.Transparency = 0.2
		burst.CastShadow = false
		burst.Parent = getFolder()
		TweenService:Create(burst, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(14, 14, 14),
			Transparency = 1,
		}):Play()
		task.delay(0.5, function()
			burst:Destroy()
		end)
		local audio = registry.AudioController
		if audio and shell then
			audio.play3D("EggPickup", shell, 0.05)
		end
	end
	model:Destroy()
end

local function addEgg(info)
	if type(info) ~= "table" or type(info.Key) ~= "string" then
		return
	end
	removeEgg(info.Key, false)
	local luck = math.max(1, tonumber(info.Luck) or 1)
	local model = EggVisual.build(info.Type, { Beam = true, Scale = luck >= 50 and 1.25 or (luck >= 10 and 1.12 or 1) })
	model.Name = "Egg_" .. info.Key
	EggVisual.place(model, CFrame.new(info.Position))
	local shell = model.PrimaryPart
	local def = EggConfig.Eggs[info.Type] or EggConfig.Eggs.HavenEgg
	-- floating label: egg name + its luck (big, coloured by how lucky)
	if shell then
		local bb = Instance.new("BillboardGui")
		bb.Name = "LuckLabel"
		bb.Size = UDim2.fromScale(9, 3.2)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 4.6, 0)
		bb.MaxDistance = 220
		bb.LightInfluence = 0
		bb.AlwaysOnTop = luck >= 25
		bb.Parent = shell
		local luckText = Instance.new("TextLabel")
		luckText.Name = "Luck"
		luckText.BackgroundTransparency = 1
		luckText.Size = UDim2.fromScale(1, 0.6)
		luckText.Font = Enum.Font.GothamBlack
		luckText.TextScaled = true
		luckText.Text = "x" .. tostring(luck) .. " LUCK"
		luckText.TextColor3 = EggConfig.luckColor(luck)
		luckText.TextStrokeTransparency = 0.25
		luckText.Parent = bb
		local nameText = Instance.new("TextLabel")
		nameText.Name = "EggName"
		nameText.BackgroundTransparency = 1
		nameText.Position = UDim2.fromScale(0, 0.62)
		nameText.Size = UDim2.fromScale(1, 0.36)
		nameText.Font = Enum.Font.GothamBold
		nameText.TextScaled = true
		nameText.Text = string.upper(def.Name)
		nameText.TextColor3 = def.Glow
		nameText.TextStrokeTransparency = 0.35
		nameText.Parent = bb
		if luck >= 10 then
			-- lucky eggs sparkle in their luck colour (rainbow from x100)
			local pe = Instance.new("ParticleEmitter")
			pe.Name = "LuckSparkles"
			pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			pe.Color = luck >= 100 and ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
				ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 220, 60)),
				ColorSequenceKeypoint.new(0.66, Color3.fromRGB(90, 220, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 120, 255)),
			}) or ColorSequence.new(EggConfig.luckColor(luck))
			pe.LightEmission = 1
			pe.Rate = luck >= 100 and 26 or 12
			pe.Lifetime = NumberRange.new(0.8, 1.6)
			pe.Speed = NumberRange.new(1, 3)
			pe.SpreadAngle = Vector2.new(180, 180)
			pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 0.6), NumberSequenceKeypoint.new(1, 0) })
			pe.Parent = shell
		end
	end
	model.Parent = getFolder()
	local guard = type(info.Guard) == "table" and info.Guard or nil
	local nest = nil
	if guard then
		-- the egg rests in a nest (the egg's spot is 2.6 studs above the ground)
		nest = buildNest(info.Position - Vector3.new(0, 2.6, 0), def.Glow, seedOf(info.Key))
		nest.Name = "Nest_" .. info.Key
		nest.Parent = getFolder()
	end
	eggs[info.Key] = {
		Key = info.Key,
		Type = info.Type,
		Luck = luck,
		Position = info.Position,
		Model = model,
		Phase = math.random() * math.pi * 2,
		Pending = false,
		Guard = guard,
		Nest = nest,
	}
end

local function myPositions(): ({ Vector3 }, number)
	local out = {}
	local slack = 0
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		table.insert(out, hrp.Position)
	end
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. LocalPlayer.UserId)
	local root = model and model:FindFirstChild("Root") :: BasePart?
	if root then
		-- your dragon picks eggs up too (ridden or flying around you)
		table.insert(out, root.Position)
		slack = ((model :: Model):GetAttribute("BodyRadius") or 0) * 0.5
		if (model :: Model):GetAttribute("RiderUserId") == LocalPlayer.UserId then
			slack += 6 -- swooping over an egg while riding is enough
		end
	end
	return out, slack
end

local function distanceTo(positions: { Vector3 }, target: Vector3): (number, Vector3?)
	local best, at = math.huge, nil
	for _, p in positions do
		local d = (p - target).Magnitude
		if d < best then
			best, at = d, p
		end
	end
	return best, at
end

local function tryPickup(e)
	e.Pending = true
	task.spawn(function()
		local res = Net.request("Egg", "Pickup", { Key = e.Key })
		if res.ok then
			removeEgg(e.Key, true)
			local uic = registry.UIController
			local def = EggConfig.Eggs[res.data.Type]
			-- the egg jumps into your hand (or into the bag when your hand is full)
			local held = registry.HeldEggController
			if held and res.data.Held then
				held.flyIn(res.data.Type, e.Position)
			end
			local reactLuck = tonumber(res.data.Luck) or 1
			if registry.AnimationController then
				registry.AnimationController.react(reactLuck >= 25 and "Rare" or "Egg", math.clamp(reactLuck / 100, 0, 1))
			end
			if uic then
				local luck = tonumber(res.data.Luck) or 1
				local where = res.data.Held and "  -  in your hand" or "  -  in your bag"
				uic.Notify(luck >= 25 and "rare" or "success", "+1 " .. (def and def.Name or "Egg") .. (luck > 1 and ("  (x" .. tostring(luck) .. " LUCK)") or "") .. where)
			end
		else
			e.Pending = false
			if res.err == "EGG_STORAGE_FULL" then
				e.CooldownUntil = clock + 3
				EggController.BagFullAt = clock
				if clock - lastFullWarning > 6 then
					lastFullWarning = clock
					local uic = registry.UIController
					if uic then
						uic.Notify("warning", res.msg or "Your egg bag is full!")
					end
				end
			elseif res.err == "GONE" then
				removeEgg(e.Key, false)
			elseif res.err == "GUARDED" then
				e.CooldownUntil = clock + 30 -- (it is won with a duel, not by walking into it)
			else
				e.CooldownUntil = clock + 1
			end
		end
	end)
end

-- ============================================================== challenge (the button, key X)
local prompt: any = nil -- { Panel, Title, Sub, Button, Key }
local challenging = false
local previewing = false -- UI Lab: the button shows sample text and stays

-- Challenges the guardian of the egg `key`; returns ok, message.
function EggController.challenge(key: string): (boolean, string?)
	local e = eggs[key]
	if not e or not e.Guard then
		return false, "Nobody guards that egg."
	end
	local duel = registry and registry.DuelController
	if not duel or not duel.startGuardian then
		return false, "Duels are not ready."
	end
	if challenging then
		return false, "Wait a moment..."
	end
	challenging = true
	local ok, msg = duel.startGuardian(key)
	challenging = false
	if not ok then
		local uic = registry.UIController
		if uic and msg then
			uic.Notify("warning", msg)
		end
	end
	return ok, msg
end

local function layoutPrompt()
	if not prompt then
		return
	end
	local R = Responsive
	local panel = prompt.Panel
	if R.Device == "Phone" then
		panel.Position = UDim2.fromScale(0.5, R.Portrait and 0.8 or 0.74)
		panel.Size = UDim2.fromScale(R.Portrait and 0.9 or 0.46, R.Portrait and 0.15 or 0.3)
	else
		panel.Position = UDim2.fromScale(0.5, 0.8)
		panel.Size = UDim2.fromScale(R.Device == "Tablet" and 0.4 or 0.3, R.Device == "Tablet" and 0.15 or 0.16)
	end
end

local function getPrompt()
	if prompt and prompt.Panel.Parent then
		return prompt
	end
	local uic = registry and registry.UIController
	local layer = uic and uic.Layers and (uic.Layers.GameHUD or uic.Layers.GameUI)
	if not layer then
		return nil
	end
	local panel = Kit.surface({
		Name = "GuardianPrompt",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.8),
		Size = UDim2.fromScale(0.3, 0.16),
		Color = C.Panel,
		Transparency = 0.05,
		StrokeColor = Color3.fromRGB(255, 120, 90),
		StrokeTransparency = 0.1,
		Radius = "Window",
		Parent = layer.Root,
	})
	panel.ZIndex = 30
	panel.Visible = false
	local title = Kit.text({ Name = "Title", Text = "", Role = "Heading", Scaled = true, MinTextSize = 9, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.06), Size = UDim2.fromScale(0.92, 0.3), Truncate = true, Parent = panel })
	local sub = Kit.text({ Name = "Sub", Text = "", Role = "Micro", Scaled = true, MinTextSize = 8, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.04, 0.37), Size = UDim2.fromScale(0.92, 0.22), Truncate = true, Parent = panel })
	local button = Kit.button({ Name = "Challenge", Text = "CHALLENGE  [X]", Style = "Danger", Position = UDim2.fromScale(0.18, 0.64), Size = UDim2.fromScale(0.64, 0.3), Parent = panel })
	prompt = { Panel = panel, Title = title, Sub = sub, Button = button, Key = nil }
	button.Activated:Connect(function()
		local key = prompt and prompt.Key
		if key then
			task.spawn(EggController.challenge, key)
		end
	end)
	layoutPrompt()
	Responsive.Changed:Connect(layoutPrompt)
	return prompt
end

local function showPrompt(e)
	local p = getPrompt()
	if not p then
		return
	end
	if not e then
		p.Panel.Visible = false
		p.Key = nil
		return
	end
	if p.Key ~= e.Key then
		p.Key = e.Key
		local threat, level = threatOf(e.Guard)
		local def = EggConfig.Eggs[e.Type]
		p.Title.Text = string.format("%s  -  Lv %d", string.upper(guardianName(e.Guard)), level)
		p.Sub.Text = string.format("guards a %s x%d  -  DANGER: %s", def and def.Name or "egg", e.Luck, threat.Name)
		p.Sub.TextColor3 = threat.Color
	end
	p.Panel.Visible = true
end

-- ============================================================== per frame
local function lookAtYou(g, dt: number, target: Vector3)
	local flat = Vector3.new(target.X - g.Pos.X, 0, target.Z - g.Pos.Z)
	if flat.Magnitude > 0.5 then
		g.Look = g.Look:Lerp(flat.Unit, math.min(1, dt * 2.4))
		if g.Look.Magnitude < 0.05 then
			g.Look = flat.Unit
		end
	end
	g.Root.CFrame = CFrame.lookAt(g.Pos, g.Pos + g.Look.Unit)
end

local function step(dt: number)
	clock += dt
	local positions, slack = myPositions()
	-- Great Tree "Egg Magnet", the Egg Magnet potion and the Egg Hunter pass widen the pickup range
	local data = registry.DataController.all()
	local now = Workspace:GetServerTimeNow()
	local range = EggReach.range(data, GameConfig.Interaction.EggPickupRange, now) + slack
	local cfg = EggConfig.Guardians
	local promptRange = EggReach.range(data, cfg.PromptRange, now) + slack
	local nearest, nearestD = nil, math.huge
	local builtNow = false
	local alive = 0
	for _, e in eggs do
		if e.GuardDragon then
			alive += 1
		end
	end
	for _, e in eggs do
		local model = e.Model
		if model and model.Parent then
			-- bob + spin (an egg in a nest only rocks a little)
			local t = clock + e.Phase
			local bob = e.Guard and 0.12 or 0.35
			EggVisual.place(model, CFrame.new(e.Position + Vector3.new(0, math.sin(t * 2) * bob, 0)) * CFrame.Angles(0, t * 0.8, math.sin(t * 1.3) * 0.08))
		end
		if e.Guard then
			-- the guardian: built while you are near, awake and turned to you when you come closer
			local d, at = distanceTo(positions, e.Position)
			if d <= cfg.ShowRange and not e.GuardDragon and not e.GuardFailed and not builtNow and alive < MAX_GUARDIANS then
				builtNow = true
				alive += 1
				e.GuardDragon = buildGuardian(e)
				if e.GuardDragon then
					setGuardLabel(e)
					e.NextLabel = clock + 2
				else
					e.GuardFailed = true
				end
			elseif d > cfg.ShowRange * 1.35 and e.GuardDragon then
				destroyGuardian(e)
			end
			local g = e.GuardDragon
			if g and g.Root.Parent then
				local awake = d <= cfg.WakeRange
				if awake and not g.Awake then
					g.Awake = true
					g.Anim:Play("Roar")
					local audio = registry.AudioController
					if audio and audio.play3D then
						audio.play3D("Roar", g.Root, 0.05)
					end
				elseif g.Awake and d > cfg.WakeRange * 1.25 then
					g.Awake = false
				end
				lookAtYou(g, dt, awake and at or e.Position)
				if d <= cfg.ShowRange * 0.6 then
					g.Anim:SetParams({ Mode = "Ground", Speed = 0, Look = Vector2.zero })
					g.Anim:Update(dt)
					g.Anim:Apply(true)
				end
				if e.NextLabel and clock >= e.NextLabel then
					e.NextLabel = clock + 2
					setGuardLabel(e)
				end
			end
			if d <= promptRange and d < nearestD then
				nearest, nearestD = e, d
			end
			-- flying through a guarded egg: tell the player what to do (once in a while)
			if d <= range and clock - lastGuardHint > 12 and not e.Pending then
				lastGuardHint = clock
				local uic = registry.UIController
				if uic then
					uic.Notify("info", "A dragon guards this egg! Press X (or CHALLENGE) and beat it in a duel.")
				end
			end
		elseif not e.Pending and (not e.CooldownUntil or clock > e.CooldownUntil) then
			for _, p in positions do
				if (p - e.Position).Magnitude <= range then
					tryPickup(e)
					break
				end
			end
		end
	end
	-- the CHALLENGE button of the nearest guarded egg
	local duel = registry.DuelController
	if duel and duel.active() then
		nearest = nil
	end
	if not previewing and (nearest or prompt) then
		showPrompt(nearest)
	end
end

-- Nearest egg the companion should fly to and pick up (nil when the bag is
-- full or nothing is close to the player). Guarded eggs are not for the companion.
EggController.BagFullAt = -100
function EggController.fetchTarget(center: Vector3, range: number): Vector3?
	if clock - EggController.BagFullAt < 12 then
		return nil
	end
	local best, bestD = nil, range
	for _, e in eggs do
		if not e.Guard and not e.Pending and (not e.CooldownUntil or clock > e.CooldownUntil) then
			local d = (e.Position - center).Magnitude
			if d < bestD then
				best, bestD = e.Position, d
			end
		end
	end
	return best
end

function EggController.count(): number
	local n = 0
	for _ in eggs do
		n += 1
	end
	return n
end

function EggController.list()
	return eggs
end

-- The key of the egg whose CHALLENGE button is showing (nil = none) - for tools and tests.
function EggController.promptKey(): string?
	return prompt and prompt.Panel.Visible and prompt.Key or nil
end

-- UI Lab: the CHALLENGE button with sample text (no egg needed).
function EggController.preview(on: boolean)
	previewing = on
	local p = getPrompt()
	if not p then
		return
	end
	if on then
		local hard = EggConfig.Guardians.Threat[3]
		p.Key = "preview"
		p.Title.Text = "SHINY FROST DRAGON  -  Lv 18"
		p.Sub.Text = "guards a Frost Egg x10  -  DANGER: " .. hard.Name
		p.Sub.TextColor3 = hard.Color
		p.Panel.Visible = true
	else
		p.Key = nil
		p.Panel.Visible = false
	end
end

function EggController.Init(reg)
	registry = reg
end

-- The guardian was beaten (the server took the egg): once the duel scene is over, the egg bursts, jumps into
-- your hand and the guardian fades away.
local function onCollected(payload)
	local key = payload.Key
	task.spawn(function()
		local duel = registry.DuelController
		local waited = 0
		while duel and duel.active() and waited < 180 do
			waited += task.wait(0.25)
		end
		local e = eggs[key]
		local position = e and e.Position
		removeEgg(key, true)
		local def = EggConfig.Eggs[payload.Type]
		local held = registry.HeldEggController
		if held and payload.Held and position then
			held.flyIn(payload.Type, position)
		end
		local luck = tonumber(payload.Luck) or 1
		if registry.AnimationController then
			registry.AnimationController.react(luck >= 25 and "Rare" or "Egg", math.clamp(luck / 100, 0, 1))
		end
		local uic = registry.UIController
		if uic then
			local where = payload.Held and "  -  in your hand" or "  -  in your bag"
			uic.Notify(luck >= 25 and "rare" or "success", "+1 " .. (def and def.Name or "Egg") .. (luck > 1 and ("  (x" .. tostring(luck) .. " LUCK)") or "") .. where)
		end
	end)
end

function EggController.Start()
	Net.onSignal("Eggs", function(payload)
		for key in table.clone(eggs) do
			removeEgg(key, false)
		end
		for _, info in payload and payload.List or {} do
			addEgg(info)
		end
	end)
	Net.onSignal("EggAdded", addEgg)
	Net.onSignal("EggRemoved", function(payload)
		if payload and payload.Key then
			if payload.Collected then
				onCollected(payload)
			else
				removeEgg(payload.Key, false)
			end
		end
	end)
	RunService.Heartbeat:Connect(step)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= GUARD_KEY then
			return
		end
		local key = prompt and prompt.Panel.Visible and prompt.Key
		if key then
			task.spawn(EggController.challenge, key)
		end
	end)
	-- resync once in case the initial list arrived before this controller started
	task.delay(4, function()
		if EggController.count() == 0 then
			local res = Net.request("Egg", "Sync", {})
			if res.ok and res.data then
				for _, info in res.data.List or {} do
					addEgg(info)
				end
			end
		end
	end)
end

return EggController

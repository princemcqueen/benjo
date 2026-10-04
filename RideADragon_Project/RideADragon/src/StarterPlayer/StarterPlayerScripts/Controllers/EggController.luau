--[[
	EggController
	Shows the local player's personal world eggs (glowing shells with a light
	pillar visible from the air), animates them, and picks them up when the
	player walks or flies through them (server validates range + capacity).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))

local EggController = {}

local registry
local LocalPlayer = Players.LocalPlayer
local folder: Folder? = nil
local eggs: { [string]: any } = {} -- key -> { Key, Type, Position, Model, Pending }
local lastFullWarning = 0
local clock = 0

local function getFolder(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MyEggs"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

local function removeEgg(key: string, collected: boolean)
	local e = eggs[key]
	if not e then
		return
	end
	eggs[key] = nil
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
	eggs[info.Key] = {
		Key = info.Key,
		Type = info.Type,
		Luck = luck,
		Position = info.Position,
		Model = model,
		Phase = math.random() * math.pi * 2,
		Pending = false,
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

local function tryPickup(e)
	e.Pending = true
	task.spawn(function()
		local res = Net.request("Egg", "Pickup", { Key = e.Key })
		if res.ok then
			removeEgg(e.Key, true)
			local uic = registry.UIController
			local def = EggConfig.Eggs[res.data.Type]
			if uic then
				local luck = tonumber(res.data.Luck) or 1
				uic.Notify(luck >= 25 and "rare" or "success", "+1 " .. (def and def.Name or "Egg") .. (luck > 1 and ("  (x" .. tostring(luck) .. " LUCK)") or ""))
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
			else
				e.CooldownUntil = clock + 1
			end
		end
	end)
end

local function step(dt: number)
	clock += dt
	local positions, slack = myPositions()
	local range = GameConfig.Interaction.EggPickupRange + slack
	for _, e in eggs do
		local model = e.Model
		if model and model.Parent then
			-- bob + spin
			local t = clock + e.Phase
			EggVisual.place(model, CFrame.new(e.Position + Vector3.new(0, math.sin(t * 2) * 0.35, 0)) * CFrame.Angles(0, t * 0.8, math.sin(t * 1.3) * 0.08))
		end
		if not e.Pending and (not e.CooldownUntil or clock > e.CooldownUntil) then
			for _, p in positions do
				if (p - e.Position).Magnitude <= range then
					tryPickup(e)
					break
				end
			end
		end
	end
end

-- Nearest egg the companion should fly to and pick up (nil when the bag is
-- full or nothing is close to the player).
EggController.BagFullAt = -100
function EggController.fetchTarget(center: Vector3, range: number): Vector3?
	if clock - EggController.BagFullAt < 12 then
		return nil
	end
	local best, bestD = nil, range
	for _, e in eggs do
		if not e.Pending and (not e.CooldownUntil or clock > e.CooldownUntil) then
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

function EggController.Init(reg)
	registry = reg
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
			removeEgg(payload.Key, false)
		end
	end)
	RunService.Heartbeat:Connect(step)
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

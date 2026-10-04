--[[
	BreathFX
	Fire breath visuals for a dragon model (everybody sees them: BondController
	starts/stops them from the model's "Breathing" attribute, the owner starts
	them instantly on key press).

	The flames shoot out of the model's "Mouth" attachment (made by BrickBuilder
	on the jaw): a bright core, sparks, a smoke trail and a flickering light. The
	colours follow the dragon's mutation (frost breath, toxic breath, hellfire,
	lightning, holy light, rainbow...), see THEMES.

	The breath has a wind-up that matches the Animator's FireBreath (the dragon inhales for
	~0.2 s): a glowing ball gathers at the mouth, then it pops and the flames burst out.

	BreathFX.start(model, scale?) / BreathFX.stop(model) / BreathFX.isOn(model)
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BreathFX = {}

local TEX = {
	Fire = "rbxasset://textures/particles/fire_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
}

local WINDUP = 0.2 -- seconds of inhaling before the flames come out

local active: { [Model]: { Folder: Instance, Light: PointLight?, Conn: RBXScriptConnection? } } = {}

-- Breath colours: Flame = core / middle / edge, Sparks = from / to, Smoke, Light.
local C3 = Color3.fromRGB
local function theme(core, mid, edge, spark1, spark2, smoke, light)
	return { Core = core, Mid = mid, Edge = edge, Spark1 = spark1, Spark2 = spark2, Smoke = smoke, Light = light }
end
local FIRE = theme(C3(255, 244, 190), C3(255, 170, 50), C3(220, 50, 20), C3(255, 220, 120), C3(255, 120, 40), C3(70, 56, 52), C3(255, 150, 60))
local HELL = theme(C3(255, 230, 160), C3(255, 100, 20), C3(140, 10, 10), C3(255, 190, 80), C3(255, 60, 20), C3(36, 18, 18), C3(255, 90, 30))
local ICE = theme(C3(240, 252, 255), C3(140, 210, 255), C3(60, 120, 230), C3(210, 240, 255), C3(120, 190, 255), C3(190, 210, 230), C3(150, 210, 255))
local VENOM = theme(C3(235, 255, 175), C3(130, 255, 60), C3(40, 140, 30), C3(200, 255, 120), C3(90, 220, 40), C3(40, 90, 30), C3(140, 255, 70))
local DARK = theme(C3(240, 205, 255), C3(150, 60, 255), C3(50, 10, 110), C3(220, 160, 255), C3(110, 40, 200), C3(28, 10, 48), C3(170, 90, 255))
local NEON = theme(C3(255, 255, 255), C3(80, 255, 230), C3(255, 70, 210), C3(150, 255, 240), C3(255, 110, 225), C3(70, 40, 110), C3(100, 255, 230))
local BOLT = theme(C3(255, 255, 255), C3(255, 240, 90), C3(90, 140, 255), C3(255, 250, 170), C3(130, 190, 255), C3(70, 80, 120), C3(255, 240, 120))
local HOLY = theme(C3(255, 255, 255), C3(255, 232, 150), C3(255, 190, 60), C3(255, 250, 215), C3(255, 215, 110), C3(235, 235, 245), C3(255, 235, 170))
local PRISM = theme(C3(255, 255, 255), C3(200, 160, 255), C3(110, 255, 225), C3(235, 215, 255), C3(140, 255, 235), C3(150, 130, 190), C3(200, 170, 255))
local RAINBOW = theme(C3(255, 255, 255), C3(255, 120, 200), C3(80, 200, 255), C3(255, 235, 140), C3(180, 120, 255), C3(110, 90, 140), C3(255, 170, 230))
BreathFX.Themes = {
	None = FIRE, Shiny = HOLY, Neon = NEON, Golden = HOLY, Frost = ICE, Toxic = VENOM, Lava = HELL, Infernal = HELL,
	Shadow = DARK, Corrupted = DARK, Diamond = PRISM, Crystal = PRISM, Lightning = BOLT, Angelic = HOLY,
	Galaxy = DARK, Rainbow = RAINBOW, Void = DARK, Omni = RAINBOW,
}

local function seq(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

local function mouthOf(model: Model): Instance?
	local visual = model:FindFirstChild("Visual")
	return visual and visual:FindFirstChild("Mouth", true) or model:FindFirstChild("Mouth", true)
end

function BreathFX.isOn(model: Model): boolean
	return active[model] ~= nil
end

function BreathFX.start(model: Model, scale: number?)
	if active[model] then
		return
	end
	local mouth = mouthOf(model)
	if not mouth then
		return
	end
	local S = scale or model:GetAttribute("Scale") or 1
	local th = BreathFX.Themes[model:GetAttribute("Mutation") or "None"] or FIRE
	local folder = Instance.new("Folder")
	folder.Name = "BreathFX"
	folder.Parent = mouth

	local function emitter(name: string, props: { [string]: any })
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Enabled = false -- switched on when the wind-up is over
		e.EmissionDirection = Enum.NormalId.Front
		e.LightInfluence = 0
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-90, 90)
		for k, v in props do
			(e :: any)[k] = v
		end
		e.Parent = folder
		CollectionService:AddTag(e, "FX")
		return e
	end

	emitter("Flame", {
		Texture = TEX.Fire,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, th.Core),
			ColorSequenceKeypoint.new(0.35, th.Mid),
			ColorSequenceKeypoint.new(1, th.Edge),
		}),
		LightEmission = 1,
		Rate = 110,
		Lifetime = NumberRange.new(0.5, 0.8),
		Speed = NumberRange.new(55 * S, 75 * S),
		SpreadAngle = Vector2.new(9, 9),
		Acceleration = Vector3.new(0, 5, 0),
		Size = seq({ { 0, 1.4 * S }, { 0.5, 4.5 * S }, { 1, 7.5 * S } }),
		Transparency = seq({ { 0, 0.1 }, { 0.7, 0.35 }, { 1, 1 } }),
	})
	emitter("Sparks", {
		Texture = TEX.Sparkle,
		Color = ColorSequence.new(th.Spark1, th.Spark2),
		LightEmission = 1,
		Rate = 45,
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(70 * S, 100 * S),
		SpreadAngle = Vector2.new(16, 16),
		Acceleration = Vector3.new(0, -14, 0),
		Size = seq({ { 0, 0.9 * S }, { 1, 0 } }),
	})
	emitter("Smoke", {
		Texture = TEX.Smoke,
		Color = ColorSequence.new(th.Smoke),
		LightEmission = 0,
		Rate = 22,
		Lifetime = NumberRange.new(1.0, 1.6),
		Speed = NumberRange.new(30 * S, 45 * S),
		SpreadAngle = Vector2.new(14, 14),
		Acceleration = Vector3.new(0, 7, 0),
		Size = seq({ { 0, 2 * S }, { 1, 7 * S } }),
		Transparency = seq({ { 0, 0.5 }, { 1, 1 } }),
	})

	local light = Instance.new("PointLight")
	light.Name = "BreathLight"
	light.Color = th.Light
	light.Range = 26 * math.max(1, S * 0.6)
	light.Brightness = 2.2
	light.Shadows = false
	local host = mouth.Parent
	light.Parent = host and host:IsA("BasePart") and host or folder.Parent
	light.Enabled = false
	local entry = { Folder = folder, Light = light, Conn = nil }
	entry.Conn = RunService.Heartbeat:Connect(function()
		if light.Parent then
			light.Brightness = 2 + math.sin(os.clock() * 37) * 0.6 + math.random() * 0.4
		end
	end)
	active[model] = entry
	-- wind-up: a glowing ball gathers at the mouth (follows the jaw), then the flames burst out
	local ball: Part? = nil
	if host and host:IsA("BasePart") and mouth:IsA("Attachment") then
		ball = Instance.new("Part")
		local b = ball :: Part
		b.Name = "BreathCharge"
		b.Shape = Enum.PartType.Ball
		b.Material = Enum.Material.Neon
		b.Color = th.Core
		b.Size = Vector3.one * 0.3 * S
		b.Transparency = 0.15
		b.CanCollide = false
		b.CanQuery = false
		b.CanTouch = false
		b.CastShadow = false
		b.Massless = true
		b.CFrame = CFrame.new(mouth.WorldPosition)
		b.Parent = folder
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = host
		weld.Part1 = b
		weld.Parent = b
		TweenService:Create(b, TweenInfo.new(WINDUP, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = Vector3.one * 3.2 * S,
			Transparency = 0.35,
		}):Play()
		light.Enabled = true
		light.Brightness = 3
	end
	task.delay(WINDUP, function()
		if active[model] ~= entry then
			if ball then
				ball:Destroy()
			end
			return
		end
		light.Enabled = true
		for _, d in folder:GetChildren() do
			if d:IsA("ParticleEmitter") then
				d.Enabled = true
				if d.Name == "Flame" then
					d:Emit(16)
				end
			end
		end
		if ball then
			local b = ball :: Part
			local pop = TweenService:Create(b, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.one * 6 * S,
				Transparency = 1,
			})
			pop:Play()
			task.delay(0.25, function()
				b:Destroy()
			end)
		end
	end)
	model.AncestryChanged:Once(function(_, parent)
		if parent == nil then
			BreathFX.stop(model)
		end
	end)
end

function BreathFX.stop(model: Model)
	local entry = active[model]
	if not entry then
		return
	end
	active[model] = nil
	if entry.Conn then
		entry.Conn:Disconnect()
	end
	for _, d in entry.Folder:GetChildren() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
		end
	end
	if entry.Light then
		entry.Light:Destroy()
	end
	task.delay(1.8, function()
		entry.Folder:Destroy()
	end)
end

return BreathFX

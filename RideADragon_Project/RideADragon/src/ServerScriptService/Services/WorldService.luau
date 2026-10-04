--[[
	WorldService
	Builds the world at server start from code (deterministic, seeded), so the
	whole map lives in source control. Each region module exposes
	build(context) and returns its spawn/landmark data.

	Also owns the lighting/post-processing stack (GraphicsController toggles
	the effects per quality preset on each client).

	Developer: in Studio's command bar you can bake the current world into
	the place (run the server once, then copy Workspace.World from the
	server view) if you prefer editing it by hand.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local WorldService = {}
WorldService.Spawn = CFrame.new(0, 8, 0)
WorldService.Landmarks = {}
WorldService.Ready = false

local function ensure(className: string, name: string, parent: Instance, props: { [string]: any })
	local inst = parent:FindFirstChild(name)
	if not inst then
		inst = Instance.new(className)
		inst.Name = name
		inst.Parent = parent
	end
	for k, v in props do
		(inst :: any)[k] = v
	end
	return inst
end

-- Premium-but-readable daylight: warm sun, soft blue ambient, light haze.
local function setupLighting()
	-- short grass: the tall default hides characters' legs and small eggs
	pcall(function()
		(Workspace.Terrain :: any).GrassLength = 0.35
	end)
	Lighting.Ambient = Color3.fromRGB(70, 74, 88)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 132, 146)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 242, 222)
	Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
	Lighting.ShadowSoftness = 0.25
	Lighting.ExposureCompensation = 0.1
	ensure("Atmosphere", "Atmosphere", Lighting, {
		Density = 0.32,
		Offset = 0.22,
		Color = Color3.fromRGB(199, 214, 232),
		Decay = Color3.fromRGB(106, 112, 125),
		Glare = 0.25,
		Haze = 1.35,
	})
	ensure("Sky", "Sky", Lighting, {
		SunAngularSize = 14,
		MoonAngularSize = 9,
		StarCount = 2500,
		CelestialBodiesShown = true,
	})
	ensure("BloomEffect", "Bloom", Lighting, { Intensity = 0.55, Size = 28, Threshold = 1.15 })
	ensure("SunRaysEffect", "SunRays", Lighting, { Intensity = 0.045, Spread = 0.72 })
	ensure("ColorCorrectionEffect", "Grade", Lighting, {
		Brightness = 0.02,
		Contrast = 0.08,
		Saturation = 0.12,
		TintColor = Color3.fromRGB(255, 250, 244),
	})
	ensure("DepthOfFieldEffect", "DepthOfField", Lighting, {
		FarIntensity = 0.12,
		FocusDistance = 260,
		InFocusRadius = 240,
		NearIntensity = 0,
		Enabled = true,
	})
end

-- Characters spawn only once the world exists (never into the void).
local function spawnLoop(player: Player)
	while not WorldService.Ready and player.Parent == Players do
		task.wait(0.1)
	end
	if player.Parent == Players and not player.Character then
		player:LoadCharacter()
	end
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			humanoid.Died:Connect(function()
				task.delay(Players.RespawnTime, function()
					if player.Parent == Players and player.Character == character then
						player:LoadCharacter()
					end
				end)
			end)
		end
	end)
	task.spawn(spawnLoop, player)
end

function WorldService.Init()
	Players.CharacterAutoLoads = false
	setupLighting()
end

function WorldService.Start()
	local worldFolder = Workspace:FindFirstChild("World")
	if not worldFolder then
		worldFolder = Instance.new("Folder")
		worldFolder.Name = "World"
		worldFolder.Parent = Workspace
	end
	local regions = ServerScriptService:FindFirstChild("World")
	local builder = regions and regions:FindFirstChild("Haven")
	if builder and not worldFolder:GetAttribute("Built") then
		local t0 = os.clock()
		local ok, result = pcall(function()
			return require(builder).build({
				Folder = worldFolder,
				Terrain = Workspace.Terrain,
				Progress = function(f: number)
					Workspace:SetAttribute("WorldProgress", f)
				end,
			})
		end)
		if ok and type(result) == "table" then
			WorldService.Spawn = result.Spawn or WorldService.Spawn
			WorldService.Landmarks = result.Landmarks or {}
			WorldService.Ground = result.Ground
		elseif not ok then
			warn("[World] build failed: " .. tostring(result))
		end
		worldFolder:SetAttribute("Built", true)
		worldFolder:SetAttribute("BuildSeconds", math.floor((os.clock() - t0) * 10) / 10)
	end
	WorldService.Ready = true
	Workspace:SetAttribute("WorldReady", true)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayer, p)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return WorldService

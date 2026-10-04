--[[
	GraphicsController
	Quality presets (MAX default on desktop, HIGH, MEDIUM - no LOW mode).
	Controls post effects, particle density, decoration/LOD distances and the
	soft blur behind open menus. Other systems read the live values:
	  GraphicsController.ParticleScale, .DecorDistance, .DragonDetailDistance
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local GraphicsController = {}
GraphicsController.Changed = Signal.new()
GraphicsController.Preset = "Max"
GraphicsController.ParticleScale = 1
GraphicsController.DecorDistance = 900
GraphicsController.DragonDetailDistance = 420
GraphicsController.AnimationDistance = 700
GraphicsController.Shadows = true

-- Blur is the size of the optional soft menu blur (Settings > Menu blur, off by default).
local PRESETS = {
	Max = { Particles = 1, Decor = 950, DragonDetail = 460, Anim = 800, Bloom = true, SunRays = true, DOF = true, Shadows = true, Decoration = true, Blur = 8 },
	High = { Particles = 0.7, Decor = 650, DragonDetail = 320, Anim = 550, Bloom = true, SunRays = true, DOF = false, Shadows = true, Decoration = true, Blur = 6 },
	Medium = { Particles = 0.4, Decor = 380, DragonDetail = 200, Anim = 350, Bloom = true, SunRays = false, DOF = false, Shadows = false, Decoration = false, Blur = 0 },
}

GraphicsController.MenuBlurEnabled = false -- opt-in; see Settings > Menu blur

local blur: BlurEffect = nil
local blurTween: Tween? = nil
local uiRef = nil
local particleBase = setmetatable({}, { __mode = "k" }) :: { [ParticleEmitter]: number }

local function applyParticles()
	for _, pe in CollectionService:GetTagged("FX") do
		if pe:IsA("ParticleEmitter") then
			local base = particleBase[pe]
			if base == nil then
				base = pe.Rate
				particleBase[pe] = base
			end
			pe.Rate = base * GraphicsController.ParticleScale
		end
	end
end

function GraphicsController.setPreset(name: string)
	local p = PRESETS[name] or PRESETS.Max
	GraphicsController.Preset = PRESETS[name] and name or "Max"
	GraphicsController.ParticleScale = p.Particles
	GraphicsController.DecorDistance = p.Decor
	GraphicsController.DragonDetailDistance = p.DragonDetail
	GraphicsController.AnimationDistance = p.Anim
	GraphicsController.Shadows = p.Shadows
	GraphicsController.BlurSize = p.Blur
	for _, effect in Lighting:GetChildren() do
		if effect:IsA("BloomEffect") then
			effect.Enabled = p.Bloom
		elseif effect:IsA("SunRaysEffect") then
			effect.Enabled = p.SunRays
		elseif effect:IsA("DepthOfFieldEffect") then
			effect.Enabled = p.DOF
		end
	end
	pcall(function()
		Workspace.Terrain.Decoration = p.Decoration
	end)
	for _, light in CollectionService:GetTagged("ShadowLight") do
		if light:IsA("Light") then
			light.Shadows = p.Shadows
		end
	end
	applyParticles()
	GraphicsController.Changed:Fire(GraphicsController.Preset)
end

-- The blur is opt-in (Settings > Menu blur) and never applied to windows that sit over the
-- 3D world (NoBackdrop, e.g. the Spin Wheel) - the thing you look at must stay sharp.
function GraphicsController.setMenuBlur(on: boolean)
	if not blur then
		return
	end
	if blurTween then
		blurTween:Cancel()
	end
	local size = (on and GraphicsController.MenuBlurEnabled) and (GraphicsController.BlurSize or 0) or 0
	blur.Enabled = size > 0 or blur.Size > 0
	blurTween = TweenService:Create(blur, TweenInfo.new(on and 0.22 or 0.16, Enum.EasingStyle.Quad), { Size = size })
	blurTween:Play()
end

function GraphicsController.setMenuBlurEnabled(on: boolean)
	GraphicsController.MenuBlurEnabled = on
	local ui = uiRef
	local current = ui and ui.Current and ui.Windows[ui.Current] or nil
	GraphicsController.setMenuBlur(current ~= nil and current.NoBackdrop ~= true)
end

function GraphicsController.Init(registry)
	blur = Instance.new("BlurEffect")
	blur.Name = "RAD_MenuBlur"
	blur.Size = 0
	blur.Parent = Lighting
	CollectionService:GetInstanceAddedSignal("FX"):Connect(function(pe)
		if pe:IsA("ParticleEmitter") then
			particleBase[pe] = pe.Rate
			pe.Rate = pe.Rate * GraphicsController.ParticleScale
		end
	end)
	local ui = registry.UIController
	uiRef = ui
	if ui then
		ui.WindowOpened:Connect(function(_name, window)
			GraphicsController.setMenuBlur(not (window and window.NoBackdrop == true))
		end)
		ui.WindowClosed:Connect(function()
			if not ui.Current then
				GraphicsController.setMenuBlur(false)
			end
		end)
	end
	GraphicsController.setPreset("Max")
end

return GraphicsController

--[[
	EggVisual
	Builds dragon egg models (client-side, never replicated): a glossy shell,
	speckles in the egg's spot colour, soft inner glow, optional light pillar
	(so world eggs are visible from the air) and sparkles.

	EggVisual.build(eggType, opts) -> Model (PrimaryPart = Shell)
	  opts: Scale, Beam (bool), Sparkles (bool), Light (bool)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EggConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EggConfig"))

local EggVisual = {}

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local function sphere(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = parent
	return p
end

function EggVisual.build(eggType: string, opts: { [string]: any }?): Model
	local o = opts or {}
	local def = EggConfig.Eggs[eggType] or EggConfig.Eggs.HavenEgg
	local s = o.Scale or 1
	local model = Instance.new("Model")
	model.Name = "Egg"
	model:SetAttribute("EggType", eggType)
	local size = Vector3.new(2.4, 3.1, 2.4) * s
	local shell = sphere(size, CFrame.new(), def.Shell, Enum.Material.SmoothPlastic, model)
	shell.Name = "Shell"
	shell.Reflectance = 0.04
	model.PrimaryPart = shell
	-- surface pattern (deterministic per egg type)
	local rng = Random.new(#eggType * 97 + def.Tier)
	local pattern = def.Pattern or "Spots"
	local function onShell(u: number, a: number): (Vector3, Vector3)
		local r = math.sqrt(math.max(0, 1 - u * u))
		local n = Vector3.new(math.cos(a) * r, u, math.sin(a) * r)
		return Vector3.new(n.X * size.X / 2, n.Y * size.Y / 2, n.Z * size.Z / 2) * 0.97, n
	end
	local function spot(i: number, u: number, a: number, k: number, color: Color3, material: Enum.Material?)
		local p, n = onShell(u, a)
		local part = sphere(Vector3.new(k, k * 0.35, k), CFrame.lookAt(p, p + n) * CFrame.Angles(math.rad(90), 0, 0), color, material or Enum.Material.SmoothPlastic, model)
		part.Name = "Spot" .. i
		part.CastShadow = false
		return part
	end
	local function band(i: number, y: number, thick: number, color: Color3, material: Enum.Material?)
		-- a ring around the shell at height y (ellipsoid slice)
		local u = math.clamp(y, -0.95, 0.95)
		local r = math.sqrt(1 - u * u)
		local part = sphere(Vector3.new(size.X * r * 1.025, thick * s, size.Z * r * 1.025), CFrame.new(0, u * size.Y / 2, 0), color, material or Enum.Material.SmoothPlastic, model)
		part.Name = "Band" .. i
		part.CastShadow = false
		return part
	end
	if pattern == "Stripes" or pattern == "Cracks" then
		for i, y in { -0.45, -0.05, 0.38 } do
			local b = band(i, y, pattern == "Cracks" and 0.22 or 0.42, def.Spots, pattern == "Cracks" and Enum.Material.Neon or nil)
			if pattern == "Cracks" then
				b.Transparency = 0.15
			end
		end
		for i = 1, 4 do
			spot(10 + i, rng:NextNumber(-0.6, 0.7), rng:NextNumber(0, math.pi * 2), rng:NextNumber(0.3, 0.5) * s, def.Spots, pattern == "Cracks" and Enum.Material.Neon or nil)
		end
	elseif pattern == "Rainbow" then
		local cols = { Color3.fromRGB(255, 90, 90), Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 230, 70), Color3.fromRGB(110, 220, 100), Color3.fromRGB(80, 170, 255), Color3.fromRGB(170, 110, 255) }
		for i, col in cols do
			band(i, -0.75 + (i - 1) * 0.3, 0.5, col)
		end
	elseif pattern == "Stars" or pattern == "Flowers" or pattern == "Crystal" then
		for i = 1, 11 do
			local u = rng:NextNumber(-0.7, 0.85)
			local a = rng:NextNumber(0, math.pi * 2)
			local k = rng:NextNumber(0.3, 0.55) * s
			if pattern == "Crystal" then
				local part = spot(i, u, a, k * 1.2, def.Spots)
				part.Material = Enum.Material.Glass
				part.Transparency = 0.3
			elseif pattern == "Stars" then
				local part = spot(i, u, a, k * 0.7, def.Spots, Enum.Material.Neon)
				part.Transparency = 0.1
			else
				-- tiny flower: five petals + centre
				for j = 0, 4 do
					local aa = a + (j / 5) * math.pi * 2 * 0.05
					spot(i * 10 + j, u + math.sin(j * 1.256) * 0.06, aa + math.cos(j * 1.256) * 0.07, k * 0.55, def.Spots)
				end
				spot(i * 10 + 9, u, a, k * 0.4, Color3.fromRGB(255, 230, 90))
			end
		end
	elseif pattern == "Gold" then
		shell.Reflectance = 0.35
		for i = 1, 6 do
			spot(i, rng:NextNumber(-0.6, 0.8), rng:NextNumber(0, math.pi * 2), rng:NextNumber(0.3, 0.5) * s, def.Spots, Enum.Material.Neon)
		end
	else
		for i = 1, 9 do
			spot(i, rng:NextNumber(-0.75, 0.85), rng:NextNumber(0, math.pi * 2), rng:NextNumber(0.35, 0.7) * s, def.Spots)
		end
	end
	-- inner glow band (rare eggs shine brighter)
	local glow = sphere(size * 1.04, CFrame.new(), def.Glow, Enum.Material.Neon, model)
	glow.Name = "Glow"
	glow.Transparency = 0.86 - math.min(def.Tier, 5) * 0.025
	glow.CastShadow = false
	if o.Light ~= false then
		local light = Instance.new("PointLight")
		light.Color = def.Glow
		light.Range = 10 + def.Tier * 2
		light.Brightness = 0.9 + def.Tier * 0.2
		light.Shadows = false
		light.Parent = shell
	end
	if o.Sparkles ~= false then
		local att = Instance.new("Attachment")
		att.Name = "SparkleAtt"
		att.Parent = shell
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "Sparkles"
		pe.Texture = SPARKLE
		pe.Color = ColorSequence.new(def.Glow)
		pe.LightEmission = 1
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 0.35 * s), NumberSequenceKeypoint.new(1, 0) })
		pe.Transparency = NumberSequence.new(0.15)
		pe.Lifetime = NumberRange.new(0.8, 1.4)
		pe.Rate = 5 + def.Tier * 2
		pe.Speed = NumberRange.new(0.6, 1.6)
		pe.SpreadAngle = Vector2.new(180, 180)
		pe.Shape = Enum.ParticleEmitterShape.Sphere
		pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		pe.Acceleration = Vector3.new(0, 1.5, 0)
		pe.Parent = att
	end
	if o.Beam then
		local a0 = Instance.new("Attachment")
		a0.Name = "BeamBase"
		a0.Position = Vector3.new(0, -size.Y * 0.2, 0)
		a0.Parent = shell
		local a1 = Instance.new("Attachment")
		a1.Name = "BeamTop"
		a1.Position = Vector3.new(0, 70 + def.Tier * 10, 0)
		a1.Parent = shell
		local beam = Instance.new("Beam")
		beam.Name = "Pillar"
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Color = ColorSequence.new(def.Glow)
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.FaceCamera = true
		beam.Width0 = 2.6 * s
		beam.Width1 = 0.6 * s
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.25, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.Segments = 4
		beam.Parent = shell
	end
	return model
end

-- Moves an egg model (all parts keep their offsets from the shell).
function EggVisual.place(model: Model, cf: CFrame)
	model:PivotTo(cf)
end

return EggVisual

--[[
	Props - trees, bushes and rocks from the generated layout.

	Uses mesh templates from ReplicatedStorage.WorldProps (imported
	HavenProps.glb: Oak*, Pine*, Birch*, Bush*, Rock*) when present, otherwise
	builds light part-based stand-ins so the world is never bare.
	Instances are grouped per 256-stud cell (streaming friendly).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Props = {}

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local CELL = 256

local function cellFolder(root: Instance, cells: { [string]: Instance }, x: number, z: number): Instance
	local key = math.floor(x / CELL) .. "_" .. math.floor(z / CELL)
	local f = cells[key]
	if not f then
		f = Instance.new("Model")
		f.Name = "Cell_" .. key
		f.Parent = root
		pcall(function()
			(f :: any).ModelStreamingMode = Enum.ModelStreamingMode.Default
		end)
		cells[key] = f
	end
	return f
end

-- templates: { [prefix] = { Model|BasePart } } collected from ReplicatedStorage.WorldProps
local function collectTemplates(): { [string]: { Instance } }
	local out = {}
	local folder = ReplicatedStorage:FindFirstChild("WorldProps")
	if not folder then
		return out
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("MeshPart") then
			local prefix = string.match(d.Name, "^(%a+)")
			if prefix then
				out[prefix] = out[prefix] or {}
				table.insert(out[prefix], d)
			end
		end
	end
	return out
end

local function placeMesh(template: BasePart, parent: Instance, cf: CFrame, scale: number)
	local p = template:Clone()
	p.Anchored = true
	-- foliage is walk/fly-through (no invisible hull walls); rocks are solid
	local solid = string.sub(template.Name, 1, 4) == "Rock"
	p.CanCollide = solid
	p.CanQuery = solid
	p.CanTouch = false
	p.Size = template.Size * scale
	-- template pivot = bottom centre (stored by the importer helper) or the part centre
	local base = template:GetAttribute("BaseOffset") or (template.Size.Y / 2)
	p.CFrame = cf * CF(0, base * scale, 0)
	p.Parent = parent
	return p
end

-- ============================================================== fallbacks
local LEAF = { Oak = Color3.fromRGB(66, 104, 50), Pine = Color3.fromRGB(46, 78, 52), Birch = Color3.fromRGB(116, 150, 70) }
local BARK = { Oak = Color3.fromRGB(88, 66, 48), Pine = Color3.fromRGB(78, 58, 44), Birch = Color3.fromRGB(214, 210, 198) }

local function ellipsoid(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = parent
	return p
end

local function fallbackTree(parent: Instance, kind: string, cf: CFrame, s: number, rng: Random)
	local model = Instance.new("Model")
	model.Name = kind
	local h = (kind == "Pine" and 22 or (kind == "Birch" and 18 or 16)) * s
	local trunk = Instance.new("Part")
	trunk.Anchored = true
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = V(h * 0.75, 1.6 * s, 1.6 * s)
	trunk.CFrame = cf * CF(0, h * 0.375, 0) * ANG(0, 0, math.rad(90))
	trunk.Color = BARK[kind]
	trunk.Material = Enum.Material.Wood
	trunk.Parent = model
	local leaf = LEAF[kind]
	local mat = Enum.Material.LeafyGrass
	if kind == "Pine" then
		for i = 0, 2 do
			local k = 1 - i * 0.28
			ellipsoid(model, V(10 * k * s, 9 * s, 10 * k * s), cf * CF(0, h * (0.38 + i * 0.2), 0), leaf:Lerp(Color3.new(0, 0, 0), i * 0.05), mat)
		end
	else
		ellipsoid(model, V(13 * s, 10 * s, 13 * s), cf * CF(0, h * 0.78, 0), leaf, mat)
		for i = 1, 2 do
			local a = rng:NextNumber(0, math.pi * 2)
			ellipsoid(model, V(9 * s, 7.5 * s, 9 * s), cf * CF(math.cos(a) * 4 * s, h * (0.62 + 0.1 * i), math.sin(a) * 4 * s),
				leaf:Lerp(Color3.fromRGB(150, 160, 70), 0.12 * i), mat)
		end
	end
	model.Parent = parent
	return model
end

local function fallbackRock(parent: Instance, cf: CFrame, s: number, rng: Random)
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = V(6, 4, 5) * s * V(rng:NextNumber(0.8, 1.3), rng:NextNumber(0.7, 1.1), rng:NextNumber(0.8, 1.3))
	p.CFrame = cf * CF(0, p.Size.Y * 0.35, 0) * ANG(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3))
	p.Color = Color3.fromRGB(116, 114, 108)
	p.Material = Enum.Material.Rock
	p.Parent = parent
	return p
end

-- ============================================================== build
function Props.build(parent: Instance, layout, opts: { [string]: any }?)
	local o = opts or {}
	local root = Instance.new("Folder")
	root.Name = "Nature"
	root.Parent = parent
	local cells = {}
	local templates = collectTemplates()
	local useMesh = next(templates) ~= nil
	local rng = Random.new(99)
	local stride = useMesh and 1 or (o.FallbackStride or 2)
	local kinds = layout.TreeKinds
	local count = 0
	for i, t in layout.Trees do
		if i % stride == 0 or stride == 1 then
			local kind = kinds[t[1]]
			local cf = CF(t[2], t[3] - 0.4, t[4]) * ANG(0, t[5], 0)
			local f = cellFolder(root, cells, t[2], t[4])
			local list = templates[kind]
			if list then
				placeMesh(list[(i % #list) + 1] :: BasePart, f, cf, t[6])
			else
				fallbackTree(f, kind, cf, t[6], rng)
			end
			count += 1
			if count % 200 == 0 then
				task.wait()
			end
		end
	end
	for i, b in layout.Bushes do
		local list = templates.Bush
		if list then
			local f = cellFolder(root, cells, b[1], b[3])
			placeMesh(list[(i % #list) + 1] :: BasePart, f, CF(b[1], b[2] - 0.3, b[3]) * ANG(0, b[4], 0), b[5])
		elseif i % 3 == 0 then
			local f = cellFolder(root, cells, b[1], b[3])
			ellipsoid(f, V(6, 3.6, 6) * b[5], CF(b[1], b[2] + 1, b[3]), LEAF.Oak:Lerp(Color3.fromRGB(120, 140, 60), 0.3), Enum.Material.LeafyGrass)
		end
	end
	for i, r in layout.Rocks do
		local f = cellFolder(root, cells, r[1], r[3])
		local list = templates.Rock
		local cf = CF(r[1], r[2], r[3]) * ANG(0, r[4], 0)
		if list then
			placeMesh(list[(r[6] % #list) + 1] :: BasePart, f, cf, r[5])
		else
			fallbackRock(f, cf, r[5], rng)
		end
		if i % 200 == 0 then
			task.wait()
		end
	end
	root:SetAttribute("MeshProps", useMesh)
	return root
end

return Props

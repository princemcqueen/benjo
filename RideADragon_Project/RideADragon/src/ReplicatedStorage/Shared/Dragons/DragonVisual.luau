--[[
	DragonVisual
	Creates the visual model for a dragon.

	Preferred: a skinned mesh template imported from Blender-style .glb files
	(one MeshPart + Bones, textures baked offline). Templates live in
	ReplicatedStorage.DragonModels.<SpeciesId>. When a species has no template
	yet, the procedural part-built dragon (Builder) is used instead, so the game
	always works.

	Mesh visuals:
	  * the MeshPart is welded to the server physics Root so that the template's
	    "Root" bone coincides with the Root (whatever offset/rotation the importer
	    gave the bone), which makes every bone's rest frame model-aligned;
	  * Animator drives Bone.Transform exactly like Motor6D.Transform;
	  * sockets (MemF1L, WingTipL, Mouth, SaddlePoint, ...) are Bones too, and a
	    Bone is an Attachment, so effects can use them directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(script.Parent:WaitForChild("Builder"))
local BrickBuilder = require(script.Parent:WaitForChild("BrickBuilder"))
local Species = require(script.Parent:WaitForChild("Species"))

local DragonVisual = {}

local MUTATION_TINT = {
	Shiny = Color3.fromRGB(200, 240, 255),
	Golden = Color3.fromRGB(255, 214, 120),
	Shadow = Color3.fromRGB(120, 92, 170),
	Rainbow = Color3.fromRGB(255, 190, 235),
	Neon = Color3.fromRGB(160, 255, 240),
	Infernal = Color3.fromRGB(255, 130, 100),
	Corrupted = Color3.fromRGB(190, 90, 170),
	Crystal = Color3.fromRGB(205, 175, 255),
	Lightning = Color3.fromRGB(255, 244, 150),
	Angelic = Color3.fromRGB(255, 250, 235),
}

local function modelsFolder(): Instance?
	return ReplicatedStorage:FindFirstChild("DragonModels")
end

-- Finds the skinned MeshPart and its root bone inside a template/clone.
function DragonVisual.findRig(model: Instance): (MeshPart?, Bone?)
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") then
			local root = d:FindFirstChild("Root")
			if root and root:IsA("Bone") then
				return d, root
			end
		end
	end
	return nil, nil
end

function DragonVisual.template(speciesId: string): Model?
	local folder = modelsFolder()
	local t = folder and folder:FindFirstChild(speciesId)
	if t and t:IsA("Model") then
		local mesh = DragonVisual.findRig(t)
		if mesh then
			return t
		end
	end
	return nil
end

function DragonVisual.hasMesh(speciesId: string): boolean
	return DragonVisual.template(speciesId) ~= nil
end

local function stripImporterExtras(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("AnimationController") or d:IsA("Humanoid") or d:IsA("Animator") then
			d:Destroy()
		elseif d:IsA("Folder") and d.Name == "InitialPoses" then
			d:Destroy()
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
end

local function applyMutation(mesh: MeshPart, mutation: string?)
	if not mutation or mutation == "None" then
		return
	end
	-- a pre-made SurfaceAppearance variant (Mutations/<id>) wins when present
	local variants = mesh:FindFirstChild("Mutations")
	local variant = variants and variants:FindFirstChild(mutation)
	if variant and variant:IsA("SurfaceAppearance") then
		local current = mesh:FindFirstChildWhichIsA("SurfaceAppearance")
		if current then
			current:Destroy()
		end
		variant:Clone().Parent = mesh
		return
	end
	local tint = MUTATION_TINT[mutation]
	if tint then
		local sa = mesh:FindFirstChildWhichIsA("SurfaceAppearance")
		if sa then
			pcall(function()
				(sa :: any).Color = tint
			end)
		else
			mesh.Color = tint
		end
	end
	if mutation == "Golden" then
		mesh.Reflectance = 0.06
	end
end

-- Attaches a cloned template to the physics root (rest pose aligned).
local function attachMesh(model: Model, mesh: MeshPart, rootBone: Bone, root: BasePart)
	mesh.Anchored = false
	mesh.CanCollide = false
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.Massless = true
	mesh.CastShadow = true
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= mesh then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
	local weld = Instance.new("Weld")
	weld.Name = "RootWeld"
	weld.Part0 = root
	weld.Part1 = mesh
	weld.C0 = rootBone.CFrame:Inverse()
	weld.C1 = CFrame.identity
	weld.Parent = mesh
	mesh.CFrame = root.CFrame * weld.C0
end

-- Rest position of a bone relative to the template's Root bone.
local function restPos(bone: Instance): Vector3
	local cf = CFrame.identity
	local b: Instance? = bone
	while b and b:IsA("Bone") and b.Name ~= "Root" do
		cf = (b :: Bone).CFrame * cf
		b = b.Parent
	end
	return cf.Position
end

local warned: { [string]: boolean } = {}
local function checkOrientation(speciesId: string, rootBone: Bone)
	if warned[speciesId] then
		return
	end
	local head = rootBone:FindFirstChild("Head", true)
	local tail = rootBone:FindFirstChild("Tail1", true)
	if head and tail and restPos(head).Z > restPos(tail).Z then
		warned[speciesId] = true
		warn(("[DragonVisual] %s template faces +Z (head behind tail); re-export it facing -Z"):format(speciesId))
	end
end

-- opts: Root (BasePart, required for animated dragons), Mutation, Scale
-- (extra scale multiplier), Detail, Saddle. Returns the visual Model.
function DragonVisual.build(speciesId: string, opts: { [string]: any }?): Model
	local o = opts or {}
	if Species.Style == "Brick" and not o.ForceMesh then
		return BrickBuilder.build(speciesId, o)
	end
	local template = DragonVisual.template(speciesId)
	if not template or o.ForceParts then
		return Builder.build(speciesId, o)
	end
	local def = Species.get(speciesId)
	local model = template:Clone()
	stripImporterExtras(model)
	local mesh, rootBone = DragonVisual.findRig(model)
	assert(mesh and rootBone, "dragon template without a skinned MeshPart")
	checkOrientation(speciesId, rootBone)
	local baseScale = def.Scale or 1
	local extra = o.ScaleOverride or 1
	if extra ~= 1 then
		model:ScaleTo(model:GetScale() * extra)
	end
	local S = baseScale * extra
	if o.Root then
		attachMesh(model, mesh, rootBone, o.Root)
	end
	model.PrimaryPart = mesh
	applyMutation(mesh, o.Mutation)
	model.Name = def.Name or speciesId
	model:SetAttribute("SpeciesId", speciesId)
	model:SetAttribute("Scale", S)
	model:SetAttribute("BodyRadius", (def.BodyRadius or 4.2) * S)
	model:SetAttribute("HipHeight", def.HipHeight * S)
	model:SetAttribute("Rig", def.Rig or "Quadruped")
	model:SetAttribute("MeshRig", true)
	if o.Mutation then
		model:SetAttribute("Mutation", o.Mutation)
	end
	return model
end

-- Static pose for displays / viewports. Mesh rigs pose through their bones.
function DragonVisual.pose(model: Model, pose: { [string]: CFrame }?, rootCF: CFrame?)
	if not model:GetAttribute("MeshRig") then
		Builder.pose(model, pose, rootCF)
		return
	end
	local mesh, rootBone = DragonVisual.findRig(model)
	if not mesh or not rootBone then
		return
	end
	for _, d in mesh:GetDescendants() do
		if d:IsA("Bone") and pose and pose[d.Name] then
			d.Transform = pose[d.Name]
		end
	end
	local weld = mesh:FindFirstChild("RootWeld")
	if weld then
		weld:Destroy()
	end
	mesh.Anchored = true
	mesh.CFrame = (rootCF or CFrame.identity) * rootBone.CFrame:Inverse()
end

return DragonVisual

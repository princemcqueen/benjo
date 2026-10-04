--[[
	DragonAssetService
	Collects skinned dragon mesh templates (imported .glb models) into
	ReplicatedStorage.DragonModels so every client can clone them.

	Importing in Studio (Avatar/Home > Import 3D) drops the model into
	Workspace under the species id (e.g. "GreenDrake"). Templates may be left
	there or dragged into ReplicatedStorage / ReplicatedStorage.DragonModels;
	at server start they are moved into DragonModels automatically.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Dragons = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Dragons")
local DragonVisual = require(Dragons:WaitForChild("DragonVisual"))
local Species = require(Dragons:WaitForChild("Species"))
local DragonConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("DragonConfig"))

local DragonAssetService = {}

local function speciesIds(): { string }
	local ids = {}
	local seen = {}
	for id in Species.Defs do
		if not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	for id in DragonConfig.Species or {} do
		if not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	return ids
end

local function adopt(folder: Folder, container: Instance, id: string)
	local m = container:FindFirstChild(id)
	if m and m:IsA("Model") and m.Parent ~= folder and DragonVisual.findRig(m) then
		if folder:FindFirstChild(id) then
			return
		end
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		m.Parent = folder
	end
end

function DragonAssetService.Init()
	local folder = ReplicatedStorage:FindFirstChild("DragonModels")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DragonModels"
		folder.Parent = ReplicatedStorage
	end
	for _, id in speciesIds() do
		adopt(folder :: Folder, Workspace, id)
		adopt(folder :: Folder, ReplicatedStorage, id)
	end
	-- nature props (HavenProps.glb import) -> ReplicatedStorage.WorldProps
	if not ReplicatedStorage:FindFirstChild("WorldProps") then
		for _, container in { Workspace, ReplicatedStorage } do
			local m = container:FindFirstChild("HavenProps")
			if m and m:IsA("Model") and m:FindFirstChildWhichIsA("MeshPart", true) then
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored = true
					end
				end
				m.Name = "WorldProps"
				m.Parent = ReplicatedStorage
				break
			end
		end
	end
	local count = 0
	for _, t in folder:GetChildren() do
		if DragonVisual.findRig(t) then
			count += 1
		end
	end
	ReplicatedStorage:SetAttribute("MeshDragonTemplates", count)
end

return DragonAssetService

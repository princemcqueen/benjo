--[[
	Haven - builds Dragon Haven: terrain (from generated data), the hub village
	and stations, statue, sanctuary plots, bridges, landmarks, nature props,
	spawn and egg spots. Returns spawn + landmark data for WorldService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local TerrainWriter = require(script.Parent:WaitForChild("TerrainWriter"))
local Village = require(script.Parent:WaitForChild("Village"))
local Sanctuaries = require(script.Parent:WaitForChild("Sanctuaries"))
local Landmarks = require(script.Parent:WaitForChild("Landmarks"))
local GreatTree = require(script.Parent:WaitForChild("GreatTree"))
local Props = require(script.Parent:WaitForChild("Props"))
local Kit = require(script.Parent:WaitForChild("Kit"))
local WorldConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("WorldConfig"))

local Haven = {}

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local function folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

function Haven.build(ctx)
	local root: Instance = ctx.Folder
	local terrain: Terrain = ctx.Terrain or Workspace.Terrain
	local log = ctx.Log or function(_: string) end
	local t0 = os.clock()
	local data = require(script.Parent:WaitForChild("HavenTerrainData"))
	local layout = require(script.Parent:WaitForChild("HavenLayout"))
	local map = TerrainWriter.load(data)
	TerrainWriter.applyLook(terrain, data)
	if terrain:GetAttribute("Prebuilt") == nil then
		TerrainWriter.write(terrain, map, { Progress = ctx.Progress })
		terrain:SetAttribute("Prebuilt", "Haven")
	end
	log(("terrain %.1fs"):format(os.clock() - t0))
	local function ground(x: number, z: number): number
		return TerrainWriter.heightAt(map, x, z)
	end

	-- hub: statue, stations, cottages, lamps
	local hub = folder(root, "Hub")
	local statue = Landmarks.statue(hub, V(0, WorldConfig.Hub.Height, 0))
	local stations = {}
	for _, b in layout.Buildings do
		local cf = CF(b.X, b.Y, b.Z) * ANG(0, b.Yaw, 0)
		if b.Kind == "cottage" then
			Village.cottage(hub, cf, { Seed = b.Seed, W = b.w, D = b.d, Stories = b.stories })
		else
			local station = WorldConfig.Stations[b.Station]
			local recipe = (Village :: any)[b.Kind]
			if recipe then
				local model = recipe(hub, cf, station)
				model:SetAttribute("Station", b.Station)
				stations[b.Station] = model
			end
		end
	end
	-- the Great Tree (skill tree station) north-east of the statue
	local treePos, treeYaw = GreatTree.position(ground)
	stations.Tree = GreatTree.build(hub, treePos, treeYaw)
	local lamps = Kit.new(hub, CFrame.identity, "Lamps")
	for _, l in layout.Lamps do
		lamps:lampPost(V(l[1], l[2] - 0.2, l[3]), 10)
	end
	log(("hub %.1fs"):format(os.clock() - t0))

	-- sanctuary plots
	local plots = folder(root, "Sanctuaries")
	local plotModels = {}
	for _, p in WorldConfig.Plots do
		plotModels[p.Id] = Sanctuaries.build(plots, p)
	end

	-- bridges
	local bridges = folder(root, "Bridges")
	for _, b in layout.Bridges do
		Landmarks.bridge(bridges, b)
	end

	-- landmarks
	local lm = folder(root, "Landmarks")
	local rc = WorldConfig.Ruins.Center
	Landmarks.ruins(lm, V(rc.X, ground(rc.X, rc.Z), rc.Z), ground)
	local wf = WorldConfig.Waterfall
	Landmarks.waterfall(lm, wf.Top, wf.Bottom, wf.Width)
	local cavePath = {}
	for i, c in data.Carves do
		table.insert(cavePath, V(c[1], c[2], c[3]))
		if i == #data.Carves then
			table.insert(cavePath, V(c[4], c[5], c[6]))
		end
	end
	Landmarks.caveDecor(lm, cavePath)
	local sp = WorldConfig.SkyPillar.Center
	local pillarTop = ground(sp.X, sp.Z)
	for _, off in { V(10, 0, 0), V(-10, 0, 0), V(0, 0, 10), V(0, 0, -10) } do
		pillarTop = math.max(pillarTop, ground(sp.X + off.X, sp.Z + off.Z))
	end
	Landmarks.skyIslands(lm, terrain, V(sp.X, 0, sp.Z), pillarTop)
	log(("landmarks %.1fs"):format(os.clock() - t0))

	-- nature
	Props.build(root, layout)
	log(("props %.1fs"):format(os.clock() - t0))

	-- spawn (plaza, facing the statue)
	local spawnPos = WorldConfig.Spawn.Position
	local spawnY = ground(spawnPos.X, spawnPos.Z)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HavenSpawn"
	spawn.Anchored = true
	spawn.Size = V(10, 0.6, 10)
	spawn.CFrame = CFrame.lookAt(V(spawnPos.X, spawnY + 0.3, spawnPos.Z), V(0, spawnY + 0.3, 0))
	spawn.Material = Enum.Material.Slate
	spawn.Color = Color3.fromRGB(150, 142, 128)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Duration = 0
	spawn.Neutral = true
	spawn.Parent = root

	-- egg spots (EggService)
	local eggs = folder(root, "EggSpots")
	for i, e in layout.EggSpots do
		local p = Instance.new("Part")
		p.Name = "EggSpot" .. i
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Transparency = 1
		p.Size = V(4, 4, 4)
		local y = e.Y
		if e.Name == "Pillar" then
			y = pillarTop
		end
		p.CFrame = CF(e.X, y + 2.5, e.Z)
		p:SetAttribute("Area", e.Name)
		p.Parent = eggs
	end

	return {
		Spawn = spawn.CFrame + V(0, 3, 0),
		Landmarks = { Statue = statue, Stations = stations, Plots = plotModels },
		Map = map,
		Ground = ground,
	}
end

return Haven

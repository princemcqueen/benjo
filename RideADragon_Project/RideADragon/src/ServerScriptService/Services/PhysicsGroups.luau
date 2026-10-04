--[[
	PhysicsGroups
	Collision groups:
	  Dragons      dragon physics roots + visuals (never collide with anything)
	  Characters   player characters on foot
	  Riders       characters while mounted (collide with nothing, so a rider
	               can never snag the dragon on geometry)
	  Eggs         pickup eggs
	  DragonQuery  raycast group used by movement/camera queries: ignores
	               dragons, characters, riders and eggs
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local PhysicsGroups = {}

local GROUPS = { "Dragons", "Characters", "Riders", "Eggs", "DragonQuery" }

local function register(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end

local function setGroup(model: Instance, group: string)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
end
PhysicsGroups.setGroup = setGroup

function PhysicsGroups.Init()
	for _, g in GROUPS do
		register(g)
	end
	local function off(a: string, b: string)
		PhysicsService:CollisionGroupSetCollidable(a, b, false)
	end
	off("Dragons", "Dragons")
	off("Dragons", "Characters")
	off("Dragons", "Riders")
	off("Dragons", "Default")
	off("Dragons", "Eggs")
	off("Riders", "Default")
	off("Riders", "Characters")
	off("Riders", "Riders")
	off("Riders", "Eggs")
	off("DragonQuery", "Dragons")
	off("DragonQuery", "Characters")
	off("DragonQuery", "Riders")
	off("DragonQuery", "Eggs")
end

local function watchCharacter(character: Model)
	local group = character:GetAttribute("Mounted") and "Riders" or "Characters"
	setGroup(character, group)
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = character:GetAttribute("Mounted") and "Riders" or "Characters"
		end
	end)
end

function PhysicsGroups.Start()
	local function onPlayer(player: Player)
		if player.Character then
			watchCharacter(player.Character)
		end
		player.CharacterAdded:Connect(watchCharacter)
	end
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return PhysicsGroups

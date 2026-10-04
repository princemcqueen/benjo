--[[
	TravelService
	Fast travel (HUD "Teleport" menu): the player's sanctuary and every hub
	station. Server-validated destinations only (clients send a name), with a
	short cooldown. Riding players travel with their dragon (the physics root
	moves, the rider stays seated); on foot, the companion is brought along.

	Net (domain "Travel"): To { Place } -> { Place }
	Places: Sanctuary, Spawn (leaderboards), SpinIsland, RaceIsland, Shop, Forge, Quests, Library
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local SpinConfig = require(Configs:WaitForChild("SpinConfig"))
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))

local TravelService = {}

local Services
local COOLDOWN = 2.5
local lastTravel: { [Player]: number } = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function groundY(pos: Vector3, fallback: number): number
	local dragons = Workspace:FindFirstChild("Dragons")
	rayParams.FilterDescendantsInstances = dragons and { dragons } or {}
	local hit = Workspace:Raycast(pos + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), rayParams)
	return hit and hit.Position.Y or fallback
end

-- Where a destination puts the player (standing, facing the place).
function TravelService.Destination(player: Player, place: string): CFrame?
	if place == "SpinIsland" then
		return SpinConfig.arrival()
	end
	if place == "RaceIsland" then
		local at = RaceConfig.toWorld(RaceConfig.Arrival)
		return CFrame.lookAt(at, at + Vector3.new(0, 0, -10))
	end
	if place == "Spawn" then
		local lb = Services.LeaderboardService
		return lb and lb.ArrivalCFrame() or nil
	end
	if place == "Sanctuary" then
		local sanctuary = Services.SanctuaryService
		local id = sanctuary and sanctuary.GetPlotId(player)
		return id and sanctuary.SpawnCFrame(id) or nil
	end
	local station = WorldConfig.Stations[place]
	if not station then
		return nil
	end
	local base = CFrame.new(station.Position) * CFrame.Angles(0, station.Facing, 0)
	local front = (base * CFrame.new(0, 0, -((station.Radius or 20) + 6))).Position
	local y = groundY(front, station.Position.Y) + 3.4
	local stand = Vector3.new(front.X, y, front.Z)
	return CFrame.lookAt(stand, Vector3.new(station.Position.X, y, station.Position.Z))
end

local function travel(player: Player, p)
	if not Net.check.str(p.Place, 20) then
		return false, "BAD_REQUEST"
	end
	if player:GetAttribute("RaceActive") then
		return false, "RACING", "You can't travel during a race."
	end
	local now = os.clock()
	if now - (lastTravel[player] or -100) < COOLDOWN then
		return false, "COOLDOWN", "Wait a moment before traveling again."
	end
	local cf = TravelService.Destination(player, p.Place)
	if not cf then
		return false, "BAD_PLACE"
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid or humanoid.Health <= 0 then
		return false, "NO_CHARACTER"
	end
	lastTravel[player] = now
	pcall(function()
		player:RequestStreamAroundAsync(cf.Position, 5)
	end)
	local mount = Services.MountService
	if mount and mount.IsRiding(player) and mount.MoveTo then
		-- arrive hovering above the spot, still mounted
		mount.MoveTo(player, cf + Vector3.new(0, 14, 0))
	else
		character:PivotTo(cf)
		if mount and mount.Spawn then
			mount.Spawn(player)
		end
	end
	return true, { Place = p.Place }
end

function TravelService.Init(services)
	Services = services
	Net.handle("Travel", "To", travel, { Burst = 3, PerSecond = 1 })
end

function TravelService.Start()
	Players.PlayerRemoving:Connect(function(player)
		lastTravel[player] = nil
	end)
end

return TravelService

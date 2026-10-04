--[[
	WildEggService
	Lucky Wild Eggs (WildEggConfig): every few minutes one special egg appears at a
	random egg area for the WHOLE server. A pillar of light marks it from afar. The first
	player (or ridden dragon) to reach it takes it - into their hand, with its big luck.
	After WildEggConfig.Lifetime seconds an unclaimed egg vanishes.

	Server authority: spawn time/place/tier/luck, pickup range, bag capacity and "first
	come first served" are all decided here.

	Net (domain "WildEgg"):   Claim {}  -> { Id, Type, Luck, Held, Name }
	                          Sync {}   -> { Current = info | nil }
	Net signals (to everyone): "WildEggSpawn" { Id, Tier, Name, Egg, Luck, Position, Region,
	                           Area, EndsAt, Color }, "WildEggClaimed" { Id, Player, Name, Luck },
	                           "WildEggGone" { Id }
	Signals: Spawned(info), Claimed(player, info), Expired(info)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local EggReach = require(Shared:WaitForChild("EggReach"))
local WildEggConfig = require(Configs:WaitForChild("WildEggConfig"))

local WildEggService = {}
WildEggService.Spawned = Signal.new() -- (info)
WildEggService.Claimed = Signal.new() -- (player, info)
WildEggService.Expired = Signal.new() -- (info)

local Services
local Data
local rng = Random.new()
local serial = 0
local current: any = nil -- { Id, Tier, Egg, Luck, Position, Area, Region, EndsAt, Model, Claimed }
local lastPosition: Vector3? = nil -- where the previous wild egg was (the next one keeps away from it)

local function payloadOf(egg)
	return {
		Id = egg.Id,
		Tier = egg.Tier.Id,
		Name = egg.Tier.Name,
		Egg = egg.Egg,
		Luck = egg.Luck,
		Position = egg.Position,
		Region = egg.Region,
		Area = egg.Area,
		EndsAt = egg.EndsAt,
		Color = egg.Tier.Color,
	}
end

function WildEggService.Current()
	return current
end

-- ============================================================== the egg in the world
local function buildModel(egg)
	local model = EggVisual.build(egg.Egg, { Beam = true, Scale = 2.4 })
	model.Name = "WildEgg"
	model:SetAttribute("Tier", egg.Tier.Id)
	model:SetAttribute("Luck", egg.Luck)
	model:SetAttribute("EndsAt", egg.EndsAt)
	-- a tall, wide pillar in the tier colour: visible from the far end of the map
	local shell = model.PrimaryPart
	local pillar = shell and shell:FindFirstChild("Pillar")
	if pillar and pillar:IsA("Beam") then
		pillar.Color = ColorSequence.new(egg.Tier.Color)
		pillar.Width0 = 7
		pillar.Width1 = 1.5
		pillar.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.4, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		local top = shell:FindFirstChild("BeamTop")
		if top and top:IsA("Attachment") then
			top.Position = Vector3.new(0, 320, 0)
		end
	end
	EggVisual.place(model, CFrame.new(egg.Position))
	-- (stays streamed in for everybody, so the pillar is visible from anywhere)
	local anyModel: any = model
	anyModel.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	CollectionService:AddTag(model, "WildEgg")
	local world = Workspace:FindFirstChild("World")
	model.Parent = world or Workspace
	return model
end

local function remove(egg, reason: string)
	if current ~= egg then
		return
	end
	current = nil
	if egg.Model then
		egg.Model:Destroy()
	end
	if reason == "expired" then
		Net.broadcast("WildEggGone", { Id = egg.Id })
		WildEggService.Expired:Fire(egg)
	end
end

-- Spawns a wild egg now (optionally of a given tier). Returns the info table or nil.
function WildEggService.Spawn(tierId: string?)
	if current then
		return nil
	end
	local eggService = Services.EggService
	local areas = eggService and eggService.Areas()
	if not areas or #areas == 0 then
		return nil
	end
	-- a completely random place of the land (not one of the fixed areas), away from the last wild egg
	local position, area = eggService.RandomSpot(lastPosition)
	if not position then
		-- (no free land found: a random area with a good resting spot)
		area = nil
	end
	for _ = 1, 8 do
		if area and position then
			break
		end
		local candidate = areas[rng:NextInteger(1, #areas)]
		local spot = eggService.FindSpot(candidate)
		if spot then
			area, position = candidate, spot
			break
		end
	end
	if not area or not position then
		return nil
	end
	local tier, eggType, luck = WildEggConfig.roll(rng, tierId)
	serial += 1
	local egg = {
		Id = "W" .. serial,
		Tier = tier,
		Egg = eggType,
		Luck = luck,
		Position = position + Vector3.new(0, 2.2, 0),
		Area = area.Name,
		Region = area.Region,
		EndsAt = Workspace:GetServerTimeNow() + WildEggConfig.Lifetime,
		Claimed = false,
	}
	egg.Model = buildModel(egg)
	current = egg
	lastPosition = position
	Net.broadcast("WildEggSpawn", payloadOf(egg))
	WildEggService.Spawned:Fire(egg)
	task.delay(WildEggConfig.Lifetime, function()
		if current == egg and not egg.Claimed then
			remove(egg, "expired")
		end
	end)
	return egg
end

-- ============================================================== claiming
local function handleClaim(player: Player)
	local egg = current
	if not egg or egg.Claimed then
		return false, "GONE", "The lucky egg is gone."
	end
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local slack = 0
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. player.UserId)
	if model then
		slack = (model:GetAttribute("BodyRadius") or 0) * 0.5
	end
	local reach = EggReach.range(data, WildEggConfig.PickupRange) + slack
	if Services.EggService.DistanceTo(player, egg.Position) > reach then
		return false, "TOO_FAR"
	end
	local ok, id, inHand = Services.EggService.GiveEgg(player, egg.Egg, egg.Luck)
	if not ok then
		if id == "EGG_STORAGE_FULL" then
			return false, id, "Your egg bag is full! Make room - the lucky egg is waiting."
		end
		return false, id
	end
	egg.Claimed = true
	Net.broadcast("WildEggClaimed", { Id = egg.Id, Player = player.DisplayName, Name = egg.Tier.Name, Luck = egg.Luck })
	WildEggService.Claimed:Fire(player, egg)
	remove(egg, "claimed")
	return true, { Id = id, Type = egg.Egg, Luck = egg.Luck, Held = inHand, Name = egg.Tier.Name }
end

-- A client that starts late (or restarts its controller) asks what is going on.
local function handleSync()
	if current and not current.Claimed then
		return true, { Current = payloadOf(current) }
	end
	return true, {}
end

-- ============================================================== lifecycle
function WildEggService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("WildEgg", "Claim", handleClaim, { Burst = 4, PerSecond = 2 })
	Net.handle("WildEgg", "Sync", handleSync, { Burst = 3, PerSecond = 1 })
end

function WildEggService.Start()
	-- players who join while an egg is out get the announcement too
	Data.Loaded:Connect(function(player)
		if current and not current.Claimed then
			Net.signal(player, "WildEggSpawn", payloadOf(current))
		end
	end)
	task.spawn(function()
		while not Workspace:GetAttribute("WorldReady") do
			task.wait(0.5)
		end
		local d = WildEggConfig.FirstDelay
		task.wait(rng:NextNumber(d.Min, d.Max))
		while true do
			-- (tests and tools can switch the automatic spawns off)
			if #Players:GetPlayers() > 0 and not ReplicatedStorage:GetAttribute("DevDisableWildEggs") then
				pcall(WildEggService.Spawn)
			end
			local i = WildEggConfig.Interval
			task.wait(rng:NextNumber(i.Min, i.Max))
		end
	end)
end

return WildEggService

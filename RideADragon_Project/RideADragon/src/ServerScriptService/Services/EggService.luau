--[[
	EggService
	Personal dragon eggs: every player has their own eggs scattered around
	the world's egg areas (Workspace.World.EggSpots). Picking one up stores it
	in the player's egg bag (data.Eggs, capacity = Egg Storage upgrade).
	Eggs are incubated in the sanctuary nest (data.Incubator slots, timed) and
	hatched there into dragons (luck-weighted roll + mutation roll).

	Server authority: spawn positions, pickup range, capacity, incubation
	timers, hatch results and prices are all decided here.

	The egg you pick up is carried IN YOUR HAND (one at a time, the rest stay in the
	bag): player attributes HeldEggId / HeldEggType / HeldEggLuck replicate it so every
	client can draw it in the character's hand. You walk to your nest and put it in the
	nest spot you like - the server only checks range, slot and ownership.

	Net (domain "Egg"):
	  Pickup { Key }            -> { Id, Type, Luck, Held }
	  Hold   { Id? | Best? }    -> { Id }   (Id: take that egg in hand, Best: the best egg,
	                                         neither: put the egg back in the bag)
	  Place  { Id?, Slot? }     -> { Slot, Ready, Next }  (Id defaults to the egg in hand)
	  Hatch  { Slot }           -> { Dragon = record, New = bool, Egg = type }
	  BuyIncubator { Slot }     -> { Unlocked }
	Signals to the owner: "Eggs" { List }, "EggAdded" egg, "EggRemoved" { Key }

	Robux items use EggService.GiveEgg(.., force) (the bag may overflow - paid eggs are never
	lost) and EggService.SpawnBonusEggs (Lucky Egg Call: lucky eggs near the player for a while).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))
local HatchConfig = require(Configs:WaitForChild("HatchConfig"))
local WildEggConfig = require(Configs:WaitForChild("WildEggConfig"))
local EggReach = require(Shared:WaitForChild("EggReach"))

local EggService = {}
EggService.PickedUp = Signal.new() -- (player, eggType)
EggService.Hatched = Signal.new() -- (player, record, eggType)

local Data
local Services
local areas: { any } = {} -- { Name, Position, Region, Label?, Radius?, Island? }
local extraAreas: { any } = {} -- areas added by other services (sky islands): they survive a reload
local areasLoaded = false -- the fixed areas of the world are in (eggs are only spawned after that)
local states: { [Player]: any } = {}
local rng = Random.new()

local function now(): number
	return os.time()
end

-- ============================================================== spawn areas
local function loadAreas()
	local world = Workspace:WaitForChild("World", 120)
	local folder = world and world:WaitForChild("EggSpots", 120)
	if not folder then
		warn("[Eggs] no EggSpots in the world")
		return
	end
	table.clear(areas)
	for _, p in folder:GetChildren() do
		if p:IsA("BasePart") then
			local name = p:GetAttribute("Area") or "Area"
			local region = p:GetAttribute("Region") or EggConfig.AreaRegion[name] or "Haven"
			table.insert(areas, { Name = name, Position = p.Position, Region = region })
		end
	end
	for _, a in extraAreas do
		table.insert(areas, a)
	end
	areasLoaded = true
end

-- Eggs rest on the terrain (not in water) or on a part marked EggSurface (the plate of a sky island).
local function eggGround(hit): boolean
	if not hit or hit.Normal.Y <= 0.6 then
		return false
	end
	if hit.Instance == Workspace.Terrain then
		return hit.Material ~= Enum.Material.Water
	end
	return hit.Instance:GetAttribute("EggSurface") == true
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

-- Finds a resting spot near an area centre (on terrain, not water/buildings).
local function findSpot(area): Vector3?
	local exclude = {}
	local world = Workspace:FindFirstChild("World")
	local nature = world and world:FindFirstChild("Nature")
	if nature then
		table.insert(exclude, nature)
	end
	local eggSpots = world and world:FindFirstChild("EggSpots")
	if eggSpots then
		table.insert(exclude, eggSpots)
	end
	local dragons = Workspace:FindFirstChild("Dragons")
	if dragons then
		table.insert(exclude, dragons)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
	local radius = area.Radius or (area.Name == "Pillar" and 8 or EggConfig.Spawning.ScatterRadius)
	for _ = 1, 8 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = math.sqrt(rng:NextNumber()) * radius
		local x = area.Position.X + math.cos(a) * r
		local z = area.Position.Z + math.sin(a) * r
		local origin = Vector3.new(x, area.Position.Y + 160, z)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -400, 0), rayParams)
		if eggGround(hit) then
			return hit.Position + Vector3.new(0, 2.6, 0)
		end
	end
	return nil
end

-- A completely random resting spot on the land (not near any fixed area). Returns the spot and an
-- "area" record named after the nearest real area (it gives the label and the region of the egg).
-- `avoid` = a point the spot must keep RoamMinSeparation away from.
local function randomSpot(avoid: Vector3?): (Vector3?, any?)
	if #areas == 0 then
		return nil, nil
	end
	-- a share of the roaming eggs lands on a sky island (its own area: rare luck, its region's eggs)
	local islands = {}
	for _, a in areas do
		if a.Island then
			table.insert(islands, a)
		end
	end
	if #islands > 0 and rng:NextNumber() < EggConfig.Spawning.IslandShare then
		for _ = 1, 8 do
			local isle = islands[rng:NextInteger(1, #islands)]
			local spot = findSpot({ Name = isle.Name, Position = isle.Position, Radius = isle.Radius * EggConfig.Spawning.IslandInset / 0.78 })
			if spot and (not avoid or (Vector2.new(spot.X, spot.Z) - Vector2.new(avoid.X, avoid.Z)).Magnitude >= 40) then
				return spot, isle
			end
		end
	end
	local box = EggConfig.Spawning.WorldBox
	local skip = {}
	for _, n in EggConfig.Spawning.RoamAvoid do
		skip[n] = true
	end
	local exclude = {}
	local world = Workspace:FindFirstChild("World")
	for _, name in { "Nature", "EggSpots" } do
		local folder = world and world:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	for _, name in { "Dragons", "MyEggs", "HeldEggs" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
	for _ = 1, 24 do
		local x = rng:NextNumber(box.MinX, box.MaxX)
		local z = rng:NextNumber(box.MinZ, box.MaxZ)
		if not avoid or (Vector2.new(x, z) - Vector2.new(avoid.X, avoid.Z)).Magnitude >= EggConfig.Spawning.RoamMinSeparation then
			local hit = Workspace:Raycast(Vector3.new(x, 520, z), Vector3.new(0, -900, 0), rayParams)
			if eggGround(hit) then
				local nearest, best = nil, math.huge
				for _, a in areas do
					if not skip[a.Name] then
						local d = (Vector2.new(a.Position.X, a.Position.Z) - Vector2.new(x, z)).Magnitude
						if d < best then
							nearest, best = a, d
						end
					end
				end
				if nearest then
					return hit.Position + Vector3.new(0, 2.6, 0), { Name = nearest.Name, Position = hit.Position, Region = nearest.Region, Roaming = true }
				end
			end
		end
	end
	return nil, nil
end

local function eggTypeFor(area): string
	return EggConfig.rollEgg(area.Region or "Haven", rng)
end

local function serialize(egg)
	return { Key = egg.Key, Type = egg.Type, Position = egg.Position, Area = egg.Area, Luck = egg.Luck }
end

local function spawnOne(player: Player): boolean
	local st = states[player]
	if not st or #areas == 0 then
		return false
	end
	local area, pos
	if rng:NextNumber() < EggConfig.Spawning.RoamingShare then
		-- a random place anywhere on the land
		pos, area = randomSpot()
	end
	if not pos then
		-- around a named area; prefer areas without an active egg of this player
		local used = {}
		for _, e in st.Active do
			used[e.Area] = (used[e.Area] or 0) + 1
		end
		local candidates = {}
		for _, a in areas do
			if (used[a.Name] or 0) == 0 then
				table.insert(candidates, a)
			end
		end
		if #candidates == 0 then
			candidates = areas
		end
		area = candidates[rng:NextInteger(1, #candidates)]
		pos = findSpot(area)
	end
	if not pos or not area then
		return false
	end
	st.Serial += 1
	local eggType = eggTypeFor(area)
	local luck = EggConfig.rollLuck(eggType, rng, EggConfig.RareAreas[area.Name] == true and not area.Roaming)
	-- Great Tree "Lucky Finds": eggs you find carry more luck
	luck = math.max(1, math.floor(luck * (1 + TreeConfig.bonus(Data.Get(player), "FindLuck")) + 0.5))
	local egg = { Key = "k" .. st.Serial, Type = eggType, Position = pos, Area = area.Name, Luck = luck }
	st.Active[egg.Key] = egg
	Net.signal(player, "EggAdded", serialize(egg))
	return true
end

-- Eggs of the normal respawn cycle (bonus eggs from Robux items do not count).
local function activeCount(st): number
	local n = 0
	for _, e in st.Active do
		if not e.Bonus then
			n += 1
		end
	end
	return n
end

local function fillEggs(player: Player)
	local st = states[player]
	if not st then
		return
	end
	local tries = 0
	while activeCount(st) < EggConfig.Spawning.MaxActive and tries < 40 do
		tries += 1
		spawnOne(player)
	end
end

local function scheduleRespawn(player: Player)
	local delayS = rng:NextNumber(EggConfig.Spawning.RespawnMin, EggConfig.Spawning.RespawnMax)
	-- Great Tree "Fertile Soil": new eggs appear sooner
	delayS *= 1 - math.clamp(TreeConfig.bonus(Data.Get(player), "EggRespawn"), 0, 0.9)
	task.delay(delayS, function()
		if states[player] then
			fillEggs(player)
		end
	end)
end

-- ============================================================== announcements
-- An ultra-rare hatch ("1 in 25,000" or rarer) is announced to the whole server once the
-- hatcher's reveal is over (client banner, AnnounceController).
function EggService.announceHatch(player: Player, record, odds: number)
	local cfg = HatchConfig.Announce
	if odds < cfg.MinOdds then
		return false
	end
	local payload = {
		Player = player.DisplayName,
		UserId = player.UserId,
		Species = record.SpeciesId,
		Mutation = record.Mutation or "None",
		Rarity = record.Rarity,
		Odds = odds,
		Mega = odds >= cfg.Mega,
	}
	task.delay(cfg.Delay, function()
		Net.broadcast("RareHatch", payload)
	end)
	return true
end

-- ============================================================== helpers
local function capacity(data): number
	return TreeConfig.eggCapacity(data)
end

-- Player position for range checks: the ridden dragon root, else the HRP.
local function playerPositions(player: Player): { Vector3 }
	local out = {}
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		table.insert(out, hrp.Position)
	end
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. player.UserId)
	local root = model and model:FindFirstChild("Root") :: BasePart?
	if root then
		table.insert(out, root.Position)
	end
	return out
end

local function nearestDistance(player: Player, target: Vector3): number
	local best = math.huge
	for _, p in playerPositions(player) do
		best = math.min(best, (p - target).Magnitude)
	end
	return best
end

local function nestPart(player: Player): BasePart?
	local sanct = Services.SanctuaryService
	local plot = sanct and sanct.GetPlot(player)
	local nest = plot and plot:FindFirstChild("Nest", true)
	return nest and nest:IsA("BasePart") and nest or nil
end

local function rollSpecies(eggType: string, luck: number): string
	local odds = EggConfig.oddsFor(eggType, luck, function(id)
		local sp = DragonConfig.Species[id]
		return sp and DragonConfig.rarityRank(sp.Rarity) or 0
	end)
	local r = rng:NextNumber()
	local acc = 0
	for _, e in odds do
		acc += e.P
		if r <= acc then
			return e.Id
		end
	end
	return odds[#odds].Id
end

local function rollMutation(luckMult: number?): string
	-- rarest first so a lucky roll keeps the best mutation
	local k = math.max(1, luckMult or 1)
	for i = #MutationConfig.Order, 2, -1 do
		local id = MutationConfig.Order[i]
		local m = MutationConfig.Mutations[id]
		if m and m.HatchChance > 0 and rng:NextNumber() < m.HatchChance * k then
			return id
		end
	end
	return "None"
end

local function rankOf(id: string): number
	local sp = DragonConfig.Species[id]
	return sp and DragonConfig.rarityRank(sp.Rarity) or 0
end

-- Probability of this exact result ("1 in N" title of the hatched dragon).
local function resultOdds(eggType: string, luck: number, luckMult: number, species: string, mutation: string): number
	local pSpecies = 0
	for _, e in EggConfig.oddsFor(eggType, luck, rankOf) do
		if e.Id == species then
			pSpecies = e.P
		end
	end
	local k = math.max(1, luckMult)
	local pMutation
	if mutation == "None" then
		local miss = 1
		for i = 2, #MutationConfig.Order do
			local m = MutationConfig.Mutations[MutationConfig.Order[i]]
			miss *= 1 - math.min(1, (m.HatchChance or 0) * k)
		end
		pMutation = miss
	else
		local m = MutationConfig.Mutations[mutation]
		pMutation = math.min(1, (m and m.HatchChance or 1) * k)
	end
	local p = pSpecies * pMutation
	if p <= 0 then
		return 0
	end
	return math.max(1, math.floor(1 / p + 0.5))
end
EggService.resultOdds = resultOdds

-- ============================================================== held egg
-- Best carried egg = highest tier, then highest luck.
local function bestIndex(data): number?
	local index, bestScore = nil, -1
	for i, e in data.Eggs do
		local tier = EggConfig.Eggs[e.Type] and EggConfig.Eggs[e.Type].Tier or 0
		local score = tier * 100000 + math.min(99999, tonumber(e.Luck) or 1)
		if score > bestScore then
			index, bestScore = i, score
		end
	end
	return index
end

-- Id of the egg in the player's hand (nil = empty hand).
function EggService.Held(player: Player): string?
	local id = player:GetAttribute("HeldEggId")
	return type(id) == "string" and id ~= "" and id or nil
end

local function clearHeld(player: Player)
	player:SetAttribute("HeldEggId", nil)
	player:SetAttribute("HeldEggType", nil)
	player:SetAttribute("HeldEggLuck", nil)
end

-- id = nil puts the egg back in the bag. false when that egg is not in the bag.
function EggService.SetHeld(player: Player, id: string?): boolean
	if not id then
		clearHeld(player)
		return true
	end
	local data = Data.Get(player)
	for _, e in data and data.Eggs or {} do
		if e.Id == id then
			player:SetAttribute("HeldEggId", e.Id)
			player:SetAttribute("HeldEggType", e.Type)
			player:SetAttribute("HeldEggLuck", math.max(1, tonumber(e.Luck) or 1))
			return true
		end
	end
	return false
end

-- Drops a held egg that left the bag some other way (spent, traded, reset...).
local function reconcileHeld(player: Player)
	local id = EggService.Held(player)
	if not id then
		return
	end
	local data = Data.Get(player)
	for _, e in data and data.Eggs or {} do
		if e.Id == id then
			return
		end
	end
	clearHeld(player)
end

-- ============================================================== giving eggs
-- Puts a new egg in the player's bag (capacity checked) and - when the hand is free - in
-- the hand. Used by pickups and by world events (Lucky Wild Eggs).
-- `force` (paid items) lets the bag overflow instead of refusing.
-- Returns ok, id | errorCode, inHand
function EggService.GiveEgg(player: Player, eggType: string, luck: number?, force: boolean?): (boolean, string, boolean?)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	if not EggConfig.Eggs[eggType] then
		return false, "BAD_EGG"
	end
	if #data.Eggs >= capacity(data) and not force then
		return false, "EGG_STORAGE_FULL"
	end
	local id = Data.NextId(player, "EggSerial", "E")
	local list = table.clone(data.Eggs)
	table.insert(list, { Id = id, Type = eggType, Found = now(), Luck = math.max(1, math.floor(tonumber(luck) or 1)) })
	Data.Set(player, { "Eggs" }, list)
	Data.Increment(player, { "Stats", "EggsFound" }, 1)
	EggService.PickedUp:Fire(player, eggType)
	-- hands free: the egg goes straight into your hand (otherwise into the bag)
	local inHand = EggService.Held(player) == nil
	if inHand then
		EggService.SetHeld(player, id)
	end
	return true, id, inHand
end

-- Distance from the player (character or ridden dragon, whichever is closer) to a point.
function EggService.DistanceTo(player: Player, position: Vector3): number
	return nearestDistance(player, position)
end

-- World egg areas (positions + regions) and a resting spot inside one - for events.
function EggService.Areas()
	return areas
end

function EggService.FindSpot(area): Vector3?
	return findSpot(area)
end

-- Adds an egg area from another service (a sky island): { Name, Label?, Position, Region, Radius?, Island? }.
-- Kept across a reload of the world areas, so the order of the services does not matter.
function EggService.AddArea(area)
	table.insert(extraAreas, area)
	if areasLoaded then
		table.insert(areas, area)
	end
end

-- A completely random spot on the land + an area record for it (see randomSpot).
function EggService.RandomSpot(avoid: Vector3?): (Vector3?, any?)
	return randomSpot(avoid)
end

-- Resting spot on the terrain around a point (for eggs that appear next to the player).
local function findSpotNear(center: Vector3, minRadius: number, maxRadius: number): Vector3?
	local exclude = {}
	local world = Workspace:FindFirstChild("World")
	for _, name in { "Nature", "EggSpots" } do
		local folder = world and world:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	for _, name in { "Dragons", "MyEggs", "HeldEggs" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
	for _ = 1, 14 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(minRadius, maxRadius)
		local x = center.X + math.cos(a) * r
		local z = center.Z + math.sin(a) * r
		local hit = Workspace:Raycast(Vector3.new(x, center.Y + 180, z), Vector3.new(0, -600, 0), rayParams)
		if hit and hit.Instance == Workspace.Terrain and hit.Material ~= Enum.Material.Water and hit.Normal.Y > 0.6 then
			return hit.Position + Vector3.new(0, 2.6, 0)
		end
	end
	return nil
end

-- Lucky Egg Call (Robux): `count` very lucky eggs appear around the player - only they can see and
-- take them - and vanish after `lifetime` seconds. luckRange = { min, max }. Returns how many appeared.
function EggService.SpawnBonusEggs(player: Player, count: number, luckRange: { number }?, lifetime: number?): number
	local st = states[player]
	if not st then
		return 0
	end
	local positions = playerPositions(player)
	local center = positions[1]
	if not center then
		return 0
	end
	local epic = WildEggConfig.ById.Epic
	local range = luckRange or { 25, 100 }
	local spawned = 0
	local stay = lifetime or 300
	for _ = 1, count do
		local pos = findSpotNear(center, 22, 70)
		if pos then
			st.Serial += 1
			local egg = {
				Key = "b" .. st.Serial,
				Type = epic.Eggs[rng:NextInteger(1, #epic.Eggs)],
				Position = pos,
				Area = "Lucky Call",
				Luck = rng:NextInteger(math.floor(range[1]), math.floor(range[2])),
				Bonus = true,
			}
			st.Active[egg.Key] = egg
			Net.signal(player, "EggAdded", serialize(egg))
			spawned += 1
			local key = egg.Key
			task.delay(stay, function()
				if states[player] == st and st.Active[key] then
					st.Active[key] = nil
					Net.signal(player, "EggRemoved", { Key = key })
				end
			end)
		end
	end
	return spawned
end

-- ============================================================== handlers
local function handlePickup(player: Player, p)
	if not Net.check.str(p.Key, 16) then
		return false, "BAD_REQUEST"
	end
	local st = states[player]
	local data = Data.Get(player)
	if not st or not data then
		return false, "NOT_LOADED"
	end
	local egg = st.Active[p.Key]
	if not egg then
		return false, "GONE"
	end
	local slack = 0
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. player.UserId)
	if model then
		slack = (model:GetAttribute("BodyRadius") or 0) * 0.5
	end
	local reach = EggReach.range(data, GameConfig.Interaction.EggPickupServerRange)
	if nearestDistance(player, egg.Position) > reach + slack then
		return false, "TOO_FAR"
	end
	if #data.Eggs >= capacity(data) then
		return false, "EGG_STORAGE_FULL", "Your egg bag is full! Hatch eggs at your sanctuary nest or upgrade Egg Storage."
	end
	st.Active[p.Key] = nil
	Net.signal(player, "EggRemoved", { Key = p.Key })
	local ok, id, inHand = EggService.GiveEgg(player, egg.Type, egg.Luck or 1)
	if not ok then
		return false, id
	end
	scheduleRespawn(player)
	return true, { Id = id, Type = egg.Type, Luck = egg.Luck or 1, Held = inHand }
end

local function freeSlot(data): number?
	for i = 1, data.Incubator.Unlocked do
		if data.Incubator.Slots[tostring(i)] == nil then
			return i
		end
	end
	return nil
end

local function handlePlace(player: Player, p)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local nest = nestPart(player)
	if not nest then
		return false, "NO_SANCTUARY"
	end
	if nearestDistance(player, nest.Position) > GameConfig.Interaction.NestServerRange + 20 then
		return false, "TOO_FAR", "Go to your sanctuary nest to incubate eggs."
	end
	if #data.Eggs == 0 then
		return false, "NO_EGGS", "You have no eggs. Find them around Dragon Haven!"
	end
	-- egg: the requested id, else the one in hand, else the best carried egg
	local index = nil
	local wantId = p.Id
	if wantId ~= nil and not Net.check.str(wantId, 20) then
		return false, "BAD_REQUEST"
	end
	if wantId == nil then
		wantId = EggService.Held(player)
	end
	if wantId ~= nil then
		for i, e in data.Eggs do
			if e.Id == wantId then
				index = i
				break
			end
		end
	end
	if not index and p.Id == nil then
		index = bestIndex(data)
	end
	if not index then
		return false, "NOT_FOUND"
	end
	local slot = nil
	if p.Slot ~= nil then
		if not Net.check.int(p.Slot, 1, #EggConfig.IncubatorPrices) then
			return false, "BAD_REQUEST"
		end
		if p.Slot > data.Incubator.Unlocked or data.Incubator.Slots[tostring(p.Slot)] then
			return false, "SLOT_BUSY", "That nest spot is not free."
		end
		slot = p.Slot
	else
		slot = freeSlot(data)
	end
	if not slot then
		return false, "NEST_FULL", "Your nest is full. Hatch the ready eggs first!"
	end
	local egg = data.Eggs[index]
	local def = EggConfig.Eggs[egg.Type]
	if not def then
		return false, "BAD_EGG"
	end
	local list = table.clone(data.Eggs)
	table.remove(list, index)
	Data.Set(player, { "Eggs" }, list)
	local t = now()
	local hatchTime = def.HatchTime
	local tree = Services.TreeService
	if tree and tree.Bonus then
		hatchTime = hatchTime * (1 - tree.Bonus(player, "HatchSpeed"))
	end
	-- Fast Hatch potion: the nest works faster while it runs
	hatchTime = math.max(3, math.floor(hatchTime * EggReach.hatchFactor(data, now()) + 0.5))
	Data.Set(player, { "Incubator", "Slots", tostring(slot) }, { Type = egg.Type, Start = t, Ready = t + hatchTime, Id = egg.Id, Luck = egg.Luck or 1 })
	-- the hand is empty now; while nest spots remain, the next egg of the bag is taken
	-- in hand so several eggs can be placed one after another
	local nextId = nil
	if EggService.Held(player) == egg.Id then
		clearHeld(player)
		local nextIndex = freeSlot(data) and bestIndex(data)
		if nextIndex then
			nextId = data.Eggs[nextIndex].Id
			EggService.SetHeld(player, nextId)
		end
	end
	return true, { Slot = slot, Ready = t + hatchTime, Next = nextId }
end

local function handleHold(player: Player, p)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	if p.Id ~= nil then
		if not Net.check.str(p.Id, 20) then
			return false, "BAD_REQUEST"
		end
		if not EggService.SetHeld(player, p.Id) then
			return false, "NOT_FOUND"
		end
		return true, { Id = p.Id }
	end
	if p.Best == true then
		local index = bestIndex(data)
		if not index then
			return false, "NO_EGGS", "You have no eggs. Find them around Dragon Haven!"
		end
		EggService.SetHeld(player, data.Eggs[index].Id)
		return true, { Id = data.Eggs[index].Id }
	end
	clearHeld(player)
	return true, {}
end

local function handleHatch(player: Player, p)
	if not Net.check.int(p.Slot, 1, #EggConfig.IncubatorPrices) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local key = tostring(p.Slot)
	local slot = data.Incubator.Slots[key]
	if not slot then
		return false, "EMPTY"
	end
	if now() < slot.Ready then
		return false, "NOT_READY", "This egg is still warming up."
	end
	local nest = nestPart(player)
	if nest and nearestDistance(player, nest.Position) > GameConfig.Interaction.NestServerRange + 40 then
		return false, "TOO_FAR", "Go to your sanctuary to hatch it."
	end
	local services = Services
	local dragonService = services.DragonService
	-- luck: Forge upgrade (+%), multiplied by potions / Owner Dragon pass
	local boosts = services.BoostService
	local eggLuck = math.max(1, tonumber(slot.Luck) or 1)
	local luckMult = (boosts and boosts.LuckMultiplier(player) or 1) * eggLuck
	local mutationMult = luckMult
	local tree = services.TreeService
	if tree and tree.Bonus then
		mutationMult *= 1 + tree.Bonus(player, "MutationLuck")
	end
	local luck = (1 + EconomyConfig.upgradeValue("HatchLuck", data.Upgrades.HatchLuck or 0)) * luckMult - 1
	local species = rollSpecies(slot.Type, luck)
	local mutation = rollMutation(mutationMult)
	local eggDef = EggConfig.Eggs[slot.Type]
	if mutation == "None" and eggDef and eggDef.GuaranteedMutation then
		-- Rainbow eggs always hatch mutated (weighted like the Mutate action)
		local total = 0
		for _, e in MutationConfig.MutateWeights do
			total += e.Weight
		end
		local r = rng:NextNumber() * total
		for _, e in MutationConfig.MutateWeights do
			r -= e.Weight
			if r <= 0 then
				mutation = e.Id
				break
			end
		end
	end
	local isNew = data.Index[species] == nil
	local record, err = dragonService.Add(player, species, mutation, "Hatch")
	if not record then
		if err == "STORAGE_FULL" then
			return false, err, "Your dragon storage is full! Release a dragon or upgrade Dragon Storage."
		end
		return false, err or "FAILED"
	end
	-- "1 in N" title: the result's base odds from this egg (luck makes it likelier, not less rare)
	local odds = resultOdds(slot.Type, 0, 1, species, mutation)
	if odds > 0 then
		record = table.clone(record)
		record.Odds = odds
		Data.Set(player, { "Dragons", record.UniqueId, "Odds" }, odds)
	end
	Data.Set(player, { "Incubator", "Slots", key }, nil)
	EggService.Hatched:Fire(player, record, slot.Type)
	EggService.announceHatch(player, record, odds)
	return true, { Dragon = record, New = isNew, Egg = slot.Type, Luck = eggLuck }
end

local function handleBuyIncubator(player: Player, p)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local slot = data.Incubator.Unlocked + 1
	if p.Slot ~= nil and p.Slot ~= slot then
		return false, "BAD_REQUEST"
	end
	local price = EggConfig.IncubatorPrices[slot]
	if not price then
		return false, "MAXED", "Your nest is fully expanded."
	end
	if not Services.EconomyService.Spend(player, price, "Incubator") then
		return false, "NOT_ENOUGH_CASH", "You need more coins."
	end
	Data.Set(player, { "Incubator", "Unlocked" }, slot)
	return true, { Unlocked = slot }
end

-- ============================================================== lifecycle
local function onLoaded(player: Player)
	if states[player] then
		return
	end
	states[player] = { Active = {}, Serial = 0 }
	task.spawn(function()
		while not areasLoaded and player.Parent == Players do
			task.wait(0.5)
		end
		fillEggs(player)
		local list = {}
		for _, e in states[player] and states[player].Active or {} do
			table.insert(list, serialize(e))
		end
		Net.signal(player, "Eggs", { List = list })
	end)
end

function EggService.GetActive(player: Player)
	local st = states[player]
	return st and st.Active or {}
end

-- Client asks for a full resync (e.g. after its controller restarts).
local function handleSync(player: Player)
	local st = states[player]
	if not st then
		return false, "NOT_LOADED"
	end
	local list = {}
	for _, e in st.Active do
		table.insert(list, serialize(e))
	end
	return true, { List = list }
end

function EggService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Egg", "Pickup", handlePickup, { Burst = 10, PerSecond = 6 })
	Net.handle("Egg", "Place", handlePlace, { Burst = 6, PerSecond = 3 })
	Net.handle("Egg", "Hold", handleHold, { Burst = 8, PerSecond = 4 })
	Net.handle("Egg", "Hatch", handleHatch, { Burst = 4, PerSecond = 2 })
	Net.handle("Egg", "BuyIncubator", handleBuyIncubator, { Burst = 3, PerSecond = 1 })
	Net.handle("Egg", "Sync", handleSync, { Burst = 3, PerSecond = 1 })
end

function EggService.Start()
	task.spawn(function()
		while not Workspace:GetAttribute("WorldReady") do
			task.wait(0.25)
		end
		loadAreas()
	end)
	Data.Loaded:Connect(function(player)
		onLoaded(player)
	end)
	for _, player in Players:GetPlayers() do
		if Data.IsLoaded(player) then
			onLoaded(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				pcall(reconcileHeld, player)
			end
		end
	end)
end

return EggService

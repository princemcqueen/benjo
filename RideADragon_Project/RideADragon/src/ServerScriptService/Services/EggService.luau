--[[
	EggService
	Personal dragon eggs: every player has their own eggs scattered around
	the world's egg areas (Workspace.World.EggSpots). Picking one up stores it
	in the player's egg bag (data.Eggs, capacity = Egg Storage upgrade).
	Eggs are incubated in the sanctuary nest (data.Incubator slots, timed) and
	hatched there into dragons (luck-weighted roll + mutation roll).

	Server authority: spawn positions, pickup range, capacity, incubation
	timers, hatch results and prices are all decided here.

	Net (domain "Egg"):
	  Pickup { Key }            -> { Id, Type }
	  Place  { Id?, Slot? }     -> { Slot, Ready }
	  Hatch  { Slot }           -> { Dragon = record, New = bool, Egg = type }
	  BuyIncubator { Slot }     -> { Unlocked }
	Signals to the owner: "Eggs" { List }, "EggAdded" egg, "EggRemoved" { Key }
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

local EggService = {}
EggService.PickedUp = Signal.new() -- (player, eggType)
EggService.Hatched = Signal.new() -- (player, record, eggType)

local Data
local Services
local areas: { { Name: string, Position: Vector3, Region: string } } = {}
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
	local radius = area.Name == "Pillar" and 8 or EggConfig.Spawning.ScatterRadius
	for _ = 1, 8 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = math.sqrt(rng:NextNumber()) * radius
		local x = area.Position.X + math.cos(a) * r
		local z = area.Position.Z + math.sin(a) * r
		local origin = Vector3.new(x, area.Position.Y + 160, z)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -400, 0), rayParams)
		if hit and hit.Instance == Workspace.Terrain and hit.Material ~= Enum.Material.Water and hit.Normal.Y > 0.6 then
			return hit.Position + Vector3.new(0, 2.6, 0)
		end
	end
	return nil
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
	-- prefer areas without an active egg of this player
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
	local area = candidates[rng:NextInteger(1, #candidates)]
	local pos = findSpot(area)
	if not pos then
		return false
	end
	st.Serial += 1
	local eggType = eggTypeFor(area)
	local luck = EggConfig.rollLuck(eggType, rng, EggConfig.RareAreas[area.Name] == true)
	local egg = { Key = "k" .. st.Serial, Type = eggType, Position = pos, Area = area.Name, Luck = luck }
	st.Active[egg.Key] = egg
	Net.signal(player, "EggAdded", serialize(egg))
	return true
end

local function activeCount(st): number
	local n = 0
	for _ in st.Active do
		n += 1
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
	task.delay(delayS, function()
		if states[player] then
			fillEggs(player)
		end
	end)
end

-- ============================================================== helpers
local function capacity(data): number
	return EconomyConfig.upgradeValue("EggStorage", data.Upgrades.EggStorage or 0)
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
	if nearestDistance(player, egg.Position) > GameConfig.Interaction.EggPickupServerRange + slack then
		return false, "TOO_FAR"
	end
	if #data.Eggs >= capacity(data) then
		return false, "EGG_STORAGE_FULL", "Your egg bag is full! Hatch eggs at your sanctuary nest or upgrade Egg Storage."
	end
	st.Active[p.Key] = nil
	Net.signal(player, "EggRemoved", { Key = p.Key })
	local id = Data.NextId(player, "EggSerial", "E")
	local list = table.clone(data.Eggs)
	table.insert(list, { Id = id, Type = egg.Type, Found = now(), Luck = egg.Luck or 1 })
	Data.Set(player, { "Eggs" }, list)
	Data.Increment(player, { "Stats", "EggsFound" }, 1)
	EggService.PickedUp:Fire(player, egg.Type)
	scheduleRespawn(player)
	return true, { Id = id, Type = egg.Type, Luck = egg.Luck or 1 }
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
	-- egg: requested id or the best (highest tier) carried egg
	local index = nil
	if p.Id ~= nil then
		if not Net.check.str(p.Id, 20) then
			return false, "BAD_REQUEST"
		end
		for i, e in data.Eggs do
			if e.Id == p.Id then
				index = i
				break
			end
		end
	else
		-- best = highest tier, then highest luck
		local bestScore = -1
		for i, e in data.Eggs do
			local tier = EggConfig.Eggs[e.Type] and EggConfig.Eggs[e.Type].Tier or 0
			local score = tier * 100000 + math.min(99999, tonumber(e.Luck) or 1)
			if score > bestScore then
				index, bestScore = i, score
			end
		end
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
		hatchTime = math.max(3, math.floor(hatchTime * (1 - tree.Bonus(player, "HatchSpeed")) + 0.5))
	end
	Data.Set(player, { "Incubator", "Slots", tostring(slot) }, { Type = egg.Type, Start = t, Ready = t + hatchTime, Id = egg.Id, Luck = egg.Luck or 1 })
	return true, { Slot = slot, Ready = t + hatchTime }
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
		while #areas == 0 and player.Parent == Players do
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
end

return EggService

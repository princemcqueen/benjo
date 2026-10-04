--[[
	DragonService
	Authoritative dragon inventory. Every dragon is a record with a unique id
	(see DragonStats.newRecord). Clients only send ids (and perch numbers);
	all validation, stats and costs are computed here.

	API (server):
	  DragonService.Add(player, speciesId, mutation?, source?) -> record?, err?
	  DragonService.Remove(player, uid) -> boolean
	  DragonService.Get(player, uid) -> record?
	  DragonService.Count(player), DragonService.Capacity(player)
	  DragonService.Equip(player, uid) -> ok, err
	Signals: Added(player, record), Removed(player, uid),
	         EquippedChanged(player, uid), PlacedChanged(player)

	Net (domain "Dragon"):
	  Equip { Id }            Unequip {}
	  Lock { Id, Locked }     Release { Id }            -> { Refund }
	  Feed { Id }             -> { Levels, Level, Cost }
	  Mutate { Id }           -> { Improved, Mutation, Cost }
	  Place { Id, Slot? }     -> { Slot, Swapped? }     (sanctuary perch)
	  TakeBack { Id }         AutoPlace {}              -> { Placed }
	  BuyPerch {}             -> { Unlocked }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local DragonStats = require(Shared:WaitForChild("DragonStats"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local DragonService = {}
DragonService.Added = Signal.new()
DragonService.Removed = Signal.new()
DragonService.EquippedChanged = Signal.new()
DragonService.PlacedChanged = Signal.new() -- (player) perches changed (place / take back / level / mutation)

local Data -- PlayerDataService
local Services

local STARTER_SPECIES = "GreenDrake"
local rng = Random.new()

local function now(): number
	return os.time()
end

local function maxPerches(): number
	return math.min(#EconomyConfig.NestPrices, WorldConfig.Sanctuary.PerchCount)
end

local function spend(player: Player, amount: number, reason: string): boolean
	return Services.EconomyService.Spend(player, amount, reason)
end

-- Is the player currently riding this dragon?
local function ridingThis(player: Player, uid: string): boolean
	local mount = Services.MountService
	if not mount or not mount.IsRiding(player) then
		return false
	end
	local comp = mount.Get(player)
	return comp ~= nil and comp.Uid == uid
end

function DragonService.Get(player: Player, uid: any)
	if type(uid) ~= "string" then
		return nil
	end
	local data = Data.Get(player)
	return data and data.Dragons[uid] or nil
end

function DragonService.Count(player: Player): number
	local data = Data.Get(player)
	if not data then
		return 0
	end
	local n = 0
	for _ in data.Dragons do
		n += 1
	end
	return n
end

-- Dragons that are not resting on a perch (can be ridden).
local function freeCount(data): number
	local n = 0
	for _, rec in data.Dragons do
		if rec.PlacedNestId == "" then
			n += 1
		end
	end
	return n
end

function DragonService.Capacity(player: Player): number
	local data = Data.Get(player)
	local level = data and data.Upgrades.DragonStorage or 0
	return EconomyConfig.upgradeValue("DragonStorage", level)
end

local function discover(player: Player, data, key: string)
	if not data.Index[key] then
		Data.Set(player, { "Index", key }, { First = now(), Count = 1 })
	else
		Data.Update(player, { "Index", key }, function(entry)
			entry = entry or { First = now(), Count = 0 }
			entry.Count = (entry.Count or 0) + 1
			return entry
		end)
	end
end

function DragonService.Add(player: Player, speciesId: string, mutation: string?, source: string?, force: boolean?)
	local data = Data.Get(player)
	if not data then
		return nil, "NOT_LOADED"
	end
	if not DragonConfig.Species[speciesId] then
		return nil, "BAD_SPECIES"
	end
	if not force and DragonService.Count(player) >= DragonService.Capacity(player) then
		return nil, "STORAGE_FULL"
	end
	local uid = Data.NextId(player, "DragonSerial", "D")
	local record = DragonStats.newRecord(uid, speciesId, mutation, now())
	Data.Set(player, { "Dragons", uid }, record)
	-- discovery index (species, and species+mutation)
	discover(player, data, speciesId)
	if mutation and mutation ~= "None" then
		discover(player, data, speciesId .. ":" .. mutation)
	end
	if source == "Hatch" then
		Data.Increment(player, { "Stats", "Hatched" }, 1)
	end
	DragonService.Added:Fire(player, record)
	return record
end

function DragonService.Remove(player: Player, uid: string): boolean
	local data = Data.Get(player)
	if not data or not data.Dragons[uid] then
		return false
	end
	if data.EquippedDragon == uid then
		Data.Set(player, { "EquippedDragon" }, "")
		DragonService.EquippedChanged:Fire(player, "")
	end
	-- free the perch it rested on
	local wasPlaced = false
	for slot, id in data.Nests.Slots do
		if id == uid then
			Data.Set(player, { "Nests", "Slots", slot }, nil)
			wasPlaced = true
		end
	end
	Data.Set(player, { "Dragons", uid }, nil)
	DragonService.Removed:Fire(player, uid)
	if wasPlaced then
		DragonService.PlacedChanged:Fire(player)
	end
	return true
end

function DragonService.Equip(player: Player, uid: string)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local record = data.Dragons[uid]
	if not record then
		return false, "NOT_FOUND"
	end
	if record.PlacedNestId ~= "" then
		return false, "PLACED", "This dragon is resting in your sanctuary. Take it back first."
	end
	if data.EquippedDragon == uid then
		return true
	end
	Data.Set(player, { "EquippedDragon" }, uid)
	DragonService.EquippedChanged:Fire(player, uid)
	return true
end

-- ============================================================== starter / equip upkeep
local function grantStarter(player: Player, data)
	if data.Flags.StarterGranted then
		return
	end
	local record = DragonService.Add(player, STARTER_SPECIES, "None", "Starter")
	if record then
		Data.Set(player, { "Flags", "StarterGranted" }, true)
		Data.Set(player, { "EquippedDragon" }, record.UniqueId)
		DragonService.EquippedChanged:Fire(player, record.UniqueId)
	end
end

-- Makes sure the equipped dragon still exists and is free; otherwise equips
-- the best free dragon so players are never stranded. Returns true when the
-- equipped dragon changed.
local function validateEquipped(player: Player, data): boolean
	local before = data.EquippedDragon
	local uid = before
	if uid ~= "" and (not data.Dragons[uid] or data.Dragons[uid].PlacedNestId ~= "") then
		uid = ""
	end
	if uid == "" then
		local best, bestScore = nil, -math.huge
		for id, rec in data.Dragons do
			if rec.PlacedNestId == "" then
				local s = DragonStats.score(rec)
				if s > bestScore then
					best, bestScore = id, s
				end
			end
		end
		uid = best or ""
	end
	if uid ~= before then
		Data.Set(player, { "EquippedDragon" }, uid)
		return true
	end
	return false
end

-- ============================================================== perches
local function setPlaced(player: Player, uid: string, slot: string)
	Data.Set(player, { "Nests", "Slots", slot }, uid)
	Data.Set(player, { "Dragons", uid, "PlacedNestId" }, slot)
end

local function clearPlaced(player: Player, uid: string)
	local data = Data.Get(player)
	local record = data.Dragons[uid]
	if not record or record.PlacedNestId == "" then
		return
	end
	local slot = record.PlacedNestId
	if data.Nests.Slots[slot] == uid then
		Data.Set(player, { "Nests", "Slots", slot }, nil)
	end
	Data.Set(player, { "Dragons", uid, "PlacedNestId" }, "")
end

local function freePerch(data): number?
	for i = 1, math.min(data.Nests.Unlocked, maxPerches()) do
		if data.Nests.Slots[tostring(i)] == nil then
			return i
		end
	end
	return nil
end

-- Places `uid` on perch `slot` (swapping out any dragon already there).
local function placeOn(player: Player, data, uid: string, slot: number): (boolean, string?, string?, any)
	local key = tostring(slot)
	local swapped = nil
	local occupant = data.Nests.Slots[key]
	if occupant and occupant ~= uid then
		clearPlaced(player, occupant)
		swapped = occupant
	end
	clearPlaced(player, uid)
	setPlaced(player, uid, key)
	if validateEquipped(player, data) then
		DragonService.EquippedChanged:Fire(player, data.EquippedDragon)
	end
	DragonService.PlacedChanged:Fire(player)
	return true, nil, nil, { Slot = slot, Swapped = swapped }
end

-- ============================================================== net handlers
local function handleEquip(player: Player, p)
	if not Net.check.str(p.Id, 40) then
		return false, "BAD_REQUEST"
	end
	return DragonService.Equip(player, p.Id)
end

local function handleUnequip(player: Player)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	if data.EquippedDragon ~= "" then
		Data.Set(player, { "EquippedDragon" }, "")
		DragonService.EquippedChanged:Fire(player, "")
	end
	return true
end

local function handleLock(player: Player, p)
	if not Net.check.str(p.Id, 40) or not Net.check.bool(p.Locked) then
		return false, "BAD_REQUEST"
	end
	local record = DragonService.Get(player, p.Id)
	if not record then
		return false, "NOT_FOUND"
	end
	Data.Set(player, { "Dragons", p.Id, "Locked" }, p.Locked)
	return true, { Locked = p.Locked }
end

local function handleRelease(player: Player, p)
	if not Net.check.str(p.Id, 40) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	local record = DragonService.Get(player, p.Id)
	if not data or not record then
		return false, "NOT_FOUND"
	end
	if record.Locked then
		return false, "LOCKED", "Unlock this dragon before releasing it."
	end
	if DragonService.Count(player) <= 1 then
		return false, "LAST_DRAGON", "You can't release your only dragon."
	end
	if record.PlacedNestId == "" and freeCount(data) <= 1 then
		return false, "KEEP_ONE", "Keep at least one dragon out of the sanctuary to ride."
	end
	if ridingThis(player, p.Id) then
		return false, "RIDING", "Dismount before releasing the dragon you are riding."
	end
	local refund = math.floor(record.IncomePerSecond * TreeConfig.refundSeconds(data) + 0.5)
	DragonService.Remove(player, p.Id)
	Data.Increment(player, { "Stats", "Released" }, 1)
	if refund > 0 then
		Services.EconomyService.Earn(player, refund, "Release")
	end
	if validateEquipped(player, Data.Get(player)) then
		DragonService.EquippedChanged:Fire(player, Data.Get(player).EquippedDragon)
	end
	return true, { Refund = refund }
end

local function handleFeed(player: Player, p)
	if not Net.check.str(p.Id, 40) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	local record = DragonService.Get(player, p.Id)
	if not data or not record then
		return false, "NOT_FOUND"
	end
	if record.Level >= DragonConfig.MaxLevel then
		return false, "MAX_LEVEL", "This dragon is fully grown."
	end
	local species = DragonConfig.Species[record.SpeciesId]
	local cost = EconomyConfig.feedCost(species.FeedCost, record.Level)
	if not spend(player, cost, "Feed") then
		return false, "NO_CASH", "Not enough cash to feed."
	end
	local copy = table.clone(record)
	local gained = DragonStats.addXP(copy, EconomyConfig.feedXP(DragonConfig.xpToNext(record.Level)))
	Data.Set(player, { "Dragons", p.Id }, copy)
	Data.Increment(player, { "Stats", "Fed" }, 1)
	if gained > 0 then
		if data.EquippedDragon == p.Id then
			DragonService.EquippedChanged:Fire(player, p.Id)
		end
		if copy.PlacedNestId ~= "" then
			DragonService.PlacedChanged:Fire(player)
		end
	end
	return true, { Levels = gained, Level = copy.Level, Cost = cost }
end

local function rollMutation(): string
	local total = 0
	for _, e in MutationConfig.MutateWeights do
		total += e.Weight
	end
	local r = rng:NextNumber() * total
	for _, e in MutationConfig.MutateWeights do
		r -= e.Weight
		if r <= 0 then
			return e.Id
		end
	end
	return MutationConfig.MutateWeights[1].Id
end

local function handleMutate(player: Player, p)
	if not Net.check.str(p.Id, 40) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	local record = DragonService.Get(player, p.Id)
	if not data or not record then
		return false, "NOT_FOUND"
	end
	local current = record.Mutation or "None"
	if MutationConfig.rank(current) >= MutationConfig.MaxRank then
		return false, "MAX_MUTATION", "This dragon already has the rarest mutation."
	end
	local species = DragonConfig.Species[record.SpeciesId]
	local cost = MutationConfig.cost(species.Income, current)
	if not spend(player, cost, "Mutate") then
		return false, "NO_CASH", "Not enough cash to mutate."
	end
	Data.Increment(player, { "Stats", "MutateTries" }, 1)
	local rolled = rollMutation()
	if MutationConfig.rank(rolled) <= MutationConfig.rank(current) then
		return true, { Improved = false, Mutation = current, Rolled = rolled, Cost = cost }
	end
	local copy = table.clone(record)
	copy.Mutation = rolled
	DragonStats.refresh(copy)
	Data.Set(player, { "Dragons", p.Id }, copy)
	discover(player, data, record.SpeciesId .. ":" .. rolled)
	if data.EquippedDragon == p.Id then
		DragonService.EquippedChanged:Fire(player, p.Id)
	end
	if copy.PlacedNestId ~= "" then
		DragonService.PlacedChanged:Fire(player)
	end
	return true, { Improved = true, Mutation = rolled, Cost = cost }
end

-- Public helpers (potions / rewards) ------------------------------------
local function commitRecord(player: Player, data, uid: string, copy)
	DragonStats.refresh(copy)
	Data.Set(player, { "Dragons", uid }, copy)
	if data.EquippedDragon == uid then
		DragonService.EquippedChanged:Fire(player, uid)
	end
	if copy.PlacedNestId ~= "" then
		DragonService.PlacedChanged:Fire(player)
	end
end

function DragonService.SetMutation(player: Player, uid: string, mutation: string): boolean
	local data = Data.Get(player)
	local record = DragonService.Get(player, uid)
	if not data or not record or not MutationConfig.Mutations[mutation] then
		return false
	end
	local copy = table.clone(record)
	copy.Mutation = mutation
	commitRecord(player, data, uid, copy)
	if mutation ~= "None" then
		discover(player, data, record.SpeciesId .. ":" .. mutation)
	end
	return true
end

function DragonService.AddLevels(player: Player, uid: string, levels: number): number
	local data = Data.Get(player)
	local record = DragonService.Get(player, uid)
	if not data or not record then
		return 0
	end
	local copy = table.clone(record)
	local before = copy.Level
	copy.Level = math.min(DragonConfig.MaxLevel, copy.Level + math.max(0, math.floor(levels)))
	copy.XP = 0
	commitRecord(player, data, uid, copy)
	return copy.Level - before
end

-- The dragon a potion applies to: the equipped one, else the best earner.
function DragonService.PotionTarget(player: Player): string?
	local data = Data.Get(player)
	if not data then
		return nil
	end
	if data.EquippedDragon ~= "" and data.Dragons[data.EquippedDragon] then
		return data.EquippedDragon
	end
	local best, bestIncome = nil, -1
	for uid, r in data.Dragons do
		if r.IncomePerSecond > bestIncome then
			best, bestIncome = uid, r.IncomePerSecond
		end
	end
	return best
end

-- One guaranteed-better mutation roll (Mutation Potion).
function DragonService.UpgradeMutation(player: Player, uid: string): string?
	local record = DragonService.Get(player, uid)
	if not record then
		return nil
	end
	local rank = MutationConfig.rank(record.Mutation)
	if rank >= MutationConfig.MaxRank then
		return nil
	end
	local total = 0
	local pool = {}
	for _, e in MutationConfig.MutateWeights do
		if MutationConfig.rank(e.Id) > rank then
			total += e.Weight
			table.insert(pool, e)
		end
	end
	local r = Random.new():NextNumber() * total
	local pick = pool[#pool].Id
	for _, e in pool do
		r -= e.Weight
		if r <= 0 then
			pick = e.Id
			break
		end
	end
	DragonService.SetMutation(player, uid, pick)
	return pick
end

local function handlePlace(player: Player, p)
	if not Net.check.str(p.Id, 40) or (p.Slot ~= nil and not Net.check.int(p.Slot, 1, maxPerches())) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	local record = DragonService.Get(player, p.Id)
	if not data or not record then
		return false, "NOT_FOUND"
	end
	local sanctuary = Services.SanctuaryService
	if sanctuary and not sanctuary.GetPlotId(player) then
		return false, "NO_PLOT", "You don't have a sanctuary in this server."
	end
	if ridingThis(player, p.Id) then
		return false, "RIDING", "Dismount before sending this dragon to rest."
	end
	local slot = p.Slot
	if slot then
		if slot > data.Nests.Unlocked then
			return false, "PERCH_LOCKED", "Unlock that perch first."
		end
		if record.PlacedNestId == tostring(slot) then
			return true, { Slot = slot }
		end
	else
		if record.PlacedNestId ~= "" then
			return true, { Slot = tonumber(record.PlacedNestId) }
		end
		slot = freePerch(data)
		if not slot then
			return false, "PERCHES_FULL", "All your perches are taken. Unlock more in your sanctuary."
		end
	end
	-- the dragon leaving the free pool must not strand the player
	local occupant = data.Nests.Slots[tostring(slot)]
	if record.PlacedNestId == "" and not occupant and freeCount(data) <= 1 then
		return false, "KEEP_ONE", "Keep at least one dragon out of the sanctuary to ride."
	end
	local ok, err, msg, result = placeOn(player, data, p.Id, slot)
	if not ok then
		return false, err, msg
	end
	return true, result
end

local function handleTakeBack(player: Player, p)
	if not Net.check.str(p.Id, 40) then
		return false, "BAD_REQUEST"
	end
	local record = DragonService.Get(player, p.Id)
	if not record then
		return false, "NOT_FOUND"
	end
	if record.PlacedNestId == "" then
		return true
	end
	clearPlaced(player, p.Id)
	DragonService.PlacedChanged:Fire(player)
	return true
end

-- Fills every free perch with the best free dragons (never the equipped one,
-- always leaving one dragon to ride).
local function handleAutoPlace(player: Player)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local sanctuary = Services.SanctuaryService
	if sanctuary and not sanctuary.GetPlotId(player) then
		return false, "NO_PLOT", "You don't have a sanctuary in this server."
	end
	local candidates = {}
	for uid, rec in data.Dragons do
		if rec.PlacedNestId == "" and uid ~= data.EquippedDragon then
			table.insert(candidates, rec)
		end
	end
	table.sort(candidates, function(a, b)
		if a.IncomePerSecond ~= b.IncomePerSecond then
			return a.IncomePerSecond > b.IncomePerSecond
		end
		return a.UniqueId < b.UniqueId
	end)
	local placed = 0
	for _, rec in candidates do
		local slot = freePerch(data)
		if not slot or freeCount(data) <= 1 then
			break
		end
		setPlaced(player, rec.UniqueId, tostring(slot))
		placed += 1
	end
	if placed == 0 then
		if not freePerch(data) then
			return false, "PERCHES_FULL", "All your perches are taken."
		end
		return false, "NOTHING", "No other dragons to place."
	end
	DragonService.PlacedChanged:Fire(player)
	return true, { Placed = placed }
end

local function handleBuyPerch(player: Player)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	local nextSlot = data.Nests.Unlocked + 1
	if nextSlot > maxPerches() then
		return false, "MAXED", "All perches are unlocked."
	end
	local price = EconomyConfig.NestPrices[nextSlot]
	if not spend(player, price, "Perch") then
		return false, "NO_CASH", "You need " .. tostring(price) .. " coins to unlock this perch."
	end
	Data.Set(player, { "Nests", "Unlocked" }, nextSlot)
	DragonService.PlacedChanged:Fire(player)
	return true, { Unlocked = nextSlot }
end

-- ============================================================== lifecycle
function DragonService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Dragon", "Equip", handleEquip, { Burst = 6, PerSecond = 3 })
	Net.handle("Dragon", "Unequip", handleUnequip, { Burst = 4, PerSecond = 2 })
	Net.handle("Dragon", "Lock", handleLock, { Burst = 8, PerSecond = 4 })
	Net.handle("Dragon", "Release", handleRelease, { Burst = 6, PerSecond = 3 })
	Net.handle("Dragon", "Feed", handleFeed, { Burst = 8, PerSecond = 5 })
	Net.handle("Dragon", "Mutate", handleMutate, { Burst = 6, PerSecond = 3 })
	Net.handle("Dragon", "Place", handlePlace, { Burst = 6, PerSecond = 3 })
	Net.handle("Dragon", "TakeBack", handleTakeBack, { Burst = 6, PerSecond = 3 })
	Net.handle("Dragon", "AutoPlace", handleAutoPlace, { Burst = 2, PerSecond = 0.5 })
	Net.handle("Dragon", "BuyPerch", handleBuyPerch, { Burst = 3, PerSecond = 1 })
end

function DragonService.Start()
	local function onLoaded(player: Player, data)
		-- refresh stats on load (balance changes / tamper safety); the client
		-- already has the snapshot, so changed records are re-sent
		for uid, rec in table.clone(data.Dragons) do
			local copy = table.clone(rec)
			if not DragonStats.refresh(copy) then
				Data.Set(player, { "Dragons", uid }, nil)
			else
				for k, v in copy do
					if rec[k] ~= v then
						Data.Set(player, { "Dragons", uid }, copy)
						break
					end
				end
			end
		end
		-- perches beyond the current layout (config changes) return to the bag
		for slot, uid in table.clone(data.Nests.Slots) do
			local n = tonumber(slot)
			if not n or n > math.min(data.Nests.Unlocked, maxPerches()) then
				Data.Set(player, { "Nests", "Slots", slot }, nil)
				if data.Dragons[uid] then
					Data.Set(player, { "Dragons", uid, "PlacedNestId" }, "")
				end
			end
		end
		grantStarter(player, data)
		validateEquipped(player, data)
		DragonService.EquippedChanged:Fire(player, data.EquippedDragon)
		DragonService.PlacedChanged:Fire(player)
	end
	Data.Loaded:Connect(onLoaded)
	for _, player in Players:GetPlayers() do
		local data = Data.Get(player)
		if data then
			onLoaded(player, data)
		end
	end
end

-- test hooks
DragonService._validateEquipped = validateEquipped

return DragonService

--[[
	PlayerDataService
	Owns every player's saved data.

	- Loads with UpdateAsync + session lock (prevents duplication across servers)
	- Retries with backoff; never hands out a blank profile when the store fails
	  (the player is kicked with a friendly message instead, protecting saves)
	- Studio without API access: runs on an in-memory profile and warns
	- Autosave, save on leave, BindToClose flush
	- All writes go through Set/Increment/Update so the client mirror stays in
	  sync (batched to one DataSync message per player per frame)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)
local DragonStats = require(Shared.DragonStats)
local GameConfig = require(Configs.GameConfig)
local EconomyConfig = require(Configs.EconomyConfig)
local TreeConfig = require(Configs.TreeConfig)

local DataSync: RemoteEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DataSync")

local PlayerDataService = {}
PlayerDataService.Loaded = Signal.new() -- (player, data)
PlayerDataService.Releasing = Signal.new() -- (player, data) fired before final save

local CURRENT_VERSION = 1
local LOAD_ATTEMPTS = 6
local SAVE_ATTEMPTS = 4

local TEMPLATE = {
	Version = CURRENT_VERSION,
	Cash = GameConfig.StarterCash,
	TotalEarned = 0,
	Level = 1,
	XP = 0,
	Dragons = {},
	DragonSerial = 0,
	EquippedDragon = "",
	Eggs = {},
	EggSerial = 0,
	Nests = { Unlocked = EconomyConfig.StartingNests, Slots = {} },
	Incubator = { Unlocked = 2, Slots = {} },
	PendingIncome = 0,
	Upgrades = { EggStorage = 0, DragonStorage = 0, HatchLuck = 0, Radar = 0 },
	Tree = {}, -- Great Tree levels { [branchId] = level }, see TreeConfig
	Index = {},
	IndexClaims = {}, -- Dragon Index milestones already paid, see IndexConfig
	Regions = { Haven = true },
	Quests = { Active = {}, Completed = 0, Serial = 0 },
	Tutorial = { Step = 1, Done = false },
	Daily = { LastClaim = 0, Streak = 0 },
	Settings = {
		Graphics = "Max",
		Music = 0.6,
		SFX = 0.8,
		CameraShake = true,
		SpeedFOV = true,
		MouseLock = true,
		Sensitivity = 1,
		InvertY = false,
		UIScale = 1,
		MenuBlur = false,
	},
	Stats = {
		EggsFound = 0,
		Hatched = 0,
		DistanceFlown = 0,
		PlayTime = 0,
		Collected = 0,
		Fed = 0,
		BoostSeconds = 0,
		Released = 0,
		MutateTries = 0,
		Spins = 0,
		ArenaKills = 0,
		ArenaDeaths = 0,
		Coins = 0,
	},
	Flags = { StarterGranted = false, OwnerPass = false, Passes = {} },
	Boosts = {},
	Spin = { NextFree = 0, Tickets = 3 },
	Race = { Best = 0, Runs = 0, Wins = 0, MonthKey = "", MonthBest = 0, Crowns = {} }, -- see RaceService
	Purchases = { Receipts = {}, Robux = 0 },
	CreatedAt = 0,
	LastLogin = 0,
	LastLogout = 0,
}
PlayerDataService.Template = TEMPLATE

local store: DataStore? = nil
local profiles: { [Player]: any } = {}
local pending: { [Player]: { any } } = {}
local saving: { [Player]: boolean } = {}
local temporaryMode = false
local shuttingDown = false

-- ============================================================== helpers
local function keyFor(userId: number): string
	return "u_" .. tostring(userId)
end

local function now(): number
	return os.time()
end

local function sanitize(data)
	-- Deep copy without server-only fields.
	local copy = TableUtil.deepCopy(data)
	copy.Session = nil
	return copy
end

local function migrate(data)
	data.Version = tonumber(data.Version) or 0
	-- v0 -> v1: (initial schema) nothing to transform yet.
	if data.Version < 1 then
		data.Version = 1
	end
	TableUtil.reconcile(data, TEMPLATE)
	-- Validate dragons and drop anything corrupt.
	for uid, record in data.Dragons do
		if type(record) ~= "table" or type(uid) ~= "string" or not DragonStats.refresh(record) then
			data.Dragons[uid] = nil
		else
			record.UniqueId = uid
		end
	end
	if data.EquippedDragon ~= "" and data.Dragons[data.EquippedDragon] == nil then
		data.EquippedDragon = ""
	end
	-- Nest slots must point to dragons that agree they are placed there.
	for nestId, uid in data.Nests.Slots do
		local record = data.Dragons[uid]
		if not record or record.PlacedNestId ~= nestId then
			data.Nests.Slots[nestId] = nil
		end
	end
	for _, record in data.Dragons do
		if record.PlacedNestId ~= "" and data.Nests.Slots[record.PlacedNestId] ~= record.UniqueId then
			record.PlacedNestId = ""
		end
	end
	data.Nests.Unlocked = math.clamp(math.floor(tonumber(data.Nests.Unlocked) or 2), EconomyConfig.StartingNests, #EconomyConfig.NestPrices)
	data.Cash = math.max(0, tonumber(data.Cash) or 0)
	-- Great Tree: only known branches, levels inside their range
	for id, level in data.Tree do
		local branch = TreeConfig.ById[id]
		if not branch then
			data.Tree[id] = nil
		else
			data.Tree[id] = math.clamp(math.floor(tonumber(level) or 0), 0, #branch.Levels)
		end
	end
	return data
end

local function isStudioAccessError(err: string): boolean
	err = string.lower(err)
	return string.find(err, "studio", 1, true) ~= nil or string.find(err, "api services", 1, true) ~= nil
		or string.find(err, "not allowed", 1, true) ~= nil
end

-- ============================================================== replication
local function queue(player: Player, path: { string }, value: any)
	local list = pending[player]
	if not list then
		list = {}
		pending[player] = list
	end
	table.insert(list, { path, TableUtil.deepCopy(value) })
end

local function flush()
	for player, list in pending do
		pending[player] = nil
		if player.Parent == Players and profiles[player] then
			DataSync:FireClient(player, "Batch", list)
		end
	end
end

-- ============================================================== public API
function PlayerDataService.Get(player: Player)
	return profiles[player] and profiles[player].Data or nil
end

function PlayerDataService.IsLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

function PlayerDataService.IsTemporary(): boolean
	return temporaryMode
end

local function resolve(data, path: { string })
	local node = data
	for i = 1, #path - 1 do
		local nxt = node[path[i]]
		if type(nxt) ~= "table" then
			nxt = {}
			node[path[i]] = nxt
		end
		node = nxt
	end
	return node, path[#path]
end

function PlayerDataService.Set(player: Player, path: { string }, value: any)
	local profile = profiles[player]
	if not profile then
		return
	end
	local node, key = resolve(profile.Data, path)
	node[key] = value
	profile.Dirty = true
	queue(player, path, value)
end

function PlayerDataService.Increment(player: Player, path: { string }, delta: number): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	local node, key = resolve(profile.Data, path)
	local v = (tonumber(node[key]) or 0) + delta
	node[key] = v
	profile.Dirty = true
	queue(player, path, v)
	return v
end

-- Mutates the value at path through fn(current) -> new, then replicates it.
function PlayerDataService.Update(player: Player, path: { string }, fn)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	local node, key = resolve(profile.Data, path)
	local nv = fn(node[key])
	node[key] = nv
	profile.Dirty = true
	queue(player, path, nv)
	return nv
end

function PlayerDataService.NextId(player: Player, counterKey: string, prefix: string): string
	local n = PlayerDataService.Increment(player, { counterKey }, 1)
	return string.format("%s%d_%d", prefix, player.UserId, n)
end

-- ============================================================== load / save
local function newProfile(player: Player)
	local data = TableUtil.deepCopy(TEMPLATE)
	data.CreatedAt = now()
	return data
end

local function loadData(player: Player)
	if temporaryMode or not store then
		return newProfile(player), true
	end
	local key = keyFor(player.UserId)
	local jobId = game.JobId ~= "" and game.JobId or "studio"
	for attempt = 1, LOAD_ATTEMPTS do
		local lockedBy = nil
		local ok, result = pcall(function()
			return (store :: DataStore):UpdateAsync(key, function(old)
				old = old or newProfile(player)
				local session = old.Session
				if session and session.JobId ~= jobId and now() - (tonumber(session.Time) or 0) < GameConfig.SessionLockTimeout then
					-- Locked by another live server; steal only on the final attempt
					-- if the lock is old enough (crashed server).
					if attempt < LOAD_ATTEMPTS or now() - (tonumber(session.Time) or 0) < 120 then
						lockedBy = session.JobId
						return nil
					end
				end
				old.Session = { JobId = jobId, Time = now() }
				return old
			end)
		end)
		if ok and result ~= nil and lockedBy == nil then
			return result, false
		end
		if not ok then
			local err = tostring(result)
			if isStudioAccessError(err) then
				warn("[PlayerData] DataStore unavailable in Studio (enable 'Studio Access to API Services' to test saving). Using a temporary profile.")
				temporaryMode = true
				return newProfile(player), true
			end
			warn(string.format("[PlayerData] Load attempt %d failed for %s: %s", attempt, player.Name, err))
		end
		if player.Parent ~= Players then
			return nil, false
		end
		task.wait(math.min(2 ^ attempt, 8))
	end
	return nil, false
end

local function saveData(player: Player, releasing: boolean): boolean
	local profile = profiles[player]
	if not profile or profile.Temporary or not store then
		return true
	end
	if saving[player] and not releasing then
		return false
	end
	saving[player] = true
	local data = profile.Data
	local key = keyFor(player.UserId)
	local jobId = game.JobId ~= "" and game.JobId or "studio"
	data.LastLogout = releasing and now() or data.LastLogout
	local success = false
	for attempt = 1, SAVE_ATTEMPTS do
		local stolen = false
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(key, function(old)
				if old and old.Session and old.Session.JobId ~= jobId then
					-- Another server owns this profile now; never overwrite it.
					stolen = true
					return nil
				end
				local copy = TableUtil.deepCopy(data)
				copy.Session = (not releasing) and { JobId = jobId, Time = now() } or nil
				return copy
			end)
		end)
		if ok then
			if stolen then
				warn("[PlayerData] Session for " .. player.Name .. " was taken by another server; save skipped.")
			end
			success = true
			profile.Dirty = false
			profile.LastSave = os.clock()
			break
		end
		warn(string.format("[PlayerData] Save attempt %d failed for %s: %s", attempt, player.Name, tostring(err)))
		task.wait(attempt)
	end
	saving[player] = nil
	return success
end

PlayerDataService.SaveNow = function(player: Player)
	local profile = profiles[player]
	if profile and os.clock() - (profile.LastSave or 0) > 6 then
		task.spawn(saveData, player, false)
	elseif profile then
		profile.SaveSoon = true
	end
end

local function onPlayerAdded(player: Player)
	local data, temporary = loadData(player)
	if player.Parent ~= Players then
		if data and not temporary then
			-- Player left during load: release the lock we just took.
			profiles[player] = { Data = data, Temporary = false, Dirty = false }
			saveData(player, true)
			profiles[player] = nil
		end
		return
	end
	if not data then
		player:Kick("We couldn't load your dragons right now (data servers are busy). Please rejoin in a moment - your progress is safe.")
		return
	end
	data = migrate(data)
	data.LastLogin = now()
	profiles[player] = { Data = data, Temporary = temporary, Dirty = false, LastSave = os.clock() }
	player:SetAttribute("DataLoaded", true)
	DataSync:FireClient(player, "Init", sanitize(data), { Temporary = temporary })
	PlayerDataService.Loaded:Fire(player, data)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	PlayerDataService.Releasing:Fire(player, profile.Data)
	-- give services a moment to write final state (e.g. playtime) synchronously
	saveData(player, true)
	profiles[player] = nil
	pending[player] = nil
end

function PlayerDataService.Init()
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStoreName)
	end)
	if ok then
		store = ds
	else
		warn("[PlayerData] GetDataStore failed: " .. tostring(ds) .. " (temporary profiles will be used)")
		temporaryMode = true
	end
end

function PlayerDataService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	RunService.Heartbeat:Connect(flush)

	-- Autosave loop (staggered so all players do not save in the same frame).
	task.spawn(function()
		while not shuttingDown do
			task.wait(5)
			local t = os.clock()
			for player, profile in profiles do
				if (profile.Dirty and t - (profile.LastSave or 0) >= GameConfig.AutosaveInterval) or (profile.SaveSoon and t - (profile.LastSave or 0) > 6) then
					profile.SaveSoon = false
					task.spawn(saveData, player, false)
					task.wait(0.5)
				end
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		local remaining = 0
		for player in profiles do
			remaining += 1
			task.spawn(function()
				PlayerDataService.Releasing:Fire(player, profiles[player] and profiles[player].Data)
				saveData(player, true)
				remaining -= 1
			end)
		end
		local deadline = os.clock() + 25
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

-- Saves right away (after Robux purchases), without blocking the caller.
function PlayerDataService.SaveNow(player: Player)
	if profiles[player] then
		task.spawn(saveData, player, false)
	end
end

-- Test hook: force a save (used by QA harness).
PlayerDataService._saveForTests = saveData

return PlayerDataService

--[[
	QuestService
	Elder Rowan's quests (QuestConfig, QuestsWindow). Data: data.Quests = { Active = { quest... }, Completed = n,
	Serial = n, Starter = { [id] = true } }, a quest = { Id = "q12", Template, Goal, Base }.

	  * GETTING STARTED: the first goals of a new player (QuestConfig.Starter); each pays once when done.
	  * ACTIVE QUESTS: QuestConfig.ActiveCount quests from the templates. Progress = the counter now minus the
	    counter when the quest was given, so it counts from that moment on. Taking the reward gives the
	    cash (grows with level and income), player XP, every 3rd quest a spin, and a NEW quest takes its place.
	  * Two counters are kept here: Stats.Rides (every time you mount) and Stats.BoostSeconds (riding with the boost on).

	Net (domain "Quests"):
	  State {} -> { Level, Completed, SpinIn, Claimable, StarterLeft, Starter = { { Id, Text, Hint, Reward, Spins, Done, Claimed } },
	                Active = { { Id, Text, Progress, Goal, Cash, XP, Ready } } }
	  Claim { Id }  Id = "q12" (an active quest) or "s:Ride" (a starter goal)  -> { Cash, XP, Spins }
	Signal "QuestReady" { Count } to the player whenever the number of rewards waiting changes.
	Test hooks: QuestService.State(player), QuestService.Ensure(player), QuestService.Claimable(player).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local QuestConfig = require(Configs:WaitForChild("QuestConfig"))

local QuestService = {}

local Data
local Services
local rng = Random.new()
local lastCount: { [Player]: number } = {}

-- ============================================================== helpers
local function stat(data, name: string): number
	return tonumber(data.Stats and data.Stats[name]) or 0
end

local function levelOf(data): number
	return math.max(1, tonumber(data.Level) or 1)
end

local function commas(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function goalText(template, goal: number): string
	local shown
	if template.Fmt == "cash" then
		shown = Format.cash(goal)
	elseif template.Fmt == "big" then
		shown = commas(goal)
	else
		shown = tostring(goal)
	end
	return string.format(template.Text, shown)
end

local function counted(t): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- ============================================================== starter goals
local function starterDone(data, s): boolean
	if s.Check == "Perch" then
		return counted(data.Nests and data.Nests.Slots or {}) >= s.Need
	elseif s.Check == "Upgrade" then
		for _, level in data.Upgrades or {} do
			if (tonumber(level) or 0) > 0 then
				return true
			end
		end
		for _, level in data.Tree or {} do
			if (tonumber(level) or 0) > 0 then
				return true
			end
		end
		return false
	end
	return stat(data, s.Check) >= s.Need
end

local function starterClaimed(data, id: string): boolean
	return data.Quests.Starter ~= nil and data.Quests.Starter[id] == true
end

-- ============================================================== active quests
local function pickTemplate(active: { any }, avoid: string?): string
	local used = {}
	for _, q in active do
		used[q.Template] = true
	end
	local pool = {}
	for _, id in QuestConfig.TemplateOrder do
		if not used[id] and id ~= avoid then
			table.insert(pool, id)
		end
	end
	if #pool == 0 then
		pool = table.clone(QuestConfig.TemplateOrder)
	end
	return pool[rng:NextInteger(1, #pool)]
end

local function newQuest(player: Player, data, active: { any }, avoid: string?)
	local template = pickTemplate(active, avoid)
	local serial = (tonumber(data.Quests.Serial) or 0) + 1
	Data.Set(player, { "Quests", "Serial" }, serial)
	local income = Services.EconomyService.IncomeRate(player)
	return {
		Id = "q" .. serial,
		Template = template,
		Goal = QuestConfig.goal(template, levelOf(data), income),
		Base = stat(data, QuestConfig.Templates[template].Stat),
	}
end

-- Makes sure the player has ActiveCount valid quests.
function QuestService.Ensure(player: Player)
	local data = Data.Get(player)
	if not data then
		return
	end
	if type(data.Quests) ~= "table" then
		return
	end
	local active = {}
	for _, q in data.Quests.Active or {} do
		if type(q) == "table" and QuestConfig.Templates[q.Template] and type(q.Id) == "string" then
			table.insert(active, q)
		end
	end
	local changed = #active ~= counted(data.Quests.Active or {})
	while #active < QuestConfig.ActiveCount do
		table.insert(active, newQuest(player, data, active, nil))
		changed = true
	end
	if changed then
		Data.Set(player, { "Quests", "Active" }, active)
	end
end

local function progress(data, q): number
	local template = QuestConfig.Templates[q.Template]
	local value = stat(data, template.Stat) - (tonumber(q.Base) or 0)
	return math.clamp(value, 0, q.Goal)
end

-- Rewards waiting: finished starter goals not yet taken + finished active quests.
function QuestService.Claimable(player: Player): number
	local data = Data.Get(player)
	if not data or type(data.Quests) ~= "table" then
		return 0
	end
	local n = 0
	for _, s in QuestConfig.Starter do
		if not starterClaimed(data, s.Id) and starterDone(data, s) then
			n += 1
		end
	end
	for _, q in data.Quests.Active or {} do
		if QuestConfig.Templates[q.Template] and progress(data, q) >= q.Goal then
			n += 1
		end
	end
	return n
end

function QuestService.State(player: Player)
	local data = Data.Get(player)
	if not data or type(data.Quests) ~= "table" then
		return nil
	end
	QuestService.Ensure(player)
	local level = levelOf(data)
	local income = Services.EconomyService.IncomeRate(player)
	local starter, left = {}, 0
	for _, s in QuestConfig.Starter do
		local claimed = starterClaimed(data, s.Id)
		if not claimed then
			left += 1
		end
		table.insert(starter, { Id = s.Id, Text = s.Text, Hint = s.Hint, Reward = s.Reward, Spins = s.Spins or 0, Done = starterDone(data, s), Claimed = claimed })
	end
	if left == 0 then
		starter = {}
	end
	local active = {}
	for _, q in data.Quests.Active do
		local template = QuestConfig.Templates[q.Template]
		local value = progress(data, q)
		table.insert(active, {
			Id = q.Id,
			Template = q.Template,
			Text = goalText(template, q.Goal),
			Progress = value,
			Goal = q.Goal,
			Fmt = template.Fmt,
			Cash = QuestConfig.cash(q.Template, level, income),
			XP = QuestConfig.xp(level),
			Ready = value >= q.Goal,
		})
	end
	local completed = tonumber(data.Quests.Completed) or 0
	return {
		Level = level,
		Completed = completed,
		SpinIn = QuestConfig.SpinEvery - completed % QuestConfig.SpinEvery,
		Claimable = QuestService.Claimable(player),
		StarterLeft = left,
		StarterTotal = #QuestConfig.Starter,
		Starter = starter,
		Active = active,
	}
end

-- ============================================================== claiming
local function claimStarter(player: Player, data, id: string)
	local s = QuestConfig.StarterById[id]
	if not s then
		return false, "BAD_REQUEST"
	end
	if starterClaimed(data, id) then
		return false, "ALREADY_CLAIMED", "You already took that reward."
	end
	if not starterDone(data, s) then
		return false, "NOT_DONE", "Not finished yet: " .. s.Text
	end
	Data.Set(player, { "Quests", "Starter", id }, true)
	Services.EconomyService.Earn(player, s.Reward, "Quest")
	local parts = { Format.cash(s.Reward) }
	if s.Spins then
		Services.SpinService.AddTickets(player, s.Spins)
		table.insert(parts, string.format("%d spins", s.Spins))
	end
	Net.notify(player, "success", string.format("GOAL DONE: %s  +%s", s.Text, table.concat(parts, "  +")))
	return true, { Cash = s.Reward, XP = 0, Spins = s.Spins or 0 }
end

local function claimQuest(player: Player, data, id: string)
	local index
	for i, q in data.Quests.Active do
		if q.Id == id then
			index = i
			break
		end
	end
	if not index then
		return false, "GONE", "That quest is gone."
	end
	local q = data.Quests.Active[index]
	local template = QuestConfig.Templates[q.Template]
	if not template then
		return false, "GONE"
	end
	if progress(data, q) < q.Goal then
		return false, "NOT_DONE", "Not finished yet: " .. goalText(template, q.Goal)
	end
	local level = levelOf(data)
	local income = Services.EconomyService.IncomeRate(player)
	local cash = QuestConfig.cash(q.Template, level, income)
	local xp = QuestConfig.xp(level)
	local text = goalText(template, q.Goal)
	-- a new quest takes its place
	local rest = {}
	for i, other in data.Quests.Active do
		if i ~= index then
			table.insert(rest, other)
		end
	end
	local fresh = newQuest(player, data, rest, q.Template)
	table.insert(rest, math.min(index, #rest + 1), fresh)
	local completed = (tonumber(data.Quests.Completed) or 0) + 1
	Data.Set(player, { "Quests", "Active" }, rest)
	Data.Set(player, { "Quests", "Completed" }, completed)
	Services.EconomyService.Earn(player, cash, "Quest")
	Services.LevelService.Add(player, xp, "Quest")
	local parts = { Format.cash(cash), xp .. " XP" }
	local spins = 0
	if completed % QuestConfig.SpinEvery == 0 then
		spins = 1
		Services.SpinService.AddTickets(player, 1)
		table.insert(parts, "1 free spin")
	end
	Net.notify(player, "success", string.format("QUEST DONE: %s  +%s", text, table.concat(parts, "  +")))
	return true, { Cash = cash, XP = xp, Spins = spins }
end

local function handleState(player: Player)
	local state = QuestService.State(player)
	if not state then
		return false, "NOT_LOADED"
	end
	return true, state
end

local function handleClaim(player: Player, p)
	if not Net.check.str(p.Id, 24) then
		return false, "BAD_REQUEST"
	end
	local data = Data.Get(player)
	if not data or type(data.Quests) ~= "table" then
		return false, "NOT_LOADED"
	end
	QuestService.Ensure(player)
	local ok, a, b
	if string.sub(p.Id, 1, 2) == "s:" then
		ok, a, b = claimStarter(player, data, string.sub(p.Id, 3))
	else
		ok, a, b = claimQuest(player, data, p.Id)
	end
	if ok then
		lastCount[player] = QuestService.Claimable(player)
		Net.signal(player, "QuestReady", { Count = lastCount[player] })
	end
	return ok, a, b
end

-- ============================================================== lifecycle
function QuestService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Quests", "State", handleState, { Burst = 6, PerSecond = 2 })
	Net.handle("Quests", "Claim", handleClaim, { Burst = 4, PerSecond = 1.5 })
end

function QuestService.Start()
	Data.Loaded:Connect(function(player)
		QuestService.Ensure(player)
		lastCount[player] = QuestService.Claimable(player)
		if lastCount[player] > 0 then
			Net.signal(player, "QuestReady", { Count = lastCount[player] })
		end
	end)
	local mount = Services.MountService
	if mount and mount.Mounted then
		mount.Mounted:Connect(function(player)
			if Data.Get(player) then
				Data.Increment(player, { "Stats", "Rides" }, 1)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastCount[player] = nil
	end)
	-- once a second: boost seconds; every two seconds: tell the player when rewards are waiting
	task.spawn(function()
		local tick = 0
		while true do
			task.wait(1)
			tick += 1
			for _, player in Players:GetPlayers() do
				local data = Data.Get(player)
				if data then
					local comp = mount and mount.Get(player)
					if comp and comp.Riding and comp.Model and comp.Model.Parent and comp.Model:GetAttribute("Boost") == true then
						Data.Increment(player, { "Stats", "BoostSeconds" }, 1)
					end
					if tick % 2 == 0 then
						local n = QuestService.Claimable(player)
						if n ~= lastCount[player] then
							lastCount[player] = n
							Net.signal(player, "QuestReady", { Count = n })
						end
					end
				end
			end
		end
	end)
end

return QuestService

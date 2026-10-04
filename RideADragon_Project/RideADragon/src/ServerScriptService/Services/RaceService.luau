--[[
	RaceService
	The sky circuit of the Race & Battle Island (RaceConfig). The server decides everything:

	  Lobby      Race.Join (from the Race window / the join pad). The lobby stays open for
	             LobbySeconds (shorter when it is full); a lone racer can start at once.
	  Countdown  everybody is mounted, put on the start grid and frozen; 3-2-1.
	  Running    the server samples every racer's dragon 10 times a second: the next ring gate must
	             be crossed forward inside its radius, in order. Teleporting, flying faster than
	             anything legal, dismounting or leaving the course ends the run (DNF / disqualified).
	  Finish     lap count reached: time (server clock, interpolated inside the sample), place,
	             rewards, best times (all-time + monthly) and the leaderboards.

	Everybody races with the SAME standard dragon stats (player attribute RaceActive: the client
	and the movement validation switch to RaceConfig.Standard), so skill decides, not purchases.

	Monthly prize: on the first day of a month the fastest racer of the previous month is read from
	the monthly leaderboard store and written to the winners history (DataStore RaceWinners_v1, also
	shown on the podium of the island). The winner gets a trophy, a title and a reward in the game and
	the whole server is told. The real-money prize is paid by the game's owner from that record.

	Net (domain "Race"):
	  Join {}      -> { State, Queued? }       Leave {}      StartNow {}
	  State {}     -> snapshot for the window  Top { Board } -> { List }
	Signals to racers: RaceLobby, RaceCount { N }, RaceGo, RaceProgress, RaceFinish, RaceEnd
	Player attributes: RaceState (Lobby | Countdown | Running | Finished), RaceActive, RaceStart, RacePass
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))

local RaceService = {}
RaceService.Finished = Signal.new() -- (player, ms, place, newBest)

local Services
local Data
local island: Model? = nil
local race: any = nil -- the current race (lobby / countdown / running / done)
local waiting: { Player } = {} -- joined while a race was running: they open the next lobby
local winners: { any } = {} -- monthly champions, newest first
local winnersStore: DataStore? = nil

-- One clock for the whole race: the same server time the clients get as RaceStart, so the
-- lobby timer, the countdown and the finish times can never drift apart.
local function clock(): number
	return Workspace:GetServerTimeNow()
end

-- ============================================================== helpers
local function racerOf(player: Player)
	return race and race.Racers[player] or nil
end

-- The ridden dragon's root, else the character: what the race measures.
local function positionOf(player: Player): Vector3?
	local mount = Services.MountService
	local comp = mount and mount.Get(player)
	if comp and comp.Riding and comp.Root.Parent then
		return comp.Root.Position
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return hrp and hrp.Position or nil
end

local function onIsland(position: Vector3?): boolean
	return position ~= nil and (position - RaceConfig.Island.Center).Magnitude <= RaceConfig.JoinDistance
end

local function setState(player: Player, state: string?)
	player:SetAttribute("RaceState", state)
end

-- Sends the lobby picture to everyone in it.
local function lobbySignal()
	if not race then
		return
	end
	local list = {}
	for _, p in race.Players do
		table.insert(list, { Name = p.DisplayName, UserId = p.UserId })
	end
	local left = race.State == "Lobby" and math.max(0, race.LobbyEnds - clock()) or 0
	for _, p in race.Players do
		Net.signal(p, "RaceLobby", { Racers = list, Left = left, State = race.State, Laps = RaceConfig.Laps, Gates = RaceConfig.GateCount })
	end
end

local function removeFrom(list: { Player }, player: Player)
	local i = table.find(list, player)
	if i then
		table.remove(list, i)
	end
end

-- ============================================================== results / rewards
local function reward(player: Player, spec, label: string)
	local econ = Services.EconomyService
	local rate = econ and econ.IncomeRate(player) or 0
	local cash = math.max(spec.Min or 0, math.floor(rate * (spec.Minutes or 0) * 60))
	if cash > 0 and econ then
		econ.Earn(player, cash, "Race")
	end
	local level = Services.LevelService
	if level and (spec.XP or 0) > 0 then
		level.Add(player, spec.XP, "Race")
	end
	return { Label = label, Cash = cash, XP = spec.XP or 0 }
end

local function updateBests(player: Player, ms: number): (boolean, boolean)
	local data = Data.Get(player)
	if not data then
		return false, false
	end
	local key = RaceConfig.monthKey()
	local best = tonumber(data.Race.Best) or 0
	local newBest = best <= 0 or ms < best
	if newBest then
		Data.Set(player, { "Race", "Best" }, ms)
	end
	if data.Race.MonthKey ~= key then
		Data.Set(player, { "Race", "MonthKey" }, key)
		Data.Set(player, { "Race", "MonthBest" }, 0)
	end
	local monthBest = tonumber(data.Race.MonthBest) or 0
	local newMonth = monthBest <= 0 or ms < monthBest
	if newMonth then
		Data.Set(player, { "Race", "MonthBest" }, ms)
	end
	Data.Increment(player, { "Race", "Runs" }, 1)
	return newBest, newMonth
end

local function results(r): { any }
	local list = {}
	for _, p in r.Order do
		local rc = r.Racers[p]
		table.insert(list, { Name = p.DisplayName, UserId = p.UserId, Ms = rc.FinishMs, Place = rc.Place })
	end
	for _, p in r.Players do
		local rc = r.Racers[p]
		if rc and rc.Status ~= "Finished" then
			table.insert(list, { Name = p.DisplayName, UserId = p.UserId, Ms = 0, Place = 0, Reason = rc.Reason })
		end
	end
	return list
end

local function finishRacer(r, player: Player, rc, ms: number)
	rc.Status = "Finished"
	rc.FinishMs = ms
	table.insert(r.Order, player)
	rc.Place = #r.Order
	if not r.FirstFinish then
		r.FirstFinish = clock()
	end
	local newBest, newMonth = updateBests(player, ms)
	local rewards = {}
	local multi = r.Started > 1
	if multi and RaceConfig.Rewards.Places[rc.Place] then
		table.insert(rewards, reward(player, RaceConfig.Rewards.Places[rc.Place], "PLACE " .. rc.Place))
	else
		table.insert(rewards, reward(player, RaceConfig.Rewards.Finish, "FINISHED"))
	end
	if newBest then
		table.insert(rewards, reward(player, RaceConfig.Rewards.PersonalBest, "NEW BEST"))
	end
	if multi and rc.Place == 1 then
		Data.Increment(player, { "Race", "Wins" }, 1)
	end
	setState(player, "Finished")
	player:SetAttribute("RaceActive", nil) -- the finisher is free: own dragon again, may travel
	player:SetAttribute("RacePass", nil)
	local data = Data.Get(player)
	Net.signal(player, "RaceFinish", {
		Place = rc.Place,
		Racers = r.Started,
		Ms = ms,
		NewBest = newBest,
		NewMonthBest = newMonth,
		Best = data and data.Race.Best or ms,
		MonthBest = data and data.Race.MonthBest or ms,
		Rewards = rewards,
	})
	local lb = Services.LeaderboardService
	if lb and (newBest or newMonth) and lb.WriteNow then
		task.spawn(lb.WriteNow, player)
	end
	RaceService.Finished:Fire(player, ms, rc.Place, newBest)
end

-- Ends a racer without a result.
local function dnf(r, player: Player, reason: string)
	local rc = r.Racers[player]
	if not rc or rc.Status ~= "Racing" then
		return
	end
	rc.Status = "DNF"
	rc.Reason = reason
	setState(player, nil)
	player:SetAttribute("RaceActive", nil)
	Net.signal(player, "RaceEnd", { Reason = reason })
end

local function releaseRacer(player: Player)
	player:SetAttribute("RaceActive", nil)
	player:SetAttribute("RacePass", nil)
	player:SetAttribute("RaceStart", nil)
	player:SetAttribute("RaceState", nil)
	local mount = Services.MountService
	if mount and mount.Freeze then
		mount.Freeze(player, false)
	end
end

-- ============================================================== race flow
local function newRace()
	return {
		State = "Lobby",
		Players = {},
		Racers = {},
		Order = {},
		Started = 0,
		LobbyEnds = clock() + RaceConfig.LobbySeconds,
	}
end

local function closeRace()
	if not race then
		return
	end
	for _, p in race.Players do
		releaseRacer(p)
	end
	race = nil
	if #waiting > 0 then
		race = newRace()
		for _, p in waiting do
			if p.Parent == Players then
				table.insert(race.Players, p)
				setState(p, "Lobby")
			end
		end
		table.clear(waiting)
		if #race.Players == 0 then
			race = nil
		else
			lobbySignal()
		end
	end
end

local function ready(player: Player): boolean
	return player.Parent == Players and Data.Get(player) ~= nil and onIsland(positionOf(player))
end

local function padCFrame(slot: number, hip: number): CFrame
	local world = RaceConfig.toWorld(RaceConfig.Pads[slot])
	local pos = Vector3.new(world.X, world.Y + 2 + hip, world.Z)
	return CFrame.lookAt(pos, pos + Vector3.new(0, 0, -1))
end

local function beginCountdown()
	local r = race
	if not r or r.State ~= "Lobby" then
		return
	end
	local mount = Services.MountService
	local list = {}
	for _, p in r.Players do
		if ready(p) then
			table.insert(list, p)
		else
			Net.notify(p, "warning", "You left the island - the race started without you.")
			releaseRacer(p)
		end
	end
	r.Players = {}
	local slot = 0
	for _, p in list do
		if slot >= RaceConfig.MaxRacers then
			break
		end
		-- onto a dragon (the strongest comes down from its perch when nobody is out)
		local ok = mount.Mount(p)
		local comp = ok and mount.Get(p)
		if ok and comp and comp.Riding then
			slot += 1
			table.insert(r.Players, p)
			local hip = comp.Model:GetAttribute("HipHeight") or 5
			mount.MoveTo(p, padCFrame(slot, hip))
			mount.Freeze(p, true)
			p:SetAttribute("RaceActive", true)
			p:SetAttribute("RacePass", 0)
			p:SetAttribute("RaceStart", nil)
			setState(p, "Countdown")
			r.Racers[p] = { Slot = slot, Pass = 0, Status = "Waiting", Over = 0 }
		else
			Net.notify(p, "warning", "You need a dragon to race - hatch an egg first!")
			releaseRacer(p)
		end
	end
	r.Started = #r.Players
	if r.Started == 0 then
		race = nil
		return
	end
	r.State = "Countdown"
	r.CountEnds = clock() + RaceConfig.CountdownSeconds
	r.Counted = RaceConfig.CountdownSeconds + 1
	lobbySignal()
end

local function go()
	local r = race
	if not r then
		return
	end
	r.State = "Running"
	r.StartClock = clock()
	r.StartTime = Workspace:GetServerTimeNow()
	local mount = Services.MountService
	for _, p in r.Players do
		local rc = r.Racers[p]
		mount.Freeze(p, false)
		rc.Status = "Racing"
		rc.Pass = 1
		rc.LastPos = positionOf(p)
		rc.LastT = clock()
		p:SetAttribute("RacePass", 1)
		p:SetAttribute("RaceStart", r.StartTime)
		setState(p, "Running")
		Net.signal(p, "RaceGo", { Start = r.StartTime })
	end
end

-- One 0.1 s step of a racing player: validate movement, check the next gate.
local function sample(r, player: Player, rc, now: number)
	local position = positionOf(player)
	local mount = Services.MountService
	local comp = mount.Get(player)
	if not position or not comp or not comp.Riding then
		return dnf(r, player, "You left your dragon.")
	end
	if (position - RaceConfig.Island.Center).Magnitude > RaceConfig.CourseLeave then
		return dnf(r, player, "You left the course.")
	end
	local dt = math.max(now - rc.LastT, 1e-3)
	local last = rc.LastPos or position
	-- speed over a short window (replication makes single samples noisy); teleports and hacked
	-- speed stay over the limit for several samples in a row
	local history = rc.History
	if not history then
		history = {}
		rc.History = history
	end
	table.insert(history, { T = now, P = position })
	while #history > 1 and now - history[1].T > RaceConfig.SpeedWindow do
		table.remove(history, 1)
	end
	local span = now - history[1].T
	if span >= 0.3 then
		local windowed = (position - history[1].P).Magnitude / span
		if windowed > RaceConfig.MaxSpeed then
			rc.Over = (rc.Over or 0) + 1
			if rc.Over >= RaceConfig.MaxOverSamples then
				return dnf(r, player, "Disqualified: moving too fast.")
			end
		else
			rc.Over = math.max(0, (rc.Over or 0) - 1)
		end
	end
	-- a ring only counts for honest movement: a jump through it never does
	local honest = (position - last).Magnitude <= math.max(40, RaceConfig.MaxSpeed * dt * 1.15)
	local total = RaceConfig.totalPasses()
	local gate = RaceConfig.gateForPass(rc.Pass)
	local f = (function()
		-- segment vs the gate's disc (forward crossings only)
		local c = RaceConfig.toWorld(gate.Position)
		local n = gate.Direction
		local s0 = (last - c):Dot(n)
		local s1 = (position - c):Dot(n)
		if honest and s0 <= 0 and s1 > 0 then
			local frac = (0 - s0) / (s1 - s0)
			local hit = last:Lerp(position, frac)
			if (hit - c).Magnitude <= RaceConfig.GateRadius + RaceConfig.GateSlack then
				return frac
			end
		end
		return nil
	end)()
	if f then
		local crossed = rc.LastT + f * dt
		rc.PassTimes = rc.PassTimes or {}
		rc.PassTimes[rc.Pass] = crossed - r.StartClock
		if rc.Pass >= total then
			finishRacer(r, player, rc, math.floor((crossed - r.StartClock) * 1000 + 0.5))
		else
			rc.Pass += 1
			player:SetAttribute("RacePass", rc.Pass)
			Net.signal(player, "RaceProgress", {
				Pass = rc.Pass,
				Total = total,
				Lap = RaceConfig.lapOfPass(rc.Pass),
				Ms = math.floor((crossed - r.StartClock) * 1000),
			})
		end
	end
	rc.LastPos = position
	rc.LastT = now
end

local function endRace()
	local r = race
	if not r then
		return
	end
	r.State = "Done"
	r.DoneAt = clock()
	local list = results(r)
	for _, p in r.Players do
		Net.signal(p, "RaceEnd", { Results = list, Racers = r.Started })
		setState(p, nil)
		p:SetAttribute("RaceActive", nil)
		p:SetAttribute("RacePass", nil)
		p:SetAttribute("RaceStart", nil)
	end
	-- a short pause, then the lobby opens for the people who were waiting
	task.delay(4, function()
		if race == r then
			closeRace()
		end
	end)
end

-- Race order for the HUD ("2ND of 4"): finished racers by place, the others by gates passed and
-- the distance left to the next one.
local function sendPositions(r)
	local score: { [Player]: number } = {}
	local order = {}
	for _, p in r.Players do
		local rc = r.Racers[p]
		if rc and (rc.Status == "Racing" or rc.Status == "Finished") then
			if rc.Status == "Finished" then
				score[p] = 1e9 - rc.Place
			else
				local position = positionOf(p)
				local gate = RaceConfig.gateForPass(rc.Pass)
				local left = position and (position - RaceConfig.toWorld(gate.Position)).Magnitude or 1e4
				score[p] = rc.Pass * 1e4 - math.min(left, 9999)
			end
			table.insert(order, p)
		end
	end
	table.sort(order, function(a, b)
		return score[a] > score[b]
	end)
	for i, p in order do
		if r.Racers[p].Status == "Racing" then
			Net.signal(p, "RacePos", { Place = i, Of = #order })
		end
	end
end

local function step()
	local r = race
	if not r then
		return
	end
	local now = clock()
	if r.State == "Lobby" then
		for i = #r.Players, 1, -1 do
			local p = r.Players[i]
			if p.Parent ~= Players then
				table.remove(r.Players, i)
			end
		end
		if #r.Players == 0 then
			race = nil
			return
		end
		r.Tick = (r.Tick or 0) + 1
		if r.Tick % 5 == 0 then
			lobbySignal() -- the countdown label refreshes twice a second
		end
		if now >= r.LobbyEnds then
			beginCountdown()
		end
	elseif r.State == "Countdown" then
		local left = r.CountEnds - now
		local n = math.ceil(left)
		if n < r.Counted and n >= 1 then
			r.Counted = n
			for _, p in r.Players do
				Net.signal(p, "RaceCount", { N = n })
			end
		end
		if left <= 0 then
			go()
		end
	elseif r.State == "Running" then
		local racing = 0
		for _, p in table.clone(r.Players) do
			local rc = r.Racers[p]
			if rc and rc.Status == "Racing" then
				if p.Parent ~= Players then
					rc.Status = "DNF"
					rc.Reason = "Left the game."
				else
					sample(r, p, rc, now)
				end
				if rc.Status == "Racing" then
					racing += 1
				end
			end
		end
		r.PosTick = (r.PosTick or 0) + 1
		if r.PosTick % 5 == 0 and r.Started > 1 then
			sendPositions(r)
		end
		local timeout = now - r.StartClock > RaceConfig.MaxRaceSeconds
		local grace = r.FirstFinish and (now - r.FirstFinish > RaceConfig.FinishGraceSeconds)
		if racing == 0 or timeout or grace then
			for _, p in r.Players do
				local rc = r.Racers[p]
				if rc and rc.Status == "Racing" then
					dnf(r, p, timeout and "Time is up." or "Too slow.")
				end
			end
			endRace()
		end
	end
end

-- A boost ring was flown through (the client starts the dash at once): the movement check is
-- relaxed for the length of the dash, but only when the racer really is at that ring.
local function onBoost(player: Player, p)
	local rc = racerOf(player)
	if not rc or rc.Status ~= "Racing" or not Net.check.int(p.Index, 1, #RaceConfig.Boosts) then
		return
	end
	local ring = RaceConfig.Boosts[p.Index]
	local position = positionOf(player)
	if not position or (position - RaceConfig.toWorld(ring.Position)).Magnitude > RaceConfig.Boost.Radius * 3 + 60 then
		return
	end
	local mount = Services.MountService
	local comp = mount and mount.Get(player)
	if comp then
		comp.DashUntil = os.clock() + RaceConfig.Boost.Duration + 0.8
	end
end

-- ============================================================== requests
local function snapshot(player: Player)
	local data = Data.Get(player)
	local mine = racerOf(player)
	local list = {}
	if race then
		for _, p in race.Players do
			table.insert(list, { Name = p.DisplayName, UserId = p.UserId })
		end
	end
	local key = RaceConfig.monthKey()
	local rd = data and data.Race
	return {
		State = race and race.State or "Idle",
		Racers = list,
		Left = (race and race.State == "Lobby") and math.max(0, race.LobbyEnds - clock()) or 0,
		Joined = (race and table.find(race.Players, player) ~= nil) or table.find(waiting, player) ~= nil,
		Queued = table.find(waiting, player) ~= nil,
		Running = race ~= nil and (race.State == "Running" or race.State == "Countdown"),
		Mine = mine and { Slot = mine.Slot, Pass = mine.Pass } or nil,
		Best = rd and rd.Best or 0,
		MonthBest = (rd and rd.MonthKey == key) and rd.MonthBest or 0,
		Runs = rd and rd.Runs or 0,
		Wins = rd and rd.Wins or 0,
		Month = key,
		MonthLeft = RaceConfig.secondsLeftInMonth(),
		Prize = RaceConfig.Monthly.PrizeText,
		Headline = RaceConfig.Monthly.Headline,
		OnIsland = onIsland(positionOf(player)),
		Winners = winners,
		Laps = RaceConfig.Laps,
		Gates = RaceConfig.GateCount,
		Max = RaceConfig.MaxRacers,
	}
end

local function handleJoin(player: Player)
	if not Data.Get(player) then
		return false, "NOT_LOADED"
	end
	if not onIsland(positionOf(player)) then
		return false, "NOT_ON_ISLAND", "Fly to Race Island first (Teleport menu)."
	end
	if player:GetAttribute("InArena") then
		return false, "IN_ARENA", "Leave the arena before you race."
	end
	local mine = racerOf(player)
	if mine and (mine.Status == "Racing" or mine.Status == "Waiting") and race.State ~= "Done" then
		return true, snapshot(player)
	end
	if race and table.find(waiting, player) then
		return true, snapshot(player)
	end
	if not race or race.State == "Done" then
		race = newRace()
	end
	if race.State == "Lobby" then
		if #race.Players >= RaceConfig.MaxRacers then
			return false, "FULL", "The lobby is full - wait for the next race."
		end
		if not table.find(race.Players, player) then
			table.insert(race.Players, player)
		end
		setState(player, "Lobby")
		if #race.Players >= RaceConfig.MaxRacers then
			race.LobbyEnds = math.min(race.LobbyEnds, clock() + RaceConfig.FullLobbySeconds)
		end
		lobbySignal()
		return true, snapshot(player)
	end
	-- a race is under way: you open the next lobby
	table.insert(waiting, player)
	return true, snapshot(player)
end

local function handleLeave(player: Player)
	removeFrom(waiting, player)
	if race then
		if race.State == "Lobby" then
			removeFrom(race.Players, player)
			releaseRacer(player)
			if #race.Players == 0 then
				race = nil
			else
				lobbySignal()
			end
		elseif race.Racers[player] and race.Racers[player].Status == "Racing" then
			dnf(race, player, "You left the race.")
		end
	end
	return true, snapshot(player)
end

local function handleStartNow(player: Player)
	if not race or race.State ~= "Lobby" or not table.find(race.Players, player) then
		return false, "NOT_IN_LOBBY"
	end
	if #race.Players ~= 1 then
		return false, "NOT_ALONE", "Other racers are waiting - the race starts when the lobby timer ends."
	end
	race.LobbyEnds = math.min(race.LobbyEnds, clock() + RaceConfig.SoloStartSeconds)
	lobbySignal()
	return true, snapshot(player)
end

local function handleTop(player: Player, p)
	if not Net.check.str(p.Board, 24) then
		return false, "BAD_REQUEST"
	end
	local lb = Services.LeaderboardService
	if not lb or not lb.TopNamed then
		return false, "NO_BOARD"
	end
	return true, { List = lb.TopNamed(p.Board) }
end

-- ============================================================== monthly champions
local function loadWinners()
	if not winnersStore then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore("RaceWinners_v1")
		end)
		winnersStore = ok and store or nil
	end
	if winnersStore then
		local ok, value = pcall(function()
			return (winnersStore :: DataStore):GetAsync("history")
		end)
		if ok and type(value) == "table" then
			winners = value
		end
	end
end

local function saveWinners(entry)
	for _, w in winners do
		if w.Month == entry.Month then
			return false
		end
	end
	-- another server may have crowned the same month a moment ago: the stored history decides
	local added = true
	if winnersStore then
		local ok = pcall(function()
			(winnersStore :: DataStore):UpdateAsync("history", function(old)
				local list = type(old) == "table" and old or {}
				for _, w in list do
					if w.Month == entry.Month then
						added = false
						return nil
					end
				end
				table.insert(list, 1, entry)
				while #list > 24 do
					table.remove(list)
				end
				return list
			end)
		end)
		if ok and not added then
			loadWinners() -- take over the other server's record, no second announcement
			return false
		end
	end
	table.insert(winners, 1, entry)
	while #winners > 24 do
		table.remove(winners)
	end
	return true
end

local function showWinners()
	if island then
		local ok, RaceIsland = pcall(function()
			return require(ServerScriptService:WaitForChild("World"):WaitForChild("RaceIsland"))
		end)
		if ok then
			RaceIsland.setWinners(island, winners)
		end
	end
end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

-- The champion of `monthKey` is rewarded once, as soon as they are in a server.
local function crown(player: Player, entry)
	local data = Data.Get(player)
	if not data or (data.Race.Crowns or {})[entry.Month] then
		return
	end
	Data.Set(player, { "Race", "Crowns", entry.Month }, true)
	Data.Set(player, { "Flags", "RaceChampion" }, entry.Month)
	player:SetAttribute("RaceChampion", entry.Month)
	local given = reward(player, RaceConfig.Monthly.Winner, "RACE CHAMPION")
	Net.notify(player, "rare", string.format("You are the RACE CHAMPION of %s!  +$%d", MONTHS[tonumber(string.sub(entry.Month, 5, 6)) or 1] or entry.Month, given.Cash))
end

local function announce(entry)
	local month = MONTHS[tonumber(string.sub(entry.Month, 5, 6)) or 1] or entry.Month
	Net.broadcast("RareHatch", {
		Player = entry.Name,
		UserId = entry.UserId,
		Species = "",
		Mutation = "None",
		Rarity = "Exclusive",
		Odds = 0,
		Mega = true,
		Text = string.format("%s is the RACE CHAMPION of %s!", entry.Name, month),
		Sub = string.format("%s  -  %s", RaceConfig.formatTime(entry.Ms), RaceConfig.Monthly.PrizeText),
	})
end

local function rollover()
	local lb = Services.LeaderboardService
	if not lb or not lb.TopOfStore then
		return
	end
	local prev = RaceConfig.previousMonthKey()
	for _, w in winners do
		if w.Month == prev then
			return
		end
	end
	local top = lb.TopOfStore("LB_RaceMonthly_" .. prev .. "_v1", 1)
	local first = top and top[1]
	if not first or first.Value <= 0 then
		return
	end
	local entry = {
		Month = prev,
		UserId = first.UserId,
		Name = lb.NameOf(first.UserId),
		Ms = RaceConfig.scoreTime(first.Value),
	}
	if saveWinners(entry) then
		warn(string.format("[Race] MONTHLY WINNER %s: %s (id %d) in %s - %s", entry.Month, entry.Name, entry.UserId, RaceConfig.formatTime(entry.Ms), RaceConfig.Monthly.PrizeText))
		announce(entry)
		showWinners()
		local online = Players:GetPlayerByUserId(entry.UserId)
		if online then
			crown(online, entry)
		end
	end
end

-- ============================================================== lifecycle
function RaceService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Race", "Join", handleJoin, { Burst = 4, PerSecond = 1.5 })
	Net.handle("Race", "Leave", handleLeave, { Burst = 4, PerSecond = 1.5 })
	Net.handle("Race", "StartNow", handleStartNow, { Burst = 3, PerSecond = 1 })
	Net.handle("Race", "State", function(player)
		return true, snapshot(player)
	end, { Burst = 6, PerSecond = 2 })
	Net.handle("Race", "Top", handleTop, { Burst = 4, PerSecond = 1.5 })
	Net.onEvent("RaceBoost", onBoost, { Burst = 6, PerSecond = 2 })
end

-- The race the player is in (nil when none): used by other services (travel, arena).
function RaceService.Active(player: Player): boolean
	local rc = racerOf(player)
	return rc ~= nil and (rc.Status == "Racing" or rc.Status == "Waiting")
end

function RaceService.Winners()
	return winners
end

function RaceService.Island(): Model?
	return island
end

-- Studio only (UI Lab, via DevService): crowns the player as last month's champion without any
-- DataStore round trip - banner, podium, trophy flag and reward, as on the first of a month.
function RaceService.DevCrown(player: Player)
	local data = Data.Get(player)
	if not data then
		return
	end
	local ms = tonumber(data.Race.Best) or 0
	local entry = {
		Month = RaceConfig.previousMonthKey(),
		UserId = player.UserId,
		Name = player.DisplayName,
		Ms = ms > 0 and ms or 41234,
	}
	for i = #winners, 1, -1 do
		if winners[i].Month == entry.Month then
			table.remove(winners, i)
		end
	end
	table.insert(winners, 1, entry)
	Data.Set(player, { "Race", "Crowns", entry.Month }, nil)
	announce(entry)
	showWinners()
	crown(player, entry)
end

-- tests / dev: current race table, the monthly check, the lobby / waiting lists
function RaceService._race()
	return race
end
function RaceService._rollover()
	rollover()
end
function RaceService._waiting()
	return waiting
end

function RaceService.Start()
	while not (Services.WorldService and Services.WorldService.Ready) do
		task.wait(0.25)
	end
	local worldFolder = Workspace:FindFirstChild("World") or Workspace
	local okBuild, built = pcall(function()
		local RaceIsland = require(ServerScriptService:WaitForChild("World"):WaitForChild("RaceIsland"))
		return RaceIsland.build(worldFolder)
	end)
	if okBuild then
		island = built
	else
		warn("[Race] island build failed: " .. tostring(built))
	end
	task.spawn(function()
		loadWinners()
		showWinners()
		while true do
			local ok, err = pcall(rollover)
			if not ok then
				warn("[Race] rollover: " .. tostring(err))
			end
			task.wait(RaceConfig.Monthly.CheckSeconds)
		end
	end)
	-- the champion of last month is crowned when they join
	Data.Loaded:Connect(function(player)
		-- the crown stays on for the month after the win
		local data = Data.Get(player)
		local mark = data and data.Flags and data.Flags.RaceChampion
		if mark == RaceConfig.previousMonthKey() or mark == RaceConfig.monthKey() then
			player:SetAttribute("RaceChampion", mark)
		end
		for _, w in winners do
			if w.UserId == player.UserId and w.Month == RaceConfig.previousMonthKey() then
				crown(player, w)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		removeFrom(waiting, player)
		if race and race.Racers[player] and race.Racers[player].Status == "Racing" then
			race.Racers[player].Status = "DNF"
			race.Racers[player].Reason = "Left the game."
		end
	end)
	task.spawn(function()
		while true do
			task.wait(RaceConfig.SampleSeconds)
			local ok, err = pcall(step)
			if not ok then
				warn("[Race] step: " .. tostring(err))
			end
		end
	end)
end

return RaceService

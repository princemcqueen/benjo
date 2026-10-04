--[[
	DuelService
	Turn-based dragon duels (DuelConfig): against an NPC trainer or another player. Server authority:
	the server keeps the match, rolls every hit and pays; the clients (DuelController) play the scene.

	Net (domain "Duel"):
	  Trainers {}            -> { List = { { Id, Name, Title, Level, Species preview..., Reward, Ready } }, Dragon = {..} | nil }
	  Start { Trainer }      -> match view (see view())
	  Challenge { UserId }   -> {} (the other player gets the signal DuelChallenge)
	  Respond { From, Accept } -> match view when accepted
	  Move { Id, Move }      -> { Waiting = true } (the result of the turn arrives as signal DuelTurn)
	  Forfeit { Id }         -> {}
	Signals to the players of a match:
	  DuelStart { match view }       DuelTurn { Id, Turn, Events = { ... }, State = { HP1, HP2, PP... } }
	  DuelEnd { Id, Winner = side, Reward = { Cash, XP }, Forfeit? }
	  DuelChallenge { From, Name, Expires }   DuelChallengeEnd { From, Reason }
	Player attributes: InDuel (true while in a match).

	A turn: both sides choose; GUARD goes first, then the faster dragon; a KO ends the match at once.
	Events of a turn: { Side, Move, Name, Hit, Damage, Crit, Eff, Guarded, Fail, Text, HP1, HP2 }.
	Test hooks: DuelService.Seed(n), DuelService.Match(player), DuelService.Resolve(match, choices).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local DragonStats = require(Shared:WaitForChild("DragonStats"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local DuelConfig = require(Configs:WaitForChild("DuelConfig"))

local DuelService = {}

local Data
local Services
local rng = Random.new()
local matches: { [string]: any } = {} -- by id
local byPlayer: { [Player]: any } = {}
local challenges: { [Player]: { From: Player, At: number } } = {} -- by the challenged player
local lastWin: { [Player]: { [string]: number } } = {} -- trainer cooldowns
local pairLast: { [string]: number } = {} -- last player duel of two players
local serial = 0

local function clock(): number
	return Workspace:GetServerTimeNow()
end

function DuelService.Seed(n: number)
	rng = Random.new(n)
end

-- ============================================================== fighters
local function specialOf(record): (string, string)
	if record.Mutation and record.Mutation ~= "None" then
		local m = MutationConfig.Mutations[record.Mutation]
		return "Burst", string.upper((m and m.Name or record.Mutation) .. " BURST")
	end
	return "Roar", "ROAR"
end

-- "Frost Dragon" / "Shiny Green Drake"
local function fullName(record): string
	if record.Mutation and record.Mutation ~= "None" then
		local m = MutationConfig.Mutations[record.Mutation]
		return (m and m.Name or record.Mutation) .. " " .. record.Name
	end
	return record.Name
end

-- A fighter from a dragon record (the player's own, or one made for a trainer); owner = whose it is.
local function makeFighter(player: Player?, owner: string, record)
	local rank = DragonConfig.rarityRank(record.Rarity)
	local special, specialName = specialOf(record)
	local maxHP = DuelConfig.maxHP(record.Level, rank)
	return {
		Player = player,
		Owner = owner,
		Name = fullName(record),
		Species = record.SpeciesId,
		DragonName = record.Name,
		Mutation = record.Mutation or "None",
		Level = record.Level,
		Rarity = record.Rarity,
		Rank = rank,
		Element = DuelConfig.elementOf(record.SpeciesId),
		MaxHP = maxHP,
		HP = maxHP,
		Speed = DragonStats.cruiseSpeed(record),
		Damage = DuelConfig.baseDamage(record.Level, rank),
		Special = special, -- "Burst" | "Roar"
		SpecialName = specialName,
		PP = { Fire = DuelConfig.Moves.Fire.PP, Guard = DuelConfig.Moves.Guard.PP, Special = DuelConfig.Moves[special == "Burst" and "Special" or "Roar"].PP },
		Buff = 1,
		BuffTurns = 0,
		Guarding = false,
		LastMove = "",
	}
end

local function fighterView(f)
	return {
		Name = f.Name,
		Owner = f.Owner,
		Species = f.Species,
		DragonName = f.DragonName,
		Mutation = f.Mutation,
		Level = f.Level,
		Rarity = f.Rarity,
		Element = f.Element,
		MaxHP = f.MaxHP,
		HP = f.HP,
		Special = f.Special,
		SpecialName = f.SpecialName,
		PP = { Fire = f.PP.Fire, Guard = f.PP.Guard, Special = f.PP.Special },
		Buff = f.Buff,
	}
end

-- What the match looks like to the player on `side` (1 or 2): Fighters[1] is always them.
local function view(match, side: number)
	local me, foe = match.Sides[side], match.Sides[3 - side]
	return {
		Id = match.Id,
		Kind = match.Kind,
		Side = side,
		Turn = match.Turn,
		Title = match.Title,
		Color = match.Color,
		Fighters = { fighterView(me), fighterView(foe) },
	}
end

-- The player's equipped dragon (a copy of the record) or nil.
local function equipped(player: Player)
	local data = Data.Get(player)
	local record = data and data.Dragons[data.EquippedDragon]
	return record
end

local function trainerDragon(trainer, level: number)
	local id = trainer.Species[rng:NextInteger(1, #trainer.Species)]
	local mutation = "None"
	for _, m in trainer.Mutations do
		if rng:NextNumber() < m[2] then
			mutation = m[1]
			break
		end
	end
	local record = DragonStats.newRecord("NPC", id, mutation, 0)
	record.Level = level
	DragonStats.refresh(record)
	return record
end

-- ============================================================== resolving a turn
local function actionOf(f, move: string)
	if move == "Special" then
		return f.Special == "Burst" and "Special" or "Roar"
	end
	return move
end

local function usable(f, move: string): boolean
	if move == "Strike" then
		return true
	end
	if move == "Fire" or move == "Guard" then
		return f.PP[move] > 0
	end
	if move == "Special" then
		return f.PP.Special > 0
	end
	return false
end

-- The NPC picks its move.
local function chooseFor(f, foe): string
	local lowHP = f.HP < f.MaxHP * 0.3
	if lowHP and usable(f, "Guard") and f.LastMove ~= "Guard" and rng:NextNumber() < 0.3 then
		return "Guard"
	end
	local pool = { { "Strike", 0.34 } }
	if usable(f, "Fire") then
		table.insert(pool, { "Fire", 0.4 })
	end
	if usable(f, "Special") and (f.Special == "Burst" or f.Buff == 1) then
		table.insert(pool, { "Special", 0.26 })
	end
	local total = 0
	for _, e in pool do
		total += e[2]
	end
	local roll = rng:NextNumber() * total
	for _, e in pool do
		roll -= e[2]
		if roll <= 0 then
			return e[1]
		end
	end
	return "Strike"
end

local function speedOrder(match, choices)
	local order = { 1, 2 }
	local function priority(side)
		return choices[side] == "Guard" and 1 or 0
	end
	table.sort(order, function(a, b)
		if priority(a) ~= priority(b) then
			return priority(a) > priority(b)
		end
		local sa, sb = match.Sides[a].Speed, match.Sides[b].Speed
		if sa ~= sb then
			return sa > sb
		end
		return a < b
	end)
	return order
end

local function eventBase(match, side, move, name)
	return { Side = side, Move = move, Name = name, Hit = false, Damage = 0, Crit = false, Eff = 1, Guarded = false, Fail = false }
end

-- Plays one action; returns the event.
local function act(match, side: number, choice: string)
	local me, foe = match.Sides[side], match.Sides[3 - side]
	local action = actionOf(me, choice)
	local def = DuelConfig.Moves[action]
	local event = eventBase(match, side, action, def.Name)
	if action == "Special" then
		event.Name = me.SpecialName
	end
	-- uses left
	if action == "Fire" or action == "Guard" then
		me.PP[action] -= 1
	elseif action == "Special" or action == "Roar" then
		me.PP.Special -= 1
	end
	if action == "Guard" then
		if me.LastMove == "Guard" then
			event.Fail = true
			event.Text = string.format("%s's guard failed!", me.Name)
		else
			me.Guarding = true
			event.Text = string.format("%s braces itself!", me.Name)
		end
	elseif action == "Roar" then
		me.Buff = def.Buff
		me.BuffTurns = def.BuffTurns
		event.Text = string.format("%s roars! Its attacks grow stronger.", me.Name)
	else
		-- an attack
		event.Text = string.format("%s used %s!", me.Name, event.Name)
		if rng:NextNumber() > def.Accuracy then
			event.Text ..= " It missed!"
		else
			local element = action == "Strike" and "Neutral" or me.Element
			local eff = element == "Neutral" and 1 or DuelConfig.effectiveness(element, foe.Element)
			local crit = not foe.Guarding and rng:NextNumber() < DuelConfig.CritChance
			local amount = me.Damage * def.Power * me.Buff * eff * (crit and DuelConfig.CritMultiplier or 1)
			amount *= rng:NextNumber(DuelConfig.Variance[1], DuelConfig.Variance[2])
			if foe.Guarding then
				amount *= 0.5
				event.Guarded = true
			end
			local dmg = math.max(1, math.floor(amount + 0.5))
			foe.HP = math.max(0, foe.HP - dmg)
			event.Hit = true
			event.Damage = dmg
			event.Crit = crit
			event.Eff = eff
			if crit then
				event.Text ..= " A critical hit!"
			end
			if eff > 1 then
				event.Text ..= " It's super effective!"
			elseif eff < 1 then
				event.Text ..= " It's not very effective..."
			end
			if event.Guarded then
				event.Text ..= string.format(" %s guarded!", foe.Name)
			end
		end
	end
	me.LastMove = choice == "Special" and "Special" or choice
	event.HP1 = match.Sides[1].HP
	event.HP2 = match.Sides[2].HP
	return event
end

-- Resolves a turn with the choices { [1] = move, [2] = move }. Returns the events; match.Over / Winner set.
function DuelService.Resolve(match, choices)
	local events = {}
	for _, side in speedOrder(match, choices) do
		local me = match.Sides[side]
		if me.HP > 0 and match.Sides[3 - side].HP > 0 then
			table.insert(events, act(match, side, choices[side]))
			if match.Sides[3 - side].HP <= 0 then
				match.Over = true
				match.Winner = side
				break
			end
		end
	end
	for _, f in match.Sides do
		f.Guarding = false
		if f.BuffTurns > 0 then
			f.BuffTurns -= 1
			if f.BuffTurns == 0 then
				f.Buff = 1
			end
		end
	end
	match.Turn += 1
	return events
end

-- ============================================================== rewards and ending
local function reward(player: Player, spec, share: number)
	local income = Services.EconomyService.IncomeRate(player)
	local cash = math.floor(math.max(spec.Min, income * spec.Minutes * 60) * share + 0.5)
	local xp = math.floor(spec.XP * share + 0.5)
	Services.EconomyService.Earn(player, cash, "Duel")
	Services.LevelService.Add(player, xp, "Duel")
	return { Cash = cash, XP = xp }
end

local function finish(match, winner: number?, forfeit: boolean?)
	if match.Closed then
		return
	end
	match.Closed = true
	match.Over = true
	match.Winner = winner
	matches[match.Id] = nil
	for side = 1, 2 do
		local player = match.Players[side]
		if player then
			byPlayer[player] = nil
			player:SetAttribute("InDuel", nil)
			local rewardOut = nil
			local data = Data.Get(player)
			if winner == side then
				if match.Kind == "NPC" then
					lastWin[player] = lastWin[player] or {}
					local last = lastWin[player][match.Trainer.Id] or -math.huge
					local fresh = clock() - last >= DuelConfig.TrainerCooldown
					rewardOut = reward(player, match.Trainer.Reward, fresh and 1 or DuelConfig.RematchShare)
					rewardOut.Rematch = not fresh
					lastWin[player][match.Trainer.Id] = clock()
				else
					-- a player duel pays only when it was a real fight (a few turns) and not a rematch of the same
					-- two players within PairCooldown seconds
					local other = match.Players[3 - side]
					local key = other and (math.min(player.UserId, other.UserId) .. ":" .. math.max(player.UserId, other.UserId)) or ""
					local fresh = clock() - (pairLast[key] or -math.huge) >= DuelConfig.PairCooldown
					local share = (match.Turn >= DuelConfig.MinTurnsForReward and not forfeit) and (fresh and 1 or DuelConfig.RematchShare) or 0
					if share > 0 then
						rewardOut = reward(player, DuelConfig.PlayerWin, share)
					else
						rewardOut = { Cash = 0, XP = 0, Rematch = true }
					end
					pairLast[key] = clock()
				end
				if data then
					Data.Increment(player, { "Stats", "DuelsWon" }, 1)
				end
			elseif winner then
				if data then
					Data.Increment(player, { "Stats", "DuelsLost" }, 1)
				end
				rewardOut = { Cash = 0, XP = DuelConfig.LoserXP }
				Services.LevelService.Add(player, DuelConfig.LoserXP, "Duel")
			end
			Net.signal(player, "DuelEnd", { Id = match.Id, Winner = winner, Side = side, Reward = rewardOut, Forfeit = forfeit == true, HP1 = match.Sides[side].HP, HP2 = match.Sides[3 - side].HP })
		end
	end
end

-- ============================================================== starting
-- Why this player cannot duel right now (nil = can).
local function blocked(player: Player): (string?, string?)
	if byPlayer[player] then
		return "IN_DUEL", "You are already in a duel."
	end
	local data = Data.Get(player)
	if not data then
		return "NOT_LOADED"
	end
	if not equipped(player) then
		return "NO_DRAGON", "Equip a dragon first (DRAGONS)."
	end
	if player:GetAttribute("RaceState") or player:GetAttribute("RaceActive") then
		return "RACING", "Finish your race first."
	end
	local combat = Services.CombatService
	if combat and combat.Fighter and combat.Fighter(player) then
		return "IN_ARENA", "Leave the arena first."
	end
	return nil
end

local function newId(): string
	serial += 1
	return "M" .. tostring(serial)
end

local function open(match)
	matches[match.Id] = match
	for side = 1, 2 do
		local player = match.Players[side]
		if player then
			byPlayer[player] = match
			player:SetAttribute("InDuel", true)
			-- stand down from the dragon: the scene shows the dragons on its own stage
			local mount = Services.MountService
			if mount and mount.IsRiding(player) then
				mount.Dismount(player)
			end
		end
	end
	match.Deadline = clock() + DuelConfig.TurnSeconds
	match.LastAct = clock()
end

local function startNPC(player: Player, trainer)
	local record = equipped(player)
	local me = makeFighter(player, player.DisplayName, record)
	local foeRecord = trainerDragon(trainer, math.clamp(record.Level + trainer.LevelDelta, 1, DragonConfig.MaxLevel))
	local foe = makeFighter(nil, trainer.Name, foeRecord)
	local match = {
		Id = newId(),
		Kind = "NPC",
		Trainer = trainer,
		Title = trainer.Title,
		Color = trainer.Color,
		Sides = { me, foe },
		Players = { player, nil },
		Turn = 1,
		Choices = {},
	}
	open(match)
	return match
end

local function startPlayers(a: Player, b: Player)
	local fa = makeFighter(a, a.DisplayName, equipped(a))
	local fb = makeFighter(b, b.DisplayName, equipped(b))
	local match = {
		Id = newId(),
		Kind = "PVP",
		Title = "Duel",
		Color = Color3.fromRGB(255, 80, 70),
		Sides = { fa, fb },
		Players = { a, b },
		Turn = 1,
		Choices = {},
	}
	open(match)
	return match
end

function DuelService.Match(player: Player)
	return byPlayer[player]
end

-- ============================================================== net handlers
local function handleTrainers(player: Player)
	local record = equipped(player)
	local list = {}
	local income = Services.EconomyService.IncomeRate(player)
	for _, t in DuelConfig.Trainers do
		local level = record and math.clamp(record.Level + t.LevelDelta, 1, DragonConfig.MaxLevel) or 0
		local last = lastWin[player] and lastWin[player][t.Id] or -math.huge
		table.insert(list, {
			Id = t.Id,
			Name = t.Name,
			Title = t.Title,
			Level = level,
			Cash = math.floor(math.max(t.Reward.Min, income * t.Reward.Minutes * 60) + 0.5),
			XP = t.Reward.XP,
			Cooldown = math.max(0, math.ceil(DuelConfig.TrainerCooldown - (clock() - last))),
		})
	end
	local dragon = nil
	if record then
		dragon = { Name = record.Name, Species = record.SpeciesId, Mutation = record.Mutation, Level = record.Level, Rarity = record.Rarity, Element = DuelConfig.elementOf(record.SpeciesId) }
	end
	return true, { List = list, Dragon = dragon }
end

local function handleStart(player: Player, p)
	local trainer = type(p.Trainer) == "string" and DuelConfig.trainer(p.Trainer) or nil
	if not trainer then
		return false, "BAD_REQUEST"
	end
	local code, msg = blocked(player)
	if code then
		return false, code, msg
	end
	local match = startNPC(player, trainer)
	return true, view(match, 1)
end

local function endChallenge(target: Player, reason: string)
	local c = challenges[target]
	if c then
		challenges[target] = nil
		Net.signal(c.From, "DuelChallengeEnd", { From = c.From.UserId, Reason = reason, Name = target.DisplayName })
		Net.signal(target, "DuelChallengeEnd", { From = c.From.UserId, Reason = reason, Name = c.From.DisplayName })
	end
end

local function handleChallenge(player: Player, p)
	if not Net.check.int(p.UserId, 1, 1e13) then
		return false, "BAD_REQUEST"
	end
	local target = Players:GetPlayerByUserId(p.UserId)
	if not target or target == player then
		return false, "NO_PLAYER", "That player is not here."
	end
	local code, msg = blocked(player)
	if code then
		return false, code, msg
	end
	local code2 = blocked(target)
	if code2 then
		return false, "BUSY", target.DisplayName .. " cannot duel right now."
	end
	if challenges[target] then
		return false, "BUSY", target.DisplayName .. " has a challenge waiting already."
	end
	challenges[target] = { From = player, At = clock() }
	Net.signal(target, "DuelChallenge", { From = player.UserId, Name = player.DisplayName, Expires = DuelConfig.ChallengeSeconds })
	task.delay(DuelConfig.ChallengeSeconds, function()
		local c = challenges[target]
		if c and c.From == player and clock() - c.At >= DuelConfig.ChallengeSeconds - 0.5 then
			endChallenge(target, "Expired")
		end
	end)
	return true, {}
end

local function handleRespond(player: Player, p)
	local c = challenges[player]
	if not c or not Net.check.int(p.From, 1, 1e13) or c.From.UserId ~= p.From then
		return false, "NO_CHALLENGE", "That challenge is over."
	end
	if p.Accept ~= true then
		endChallenge(player, "Declined")
		return true, {}
	end
	local from = c.From
	challenges[player] = nil
	if from.Parent == nil then
		return false, "NO_PLAYER"
	end
	local code, msg = blocked(player)
	if code then
		return false, code, msg
	end
	if blocked(from) then
		return false, "BUSY", from.DisplayName .. " cannot duel any more."
	end
	local match = startPlayers(from, player)
	Net.signal(from, "DuelStart", view(match, 1))
	return true, view(match, 2)
end

local function sideOf(match, player: Player): number?
	if match.Players[1] == player then
		return 1
	elseif match.Players[2] == player then
		return 2
	end
	return nil
end

local function playTurn(match)
	local choices = { match.Choices[1], match.Choices[2] }
	if match.Kind == "NPC" then
		choices[2] = chooseFor(match.Sides[2], match.Sides[1])
	end
	match.Choices = {}
	local events = DuelService.Resolve(match, choices)
	local state = {
		Turn = match.Turn,
		Fighters = { fighterView(match.Sides[1]), fighterView(match.Sides[2]) },
	}
	match.Deadline = clock() + DuelConfig.TurnSeconds
	for side = 1, 2 do
		local player = match.Players[side]
		if player then
			-- (a player on side 2 sees the match from their own side: they are "1" for themselves)
			local mine = {}
			for i, e in events do
				mine[i] = table.clone(e)
				if side == 2 then
					mine[i].Side = 3 - e.Side
					mine[i].HP1, mine[i].HP2 = e.HP2, e.HP1
				end
			end
			local st = side == 1 and state or { Turn = state.Turn, Fighters = { state.Fighters[2], state.Fighters[1] } }
			Net.signal(player, "DuelTurn", { Id = match.Id, Turn = match.Turn, Events = mine, State = st })
		end
	end
	if match.Over then
		-- (the clients play the turn first; the end follows when they are done or after a pause)
		task.delay(0.5, function()
			finish(match, match.Winner)
		end)
	end
end

local function handleMove(player: Player, p)
	local match = byPlayer[player]
	if not match or match.Closed or match.Id ~= p.Id then
		return false, "NO_MATCH"
	end
	if type(p.Move) ~= "string" or not table.find(DuelConfig.MoveOrder, p.Move) then
		return false, "BAD_REQUEST"
	end
	local side = sideOf(match, player)
	if not side or match.Over then
		return false, "NO_MATCH"
	end
	if match.Choices[side] then
		return false, "ALREADY_CHOSEN"
	end
	local me = match.Sides[side]
	if not usable(me, p.Move) then
		return false, "NO_PP", "No uses left for that move."
	end
	match.Choices[side] = p.Move
	match.LastAct = clock()
	local ready = match.Choices[1] and (match.Kind == "NPC" or match.Choices[2])
	if ready then
		playTurn(match)
		return true, { Played = true }
	end
	return true, { Waiting = true }
end

local function handleForfeit(player: Player, p)
	local match = byPlayer[player]
	if not match or match.Id ~= p.Id then
		return false, "NO_MATCH"
	end
	local side = sideOf(match, player)
	finish(match, 3 - side, true)
	return true, {}
end

-- ============================================================== lifecycle
function DuelService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Duel", "Trainers", handleTrainers, { Burst = 6, PerSecond = 2 })
	Net.handle("Duel", "Start", handleStart, { Burst = 3, PerSecond = 1 })
	Net.handle("Duel", "Challenge", handleChallenge, { Burst = 3, PerSecond = 1 })
	Net.handle("Duel", "Respond", handleRespond, { Burst = 3, PerSecond = 1 })
	Net.handle("Duel", "Move", handleMove, { Burst = 6, PerSecond = 3 })
	Net.handle("Duel", "Forfeit", handleForfeit, { Burst = 3, PerSecond = 1 })
end

function DuelService.Start()
	Players.PlayerRemoving:Connect(function(player)
		local match = byPlayer[player]
		if match and not match.Closed then
			local side = sideOf(match, player)
			finish(match, side and 3 - side or nil, true)
		end
		challenges[player] = nil
		for target, c in challenges do
			if c.From == player then
				endChallenge(target, "Left")
			end
		end
		lastWin[player] = nil
	end)
	-- a player who does not choose in time uses STRIKE (player duels)
	task.spawn(function()
		while true do
			task.wait(1)
			for _, match in matches do
				if not match.Closed and match.Kind == "NPC" and clock() - match.LastAct > DuelConfig.IdleSeconds then
					finish(match, 2, true) -- the player went away: the trainer wins, nobody is paid
				elseif not match.Closed and match.Kind == "PVP" and clock() > match.Deadline then
					for side = 1, 2 do
						if not match.Choices[side] then
							match.Choices[side] = "Strike"
						end
					end
					playTurn(match)
				end
			end
		end
	end)
end

return DuelService

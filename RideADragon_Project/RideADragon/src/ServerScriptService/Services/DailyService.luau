--[[
	DailyService
	Daily rewards with a streak (DailyConfig). Data: data.Daily = { LastClaim = unix time, Streak = n }.

	  * a day is a UTC day; a reward can be claimed once per day
	  * claimed yesterday or today = the streak lives; a whole day missed = it starts again at 1
	  * the streak decides which day of the 7-day calendar pays (day = (streak - 1) % 7 + 1)

	Net (domain "Daily"):
	  State {} -> { CanClaim, Streak, Day, ClaimedToday, SecondsLeft, Days = { { Cash, Spins, Boost, Egg, State } x7 } }
	    Day = the calendar day that pays on the next claim (or paid today); Days[i].State = "Done" | "Today" | "Next" | "Later"
	  Claim {} -> { Day, Streak, Cash, Spins, Boost, Egg }
	Signal "DailyReady" {} to a player who joins with a reward waiting.
	Test hook: DailyService.Status(player, now).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local DailyConfig = require(Configs:WaitForChild("DailyConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))

local DailyService = {}

local Data
local Services

local function now(): number
	return os.time()
end

-- Where the player stands: can they claim, which day pays, how long until the next day.
function DailyService.Status(player: Player, t: number?)
	local data = Data.Get(player)
	if not data then
		return nil
	end
	local time = t or now()
	local daily = data.Daily or { LastClaim = 0, Streak = 0 }
	local today = DailyConfig.dayOf(time)
	local last = daily.LastClaim or 0
	local lastDay = last > 0 and DailyConfig.dayOf(last) or -100
	local alive = today - lastDay <= 1
	local streak = alive and (daily.Streak or 0) or 0
	local claimedToday = lastDay == today
	local cycle = DailyConfig.Cycle
	local day
	if claimedToday then
		day = (math.max(1, streak) - 1) % cycle + 1 -- the day that paid today
	else
		day = streak % cycle + 1 -- the day that pays now
	end
	return {
		CanClaim = not claimedToday,
		ClaimedToday = claimedToday,
		Streak = streak,
		Day = day,
		SecondsLeft = claimedToday and ((today + 1) * DailyConfig.SecondsPerDay - time) or 0,
	}
end

local function rewardOf(player: Player, day: number, streak: number)
	local def = DailyConfig.Days[day]
	local income = Services.EconomyService.IncomeRate(player)
	local reward = {}
	if def.Cash then
		reward.Cash = DailyConfig.cash(day, income, streak)
	end
	if def.Spins then
		reward.Spins = def.Spins
	end
	if def.Boost then
		reward.Boost = { Id = def.Boost.Id, Seconds = def.Boost.Seconds }
	end
	if def.Egg then
		reward.Egg = { Type = def.Egg.Type, Luck = def.Egg.Luck }
	end
	return reward
end

local function handleState(player: Player)
	local st = DailyService.Status(player)
	if not st then
		return false, "NOT_LOADED"
	end
	-- the completed streak the day's cash bonus follows (before today's claim)
	local before = math.max(0, st.ClaimedToday and st.Streak - 1 or st.Streak)
	local days = {}
	for i = 1, DailyConfig.Cycle do
		local entry = rewardOf(player, i, before)
		if i < st.Day or (i == st.Day and st.ClaimedToday) then
			entry.State = "Done"
		elseif i == st.Day then
			entry.State = "Today"
		elseif i == st.Day + 1 then
			entry.State = "Next"
		else
			entry.State = "Later"
		end
		days[i] = entry
	end
	return true, {
		CanClaim = st.CanClaim,
		Streak = st.Streak,
		Day = st.Day,
		ClaimedToday = st.ClaimedToday,
		SecondsLeft = st.SecondsLeft,
		Bonus = DailyConfig.bonus(before),
		Days = days,
	}
end

local function handleClaim(player: Player)
	local data = Data.Get(player)
	local st = DailyService.Status(player)
	if not data or not st then
		return false, "NOT_LOADED"
	end
	if not st.CanClaim then
		return false, "ALREADY_CLAIMED", "You already took today's reward. Come back tomorrow!"
	end
	local newStreak = st.Streak + 1
	local day = (newStreak - 1) % DailyConfig.Cycle + 1
	local reward = rewardOf(player, day, st.Streak)
	Data.Set(player, { "Daily" }, { LastClaim = now(), Streak = newStreak })
	local parts = {}
	if reward.Cash then
		Services.EconomyService.Earn(player, reward.Cash, "Daily")
		table.insert(parts, Format.cash(reward.Cash))
	end
	if reward.Spins then
		Services.SpinService.AddTickets(player, reward.Spins)
		table.insert(parts, string.format("%d spin%s", reward.Spins, reward.Spins == 1 and "" or "s"))
	end
	if reward.Boost then
		Services.BoostService.Add(player, reward.Boost.Id, reward.Boost.Seconds)
		table.insert(parts, string.format("%d min boost", reward.Boost.Seconds // 60))
	end
	if reward.Egg then
		local ok = Services.EggService.GiveEgg(player, reward.Egg.Type, reward.Egg.Luck, true)
		local def = EggConfig.Eggs[reward.Egg.Type]
		if ok then
			table.insert(parts, string.format("%s x%d", def and def.Name or "egg", reward.Egg.Luck))
		end
	end
	Net.notify(player, "rare", string.format("DAILY REWARD  day %d  (streak %d):  %s", day, newStreak, table.concat(parts, "  +  ")))
	return true, { Day = day, Streak = newStreak, Cash = reward.Cash, Spins = reward.Spins, Boost = reward.Boost, Egg = reward.Egg }
end

function DailyService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Daily", "State", handleState, { Burst = 6, PerSecond = 2 })
	Net.handle("Daily", "Claim", handleClaim, { Burst = 3, PerSecond = 1 })
end

function DailyService.Start()
	-- a reward is waiting: the HUD lights the DAILY button
	Data.Loaded:Connect(function(player)
		task.delay(3, function()
			local st = player.Parent and DailyService.Status(player)
			if st and st.CanClaim then
				Net.signal(player, "DailyReady", {})
			end
		end)
	end)
	-- ...and again when the day turns over for players who stay online
	task.spawn(function()
		local lastDay = DailyConfig.dayOf(now())
		while true do
			task.wait(30)
			local today = DailyConfig.dayOf(now())
			if today ~= lastDay then
				lastDay = today
				for _, player in Players:GetPlayers() do
					local st = DailyService.Status(player)
					if st and st.CanClaim then
						Net.signal(player, "DailyReady", {})
					end
				end
			end
		end
	end)
end

return DailyService

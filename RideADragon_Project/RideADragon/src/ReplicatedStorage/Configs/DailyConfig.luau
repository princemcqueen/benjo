--[[
	DailyConfig
	The daily reward calendar (DailyService / DailyWindow). One reward a day (UTC days); claiming on
	consecutive days builds a streak that walks through the 7 days of the calendar and starts again.
	Missing a whole day resets the streak. Every full week adds 10% to the cash of the calendar
	(at most +100%).

	A day lists any of:
	  Cash   = { Seconds, Min }       worth that many seconds of the player's income (at least Min)
	  Spins  = n                      spin tickets
	  Boost  = { Id, Seconds }        a timed boost (MonetizationConfig.Boosts)
	  Egg    = { Type, Luck }         an egg straight into the bag (never refused)
]]

local DailyConfig = {}

DailyConfig.Cycle = 7
DailyConfig.WeekBonus = 0.1 -- per completed week
DailyConfig.MaxBonus = 1.0

DailyConfig.Days = {
	{ Cash = { Seconds = 120, Min = 1000 } },
	{ Spins = 2 },
	{ Boost = { Id = "Luck", Seconds = 300 } },
	{ Cash = { Seconds = 300, Min = 3000 } },
	{ Spins = 3, Cash = { Seconds = 120, Min = 1500 } },
	{ Egg = { Type = "GoldenEgg", Luck = 5 } },
	{ Cash = { Seconds = 900, Min = 10000 }, Spins = 5, Egg = { Type = "CelestialEgg", Luck = 10 } },
}

DailyConfig.SecondsPerDay = 86400

-- UTC day number of a time stamp.
function DailyConfig.dayOf(t: number): number
	return math.floor(t / DailyConfig.SecondsPerDay)
end

-- Cash multiplier of the streak (1 + 10% per completed week).
function DailyConfig.bonus(streak: number): number
	return 1 + math.min(DailyConfig.MaxBonus, math.floor(math.max(0, streak) / DailyConfig.Cycle) * DailyConfig.WeekBonus)
end

-- Cash of one calendar day for a given income and streak.
function DailyConfig.cash(day: number, incomePerSecond: number, streak: number): number
	local def = DailyConfig.Days[day]
	if not def or not def.Cash then
		return 0
	end
	return math.floor(math.max(def.Cash.Min, incomePerSecond * def.Cash.Seconds) * DailyConfig.bonus(streak) + 0.5)
end

return DailyConfig

--[[
	LeaderboardConfig
	Global top-10 boards shown in the hub plaza (and the Teleport menu's
	"Spawn" destination looks straight at them).

	Board.Stat: which player value is ranked
	  Earned   - lifetime cash earned (data.TotalEarned)
	  Hatched  - eggs hatched (data.Stats.Hatched)
	  Income   - current sanctuary income per second (live)
	  PlayTime - seconds played (data.Stats.PlayTime)
	  DragonPower - the best income per second of any dragon the player owns
	  DragonLevel - the highest dragon level
	  RaceBest / RaceMonthly - best race time ever / this month (score = RaceConfig.timeScore)
	  ArenaKills  - duel knockouts in the arena
	Board.Format: how values are printed (Cash, Count, PerSecond, Time, Level, RaceTime)
	Board.Where:  "Hub" (plaza ring) or "Race" (the Race Island plaza, RaceConfig.Boards)
	Board.Store:  OrderedDataStore name (a function for names that change, like the month)
	Board.SkipZero: players without a value are not listed (no race time yet...)
]]

local RaceConfig = require(script.Parent:WaitForChild("RaceConfig"))

local LeaderboardConfig = {}

LeaderboardConfig.Boards = {
	{
		Id = "Earned",
		Title = "TOP EARNERS",
		Subtitle = "Total cash earned",
		Stat = "Earned",
		Format = "Cash",
		Color = Color3.fromRGB(255, 196, 48),
		Dark = Color3.fromRGB(150, 96, 10),
		Store = "LB_Earned_v1",
		Where = "Hub",
	},
	{
		Id = "Hatched",
		Title = "TOP HATCHERS",
		Subtitle = "Eggs hatched",
		Stat = "Hatched",
		Format = "Count",
		Color = Color3.fromRGB(110, 208, 104),
		Dark = Color3.fromRGB(32, 110, 46),
		Store = "LB_Hatched_v1",
		Where = "Hub",
	},
	{
		Id = "Income",
		Title = "RICHEST SANCTUARIES",
		Subtitle = "Income per second",
		Stat = "Income",
		Format = "PerSecond",
		Color = Color3.fromRGB(77, 163, 255),
		Dark = Color3.fromRGB(20, 70, 150),
		Store = "LB_Income_v1",
		Where = "Hub",
	},
	{
		Id = "PlayTime",
		Title = "MOST DEDICATED",
		Subtitle = "Time played",
		Stat = "PlayTime",
		Format = "Time",
		Color = Color3.fromRGB(190, 120, 255),
		Dark = Color3.fromRGB(86, 40, 150),
		Store = "LB_PlayTime_v1",
		Where = "Hub",
	},
	{
		Id = "StrongDragon",
		Title = "STRONGEST DRAGON",
		Subtitle = "Dragon income per second",
		Stat = "DragonPower",
		Format = "PerSecond",
		Color = Color3.fromRGB(255, 130, 80),
		Dark = Color3.fromRGB(150, 54, 20),
		Store = "LB_DragonPower_v1",
		Where = "Hub",
		SkipZero = true,
	},
	{
		Id = "HighLevel",
		Title = "HIGHEST LEVEL DRAGON",
		Subtitle = "Dragon level",
		Stat = "DragonLevel",
		Format = "Level",
		Color = Color3.fromRGB(64, 236, 214),
		Dark = Color3.fromRGB(20, 110, 100),
		Store = "LB_DragonLevel_v1",
		Where = "Hub",
		SkipZero = true,
	},
	{
		Id = "RaceMonthly",
		Title = "MONTHLY RACE",
		Subtitle = "Fastest race this month",
		Stat = "RaceMonthly",
		Format = "RaceTime",
		Color = Color3.fromRGB(255, 215, 70),
		Dark = Color3.fromRGB(150, 100, 10),
		Store = function()
			return "LB_RaceMonthly_" .. RaceConfig.monthKey() .. "_v1"
		end,
		Where = "Race",
		SkipZero = true,
		Monthly = true,
	},
	{
		Id = "RaceBest",
		Title = "FASTEST RACERS",
		Subtitle = "Best race time ever",
		Stat = "RaceBest",
		Format = "RaceTime",
		Color = Color3.fromRGB(255, 96, 84),
		Dark = Color3.fromRGB(140, 30, 30),
		Store = "LB_RaceBest_v1",
		Where = "Race",
		SkipZero = true,
	},
	{
		Id = "ArenaKills",
		Title = "ARENA WARRIORS",
		Subtitle = "Duel knockouts",
		Stat = "ArenaKills",
		Format = "Count",
		Color = Color3.fromRGB(255, 72, 150),
		Dark = Color3.fromRGB(130, 20, 80),
		Store = "LB_ArenaKills_v1",
		Where = "Race",
		SkipZero = true,
	},
}

LeaderboardConfig.TopCount = 10
LeaderboardConfig.RefreshSeconds = 60 -- read the global tops
LeaderboardConfig.WriteSeconds = 120 -- write each player's values
LeaderboardConfig.PlayTimeTick = 30 -- seconds added to PlayTime per tick

-- Plaza placement: angles (degrees, 0 = north/-Z, 90 = east) on a ring
-- around the hub centre; each board faces the centre. The south road
-- (between 160 and 200 degrees) stays open.
LeaderboardConfig.Ring = 54
LeaderboardConfig.Angles = { 222, 196, 164, 138, 112, 248 }
-- Teleport "Spawn" arrival: south of the statue, looking at the boards.
LeaderboardConfig.Arrival = Vector3.new(0, 0, 28)

return table.freeze(LeaderboardConfig)

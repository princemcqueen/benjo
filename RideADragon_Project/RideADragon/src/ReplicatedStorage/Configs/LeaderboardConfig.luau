--[[
	LeaderboardConfig
	Global top-10 boards shown in the hub plaza (and the Teleport menu's
	"Spawn" destination looks straight at them).

	Board.Stat: which player value is ranked
	  Earned   - lifetime cash earned (data.TotalEarned)
	  Hatched  - eggs hatched (data.Stats.Hatched)
	  Income   - current sanctuary income per second (live)
	  PlayTime - seconds played (data.Stats.PlayTime)
	Board.Format: how values are printed (Cash, Count, PerSecond, Time)
]]

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
LeaderboardConfig.Angles = { 222, 196, 164, 138 }
-- Teleport "Spawn" arrival: south of the statue, looking at the boards.
LeaderboardConfig.Arrival = Vector3.new(0, 0, 28)

return table.freeze(LeaderboardConfig)

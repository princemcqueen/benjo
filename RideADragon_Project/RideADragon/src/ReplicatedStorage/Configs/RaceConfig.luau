--[[
	RaceConfig
	Race & Battle Island: a floating LEGO island in the sky north-east of the valley, with a
	start grid, a sky circuit of ring gates and an arena for dragon duels (CombatConfig).

	THE RACE
	  * Everybody races with the SAME standard dragon stats (Standard): the race is decided by
	    steering, lines and boost rings, not by how much a dragon cost.
	  * Join at the start plaza (Race window). A lobby opens for LobbySeconds, everybody is put
	    on the start grid, 3-2-1, GO. A lone racer can start straight away (time trial).
	  * The server decides everything: it samples your dragon 10 times a second, checks that you
	    fly through every ring gate in order (forward only), clocks the time and the finish order.
	  * Best times feed the all-time board and the MONTHLY board. The fastest racer of a month wins
	    the monthly prize: the game records the winner (name, id, time) for the payout and gives
	    them a trophy and a title in the game.

	Frame: island-local, origin at the centre of the island's top surface, local -Z = north
	(the direction of the first leg of the course). World = Island.Center + local.
]]

local RaceConfig = {}

RaceConfig.Island = {
	Center = Vector3.new(640, 340, -560),
	Radius = 150,
}

-- Where Travel "RaceIsland" puts the player (island-local), facing north.
RaceConfig.Arrival = Vector3.new(0, 3.4, 44)

-- Start grid: 2 rows x 4 columns of pads behind the start arch (racers face north).
RaceConfig.Pads = {}
for row = 1, 2 do
	for col = 1, 4 do
		table.insert(RaceConfig.Pads, Vector3.new((col - 2.5) * 22, 0, -62 + (row - 1) * 24))
	end
end
RaceConfig.MaxRacers = #RaceConfig.Pads

-- The Join prompt (neon pad in the plaza) and the arena entrance / board positions.
RaceConfig.JoinPad = Vector3.new(0, 0, -14)
RaceConfig.Boards = { -- leaderboard screens on the plaza, turned towards the arrival point
	{ Id = "RaceMonthly", Position = Vector3.new(-62, 0, 24) },
	{ Id = "RaceBest", Position = Vector3.new(62, 0, 24) },
	{ Id = "ArenaKills", Position = Vector3.new(124, 0, 20) },
}
RaceConfig.Podium = Vector3.new(-124, 0, 20) -- monthly winners

-- Standard dragon for the race (studs per second; the normal boost multiplier applies).
RaceConfig.Standard = {
	Cruise = 135,
	Run = 60,
	BoostLong = 1,
	BoostRegen = 1,
	Turn = 1.15,
	Accel = 1.2,
	Agility = 1.15,
}

RaceConfig.Laps = 2
RaceConfig.LobbySeconds = 20
RaceConfig.FullLobbySeconds = 5 -- when every pad is taken
RaceConfig.SoloStartSeconds = 3 -- "start now" for a lone racer
RaceConfig.CountdownSeconds = 3
RaceConfig.GateRadius = 26 -- the ring you must fly through (studs from its centre)
RaceConfig.GateSlack = 8 -- body size leniency
RaceConfig.MaxRaceSeconds = 240
RaceConfig.FinishGraceSeconds = 40 -- after the first finisher the others have this long
RaceConfig.SampleSeconds = 0.1
RaceConfig.MaxSpeed = 620 -- studs/s: faster than any legal boost + ring dash + dive (disqualified above)
RaceConfig.SpeedWindow = 0.6 -- seconds of positions the speed is averaged over (network jitter)
RaceConfig.MaxOverSamples = 4 -- samples in a row over MaxSpeed that end the run
RaceConfig.JoinDistance = 420 -- you must be on / near the island to join

-- Boost rings (a dash while you fly through): placed ahead of these gates.
RaceConfig.BoostAfter = { 4, 9, 14, 19, 24 }
RaceConfig.BoostAhead = 52
-- A dash replaces the normal boost (it never stacks), so a ring has to beat the x1.6 boost to matter.
RaceConfig.Boost = { Duration = 1.8, Multiplier = 2.1, Radius = 22 }

-- Rewards: minutes of the racer's sanctuary income (at least Min) + player XP.
RaceConfig.Rewards = {
	Places = {
		{ Minutes = 30, Min = 25000, XP = 120 },
		{ Minutes = 15, Min = 12000, XP = 80 },
		{ Minutes = 8, Min = 6000, XP = 50 },
	},
	Finish = { Minutes = 3, Min = 2500, XP = 25 },
	PersonalBest = { Minutes = 5, Min = 5000, XP = 20 },
}

-- Monthly prize. The real-money part is paid by the game's owner from the recorded winner.
RaceConfig.Monthly = {
	PrizeText = "$50 PRIZE",
	Headline = "Fastest racer of the month wins $50",
	Title = "RACE CHAMPION",
	Winner = { Minutes = 120, Min = 250000, XP = 300 },
	HistoryCount = 6,
	CheckSeconds = 600,
}

-- Leaderboard score of a time: the stores rank HIGHER first, so a time is stored as CAP - ms.
RaceConfig.ScoreCap = 3600 * 1000 -- one hour

function RaceConfig.timeScore(ms: number): number
	return RaceConfig.ScoreCap - math.clamp(math.floor(ms + 0.5), 1, RaceConfig.ScoreCap - 1)
end

function RaceConfig.scoreTime(score: number): number
	return RaceConfig.ScoreCap - score
end

-- "1:23.456"
function RaceConfig.formatTime(ms: number): string
	ms = math.max(0, math.floor(ms + 0.5))
	local total = ms // 1000
	return string.format("%d:%02d.%03d", total // 60, total % 60, ms % 1000)
end

-- "202610" for the month a unix time falls in (UTC).
function RaceConfig.monthKey(t: number?): string
	return os.date("!%Y%m", t or os.time())
end

function RaceConfig.previousMonthKey(t: number?): string
	local d = os.date("!*t", t or os.time())
	local year, month = d.year, d.month - 1
	if month < 1 then
		month, year = 12, year - 1
	end
	return string.format("%04d%02d", year, month)
end

-- Days since 1970-01-01 of a calendar date (proleptic Gregorian). Plain arithmetic, so the month
-- length never depends on os.time's time zone handling.
local function daysFromCivil(year: number, month: number, day: number): number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yearOfEra = year - era * 400
	local shifted = (month + 9) % 12 -- March = 0
	local dayOfYear = (153 * shifted + 2) // 5 + day - 1
	local dayOfEra = yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
	return era * 146097 + dayOfEra - 719468
end
RaceConfig.daysFromCivil = daysFromCivil

-- Seconds until the month ends (UTC).
function RaceConfig.secondsLeftInMonth(t: number?): number
	local now = t or os.time()
	local d = os.date("!*t", now)
	local year, month = d.year, d.month + 1
	if month > 12 then
		month, year = 1, year + 1
	end
	return math.max(0, daysFromCivil(year, month, 1) * 86400 - now)
end

-- ============================================================== the course
-- Control points (island-local), closed loop, first = the start / finish arch heading north.
local CONTROL = {
	Vector3.new(0, 16, -112),
	Vector3.new(0, 38, -300),
	Vector3.new(70, 74, -520),
	Vector3.new(250, 118, -690),
	Vector3.new(500, 158, -735),
	Vector3.new(725, 176, -620),
	Vector3.new(825, 150, -380),
	Vector3.new(765, 110, -150),
	Vector3.new(600, 72, 40),
	Vector3.new(380, 54, 128),
	Vector3.new(200, 60, 70), -- the way home passes well east of the arena (its pillars and beams)
	Vector3.new(80, 40, 0),
}

local function catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2, t3 = t * t, t * t * t
	return 0.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
end

RaceConfig.GateCount = 26 -- gates per lap (gate 0 = the start / finish arch)

local function buildCourse()
	local n = #CONTROL
	local samples: { Vector3 } = {}
	for i = 1, n do
		local p0 = CONTROL[(i - 2) % n + 1]
		local p1 = CONTROL[i]
		local p2 = CONTROL[i % n + 1]
		local p3 = CONTROL[(i + 1) % n + 1]
		for s = 0, 47 do
			table.insert(samples, catmull(p0, p1, p2, p3, s / 48))
		end
	end
	local count = #samples
	local cumulative = { 0 }
	for i = 1, count do
		local nextPoint = samples[i % count + 1]
		cumulative[i + 1] = cumulative[i] + (nextPoint - samples[i]).Magnitude
	end
	local length = cumulative[count + 1]
	local function at(distance: number): (Vector3, Vector3)
		distance %= length
		local lo, hi = 1, count
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			if cumulative[mid] <= distance then
				lo = mid
			else
				hi = mid - 1
			end
		end
		local a = samples[lo]
		local b = samples[lo % count + 1]
		local segment = cumulative[lo + 1] - cumulative[lo]
		local f = segment > 0 and (distance - cumulative[lo]) / segment or 0
		local position = a:Lerp(b, f)
		local tangent = (b - a).Magnitude > 1e-6 and (b - a).Unit or Vector3.new(0, 0, -1)
		return position, tangent
	end
	return at, length
end

local at, length = buildCourse()
RaceConfig.CourseLength = length

-- Gates of one lap: { Position, Direction } (Direction = the way you must fly through it).
RaceConfig.Gates = {}
for k = 0, RaceConfig.GateCount - 1 do
	local position, direction = at(k / RaceConfig.GateCount * length)
	table.insert(RaceConfig.Gates, { Position = position, Direction = direction })
end

-- How far from the island centre the circuit reaches: farther than that plus a margin = you left it.
local farthest = 0
for _, gate in RaceConfig.Gates do
	farthest = math.max(farthest, gate.Position.Magnitude)
end
RaceConfig.CourseRadius = farthest
RaceConfig.CourseLeave = farthest + 320

RaceConfig.Boosts = {}
for _, k in RaceConfig.BoostAfter do
	local position, direction = at(k / RaceConfig.GateCount * length + RaceConfig.BoostAhead)
	table.insert(RaceConfig.Boosts, { Position = position, Direction = direction, After = k })
end

-- The pass sequence of a race: pass j (1..Total) goes through gate index j % GateCount; the last
-- pass (gate 0 again, the arch) is the finish.
function RaceConfig.totalPasses(): number
	return RaceConfig.GateCount * RaceConfig.Laps
end

function RaceConfig.gateForPass(j: number)
	return RaceConfig.Gates[j % RaceConfig.GateCount + 1], j % RaceConfig.GateCount
end

function RaceConfig.lapOfPass(j: number): number
	return math.min(RaceConfig.Laps, (j - 1) // RaceConfig.GateCount + 1)
end

-- The race moves to the world with the island: local -> world.
function RaceConfig.toWorld(localPosition: Vector3): Vector3
	return RaceConfig.Island.Center + localPosition
end

return RaceConfig

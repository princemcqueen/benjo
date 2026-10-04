--[[
	GameConfig
	Global tuning: movement curves, riding physics, camera, ranges, saving.
	All riding/camera numbers live here so feel can be tuned in one place.
]]

local GameConfig = {}

GameConfig.Version = "1.0.0"
GameConfig.DataStoreName = "RideADragon_PlayerData_v1"
GameConfig.AutosaveInterval = 90
GameConfig.SessionLockTimeout = 30 * 60

-- Movement speed curves (studs/second) from the UI power stats.
GameConfig.Movement = {
	WalkSpeed = 17,
	RunBase = 34,
	RunPerLog = 10,
	RunCap = 110,
	FlightBase = 60,
	FlightPerLog = 32,
	FlightCap = 300,
	BoostMultiplier = 1.6,
}

function GameConfig.groundRunSpeed(speedStat: number): number
	local m = GameConfig.Movement
	return math.min(m.RunCap, m.RunBase + m.RunPerLog * math.log10(1 + math.max(0, speedStat) / 40))
end

function GameConfig.flightCruiseSpeed(flightStat: number): number
	local m = GameConfig.Movement
	return math.min(m.FlightCap, m.FlightBase + m.FlightPerLog * math.log10(1 + math.max(0, flightStat) / 60))
end

-- Riding physics. Distances are for scale 1 (Green Drake) and are multiplied
-- by the species Scale where it makes sense (hip height, clearances).
GameConfig.Riding = {
	Gravity = 115,
	JumpVelocity = 44,
	CrouchTime = 0.16,
	TakeoffHoldTime = 0.2,
	TakeoffLiftVelocity = 58,
	TakeoffDuration = 0.65,

	GroundAccel = 55,
	GroundDecel = 70,
	GroundTurnRate = 3.4, -- rad/s at low speed
	GroundTurnRateFast = 2.1, -- rad/s at full run
	GroundTurnResponse = 9, -- how quickly turn rate itself ramps (damping)
	SlopeAlignRate = 7,
	HoverHeightOverWater = 0.5,

	AirAccel = 42,
	AirBrake = 70,
	AirTurnResponse = 3.2, -- heading follows desired heading (exp rate)
	AirMaxYawRate = 1.9, -- rad/s
	VerticalSpeed = 38, -- ascend/descend studs/s
	VerticalAccel = 6, -- response rate
	HoverDrag = 2.2,
	DiveAccel = 60,
	ClimbPenalty = 0.35,
	MaxPitch = math.rad(55),
	MaxBank = math.rad(48),
	BankResponse = 5.5,
	PitchResponse = 5,
	Ceiling = 1500,
	SoftCeilingBand = 120,

	BoostDuration = 5,
	BoostRegenPerSecond = 0.22, -- fraction of full meter per second when not boosting
	BoostMinToStart = 0.15,

	LandingStartHeight = 16,
	TouchdownHeight = 1.2,
	LandingDuration = 0.42,
	AutoLandMaxSpeed = 70,
}

GameConfig.Camera = {
	BaseFOV = 70,
	BoostFOV = 82,
	SpeedFOVBonus = 4, -- extra FOV at max cruise (without boost)
	FOVRate = 4,
	DistanceGround = 24, -- at scale 1
	DistanceAir = 28,
	DistanceSpeedBonus = 5,
	MinZoom = 0.55,
	MaxZoom = 1.9,
	HeightOffset = 7.5,
	LookAheadAir = 3.5,
	LagCompensation = 0.85, -- fraction of the focus spring's steady-state lag removed
	PositionFrequency = 5.2, -- spring Hz for the focus point
	ZoomFrequency = 2.6,
	CollisionPullIn = 22, -- fast when pulling in (avoid clipping)
	CollisionPushOut = 3.5, -- slow when easing back out
	CollisionRadius = 1.4,
	MouseSensitivity = 0.0042,
	GamepadSensitivity = 3.2,
	TouchSensitivity = 0.0065,
	PitchMin = math.rad(-70),
	PitchMax = math.rad(60),
	AutoAlignDelay = 1.4,
	AutoAlignRate = 1.6,
	BankRoll = 0.14, -- fraction of dragon bank applied to the camera
}

GameConfig.Interaction = {
	EggPickupRange = 18, -- client prompt range (studs)
	EggPickupServerRange = 34, -- server validation range (includes dragon size slack)
	NestRange = 22,
	NestServerRange = 40,
	CollectorRange = 16,
}

-- Sanctuary display dragons (resting on perches)
GameConfig.Sanctuary = {
	PerchScale = 0.62, -- display size relative to the riding size
	ViewDistance = 620, -- perch dragons are built within this camera distance
	ViewDistanceLow = 260, -- on the Low graphics preset
	NameplateDistance = 110,
	PromptRange = 16,
}

GameConfig.StarterCash = 250

return table.freeze(GameConfig)

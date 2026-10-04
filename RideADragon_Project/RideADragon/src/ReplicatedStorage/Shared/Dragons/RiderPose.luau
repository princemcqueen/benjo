--[[
	RiderPose
	Procedural straddle pose for a mounted character (R15 and R6), written
	to Motor6D.Transform after the character's own animations each frame.

	RiderPose.apply(character, params)
	  params.Lean   0..1  forward lean (boost / speed)
	  params.Bounce -1..1 small vertical absorb from the dragon's gait
	  params.Bank   radians, counter-lean against the dragon's roll
	RiderPose.clear(character) restores identity transforms.
]]

local RiderPose = {}

local rad = math.rad
local Angles = CFrame.Angles

local cache = setmetatable({}, { __mode = "k" }) :: { [Model]: any }

local R15 = {
	"Root", "Waist", "Neck", "LeftHip", "RightHip", "LeftKnee", "RightKnee", "LeftAnkle", "RightAnkle",
	"LeftShoulder", "RightShoulder", "LeftElbow", "RightElbow", "LeftWrist", "RightWrist",
}
local R6 = { "RootJoint", "Neck", "Left Hip", "Right Hip", "Left Shoulder", "Right Shoulder" }

local function collect(character: Model)
	local entry = cache[character]
	if entry and entry.Valid then
		return entry
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local isR15 = humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R15
	local motors = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") then
			motors[d.Name] = d
		end
	end
	entry = { Motors = motors, R15 = isR15, Valid = true }
	cache[character] = entry
	character.DescendantRemoving:Once(function()
		entry.Valid = false
	end)
	return entry
end

local function set(motors, name: string, cf: CFrame)
	local m = motors[name]
	if m then
		m.Transform = cf
	end
end

function RiderPose.apply(character: Model, params: { [string]: number }?)
	local p = params or {}
	local lean = p.Lean or 0
	local bounce = p.Bounce or 0
	local bank = p.Bank or 0
	local e = collect(character)
	local m = e.Motors
	if e.R15 then
		set(m, "Root", CFrame.new(0, bounce * 0.08, 0) * Angles(0, 0, -bank * 0.25))
		set(m, "Waist", Angles(rad(-8 - 20 * lean) + bounce * 0.04, 0, -bank * 0.15))
		set(m, "Neck", Angles(rad(6 + 16 * lean), 0, 0))
		-- legs straddle the saddle: thighs forward and out, shins back
		set(m, "LeftHip", Angles(rad(62), 0, rad(-30)))
		set(m, "RightHip", Angles(rad(62), 0, rad(30)))
		set(m, "LeftKnee", Angles(rad(-88), 0, 0))
		set(m, "RightKnee", Angles(rad(-88), 0, 0))
		set(m, "LeftAnkle", Angles(rad(20), 0, 0))
		set(m, "RightAnkle", Angles(rad(20), 0, 0))
		-- hands forward on the saddle horn
		set(m, "LeftShoulder", Angles(rad(38 + 14 * lean), 0, rad(10)))
		set(m, "RightShoulder", Angles(rad(38 + 14 * lean), 0, rad(-10)))
		set(m, "LeftElbow", Angles(rad(42), 0, 0))
		set(m, "RightElbow", Angles(rad(42), 0, 0))
		set(m, "LeftWrist", CFrame.identity)
		set(m, "RightWrist", CFrame.identity)
	else
		-- R6 motors rotate about their joint's Z axis (DesiredAngle convention)
		set(m, "RootJoint", Angles(rad(8 + 18 * lean), 0, 0))
		set(m, "Neck", Angles(rad(-6 - 14 * lean), 0, 0))
		set(m, "Left Hip", Angles(rad(-18), 0, rad(-72)))
		set(m, "Right Hip", Angles(rad(-18), 0, rad(72)))
		set(m, "Left Shoulder", Angles(0, 0, rad(-48 - 12 * lean)))
		set(m, "Right Shoulder", Angles(0, 0, rad(48 + 12 * lean)))
	end
end

function RiderPose.clear(character: Model)
	local e = cache[character]
	if not e then
		return
	end
	for _, name in (e.R15 and R15 or R6) do
		set(e.Motors, name, CFrame.identity)
	end
	cache[character] = nil
end

return RiderPose

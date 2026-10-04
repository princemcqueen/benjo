--[[
	CameraController
	Third-person riding camera (active while mounted; the default Roblox
	camera is used on foot).

	- Focus follows the dragon's stable physics root through an analytic
	  critically damped spring (frame-rate independent, never jitters),
	  with a small look-ahead along the flight direction.
	- Orbit yaw/pitch from mouse (locked or right-drag), right stick or touch
	  drag; auto-aligns behind the dragon after a short idle.
	- Zoom (wheel / pinch), speed-based distance, FOV 70 -> 82 on boost.
	- Sphere-cast collision: pulls in fast, eases back out slowly.
	- Subtle bank roll and trauma-based shake (both optional in Settings).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Spring = require(Shared:WaitForChild("Util"):WaitForChild("Spring"))
local MathUtil = require(Shared:WaitForChild("Util"):WaitForChild("MathUtil"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))

local CameraController = {}
CameraController.Active = false
CameraController.Options = { Sensitivity = 1, Shake = true, SpeedFOV = true, MouseLock = true, InvertY = false }

local CAM = GameConfig.Camera
local BIND_NAME = "RAD_DragonCamera"

local registry
local camera: Camera
local target: BasePart? = nil
local info = { Scale = 1, Mode = "Ground", Speed = 0, Cruise = 77, Boosting = false, Roll = 0, Yaw = 0, Pitch = 0, Velocity = Vector3.zero }

local yaw, pitch = 0, -0.22
local zoom, zoomTarget = 1, 1
local focus = Spring.new(Vector3.zero, CAM.PositionFrequency)
local distSpring = Spring.new(CAM.DistanceGround, CAM.ZoomFrequency)
local collisionDist = math.huge
local fov = CAM.BaseFOV
local roll = 0
local trauma = 0
local lastManual = 0
local stick = Vector2.zero
local touchDrag: InputObject? = nil
local touchLast: Vector3? = nil
local rmbDown = false
local clock = 0

local rayParams = RaycastParams.new()
rayParams.CollisionGroup = "DragonQuery"
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = true

local function cursorFree(): boolean
	local ui = registry and registry.UIController
	if ui and ui.Current then
		return true
	end
	local input = registry and registry.InputController
	return input ~= nil and input.isDown("FreeCursor")
end

local function mouseLocked(): boolean
	return CameraController.Active and CameraController.Options.MouseLock and not UserInputService.TouchEnabled and not cursorFree()
end

function CameraController.setOptions(opts)
	for k, v in opts do
		CameraController.Options[k] = v
	end
end

function CameraController.getYaw(): number
	return yaw
end

function CameraController.getPitch(): number
	return pitch
end

function CameraController.getLook(): Vector3
	return CFrame.fromOrientation(pitch, yaw, 0).LookVector
end

-- Turns the view to `heading` (radians, 0 = north) straight away: race start grid.
function CameraController.setView(heading: number, newPitch: number?)
	yaw = MathUtil.wrapAngle(heading)
	pitch = math.clamp(newPitch or -0.22, CAM.PitchMin, CAM.PitchMax)
	lastManual = clock
end

-- amount 0..1 (adds trauma; shake = trauma^2)
function CameraController.shake(amount: number)
	if CameraController.Options.Shake then
		trauma = math.min(1, trauma + amount)
	end
end

function CameraController.setInfo(t)
	for k, v in t do
		info[k] = v
	end
end

local function rotate(dx: number, dy: number)
	local o = CameraController.Options
	local inv = o.InvertY and -1 or 1
	yaw = MathUtil.wrapAngle(yaw - dx)
	pitch = math.clamp(pitch - dy * inv, CAM.PitchMin, CAM.PitchMax)
	lastManual = clock
end

-- Cinematics (hatching, cutscenes) take the camera over temporarily.
local cinematicDepth = 0
function CameraController.beginCinematic()
	cinematicDepth += 1
	if cinematicDepth == 1 then
		if CameraController.Active then
			RunService:UnbindFromRenderStep(BIND_NAME)
		end
		camera.CameraType = Enum.CameraType.Scriptable
	end
end

function CameraController.endCinematic()
	if cinematicDepth == 0 then
		return
	end
	cinematicDepth -= 1
	if cinematicDepth == 0 then
		if CameraController.Active then
			camera.CameraType = Enum.CameraType.Scriptable
			RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, CameraController.update)
		else
			camera.CameraType = Enum.CameraType.Custom
			local character = Players.LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				camera.CameraSubject = humanoid
			end
		end
	end
end

function CameraController.inCinematic(): boolean
	return cinematicDepth > 0
end

-- Activates the riding camera on a dragon root (nil = back to default camera).
function CameraController.setTarget(root: BasePart?, scale: number?)
	target = root
	info.Scale = scale or 1
	if root then
		local wasActive = CameraController.Active
		CameraController.Active = true
		if not wasActive then
			-- start from the current view so the transition is seamless
			local cf = camera.CFrame
			local look = cf.LookVector
			yaw = math.atan2(-look.X, -look.Z)
			pitch = math.clamp(math.asin(math.clamp(look.Y, -1, 1)), CAM.PitchMin, CAM.PitchMax)
			local f = root.Position + Vector3.new(0, CAM.HeightOffset * info.Scale, 0)
			focus:Reset(f)
			local d = (cf.Position - f).Magnitude
			distSpring:Reset(math.clamp(d, 8, 120))
			collisionDist = math.huge
			fov = camera.FieldOfView
			camera.CameraType = Enum.CameraType.Scriptable
			if cinematicDepth == 0 then
				RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, CameraController.update)
			end
		end
	else
		if CameraController.Active then
			CameraController.Active = false
			RunService:UnbindFromRenderStep(BIND_NAME)
			if cinematicDepth > 0 then
				return
			end
			camera.CameraType = Enum.CameraType.Custom
			camera.FieldOfView = CAM.BaseFOV
			local character = Players.LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				camera.CameraSubject = humanoid
			end
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end
end

function CameraController.update(dt: number)
	clock += dt
	local root = target
	if not root or not root.Parent then
		return
	end
	local o = CameraController.Options
	local sens = o.Sensitivity or 1
	local scale = info.Scale
	local flying = info.Mode == "Fly" or info.Mode == "Takeoff" or info.Mode == "Landing"

	-- ---------------------------------------------------------------- input
	if mouseLocked() then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		local d = UserInputService:GetMouseDelta()
		if d.Magnitude > 0 then
			rotate(d.X * CAM.MouseSensitivity * sens, d.Y * CAM.MouseSensitivity * sens)
		end
	else
		UserInputService.MouseIconEnabled = true
		if rmbDown and not cursorFree() then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			local d = UserInputService:GetMouseDelta()
			if d.Magnitude > 0 then
				rotate(d.X * CAM.MouseSensitivity * sens, d.Y * CAM.MouseSensitivity * sens)
			end
		else
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end
	if stick.Magnitude > 0.12 then
		local s = (stick.Magnitude - 0.12) / 0.88
		local dir = stick.Unit * s * s
		rotate(dir.X * CAM.GamepadSensitivity * sens * dt, -dir.Y * CAM.GamepadSensitivity * 0.75 * sens * dt)
	end

	-- ---------------------------------------------------------------- auto align
	local vel = info.Velocity
	local hspeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	if clock - lastManual > CAM.AutoAlignDelay and hspeed > 8 then
		local k = math.clamp((hspeed - 8) / 30, 0, 1)
		yaw = MathUtil.expDecayAngle(yaw, info.Yaw, CAM.AutoAlignRate * k, dt)
		local restPitch = flying and (-0.24 + math.clamp(info.Pitch, -0.6, 0.5) * 0.45) or -0.22
		pitch = MathUtil.expDecay(pitch, restPitch, CAM.AutoAlignRate * 0.6 * k, dt)
	end

	-- ---------------------------------------------------------------- focus
	local cruise = math.max(1, info.Cruise)
	local speed01 = math.clamp(info.Speed / cruise, 0, 1.6)
	local lookAhead = flying and vel * (CAM.LookAheadAir / math.max(30, cruise)) or Vector3.zero
	if lookAhead.Magnitude > CAM.LookAheadAir * 1.6 * scale then
		lookAhead = lookAhead.Unit * CAM.LookAheadAir * 1.6 * scale
	end
	-- a critically damped spring trails a moving target by 2v/omega; lead the
	-- target by most of that so the dragon stays framed at any speed while
	-- the remaining lag still smooths accelerations
	local lead = vel * (2 / focus.Omega) * (CAM.LagCompensation or 0.85)
	focus.Target = root.Position + Vector3.new(0, CAM.HeightOffset * scale, 0) + lookAhead + lead
	local f = focus:Update(dt)

	-- ---------------------------------------------------------------- distance
	zoom = MathUtil.expDecay(zoom, zoomTarget, 10, dt)
	local base = (flying and CAM.DistanceAir or CAM.DistanceGround) * scale
	distSpring.Target = base * zoom + CAM.DistanceSpeedBonus * scale * math.min(speed01, 1.3)
	local desired = distSpring:Update(dt)

	local rot = CFrame.fromOrientation(pitch, yaw, 0)
	local look = rot.LookVector
	-- collision: cast from the focus back toward the camera
	local castDist = desired
	local hit = Workspace:Spherecast(f, CAM.CollisionRadius, -look * (desired + 0.5), rayParams)
	if hit then
		castDist = math.max(2, hit.Distance - 0.4)
	end
	if castDist < collisionDist then
		collisionDist = MathUtil.expDecay(collisionDist, castDist, CAM.CollisionPullIn, dt)
		collisionDist = math.min(collisionDist, castDist + 1.5)
	else
		collisionDist = MathUtil.expDecay(collisionDist, castDist, CAM.CollisionPushOut, dt)
	end
	local dist = math.min(desired, collisionDist)
	local camPos = f - look * dist

	-- ---------------------------------------------------------------- fov / roll / shake
	local fovTarget = CAM.BaseFOV
	if o.SpeedFOV then
		fovTarget += CAM.SpeedFOVBonus * math.min(speed01, 1)
		if info.Boosting then
			fovTarget = CAM.BoostFOV + CAM.SpeedFOVBonus * 0.5
		end
	end
	fov = MathUtil.expDecay(fov, fovTarget, CAM.FOVRate, dt)
	roll = MathUtil.expDecay(roll, flying and info.Roll * CAM.BankRoll or 0, 5, dt)
	trauma = math.max(0, trauma - dt * 1.4)
	local shake = trauma * trauma
	local shakeCF = CFrame.identity
	if shake > 0.001 then
		local t = clock * 22
		shakeCF = CFrame.Angles(
			math.noise(t, 0.3) * 0.035 * shake,
			math.noise(t, 4.1) * 0.035 * shake,
			math.noise(t, 9.7) * 0.05 * shake
		)
	end

	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(camPos, f) * CFrame.Angles(0, 0, roll) * shakeCF
	camera.Focus = CFrame.new(f)
end

function CameraController.Init(reg)
	registry = reg
	camera = Workspace.CurrentCamera
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = Workspace.CurrentCamera
		if CameraController.Active then
			camera.CameraType = Enum.CameraType.Scriptable
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and not processed then
			rmbDown = true
		elseif input.UserInputType == Enum.UserInputType.Touch and not processed and CameraController.Active then
			if not touchDrag then
				touchDrag = input
				touchLast = input.Position
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmbDown = false
		elseif input == touchDrag then
			touchDrag = nil
			touchLast = nil
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stick = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed and CameraController.Active then
			zoomTarget = math.clamp(zoomTarget * (1 - 0.12 * input.Position.Z), CAM.MinZoom, CAM.MaxZoom)
		elseif input == touchDrag and touchLast and CameraController.Active then
			local d = input.Position - touchLast
			touchLast = input.Position
			local sens = CameraController.Options.Sensitivity or 1
			rotate(d.X * CAM.TouchSensitivity * sens, d.Y * CAM.TouchSensitivity * sens)
		end
	end)
	local pinchBase = 1
	UserInputService.TouchPinch:Connect(function(_, scale, _, state, processed)
		if processed or not CameraController.Active then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinchBase = zoomTarget
		elseif state == Enum.UserInputState.Change then
			-- scale is cumulative since the pinch began
			zoomTarget = math.clamp(pinchBase / math.clamp(scale, 0.25, 4), CAM.MinZoom, CAM.MaxZoom)
		end
	end)
end

return CameraController

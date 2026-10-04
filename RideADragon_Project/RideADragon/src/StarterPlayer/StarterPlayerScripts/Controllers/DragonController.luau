--[[
	DragonController
	Drives the local player's companion dragon (client network ownership):

	  riding      input -> Locomotion -> LinearVelocity / AlignOrientation
	  on foot     follow AI (walks after the player, flies over gaps and
	              cliffs, teleports beside the player when left far behind)

	No per-frame remotes: only mode/boost/action changes are sent
	(DragonState event) so other clients can animate this dragon.

	API: toggleRide(), isRiding(), getModel(), getState()
	     preStep(dt) is called by AnimationController before animating.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local Locomotion = require(Shared:WaitForChild("Dragons"):WaitForChild("Locomotion"))
local DragonStats = require(Shared:WaitForChild("DragonStats"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))

local DragonController = {}
DragonController.RidingChanged = Signal.new() -- (riding)
DragonController.ModelChanged = Signal.new() -- (model?)

local LocalPlayer = Players.LocalPlayer
local R = GameConfig.Riding
local rad, sin, cos, abs, clamp = math.rad, math.sin, math.cos, math.abs, math.clamp

local registry
local model: Model? = nil
local root: BasePart? = nil
local drive: LinearVelocity? = nil
local attitude: AlignOrientation? = nil
local state = nil
local riding = false
local busy = false
local hudTimer = 0
local lastSent = { Mode = "Ground", Boost = false }
local roarCooldown = 0
local flyIntent = 0
local wind: Sound? = nil

-- ============================================================== world queries
local rayParams = RaycastParams.new()
rayParams.CollisionGroup = "DragonQuery"
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = false

local world = {}
function world.ground(pos: Vector3, maxDown: number)
	local r = 0.9
	local hit = Workspace:Spherecast(pos + Vector3.new(0, 2, 0), r, Vector3.new(0, -(maxDown + 2 - r), 0), rayParams)
	if hit then
		return true, hit.Position.Y, hit.Normal, hit.Material == Enum.Material.Water
	end
	return false, 0, Vector3.yAxis, false
end
function world.sweep(origin: Vector3, delta: Vector3, radius: number)
	if delta.Magnitude < 1e-3 then
		return false, 1, Vector3.zero
	end
	local hit = Workspace:Spherecast(origin, radius, delta, rayParams)
	if hit then
		return true, hit.Distance / delta.Magnitude, hit.Normal
	end
	return false, 1, Vector3.zero
end
DragonController.World = world

-- ============================================================== helpers
local function equippedRecord()
	local data = registry.DataController.all()
	if not data then
		return nil
	end
	local uid = data.EquippedDragon
	return uid ~= "" and data.Dragons[uid] or nil
end

local function buildStats()
	local m = model :: Model
	local record = equippedRecord()
	local species = DragonConfig.Species[m:GetAttribute("SpeciesId") or ""] or DragonConfig.Species.GreenDrake
	local handling = species.Handling or {}
	return {
		RunSpeed = record and DragonStats.runSpeed(record) or (m:GetAttribute("RunSpeed") or 40),
		-- Great Tree "Wind Wings": the server mirrors the bonus as a player attribute
		CruiseSpeed = record and DragonStats.cruiseSpeed(record, LocalPlayer:GetAttribute("TreeFlySpeed") or 0)
			or (m:GetAttribute("CruiseSpeed") or 77),
		Scale = m:GetAttribute("Scale") or 1,
		HipHeight = m:GetAttribute("HipHeight") or 4.8,
		BodyRadius = m:GetAttribute("BodyRadius") or 4.2,
		Turn = handling.Turn or 1,
		Accel = handling.Accel or 1,
		Agility = handling.Agility or 1,
	}
end

local function character()
	local c = LocalPlayer.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	return c, hrp, hum
end

local function send(payload)
	Net.fire("DragonState", payload)
end

local function flatYaw(cf: CFrame): number
	local l = cf.LookVector
	return math.atan2(-l.X, -l.Z)
end

-- ============================================================== model binding
local function setRiding(on: boolean)
	if riding == on then
		return
	end
	riding = on
	local input = registry.InputController
	local cam = registry.CameraController
	input.setRiding(on)
	local _, _, hum = character()
	if hum then
		hum.PlatformStand = on
	end
	if on and root and model then
		cam.setTarget(root, model:GetAttribute("Scale") or 1)
	else
		cam.setTarget(nil)
	end
	if registry.Hud then
		registry.Hud:SetRiding(on)
	end
	if wind then
		wind.Volume = 0
	end
	DragonController.RidingChanged:Fire(on)
end

local function unbind()
	if riding then
		setRiding(false)
	end
	model, root, drive, attitude, state = nil, nil, nil, nil, nil
	DragonController.ModelChanged:Fire(nil)
end

local function bind(m: Model)
	if model == m then
		return
	end
	unbind()
	local r = m:WaitForChild("Root", 10) :: BasePart?
	if not r or m.Parent == nil then
		return
	end
	model = m
	root = r
	drive = r:WaitForChild("Drive", 5) :: LinearVelocity?
	attitude = r:WaitForChild("Attitude", 5) :: AlignOrientation?
	state = Locomotion.new(buildStats(), r.Position, flatYaw(r.CFrame))
	lastSent = { Mode = "Ground", Boost = false }
	local anim = registry.AnimationController
	anim.track(m)
	m:GetAttributeChangedSignal("RiderUserId"):Connect(function()
		if model == m then
			setRiding(m:GetAttribute("RiderUserId") == LocalPlayer.UserId)
		end
	end)
	-- equip switch / mutation: the server hot-swaps the dragon on the same root
	m:GetAttributeChangedSignal("VisualRev"):Connect(function()
		if model == m and state then
			Locomotion.setStats(state, buildStats())
			if riding and root then
				registry.CameraController.setTarget(root, m:GetAttribute("Scale") or 1)
			end
		end
	end)
	m.AncestryChanged:Connect(function(_, parent)
		if parent == nil and model == m then
			unbind()
		end
	end)
	setRiding(m:GetAttribute("RiderUserId") == LocalPlayer.UserId)
	DragonController.ModelChanged:Fire(m)
end

-- ============================================================== input
local function rideInput()
	local Input = registry.InputController
	local Cam = registry.CameraController
	local raw = Input.getMoveVector()
	local yaw = Cam.getYaw()
	local camPitch = Cam.getPitch()
	local fwdFlat = Vector3.new(-sin(yaw), 0, -cos(yaw))
	local rightFlat = Vector3.new(cos(yaw), 0, -sin(yaw))
	local fwd, strafe = -raw.Z, raw.X
	local moveFlat = rightFlat * strafe + fwdFlat * fwd

	-- flight pitch from the camera: the default camera (looking slightly
	-- down at the dragon) flies level; a deadzone keeps cruising easy
	local p = camPitch + rad(14)
	if abs(p) < rad(6) then
		p = 0
	else
		p -= math.sign(p) * rad(6)
	end
	p = clamp(p * 1.2, -R.MaxPitch, R.MaxPitch)
	local c = cos(p)
	local fwd3 = Vector3.new(-sin(yaw) * c, sin(p), -cos(yaw) * c)
	local brake = false
	local move
	if fwd < -0.2 and state and state.Mode == "Fly" then
		brake = true
		move = rightFlat * strafe
	else
		move = rightFlat * strafe + fwd3 * fwd
	end
	local jumpHeld = Input.isDown("Jump")
	return {
		Move = move,
		MoveFlat = moveFlat,
		JumpPressed = Input.consume("Jump"),
		JumpHeld = jumpHeld,
		Ascend = jumpHeld,
		Descend = Input.isDown("Descend"),
		Sprint = Input.isDown("Sprint"),
		Brake = brake,
		CamYaw = yaw,
	}
end

local function teleportNear(hrp: BasePart)
	local s = state
	local r = root
	if not s or not r then
		return
	end
	local yaw = flatYaw(hrp.CFrame)
	local back = Vector3.new(sin(yaw), 0, cos(yaw))
	local right = Vector3.new(cos(yaw), 0, -sin(yaw))
	local spot = hrp.Position + back * (s.Stats.BodyRadius + 6) + right * 5
	local ok, gy = world.ground(spot + Vector3.new(0, 30, 0), 120)
	local y = ok and gy + s.Stats.HipHeight or hrp.Position.Y
	r.CFrame = CFrame.new(spot.X, y, spot.Z) * CFrame.Angles(0, yaw, 0)
	r.AssemblyLinearVelocity = Vector3.zero
	s.Position = r.Position
	s.Velocity = Vector3.zero
	s.Speed = 0
	s.Yaw = yaw
	Locomotion.setMode(s, ok and "Ground" or "Fly")
end

-- Companion behaviour while the player is on foot ("escort flight"): the
-- dragon circles above the player like a guardian (no ground path-finding,
-- so it never gets stuck on houses or bumps into the player), and lands
-- beside the player after they stand still for a few seconds.
local escort = { Angle = math.random() * math.pi * 2, Still = 0, Dir = 1 }

local function followInput(dt: number)
	local input = { Move = Vector3.zero, MoveFlat = Vector3.zero, JumpPressed = false, JumpHeld = false }
	local _, hrp, hum = character()
	local s = state
	if not hrp or not hum or hum.Health <= 0 or not s or not root then
		return input
	end
	local myPos = root.Position
	local target = hrp.Position
	local flat = Vector3.new(target.X - myPos.X, 0, target.Z - myPos.Z)
	local d = flat.Magnitude
	local hip = s.Stats.HipHeight
	local br = s.Stats.BodyRadius
	local feetY = target.Y - (hum.HipHeight + hrp.Size.Y * 0.5)
	local dy = feetY - (myPos.Y - hip)
	if d > 320 or abs(dy) > 220 then
		teleportNear(hrp)
		return input
	end
	local pv = hrp.AssemblyLinearVelocity
	local playerSpeed = Vector3.new(pv.X, 0, pv.Z).Magnitude
	local grounded = math.abs(pv.Y) < 3
	if playerSpeed > 3 or not grounded or d > 70 then
		escort.Still = 0
	else
		escort.Still += dt
	end
	local flying = s.Mode == "Fly" or s.Mode == "Takeoff" or s.Mode == "Landing"

	-- fetch: fly to eggs near the player and pick them up (like a loyal pet)
	local eggCtl = registry.EggController
	local fetch = eggCtl and eggCtl.fetchTarget and eggCtl.fetchTarget(Vector3.new(target.X, feetY, target.Z), 75)
	if fetch then
		escort.Still = 0
		if not flying then
			input.FlyToggle = true
			return input
		end
		local goal = fetch + Vector3.new(0, hip * 0.7 + 1.5, 0)
		local to = goal - myPos
		local desired = to * 1.6
		if desired.Magnitude > s.Stats.CruiseSpeed then
			desired = desired.Unit * s.Stats.CruiseSpeed
		end
		if desired.Magnitude > 0.5 then
			input.Move = desired.Unit * clamp(desired.Magnitude / math.max(1, s.Stats.CruiseSpeed), 0.25, 1)
			input.MoveFlat = Vector3.new(to.X, 0, to.Z)
		end
		return input
	end

	-- settle: land beside a player who stands still
	if escort.Still > 4 then
		if not flying then
			return input -- resting on the ground next to the player
		end
		local away = Vector3.new(myPos.X - target.X, 0, myPos.Z - target.Z)
		away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
		local spot = Vector3.new(target.X, feetY + hip, target.Z) + away * (9 + br * 1.6)
		local to = spot - myPos
		local flatTo = Vector3.new(to.X, 0, to.Z)
		if flatTo.Magnitude > 5 then
			local desired = flatTo.Unit * math.min(flatTo.Magnitude * 1.2, 40) + Vector3.new(0, math.clamp(to.Y + 6, -12, 12), 0)
			input.Move = desired.Unit * clamp(desired.Magnitude / math.max(1, s.Stats.CruiseSpeed), 0.12, 1)
			input.MoveFlat = flatTo
		else
			input.Descend = true
		end
		return input
	end

	-- escort: take off (resting dragons wait until the player walks away)
	if not flying then
		if d > 18 + br or dy > 14 or playerSpeed > 6 then
			flyIntent += dt
		else
			flyIntent = math.max(0, flyIntent - dt)
		end
		if flyIntent > 0.35 then
			flyIntent = 0
			input.FlyToggle = true
		end
		return input
	end

	-- circle the player: a glide at ~28 studs/s around a centre that leads
	-- the player's motion; height keeps clear of roofs and terrain
	local radius = 20 + br * 2.4
	local omega = 28 / radius
	escort.Angle = (escort.Angle + omega * dt * escort.Dir) % (math.pi * 2)
	local center = Vector3.new(target.X, 0, target.Z) + Vector3.new(pv.X, 0, pv.Z) * 0.5
	local a = escort.Angle
	local height = feetY + 16 + hip * 1.6
	local goal = Vector3.new(center.X + math.cos(a) * radius, height, center.Z + math.sin(a) * radius)
	local ok, gy = world.ground(goal + Vector3.new(0, 60, 0), 160)
	if ok then
		goal = Vector3.new(goal.X, math.max(goal.Y, gy + hip + 10), goal.Z)
	end
	local tangent = Vector3.new(-math.sin(a), 0, math.cos(a)) * (omega * radius * escort.Dir)
	local desired = Vector3.new(pv.X, 0, pv.Z) + tangent + (goal - myPos) * 1.1
	local speed = desired.Magnitude
	if speed > 0.5 then
		input.Move = desired.Unit * clamp(speed / math.max(1, s.Stats.CruiseSpeed), 0.15, 1)
		input.MoveFlat = Vector3.new(desired.X, 0, desired.Z)
		input.Sprint = (goal - myPos).Magnitude > 120
	end
	return input
end

-- ============================================================== events
local function handleEvents(s)
	local anim = registry.AnimationController
	local cam = registry.CameraController
	local audio = registry.AudioController
	local m = model :: Model
	local r = root :: BasePart
	for _, e in s.Events do
		local k = e.Kind
		if k == "Jump" then
			anim.play(m, "Jump")
			send({ Shot = "Jump" })
		elseif k == "Takeoff" then
			anim.play(m, "Takeoff")
			audio.play3D("Takeoff", r, 0.08)
			if riding then
				cam.shake(0.18)
			end
			send({ Shot = "Takeoff" })
		elseif k == "CatchFall" then
			anim.play(m, "Takeoff", 1.3)
		elseif k == "Touchdown" or k == "Land" then
			local impact = tonumber(e.Data) or 0
			if k == "Touchdown" or impact > 25 then
				anim.play(m, "Landing")
				audio.play3D("Landing", r, 0.06, clamp(impact / 50, 0.4, 1))
				if riding then
					cam.shake(clamp(impact / 120, 0.12, 0.45))
				end
				send({ Shot = "Landing" })
			end
		elseif k == "Bump" then
			if riding and (tonumber(e.Data) or 0) > 25 then
				cam.shake(0.12)
			end
		elseif k == "BoostStart" then
			if riding then
				cam.shake(0.12)
			end
		end
	end
	-- low-rate replication of mode / boost
	local mode = s.Mode
	if mode ~= lastSent.Mode or s.Boosting ~= lastSent.Boost then
		lastSent.Mode = mode
		lastSent.Boost = s.Boosting
		send({ Mode = mode, Boost = s.Boosting })
		if registry.Hud then
			registry.Hud:SetRideMode(mode)
		end
	end
end

-- ============================================================== frame
function DragonController.preStep(dt: number)
	local m, r, s = model, root, state
	if not m or not r or not s or not r.Parent then
		return
	end
	s.Position = r.Position
	local input
	if riding then
		input = rideInput()
		roarCooldown = math.max(0, roarCooldown - dt)
		if registry.InputController.consume("Roar") and roarCooldown <= 0 then
			roarCooldown = 2.2
			registry.AnimationController.play(m, "Roar")
			registry.AudioController.play3D("Roar", r, 0.05)
			registry.CameraController.shake(0.1)
			Net.fire("DragonState", { Shot = "Roar" })
		end
	else
		input = followInput(dt)
	end
	Locomotion.step(s, input, dt, world)
	if drive then
		drive.VectorVelocity = s.Velocity
	end
	if attitude then
		attitude.CFrame = Locomotion.orientation(s)
	end
	registry.AnimationController.setLocal(m, Locomotion.animParams(s))
	handleEvents(s)

	local v = s.Velocity
	local speed = v.Magnitude
	if riding then
		registry.CameraController.setInfo({
			Mode = s.Mode,
			Speed = s.Mode == "Fly" and s.Speed or Vector3.new(v.X, 0, v.Z).Magnitude,
			Cruise = s.Stats.CruiseSpeed,
			Boosting = s.Boosting,
			Roll = s.Roll,
			Yaw = s.Yaw,
			Pitch = s.FlightPitch,
			Velocity = v,
		})
		hudTimer += dt
		if hudTimer > 0.1 and registry.Hud then
			hudTimer = 0
			registry.Hud:SetFlightStats(speed, s.Boost, s.Boosting)
		end
		if wind then
			local target = clamp((speed - 35) / 220, 0, 0.75)
			wind.Volume += (target - wind.Volume) * math.min(1, dt * 3)
		end
	end
end

-- ============================================================== public
function DragonController.toggleRide()
	if busy then
		return
	end
	if not equippedRecord() then
		registry.UIController.Notify("info", "Equip a dragon in your collection first.")
		return
	end
	busy = true
	task.spawn(function()
		local res = Net.request("Mount", "Toggle")
		registry.UIController.HandleResult(res)
		busy = false
	end)
end

function DragonController.isRiding(): boolean
	return riding
end

function DragonController.getModel(): Model?
	return model
end

function DragonController.getState()
	return state
end

function DragonController.Init(reg)
	registry = reg
end

function DragonController.Start()
	local input = registry.InputController
	input.Pressed:Connect(function(action)
		if action == "Ride" then
			DragonController.toggleRide()
		elseif action == "MouseLock" and riding then
			local settings = registry.SettingsController
			if settings then
				local on = not (settings.get("MouseLock") ~= false)
				settings.set("MouseLock", on)
				registry.UIController.Notify("info", on and "Mouse steering ON  (hold Alt for the cursor)" or "Mouse steering OFF  (hold right mouse to look)")
			end
		end
	end)
	registry.DataController.observe("Dragons", function()
		if state and model then
			Locomotion.setStats(state, buildStats())
		end
	end)
	-- Great Tree "Wind Wings" bought while flying: new cruise speed right away
	LocalPlayer:GetAttributeChangedSignal("TreeFlySpeed"):Connect(function()
		if state and model then
			Locomotion.setStats(state, buildStats())
		end
	end)
	wind = registry.AudioController.loop("Wind")
	local folder = Workspace:WaitForChild("Dragons", 30)
	if not folder then
		return
	end
	local name = "Dragon_" .. LocalPlayer.UserId
	local function consider(child: Instance)
		if child.Name == name and child:IsA("Model") then
			task.spawn(bind, child)
		end
	end
	for _, c in folder:GetChildren() do
		consider(c)
	end
	folder.ChildAdded:Connect(consider)
	LocalPlayer.CharacterAdded:Connect(function()
		if riding then
			setRiding(false)
		end
	end)
end

return DragonController

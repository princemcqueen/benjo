--[[
	SpinController
	Builds the Spin Island wheel rotor locally (toy-brick pie slices, rim,
	pegs, hub, prize labels) at SpinConfig.Wheel, idles it slowly while you
	are nearby, and plays the spin cinematic for a server result:
	camera in front of the wheel -> 5 turns easing out -> ticks on every peg
	-> lands on the prize -> flash + confetti + reward toast.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Configs = ReplicatedStorage:WaitForChild("Configs")
local SpinConfig = require(Configs:WaitForChild("SpinConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local Primitives = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Dragons"):WaitForChild("Primitives"))

local SpinController = {}

local registry
local rotor: Model? = nil
local parts: { BasePart } = {}
local offsets: { CFrame } = {}
local segParts: { [number]: { BasePart } } = {}
local angle = 0 -- degrees, clockwise as players see it
local spinning = false
local BUILD_RANGE = 700

local V3 = Vector3.new
local WHITE = Color3.fromRGB(242, 243, 242)
local GOLD = Color3.fromRGB(245, 205, 47)
local RED = Color3.fromRGB(196, 40, 27)

local function rotorCF(deg: number): CFrame
	-- rotation about the wheel's local Z: clockwise for players looking at its front
	return SpinConfig.Wheel * CFrame.Angles(0, 0, math.rad(deg))
end

local function add(part: BasePart, localCF: CFrame)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = rotor
	table.insert(parts, part)
	table.insert(offsets, localCF)
	return part
end

-- point on the wheel face: angle clockwise from the top as players see it
local function onFace(deg: number, radius: number, z: number): Vector3
	local a = math.rad(deg)
	return V3(-math.sin(a) * radius, math.cos(a) * radius, z)
end

local function build()
	rotor = Instance.new("Model")
	rotor.Name = "SpinWheelRotor"
	table.clear(parts)
	table.clear(offsets)
	table.clear(segParts)
	local R = SpinConfig.WheelRadius
	local n = #SpinConfig.Segments
	local step = 360 / n
	local thick = 1
	-- pie slices (each slice = 2 wedges, built in rotor-local space)
	for i, seg in SpinConfig.Segments do
		local a0, a1 = (i - 1) * step, i * step
		local p0 = V3(0, 0, 0)
		local p1 = onFace(a0, R, 0)
		local p2 = onFace(a1, R, 0)
		segParts[i] = {}
		for _, w in Primitives.triangle(p0, p1, p2, thick, seg.Color, Enum.Material.SmoothPlastic) do
			local localCF = w.CFrame
			table.insert(segParts[i], add(w, localCF))
		end
		-- divider peg at the slice border (toward the players)
		local pegPos = onFace(a0, R - 0.9, -0.9)
		local peg = Primitives.block(V3(1.2, 0.8, 0.8), CFrame.new(), GOLD)
		peg.Shape = Enum.PartType.Cylinder
		add(peg, CFrame.lookAt(pegPos, pegPos + V3(0, 0, -1)) * CFrame.Angles(0, math.rad(90), 0))
	end
	-- rim
	local rimN = n * 3
	for i = 0, rimN - 1 do
		local a0, a1 = i / rimN * 360, (i + 1) / rimN * 360
		local q0, q1 = onFace(a0, R + 0.5, 0), onFace(a1, R + 0.5, 0)
		local mid = (q0 + q1) / 2
		local len = (q1 - q0).Magnitude * 1.08
		local col = (i % 3 == 0) and GOLD or WHITE
		local b = Primitives.block(V3(1.2, 1.6, len), CFrame.new(), col)
		add(b, CFrame.lookAt(mid, q1, V3(0, 0, -1)))
	end
	-- hub
	local hub = Primitives.block(V3(1.6, 5, 5), CFrame.new(), GOLD)
	hub.Shape = Enum.PartType.Cylinder
	add(hub, CFrame.new(0, 0, -0.6) * CFrame.Angles(0, math.rad(90), 0))
	local cap = Primitives.block(V3(0.6, 3, 3), CFrame.new(), RED)
	cap.Shape = Enum.PartType.Cylinder
	add(cap, CFrame.new(0, 0, -1.5) * CFrame.Angles(0, math.rad(90), 0))
	-- prize labels on a clear plate in front of the slices (rotates with the rotor)
	local plate = Instance.new("Part")
	plate.Name = "LabelPlate"
	plate.Size = V3(R * 2, R * 2, 0.1)
	plate.Transparency = 1
	add(plate, CFrame.new(0, 0, -0.62))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.MaxDistance = 600
	gui.Adornee = plate
	gui.Parent = plate
	for i, seg in SpinConfig.Segments do
		local mid = SpinConfig.segmentAngle(i)
		local a = math.rad(mid)
		local t = Instance.new("TextLabel")
		t.Name = "Label" .. i
		t.BackgroundTransparency = 1
		t.AnchorPoint = Vector2.new(0.5, 0.5)
		t.Position = UDim2.fromScale(0.5 + math.sin(a) * 0.31, 0.5 - math.cos(a) * 0.31)
		t.Size = UDim2.fromScale(0.36, 0.1)
		t.Rotation = mid - 90
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.Text = seg.Label
		t.TextColor3 = Color3.new(1, 1, 1)
		local st = Instance.new("UIStroke")
		st.Thickness = 2.5
		st.Color = Color3.fromRGB(20, 24, 40)
		st.Parent = t
		t.Parent = gui
	end
	rotor.Parent = Workspace
	SpinController.Apply()
end

function SpinController.Apply()
	if not rotor then
		return
	end
	local base = rotorCF(angle)
	local cfs = table.create(#parts)
	for i, off in offsets do
		cfs[i] = base * off
	end
	local ok = pcall(function()
		Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end)
	if not ok then
		for i, p in parts do
			p.CFrame = cfs[i]
		end
	end
end

local function cameraFocus(): Vector3?
	local cam = Workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

-- which segment is under the top pointer for a rotor angle
function SpinController.segmentAt(deg: number): number
	local n = #SpinConfig.Segments
	local step = 360 / n
	local a = (-deg) % 360
	return math.floor(a / step) % n + 1
end

local function easeOutQuint(x: number): number
	return 1 - (1 - x) ^ 5
end

local function flashSegment(i: number)
	local list = segParts[i]
	if not list then
		return
	end
	task.spawn(function()
		for k = 1, 6 do
			for _, p in list do
				p.Material = (k % 2 == 1) and Enum.Material.Neon or Enum.Material.SmoothPlastic
			end
			task.wait(0.18)
		end
	end)
end

local function confetti(at: Vector3, count: number)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = V3(1, 1, 1)
	p.CFrame = CFrame.new(at)
	p.Parent = Workspace
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
		ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 220, 60)),
		ColorSequenceKeypoint.new(0.66, Color3.fromRGB(90, 220, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 120, 255)),
	})
	e.LightEmission = 1
	e.Rate = 0
	e.Lifetime = NumberRange.new(1, 1.8)
	e.Speed = NumberRange.new(18, 34)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = V3(0, -18, 0)
	e.Drag = 1.5
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
	e.Parent = p
	e:Emit(count)
	task.delay(2.5, function()
		p:Destroy()
	end)
end

local viewing = false

local function wheelShot(): CFrame
	local wheel = SpinConfig.Wheel
	return CFrame.lookAt(wheel.Position + wheel.LookVector * 44 + V3(0, 2, 0), wheel.Position + V3(0, -2, 0))
end

local function glideCamera(to: CFrame, duration: number)
	local camera = Workspace.CurrentCamera
	local from = camera.CFrame
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		local a = (os.clock() - t0) / duration
		camera.CFrame = from:Lerp(to, a * a * (3 - 2 * a))
		RunService.RenderStepped:Wait()
	end
	camera.CFrame = to
end

-- Spin panel open: camera frames the wheel (HUD hidden) until exitView.
function SpinController.enterView()
	if viewing then
		return
	end
	viewing = true
	if not rotor then
		build()
	end
	local cam = registry.CameraController
	if cam and not cam.inCinematic() then
		cam.beginCinematic()
	end
	registry.UIController.SetHudVisible(false)
	task.spawn(glideCamera, wheelShot(), 0.7)
end

function SpinController.exitView()
	if not viewing then
		return
	end
	viewing = false
	task.spawn(function()
		while spinning do
			task.wait()
		end
		local cam = registry.CameraController
		local char = Players.LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			glideCamera(CFrame.lookAt(hrp.Position - hrp.CFrame.LookVector * 16 + V3(0, 7, 0), hrp.Position + V3(0, 2, 0)), 0.5)
		end
		if not viewing then
			registry.UIController.SetHudVisible(true)
			if cam and cam.inCinematic() then
				cam.endCinematic()
			end
		end
	end)
end

function SpinController.isViewing(): boolean
	return viewing
end

-- Plays the spin for a server result; returns when the wheel has landed.
function SpinController.play(result)
	if spinning then
		return
	end
	spinning = true
	if not rotor then
		build()
	end
	local cam = registry.CameraController
	local camera = Workspace.CurrentCamera
	local uic = registry.UIController
	local audio = registry.AudioController
	local wheel = SpinConfig.Wheel
	local ownView = not viewing
	local ok, err = pcall(function()
		if ownView then
			if cam then
				cam.beginCinematic()
			end
			uic.SetHudVisible(false)
			glideCamera(wheelShot(), 0.6)
		else
			camera.CFrame = wheelShot()
		end
		-- target angle: land inside the winning slice (not always dead centre)
		local n = #SpinConfig.Segments
		local step = 360 / n
		local target = -SpinConfig.segmentAngle(result.Index) + (math.random() - 0.5) * step * 0.6
		local start = angle
		local delta = (target - start) % 360
		local total = SpinConfig.Turns * 360 + delta
		local duration = SpinConfig.SpinSeconds
		local lastSeg = SpinController.segmentAt(angle)
		local t0 = os.clock()
		local shot = camera.CFrame
		while true do
			local a = math.clamp((os.clock() - t0) / duration, 0, 1)
			angle = start + total * easeOutQuint(a)
			SpinController.Apply()
			-- slow push-in while the wheel slows down
			camera.CFrame = shot * CFrame.new(0, 0, -6 * a * a)
			local seg = SpinController.segmentAt(angle)
			if seg ~= lastSeg then
				lastSeg = seg
				if audio then
					audio.playUI("Click")
				end
			end
			if a >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end
		angle %= 360
		-- landed
		flashSegment(result.Index)
		local seg = SpinConfig.Segments[result.Index]
		confetti(wheel.Position + wheel.LookVector * 2 + V3(0, SpinConfig.WheelRadius, 0), seg.Jackpot and 160 or 80)
		if audio then
			audio.playUI(seg.Jackpot and "LevelUp" or "Collect")
		end
		SpinController.ShowPrize(result)
		task.wait(1.6)
		if not ownView and viewing then
			glideCamera(wheelShot(), 0.4)
		end
	end)
	if not ok then
		warn("[Spin] " .. tostring(err))
	end
	if ownView then
		uic.SetHudVisible(true)
		if cam and cam.inCinematic() then
			cam.endCinematic()
		end
	end
	spinning = false
end

function SpinController.isSpinning(): boolean
	return spinning
end

-- Big "YOU WON" banner + toast.
function SpinController.ShowPrize(result)
	local uic = registry.UIController
	local prize = result.Prize or {}
	local text = prize.Label or "PRIZE"
	if prize.Kind == "Egg" then
		local egg = EggConfig.Eggs[prize.Egg]
		text = string.upper(egg and egg.Name or prize.Egg or "EGG")
		if (prize.Count or 0) == 0 then
			text ..= "  (bag full: +$" .. tostring(prize.Amount or 0) .. ")"
		end
	elseif prize.Kind == "Spin" then
		text = "+" .. tostring(prize.Count or 1) .. " SPIN"
	elseif prize.Kind == "Boost" then
		text = "x2 LUCK  " .. tostring(math.floor((prize.Seconds or 600) / 60)) .. " MIN"
	end
	-- the Spin panel shows a clean result card above its bar; the toast is only the fallback
	local seg = SpinConfig.Segments[result.Index]
	local win = uic.GetWindow and uic.GetWindow("Spin")
	if win and win.ShowPrize and win.Root.Visible then
		win:ShowPrize(text, seg and seg.Color or WHITE, seg and seg.Jackpot)
	else
		uic.Notify("rare", "Spin Wheel: you won " .. text .. "!")
	end
end

function SpinController.Init(reg)
	registry = reg
end

function SpinController.Start()
	-- build/destroy the rotor by distance and idle-rotate it while nearby
	RunService.Heartbeat:Connect(function(dt)
		local pos = cameraFocus()
		local near = pos ~= nil and (pos - SpinConfig.Wheel.Position).Magnitude < BUILD_RANGE
		if near and not rotor then
			build()
		elseif not near and rotor and not spinning then
			rotor:Destroy()
			rotor = nil
		end
		if rotor and not spinning then
			angle = (angle + dt * 8) % 360
			SpinController.Apply()
		end
	end)
end

return SpinController

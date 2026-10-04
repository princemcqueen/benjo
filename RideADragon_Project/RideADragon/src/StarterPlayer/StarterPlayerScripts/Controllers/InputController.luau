--[[
	InputController
	One place for gameplay input across keyboard/mouse, gamepad and touch.

	Movement uses the PlayerModule's move vector (WASD / left stick / touch
	thumbstick) so every platform behaves the same. Riding actions are bound
	with ContextActionService at high priority while mounted, so Space never
	makes the humanoid jump out of the saddle.

	  InputController.getMoveVector() -> Vector3 (x = right, z = back; local)
	  InputController.isDown(action)  -> boolean   (held)
	  InputController.consume(action) -> boolean   (edge, cleared on read)
	  InputController.setVirtual(action, down)     (mobile buttons)
	  InputController.Pressed: Signal(action)

	Actions: Jump, Descend, Sprint, Roar, Ride, FreeCursor, MouseLock, Dash, Fire, Flourish
	Desktop: Space jump/takeoff/ascend, Ctrl or C descend/land, Shift sprint/
	         boost, R ride, F roar, V mouse steering on/off, hold Alt to free
	         the cursor while riding.
	Dragon Bond: Q dash (B), hold E fire breath (LB), Z sky dance (RB).
	Gamepad: A jump/ascend, LT descend, RT boost, Y ride, X roar.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local InputController = {}
InputController.Pressed = Signal.new()
InputController.Riding = false
InputController.LastDevice = "KeyboardMouse" -- KeyboardMouse | Gamepad | Touch
InputController.DeviceChanged = Signal.new()

local PRIORITY = 3500

local BINDINGS = {
	Jump = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA },
	Descend = { Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl, Enum.KeyCode.C, Enum.KeyCode.ButtonL2 },
	Sprint = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonR2, Enum.KeyCode.ButtonL3 },
	Roar = { Enum.KeyCode.F, Enum.KeyCode.ButtonX },
	-- Dragon Bond abilities (unlocked by bond level, see BondConfig)
	Dash = { Enum.KeyCode.Q, Enum.KeyCode.ButtonB },
	Fire = { Enum.KeyCode.E, Enum.KeyCode.ButtonL1 },
	Flourish = { Enum.KeyCode.Z, Enum.KeyCode.ButtonR1 },
	FreeCursor = { Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt },
	MouseLock = { Enum.KeyCode.V },
}
-- always bound (mount from foot too)
local GLOBAL = {
	Ride = { Enum.KeyCode.R, Enum.KeyCode.ButtonY },
}

local held: { [string]: boolean } = {}
local virtual: { [string]: boolean } = {}
local edges: { [string]: boolean } = {}
local controls = nil

local function setHeld(action: string, down: boolean)
	local was = held[action] or virtual[action]
	held[action] = down
	if down and not was then
		edges[action] = true
		InputController.Pressed:Fire(action)
	end
end

local function handler(actionName: string, state: Enum.UserInputState, _input: InputObject)
	local action = string.sub(actionName, 5) -- strip "RAD_"
	if state == Enum.UserInputState.Begin then
		setHeld(action, true)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		held[action] = false
	end
	return Enum.ContextActionResult.Sink
end

local function textFocused(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

function InputController.setRiding(on: boolean)
	if InputController.Riding == on then
		return
	end
	InputController.Riding = on
	for action, keys in BINDINGS do
		local name = "RAD_" .. action
		if on then
			ContextActionService:BindActionAtPriority(name, handler, false, PRIORITY, table.unpack(keys))
		else
			ContextActionService:UnbindAction(name)
			held[action] = false
		end
	end
	if not on then
		table.clear(edges)
	end
end

function InputController.isDown(action: string): boolean
	if textFocused() then
		return false
	end
	return held[action] == true or virtual[action] == true
end

function InputController.consume(action: string): boolean
	local e = edges[action] == true
	edges[action] = nil
	return e
end

function InputController.setVirtual(action: string, down: boolean)
	local was = held[action] or virtual[action]
	virtual[action] = down
	if down and not was then
		edges[action] = true
		InputController.Pressed:Fire(action)
	end
end

local KEY_FALLBACK = {
	{ Enum.KeyCode.W, Vector3.new(0, 0, -1) },
	{ Enum.KeyCode.Up, Vector3.new(0, 0, -1) },
	{ Enum.KeyCode.S, Vector3.new(0, 0, 1) },
	{ Enum.KeyCode.Down, Vector3.new(0, 0, 1) },
	{ Enum.KeyCode.A, Vector3.new(-1, 0, 0) },
	{ Enum.KeyCode.D, Vector3.new(1, 0, 0) },
}

-- Local move vector: x = right, z = back (-1 = forward). Magnitude <= 1.
function InputController.getMoveVector(): Vector3
	if textFocused() then
		return Vector3.zero
	end
	if controls then
		local ok, v = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(v) == "Vector3" then
			if v.Magnitude > 1 then
				v = v.Unit
			end
			return v
		end
	end
	local v = Vector3.zero
	for _, entry in KEY_FALLBACK do
		if UserInputService:IsKeyDown(entry[1]) then
			v += entry[2]
		end
	end
	local pads = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	for _, st in pads do
		if st.KeyCode == Enum.KeyCode.Thumbstick1 and st.Position.Magnitude > 0.15 then
			v += Vector3.new(st.Position.X, 0, -st.Position.Y)
		end
	end
	if v.Magnitude > 1 then
		v = v.Unit
	end
	return v
end

local function classify(t: Enum.UserInputType): string?
	if t == Enum.UserInputType.Touch then
		return "Touch"
	elseif t.Name:find("Gamepad") then
		return "Gamepad"
	elseif t == Enum.UserInputType.Keyboard or t.Name:find("Mouse") then
		return "KeyboardMouse"
	end
	return nil
end

function InputController.Init()
	for action, keys in GLOBAL do
		ContextActionService:BindActionAtPriority("RAD_" .. action, function(_, state)
			if textFocused() then
				return Enum.ContextActionResult.Pass
			end
			if state == Enum.UserInputState.Begin then
				setHeld(action, true)
			elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				held[action] = false
			end
			return Enum.ContextActionResult.Pass
		end, false, PRIORITY - 1, table.unpack(keys))
	end
	UserInputService.LastInputTypeChanged:Connect(function(t)
		local d = classify(t)
		if d and d ~= InputController.LastDevice then
			InputController.LastDevice = d
			InputController.DeviceChanged:Fire(d)
		end
	end)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		InputController.LastDevice = "Touch"
	end
end

function InputController.Start()
	local player = Players.LocalPlayer
	local ps = player:FindFirstChild("PlayerScripts") or player:WaitForChild("PlayerScripts", 5)
	local module = ps and ps:FindFirstChild("PlayerModule") or (ps and ps:WaitForChild("PlayerModule", 5))
	if module then
		local ok, pm = pcall(require, module)
		if ok and pm and pm.GetControls then
			controls = pm:GetControls()
		end
	end
end

return InputController

--[[
	Responsive
	Screen metrics + device classification + the "unit" used for small offset
	details (padding, corner radius, stroke, text size).

	Primary layout (positions/sizes of panels, HUD clusters, windows) is done
	with Scale + AnchorPoint + aspect-ratio constraints. The unit only drives
	minor details so they keep the same *relative* size from 720p to 4K.

	A virtual resolution can be forced (Dev UI Lab) to preview any device:
	the whole UI root is laid out at that pixel size and scaled to fit.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local Theme = require(script.Parent:WaitForChild("Theme"))

local Responsive = {}
Responsive.Changed = Signal.new()

Responsive.Width = 1920
Responsive.Height = 1080
Responsive.Device = "Desktop" -- "Desktop" | "Tablet" | "Phone"
Responsive.Portrait = false
Responsive.IsTouch = false
Responsive.Unit = 1
Responsive.TopInset = 58
Responsive.UserScale = 1
Responsive.Virtual = nil -- { Width, Height, Device, Touch } when previewing

-- Weak keys: destroyed/unreferenced instances are collected automatically.
local bindings: { [Instance]: { { any } } } = setmetatable({}, { __mode = "k" }) :: any
local roots = {} -- { { Frame, UIScale } }

local function realViewport(): Vector2
	local cam = Workspace.CurrentCamera
	if cam then
		local v = cam.ViewportSize
		if v.X > 1 and v.Y > 1 then
			return v
		end
	end
	return Vector2.new(1920, 1080)
end

local function compute()
	local v = Responsive.Virtual
	local w, h, touch
	if v then
		w, h, touch = v.Width, v.Height, v.Touch
	else
		local vp = realViewport()
		w, h = vp.X, vp.Y
		touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end
	local shortSide = math.min(w, h)
	local device
	if v and v.Device then
		device = v.Device
	elseif touch then
		device = shortSide < 600 and "Phone" or "Tablet"
	else
		device = "Desktop"
	end
	local unit
	if device == "Phone" then
		unit = math.clamp(shortSide / 520, 0.62, 1.15)
	elseif device == "Tablet" then
		unit = math.clamp(shortSide / 900, 0.75, 1.6)
	else
		unit = math.clamp(math.min(w / 1920, h / 1080), 0.6, 2.4)
	end
	unit *= Responsive.UserScale

	local inset = 58
	if not v then
		local ok, tb = pcall(function()
			return GuiService.TopbarInset
		end)
		if ok and tb and tb.Height > 0 then
			inset = tb.Height
		end
	elseif device == "Phone" then
		inset = 44
	end

	local changed = w ~= Responsive.Width or h ~= Responsive.Height or device ~= Responsive.Device
		or math.abs(unit - Responsive.Unit) > 1e-4 or inset ~= Responsive.TopInset or touch ~= Responsive.IsTouch
	Responsive.Width = w
	Responsive.Height = h
	Responsive.Device = device
	Responsive.Portrait = h > w
	Responsive.IsTouch = touch or device ~= "Desktop"
	Responsive.Unit = unit
	Responsive.TopInset = inset
	return changed
end

-- Integer pixels for a 1080p design value.
function Responsive.px(n: number): number
	local v = n * Responsive.Unit
	if v > 0 and v < 1 then
		return 1
	end
	return math.floor(v + 0.5)
end

-- Fractional pixels (strokes look better unrounded).
function Responsive.pxf(n: number): number
	return n * Responsive.Unit
end

function Responsive.text(role: string): number
	local spec = Theme.TextSizes[role] or Theme.TextSizes.Body
	local size = spec[1] * Responsive.Unit
	if Responsive.Device == "Phone" then
		size *= 1.06
	end
	return math.max(spec[2], math.floor(size + 0.5))
end

function Responsive.isMobile(): boolean
	return Responsive.Device ~= "Desktop"
end

-- Re-evaluates fn(Responsive) into inst[prop] now and on every change.
function Responsive.bind(inst: Instance, prop: string, fn)
	local list = bindings[inst]
	if not list then
		list = {}
		bindings[inst] = list
	end
	-- replace an existing binding for the same property
	for _, b in list do
		if b[1] == prop then
			b[2] = fn
			local target: any = inst
			target[prop] = fn(Responsive)
			return inst
		end
	end
	table.insert(list, { prop, fn })
	local ok, err = pcall(function()
		(inst :: any)[prop] = fn(Responsive)
	end)
	if not ok then
		warn("[Responsive] bind failed: " .. tostring(err))
	end
	return inst
end

function Responsive.unbind(inst: Instance)
	bindings[inst] = nil
end

function Responsive.registerRoot(frame: Frame, scale: UIScale)
	table.insert(roots, { frame, scale })
	Responsive.applyRoot(frame, scale)
end

function Responsive.applyRoot(frame: Frame, scale: UIScale)
	local v = Responsive.Virtual
	if v then
		local real = realViewport()
		local fit = math.min(real.X / v.Width, real.Y / v.Height)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromOffset(v.Width, v.Height)
		scale.Scale = fit
	else
		frame.AnchorPoint = Vector2.zero
		frame.Position = UDim2.fromScale(0, 0)
		frame.Size = UDim2.fromScale(1, 1)
		scale.Scale = 1
	end
end

local function refresh(force: boolean?)
	local changed = compute()
	if not changed and not force then
		return
	end
	for inst, list in bindings do
		for _, b in list do
			local ok, err = pcall(function()
				(inst :: any)[b[1]] = b[2](Responsive)
			end)
			if not ok then
				warn("[Responsive] binding error: " .. tostring(err))
			end
		end
	end
	for _, r in roots do
		Responsive.applyRoot(r[1], r[2])
	end
	Responsive.Changed:Fire()
end

function Responsive.refresh()
	refresh(true)
end

function Responsive.setVirtual(width: number, height: number, device: string?, touch: boolean?)
	Responsive.Virtual = {
		Width = width,
		Height = height,
		Device = device,
		Touch = touch == true or device == "Phone" or device == "Tablet",
	}
	refresh(true)
end

function Responsive.clearVirtual()
	Responsive.Virtual = nil
	refresh(true)
end

function Responsive.setUserScale(s: number)
	Responsive.UserScale = math.clamp(s, 0.8, 1.25)
	refresh(true)
end

function Responsive.Init()
	compute()
	local function hookCamera()
		local cam = Workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				refresh(false)
			end)
		end
	end
	hookCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		hookCamera()
		refresh(false)
	end)
	UserInputService.LastInputTypeChanged:Connect(function()
		refresh(false)
	end)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(function()
			refresh(false)
		end)
	end)
end

return Responsive

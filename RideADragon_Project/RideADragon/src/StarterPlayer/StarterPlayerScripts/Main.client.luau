--[[
	Client bootstrap. Requires controllers in dependency order, wires the UI
	(windows + HUD), then starts everything.

	Every step runs in its own protected call: a controller or window that fails is reported
	(Output + the red error panel of Diagnostics in Studio) and everything else keeps working -
	one broken script must never take the whole client down.
]]

local Controllers = script.Parent:WaitForChild("Controllers")
local UI = script.Parent:WaitForChild("UI")

local okDiagnostics, Diagnostics = pcall(function()
	return require(script.Parent:WaitForChild("Diagnostics"))
end)

local function fail(stage: string, name: string, err: any)
	warn(string.format("[Boot] %s %s failed: %s", stage, name, tostring(err)))
	if okDiagnostics then
		pcall(Diagnostics.report, stage, name, err)
	end
end

-- Runs fn(...) protected. Returns ok, first result.
local function try(stage: string, name: string, fn: any, ...: any): (boolean, any)
	local ok, result = xpcall(fn, function(e)
		return tostring(e) .. "\n" .. debug.traceback("", 2)
	end, ...)
	if not ok then
		fail(stage, name, result)
		return false, nil
	end
	return true, result
end

local ORDER = {
	"DataController",
	"AudioController",
	"UIController",
	"GraphicsController",
	"SettingsController",
	"InputController",
	"CameraController",
	"AnimationController",
	"DragonController",
	"BondController",
	"InteractionController",
	"EggController",
	"HeldEggController",
	"SanctuaryController",
	"PerchController",
	"TitleController",
	"SpinController",
	"TreeController",
	"RaceController",
	"CombatController",
	"DuelController",
	"HatchController",
	"AnnounceController",
	"WildEggController",
	"RadarController",
	"CoinController",
	"DailyController",
	"ChatController",
	"InventoryController",
	"TutorialController",
	"RegionController",
	"StreamingController",
	"WorldFXController",
}

local registry = {}
for _, name in ORDER do
	local module = Controllers:FindFirstChild(name)
	if module then
		local ok, controller = try("require", name, require, module)
		if ok then
			registry[name] = controller
		end
	end
end

for _, name in ORDER do
	local controller = registry[name]
	if controller and controller.Init then
		try("Init", name, controller.Init, registry)
	end
end

-- Windows (built lazily on first open)
local uic = registry.UIController
local Windows = UI:WaitForChild("Windows")
if uic then
	for _, module in Windows:GetChildren() do
		if module:IsA("ModuleScript") then
			local name = string.gsub(module.Name, "Window$", "")
			local ok, window = try("require", module.Name, require, module)
			if ok then
				try("RegisterWindow", module.Name, uic.RegisterWindow, name, window)
			end
		end
	end
end

-- HUD
local okHud, Hud = try("require", "Hud", function()
	return require(UI:WaitForChild("Hud"):WaitForChild("Hud"))
end)
if okHud and Hud and uic then
	local ok, hud = try("new", "Hud", Hud.new, uic, registry)
	if ok then
		registry.Hud = hud
	end
end

-- Developer UI test harness (Studio / owner only)
try("Init", "UILab", function()
	require(UI:WaitForChild("Dev"):WaitForChild("UILab")).Init(uic, registry)
end)

for _, name in ORDER do
	local controller = registry[name]
	if controller and controller.Start then
		task.spawn(try, "Start", name, controller.Start)
	end
end

if okDiagnostics then
	pcall(Diagnostics.start)
end

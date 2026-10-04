--[[
	Client bootstrap. Requires controllers in dependency order, wires the UI
	(windows + HUD), then starts everything.
]]

local Controllers = script.Parent:WaitForChild("Controllers")
local UI = script.Parent:WaitForChild("UI")

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
	"HatchController",
	"AnnounceController",
	"WildEggController",
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
		registry[name] = require(module)
	end
end

for _, name in ORDER do
	local controller = registry[name]
	if controller and controller.Init then
		controller.Init(registry)
	end
end

-- Windows (built lazily on first open)
local uic = registry.UIController
local Windows = UI:WaitForChild("Windows")
for _, module in Windows:GetChildren() do
	if module:IsA("ModuleScript") then
		local name = string.gsub(module.Name, "Window$", "")
		uic.RegisterWindow(name, require(module))
	end
end

-- HUD
local Hud = require(UI:WaitForChild("Hud"):WaitForChild("Hud"))
registry.Hud = Hud.new(uic, registry)

-- Developer UI test harness (Studio / owner only)
require(UI:WaitForChild("Dev"):WaitForChild("UILab")).Init(uic, registry)

for _, name in ORDER do
	local controller = registry[name]
	if controller and controller.Start then
		task.spawn(controller.Start)
	end
end

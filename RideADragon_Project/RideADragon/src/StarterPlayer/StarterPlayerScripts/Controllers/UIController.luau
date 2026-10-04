--[[
	UIController (master UI controller)
	- Creates the layered ScreenGuis (HUD 10, Tooltip 30, Windows 50,
	  Notifications 70, Modal 100) with a responsive root each
	- Owns the window manager: exactly ONE major window open at a time,
	  centralized open/close transitions (scale 0.96 -> 1 + fade, ~190 ms)
	- Esc / Gamepad B / mobile close button = back/close
	- Keyboard shortcuts for every HUD button
	- Public helpers: Notify, Confirm, SetHudVisible
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local Scripts = script.Parent.Parent
local UI = Scripts:WaitForChild("UI")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Fade = require(UI.Fade)

local UIController = {}
UIController.WindowOpened = Signal.new()
UIController.WindowClosed = Signal.new()
UIController.HudVisibilityChanged = Signal.new()
UIController.Layers = {}
UIController.InputBlocked = false
UIController.Current = nil -- name of the open window
UIController.Windows = {} -- name -> window object
UIController.WindowModules = {} -- name -> module (lazy build)
UIController.HudVisible = true

local registry = nil
local transition = nil -- active RenderStepped connection
local backdrop: TextButton = nil

-- Hotkeys -> window names
local HOTKEYS = {
	[Enum.KeyCode.G] = "Inventory",
	[Enum.KeyCode.X] = "Index",
	[Enum.KeyCode.Q] = "Quests",
	[Enum.KeyCode.B] = "Shop",
	[Enum.KeyCode.J] = "Daily",
	[Enum.KeyCode.P] = "Settings",
	[Enum.KeyCode.K] = "EggStorage",
	[Enum.KeyCode.T] = "Teleport",
}
UIController.Hotkeys = HOTKEYS

local function makeLayer(name: string, order: number)
	local gui = Create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = order,
	})
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	end)
	local root = Create("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local scale = Create("UIScale", { Parent = root })
	Responsive.registerRoot(root, scale)
	gui.Parent = player:WaitForChild("PlayerGui")
	UIController.Layers[name] = { Gui = gui, Root = root }
	return root
end

function UIController.sound(key: string)
	local audio = registry and registry.AudioController
	if audio then
		audio.playUI(key)
	end
end

-- ============================================================== windows
function UIController.RegisterWindow(name: string, module)
	UIController.WindowModules[name] = module
end

local function getWindow(name: string)
	local w = UIController.Windows[name]
	if w then
		return w
	end
	local module = UIController.WindowModules[name]
	if not module then
		warn("[UI] Unknown window " .. name)
		return nil
	end
	w = module.new(UIController, registry)
	w.Root.Visible = false
	w.Root.Parent = UIController.Layers.GameUI.Root:FindFirstChild("Windows")
	w.OnClose = function()
		UIController.Close()
	end
	UIController.Windows[name] = w
	return w
end
UIController.GetWindow = getWindow

local function stopTransition()
	if transition then
		transition:Disconnect()
		transition = nil
	end
end

local function animate(duration: number, step: (number) -> (), done: (() -> ())?)
	stopTransition()
	local start = os.clock()
	step(0)
	transition = RunService.RenderStepped:Connect(function()
		local a = math.clamp((os.clock() - start) / duration, 0, 1)
		step(a)
		if a >= 1 then
			stopTransition()
			if done then
				done()
			end
		end
	end)
end

local fadeState = nil
local closingWindow = nil
local BACKDROP_T = 0.6

local backdropAllowed = true
local function setBackdrop(alpha: number)
	backdrop.BackgroundTransparency = backdropAllowed and (1 - (1 - BACKDROP_T) * alpha) or 1
end

local function finishClose(w)
	if w then
		w.Root.Visible = false
		w.Scale.Scale = 1
	end
	if fadeState then
		Fade.restore(fadeState)
		fadeState = nil
	end
	closingWindow = nil
end

function UIController.IsOpen(name: string?): boolean
	if name then
		return UIController.Current == name
	end
	return UIController.Current ~= nil
end

function UIController.Open(name: string, args: any?)
	if UIController.Current == name then
		local w = UIController.Windows[name]
		if w and w.OnReopen then
			w:OnReopen(args)
		end
		return
	end
	local w = getWindow(name)
	if not w then
		return
	end
	-- close the current one instantly (single-window rule)
	if UIController.Current then
		local old = UIController.Windows[UIController.Current]
		local oldName = UIController.Current
		stopTransition()
		finishClose(old)
		if old and old.OnHidden then
			old:OnHidden()
		end
		UIController.WindowClosed:Fire(oldName)
	elseif closingWindow then
		stopTransition()
		finishClose(closingWindow)
	end
	UIController.Current = name
	UIController.InputBlocked = true
	w:ApplySize()
	if w.OnOpen then
		w:OnOpen(args)
	end
	w.Root.Visible = true
	-- windows that sit over the 3D world (e.g. the Spin Wheel bar) skip the dim backdrop
	backdropAllowed = w.NoBackdrop ~= true
	backdrop.Visible = backdropAllowed
	fadeState = Fade.capture(w.Root)
	UIController.sound("Open")
	UIController.WindowOpened:Fire(name, w)
	animate(Theme.Motion.Open, function(a)
		local e = 1 - (1 - a) ^ 4 -- quart out
		if fadeState then
			Fade.apply(fadeState, e)
		end
		setBackdrop(e)
		w.Scale.Scale = Theme.Motion.StartScale + (1 - Theme.Motion.StartScale) * e
	end, function()
		if fadeState then
			Fade.restore(fadeState)
			fadeState = nil
		end
		setBackdrop(1)
	end)
end

function UIController.Close()
	local name = UIController.Current
	if not name then
		return
	end
	local w = UIController.Windows[name]
	UIController.Current = nil
	UIController.InputBlocked = false
	UIController.sound("Close")
	if w and w.OnHidden then
		w:OnHidden()
	end
	UIController.WindowClosed:Fire(name)
	stopTransition()
	if fadeState then
		Fade.restore(fadeState)
	end
	fadeState = w and Fade.capture(w.Root) or nil
	closingWindow = w
	animate(Theme.Motion.Close, function(a)
		local e = a * a
		if fadeState then
			Fade.apply(fadeState, 1 - e)
		end
		setBackdrop(1 - e)
		if w then
			w.Scale.Scale = 1 - (1 - Theme.Motion.StartScale) * e
		end
	end, function()
		backdrop.Visible = false
		finishClose(w)
	end)
end

function UIController.Toggle(name: string, args: any?)
	if UIController.Current == name then
		UIController.Close()
	else
		UIController.Open(name, args)
	end
end

-- ============================================================== helpers
function UIController.Notify(kind: string, text: string, extra: { [string]: any }?)
	if UIController.Notifications then
		UIController.Notifications:Push(kind, text, extra)
	end
end

function UIController.Confirm(opts: { [string]: any }): boolean
	return UIController.ModalDialog:Confirm(opts)
end

function UIController.SetHudVisible(visible: boolean)
	UIController.HudVisible = visible
	local hud = UIController.Layers.GameHUD
	if hud then
		hud.Gui.Enabled = visible
	end
	UIController.HudVisibilityChanged:Fire(visible)
end

-- Shows a server result error as a toast; returns ok.
function UIController.HandleResult(result, successText: string?): boolean
	if result.ok then
		if successText then
			UIController.Notify("success", successText)
		end
		return true
	end
	if result.msg then
		UIController.Notify("error", result.msg)
	elseif result.err ~= "RATE_LIMITED" then
		UIController.Notify("error", "Action failed")
	end
	return false
end

-- ============================================================== init
function UIController.Init(reg)
	registry = reg
	Responsive.Init()

	makeLayer("GameHUD", Theme.Layers.Hud)
	local tipRoot = makeLayer("GameTooltips", Theme.Layers.Tooltip)
	local winRoot = makeLayer("GameUI", Theme.Layers.Window)
	local notifyRoot = makeLayer("GameNotifications", Theme.Layers.Notification)
	local modalRoot = makeLayer("GameModal", Theme.Layers.Modal)

	backdrop = Create("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Theme.Colors.Black,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = winRoot,
	})
	backdrop.Activated:Connect(function()
		if not Responsive.isMobile() then
			UIController.Close()
		end
	end)
	Kit.frame({ Name = "Windows", Size = UDim2.fromScale(1, 1), Parent = winRoot })

	local Tooltip = require(UI.Overlays.Tooltip)
	local Notifications = require(UI.Overlays.Notifications)
	local Modal = require(UI.Overlays.Modal)

	local tooltip = Tooltip.new(tipRoot)
	UIController.Tooltip = tooltip
	UIController.Notifications = Notifications.new(notifyRoot, function(key)
		UIController.sound(key)
	end)
	UIController.ModalDialog = Modal.new(modalRoot)

	Kit.hooks.Click = function()
		UIController.sound("Click")
	end
	Kit.hooks.Hover = function()
		UIController.sound("Hover")
	end
	Kit.hooks.ShowTooltip = function(text, anchor)
		tooltip:Show(text, anchor)
	end
	Kit.hooks.HideTooltip = function()
		tooltip:Hide()
	end

	Net.Notified:Connect(function(kind, text, extra)
		UIController.Notify(kind, text, extra)
	end)

	Responsive.Changed:Connect(function()
		for _, w in UIController.Windows do
			w:ApplySize()
		end
	end)

	-- Back / close inputs
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape then
			if UIController.ModalDialog:IsOpen() then
				return
			end
			if UIController.Current then
				local w = UIController.Windows[UIController.Current]
				if w and w.OnBack and w.OnBack() then
					return
				end
				UIController.Close()
			end
			return
		end
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		local target = HOTKEYS[input.KeyCode]
		if target and not UIController.ModalDialog:IsOpen() then
			if UIController.WindowModules[target] then
				UIController.Toggle(target)
			end
		end
	end)

	ContextActionService:BindActionAtPriority("RAD_UIBack", function(_, state)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if UIController.Current and not UIController.ModalDialog:IsOpen() then
			local w = UIController.Windows[UIController.Current]
			if not (w and w.OnBack and w.OnBack()) then
				UIController.Close()
			end
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, 3000, Enum.KeyCode.ButtonB)

	GuiService.MenuOpened:Connect(function()
		if UIController.Current then
			UIController.Close()
		end
	end)
end

return UIController

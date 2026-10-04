--[[
	UILab (developer UI test harness) - Studio / place owner only.
	Toggle with the ` (backquote) key.

	- Preview the whole UI at any resolution/device (virtual screen, scaled
	  to fit your Studio window): 1280x720 ... 3840x2160, phones, tablet
	- Jump to any screen: HUD, Inventory, Details, Shop, Egg Storage, Hatch
	  Reveal, Index, Settings, Quests, Daily, Confirmation, Notifications
	- RUN CHECKS: automated layout QA on the current view
	- RUN ALL: every resolution x every screen, report printed to Output
	- TEST: Studio-only playtest helpers (+$1M, +5 dragons, fill the egg
	  bag, finish incubation) - served by DevService, absent on live servers
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local Responsive = require(UI.Responsive)
local UIChecks = require(script.Parent.UIChecks)

local UILab = {}

UILab.Resolutions = {
	{ "Native", nil },
	{ "1280x720", { 1280, 720 } },
	{ "1366x768", { 1366, 768 } },
	{ "1600x900", { 1600, 900 } },
	{ "1920x1080", { 1920, 1080 } },
	{ "1920x1200", { 1920, 1200 } },
	{ "2560x1440", { 2560, 1440 } },
	{ "2560x1600", { 2560, 1600 } },
	{ "3440x1440", { 3440, 1440 } },
	{ "3840x2160", { 3840, 2160 } },
	{ "Phone L", { 844, 390, "Phone" } },
	{ "Phone P", { 390, 844, "Phone" } },
	{ "Tablet", { 1180, 820, "Tablet" } },
}

UILab.Screens = { "HUD", "HeldEgg", "RareBanner", "WildEgg", "RaceLobby", "RaceCount", "RaceHud", "RaceFinish", "ArenaHud", "ArenaDown", "RaceTop", "RaceArena", "ArenaTouch", "Riding", "Inventory", "Details", "Shop", "Tree", "EggStorage", "Hatch", "Index", "Settings", "Quests", "Daily", "Confirm", "Notifications" }

local ui = nil
local registry = nil
local panel: ScreenGui? = nil
local output: TextLabel? = nil

function UILab.setResolution(spec)
	if spec == nil then
		Responsive.clearVirtual()
	else
		Responsive.setVirtual(spec[1], spec[2], spec[3], spec[3] ~= nil)
	end
end

function UILab.reset()
	if ui.ModalDialog:IsOpen() then
		ui.ModalDialog:_answer(false)
	end
	if ui.Current then
		ui.Close()
	end
	local hatch = registry.HatchController
	if hatch and hatch.closePreview then
		hatch.closePreview()
	end
	ui.Notifications:Clear()
	local hud = registry.Hud
	if hud and hud._labRiding then
		hud._labRiding = false
		hud:SetRiding(false)
	end
	if hud and hud._labArena then
		hud._labArena = false
		hud:SetArena(false)
	end
	if hud and hud._labHeld then
		hud._labHeld = false
		hud:SetHeldEgg(nil)
	end
	local announce = registry.AnnounceController
	if announce then
		announce.clear()
	end
	local wild = registry.WildEggController
	if wild then
		wild.clear()
	end
	local race = registry.RaceController
	if race and race.clear then
		race.clear()
	end
	local combat = registry.CombatController
	if combat and combat.clear then
		combat.clear()
	end
end

function UILab.show(screen: string)
	UILab.reset()
	task.wait(0.2)
	if screen == "HUD" then
		return nil
	elseif screen == "HeldEgg" then
		-- HUD with an egg in your hand (chip above the dragon card)
		local hud = registry.Hud
		if hud then
			hud._labHeld = true
			hud:SetHeldEgg({ Id = "E_lab", Type = "GroveEgg", Name = "Grove Egg", Luck = 12, Glow = Color3.fromRGB(120, 220, 120) })
		end
		return nil
	elseif screen == "WildEgg" then
		-- Lucky Wild Egg tracker (headline + countdown + arrow + distance)
		local wild = registry.WildEggController
		if wild then
			wild.preview()
		end
		return nil
	elseif screen == "RareBanner" then
		-- server-wide ultra-rare hatch banner (mega variant: the biggest one)
		local announce = registry.AnnounceController
		if announce then
			announce.preview(true)
		end
		return nil
	elseif screen == "RaceLobby" or screen == "RaceCount" or screen == "RaceHud" or screen == "RaceFinish" then
		local race = registry.RaceController
		if race then
			race.preview(({ RaceLobby = "Lobby", RaceCount = "Count", RaceHud = "Race", RaceFinish = "Finish" })[screen])
		end
		return nil
	elseif screen == "RaceTop" or screen == "RaceArena" then
		ui.Open("Race", { Tab = screen == "RaceTop" and "Monthly" or "Arena" })
		return "Race"
	elseif screen == "ArenaTouch" then
		-- the duel buttons of the touch cluster (STRIKE / BLAST replace the bond buttons) + the arena panel
		local hud = registry.Hud
		if hud then
			hud._labRiding = true
			hud._labArena = true
			hud:SetRiding(true)
			hud:SetRideMode("Fly")
			hud:SetFlightStats(124, 0.62, false)
			hud:SetArena(true)
			hud:SetArenaCooldowns(0.4, 0.8)
		end
		local combat = registry.CombatController
		if combat then
			combat.preview("Arena")
		end
		return nil
	elseif screen == "ArenaHud" or screen == "ArenaDown" then
		local combat = registry.CombatController
		if combat then
			combat.preview(screen == "ArenaDown" and "Down" or "Arena")
		end
		return nil
	elseif screen == "Riding" then
		-- HUD while mounted: ride panel (desktop) / touch cluster (mobile)
		local hud = registry.Hud
		if hud then
			hud._labRiding = true
			hud:SetRiding(true)
			hud:SetRideMode("Fly")
			hud:SetFlightStats(124, 0.62, false)
		end
		return nil
	elseif screen == "Details" then
		ui.Open("Inventory", { SelectFirst = true, ShowDetails = true })
		return "Inventory"
	elseif screen == "Hatch" then
		local hatch = registry.HatchController
		if hatch and hatch.previewResult then
			hatch.previewResult()
		end
		return nil
	elseif screen == "Confirm" then
		task.spawn(function()
			ui.Confirm({ Title = "Release Inferno Dragon?", Body = "This cannot be undone.", ConfirmText = "Release", Danger = true })
		end)
		return nil
	elseif screen == "Notifications" then
		ui.Notify("success", "Dragon equipped")
		ui.Notify("egg", "Egg found: Haven Egg")
		ui.Notify("error", "Not enough cash")
		ui.Notify("rare", "Legendary dragon hatched!")
		return nil
	else
		if ui.WindowModules[screen] then
			ui.Open(screen)
			return screen
		end
	end
	return nil
end

function UILab.check(windowName: string?)
	local roots = {}
	for _, layerName in { "GameHUD", "GameUI", "GameNotifications", "GameModal", "GameTooltips" } do
		local l = ui.Layers[layerName]
		if l then
			table.insert(roots, l.Root)
		end
	end
	local window = windowName and ui.Windows[windowName] and ui.Windows[windowName].Root or nil
	return UIChecks.run(roots, { Device = Responsive.Device, Window = window })
end

function UILab.runAll(screens: { string }?, resolutions: { any }?)
	local report = {}
	local failures = 0
	for _, res in resolutions or UILab.Resolutions do
		if res[2] == nil then
			continue
		end
		UILab.setResolution(res[2])
		task.wait(0.15)
		for _, screen in screens or UILab.Screens do
			local w = UILab.show(screen)
			task.wait(0.45)
			local issues = UILab.check(w)
			if #issues > 0 then
				failures += #issues
				table.insert(report, string.format("%-10s %-14s FAIL\n%s", res[1], screen, UIChecks.format(issues)))
			else
				table.insert(report, string.format("%-10s %-14s PASS", res[1], screen))
			end
		end
	end
	UILab.reset()
	UILab.setResolution(nil)
	local text = table.concat(report, "\n")
	print("===== UI LAB REPORT =====\n" .. text .. "\n===== " .. failures .. " issue(s) =====")
	return failures, text
end

local function enabled(): boolean
	if RunService:IsStudio() then
		return true
	end
	local player = Players.LocalPlayer
	return game.CreatorId ~= 0 and player.UserId == game.CreatorId
end

local function buildPanel()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RAD_UILab"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 400
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.BackgroundColor3 = Color3.fromRGB(14, 16, 20)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Position = UDim2.new(0, 12, 0, 70)
	frame.Size = UDim2.new(0, 330, 0, 640)
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = frame
	local order = 0
	local function label(text: string, h: number)
		order += 1
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, 0, 0, h)
		t.Font = Enum.Font.GothamBold
		t.TextSize = 13
		t.TextColor3 = Color3.fromRGB(240, 220, 170)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Text = text
		t.LayoutOrder = order
		t.Parent = frame
		return t
	end
	local function grid(items, onClick)
		order += 1
		local g = Instance.new("Frame")
		g.BackgroundTransparency = 1
		g.Size = UDim2.new(1, 0, 0, math.ceil(#items / 3) * 30)
		g.LayoutOrder = order
		g.Parent = frame
		local gl = Instance.new("UIGridLayout")
		gl.CellSize = UDim2.new(0.333, -4, 0, 26)
		gl.CellPadding = UDim2.new(0, 4, 0, 4)
		gl.SortOrder = Enum.SortOrder.LayoutOrder
		gl.Parent = g
		for i, item in items do
			local b = Instance.new("TextButton")
			b.Text = item
			b.Font = Enum.Font.GothamMedium
			b.TextSize = 12
			b.TextColor3 = Color3.fromRGB(240, 236, 226)
			b.BackgroundColor3 = Color3.fromRGB(40, 44, 54)
			b.BorderSizePixel = 0
			b.LayoutOrder = i
			b.Parent = g
			b.Activated:Connect(function()
				onClick(i, item)
			end)
		end
	end
	label("UI LAB  (` to hide)", 20)
	label("RESOLUTION", 16)
	local resNames = {}
	for _, r in UILab.Resolutions do
		table.insert(resNames, r[1])
	end
	grid(resNames, function(i)
		UILab.setResolution(UILab.Resolutions[i][2])
	end)
	label("SCREEN", 16)
	grid(UILab.Screens, function(_, screen)
		task.spawn(UILab.show, screen)
	end)
	label("QA", 16)
	grid({ "RUN CHECKS", "RUN ALL", "NATIVE" }, function(i)
		if i == 1 then
			local w = ui.Current
			local issues = UILab.check(w)
			local text = UIChecks.format(issues)
			print("[UI LAB] " .. Responsive.Width .. "x" .. Responsive.Height .. " " .. tostring(w or "HUD") .. ":\n" .. text)
			if output then
				output.Text = (#issues == 0 and "PASS" or (#issues .. " issue(s) - see Output")) .. "\n" .. string.sub(text, 1, 400)
			end
		elseif i == 2 then
			task.spawn(function()
				if output then
					output.Text = "Running all resolutions x screens..."
				end
				local failures = UILab.runAll()
				if output then
					output.Text = failures == 0 and "ALL PASS" or (failures .. " issue(s) - see Output")
				end
			end)
		else
			UILab.setResolution(nil)
		end
	end)
	label("TEST (Studio only)", 16)
	grid({ "+$1M", "ALL 30 DRAGONS", "FILL EGGS", "HATCH NOW", "WILD EGG", "BOND MAX", "MEGA BANNER", "RACE TIME", "CHAMPION" }, function(i)
		local actions = { "Cash", "Dragons", "Eggs", "HatchNow", "WildEgg", "BondMax", "Banner", "RaceTime", "RaceChampion" }
		task.spawn(function()
			local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
			local res = Net.request("Dev", actions[i], {})
			ui.HandleResult(res, res.ok and ({ "+$1,000,000", "+5 dragons", "Egg bag filled", "Eggs are ready to hatch", "A wild egg appeared!", "Bond level 50 - try Q / E / Z", "Banner sent", "Race time set - see the boards on the Race Island", "You are the race champion!" })[i] or nil)
		end)
	end)
	output = label("", 120)
	output.TextWrapped = true
	output.TextYAlignment = Enum.TextYAlignment.Top
	output.Font = Enum.Font.Code
	output.TextSize = 12
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

function UILab.Init(uiController, reg)
	ui = uiController
	registry = reg
	if not enabled() then
		return
	end
	panel = buildPanel()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Backquote and panel then
			panel.Enabled = not panel.Enabled
		end
	end)
end

return UILab

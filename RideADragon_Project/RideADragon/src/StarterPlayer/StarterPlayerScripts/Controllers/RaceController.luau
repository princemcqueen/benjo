--[[
	RaceController
	The client side of the Sky Circuit on the Race Island (RaceService decides everything, this
	only draws it and flies the standard dragon):

	  lobby      a panel under the cash row: who is in, a timer, START NOW (when alone) / LEAVE
	  countdown  you stand on your pad, the camera looks north, a big 3 - 2 - 1 - GO
	  racing     timer from the server's start time, gate / lap counter, place, a marker on the
	             next ring (an arrow at the screen edge while it is out of view), the next ring
	             glows; flying through a cyan boost ring gives a dash
	  finish     card with place, time, personal best, rewards and everybody's results

	Net signals (RaceService): RaceLobby, RaceCount, RaceGo, RaceProgress, RacePos, RaceFinish, RaceEnd
	Net event to the server: RaceBoost { Index } (so the speed check allows the dash)
	Player attributes read: RaceState, RaceActive, RacePass, RaceStart
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Create = require(UI:WaitForChild("Create"))
local Kit = require(UI:WaitForChild("Kit"))
local Icons = require(UI:WaitForChild("Icons"))

local C = Theme.Colors
local H = Theme.Hud
local LocalPlayer = Players.LocalPlayer

local RaceController = {}

local BIND_NAME = "RAD_RaceMarker"
local GOLD = Color3.fromRGB(255, 205, 60)
local SILVER = Color3.fromRGB(205, 214, 224)
local BRONZE = Color3.fromRGB(222, 140, 80)
local COUNT_COLORS = {
	[3] = Color3.fromRGB(255, 96, 84),
	[2] = Color3.fromRGB(255, 160, 60),
	[1] = Color3.fromRGB(255, 220, 70),
}
local GO_COLOR = Color3.fromRGB(110, 235, 120)

local registry
local layer: Frame? = nil
local ui: { [string]: any } = {}

local phase = "None" -- None | Lobby | Countdown | Running | Finished
local lobby: any = nil
local goTime = 0
local pass = 0
local place, of = 0, 0
local standing = false
local boostUsed: { [number]: number } = {}
local lastPos: Vector3? = nil
local clockT = 0
local highlight: Highlight? = nil
local highlightGate = -1
local islandModel: Instance? = nil
local finishToken = 0
local lastNumber = 0
local bound = false

-- ============================================================== helpers
local function short(): number
	return math.min(Responsive.Width, Responsive.Height)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function ordinal(n: number): string
	local last = n % 10
	local teen = n % 100 >= 11 and n % 100 <= 13
	if not teen and last == 1 then
		return n .. "ST"
	elseif not teen and last == 2 then
		return n .. "ND"
	elseif not teen and last == 3 then
		return n .. "RD"
	end
	return n .. "TH"
end

local function placeColor(n: number): Color3
	if n == 1 then
		return GOLD
	elseif n == 2 then
		return SILVER
	elseif n == 3 then
		return BRONZE
	end
	return C.Text
end

-- The same medals, darker, for the white HUD panel.
local function hudPlaceColor(n: number): Color3
	if n == 1 then
		return Color3.fromRGB(214, 146, 0)
	elseif n == 2 then
		return Color3.fromRGB(96, 108, 130)
	elseif n == 3 then
		return Color3.fromRGB(176, 96, 38)
	end
	return H.Text
end

-- Scaled hero texts need a bigger ceiling than their role's size.
local function limit(label: TextLabel, maxPx: number)
	local tsc = label:FindFirstChildOfClass("UITextSizeConstraint")
	if tsc then
		Responsive.bind(tsc, "MaxTextSize", function(R)
			return R.px(maxPx)
		end)
	end
end

local function hudPanel(name: string, parent: Instance): Frame
	local f = Create("Frame", {
		Name = name,
		BackgroundColor3 = H.Panel,
		BackgroundTransparency = H.Transparency,
		BorderSizePixel = 0,
	})
	Kit.corner(f, 16)
	Kit.stroke(f, H.Stroke, Theme.Stroke.Normal, H.StrokeTransparency)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), H.Shade), Parent = f })
	f.Parent = parent
	return f :: Frame
end

local function notify(kind: string, text: string)
	local uic = registry and registry.UIController
	if uic then
		uic.Notify(kind, text)
	end
end

local function sound(key: string)
	local audio = registry and registry.AudioController
	if audio then
		audio.playUI(key)
	end
end

local function dragon()
	return registry and registry.DragonController
end

-- ============================================================== layer
local function makeLayer(): Frame
	local gui = Create("ScreenGui", {
		Name = "GameRace",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Theme.Layers.Hud + 2,
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
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	return root
end

-- ============================================================== widgets
local function buildLobby(parent: Instance)
	local panel = hudPanel("Lobby", parent)
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(0.5, 0)
	ui.Lobby = panel
	local title = Kit.text({ Name = "Title", Text = "SKY CIRCUIT", Role = "Heading", Scaled = true, Color = H.Text, Position = UDim2.fromScale(0.05, 0.05), Size = UDim2.fromScale(0.55, 0.14), Parent = panel })
	limit(title, 30)
	ui.LobbyTimer = Kit.text({ Name = "Timer", Text = "", Role = "Heading", Scaled = true, Font = Theme.Fonts.Number, Color = C.AccentDeep, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.6, 0.04), Size = UDim2.fromScale(0.35, 0.16), Parent = panel })
	limit(ui.LobbyTimer, 38)
	ui.LobbySub = Kit.text({ Name = "Sub", Text = "", Role = "Caption", Scaled = true, Color = H.TextMuted, Position = UDim2.fromScale(0.05, 0.21), Size = UDim2.fromScale(0.9, 0.08), Parent = panel })
	limit(ui.LobbySub, 17)
	ui.LobbyNames = {}
	for i = 1, 2 do
		local names = Kit.text({ Name = "Names" .. i, Text = "", Role = "Label", Scaled = true, Color = H.Text, YAlign = Enum.TextYAlignment.Top, Wrapped = true, Position = UDim2.fromScale(0.05 + (i - 1) * 0.47, 0.32), Size = UDim2.fromScale(0.45, 0.38), Parent = panel })
		names.RichText = true
		names.LineHeight = 1.1
		limit(names, 24)
		ui.LobbyNames[i] = names
	end
	local start = Kit.button({ Name = "StartNow", Text = "START NOW", Style = "Success", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0.05, 0.94), Size = UDim2.fromScale(0.43, 0.2), Parent = panel })
	local leave = Kit.button({ Name = "Leave", Text = "LEAVE", Style = "Danger", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(0.95, 0.94), Size = UDim2.fromScale(0.43, 0.2), Parent = panel })
	ui.StartNow = start
	ui.LeaveButton = leave
	start.Activated:Connect(function()
		task.spawn(function()
			local res = Net.request("Race", "StartNow")
			registry.UIController.HandleResult(res)
		end)
	end)
	leave.Activated:Connect(function()
		task.spawn(function()
			local res = Net.request("Race", "Leave")
			if registry.UIController.HandleResult(res) then
				RaceController.hideLobby()
			end
		end)
	end)
end

local function buildCount(parent: Instance)
	local label = Kit.text({
		Name = "Countdown",
		Text = "",
		Role = "Display",
		Scaled = true,
		MaxRole = "Display",
		Font = Enum.Font.GothamBlack,
		Color = GO_COLOR,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromScale(0.5, 0.3),
		ZIndex = 5,
		Parent = parent,
	})
	label.Visible = false
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 6
	stroke.Color = Color3.fromRGB(26, 20, 40)
	stroke.Parent = label
	local scale = Create("UIScale", { Parent = label })
	ui.Count = label
	ui.CountScale = scale
	ui.CountStroke = stroke
	limit(label, 300)
end

local function buildHud(parent: Instance)
	local panel = hudPanel("RaceHud", parent)
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(0.5, 0)
	ui.Hud = panel
	ui.Timer = Kit.text({ Name = "Timer", Text = "0:00.000", Role = "Display", Scaled = true, Font = Theme.Fonts.Number, Color = H.Text, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.28, 0.04), Size = UDim2.fromScale(0.44, 0.5), Parent = panel })
	ui.Gate = Kit.text({ Name = "Gate", Text = "GATE 1/26", Role = "Label", Scaled = true, Color = H.Text, Position = UDim2.fromScale(0.04, 0.12), Size = UDim2.fromScale(0.26, 0.3), Parent = panel })
	ui.Lap = Kit.text({ Name = "Lap", Text = "LAP 1/2", Role = "Label", Scaled = true, Color = C.AccentDeep, Position = UDim2.fromScale(0.04, 0.42), Size = UDim2.fromScale(0.26, 0.26), Parent = panel })
	ui.Place = Kit.text({ Name = "Place", Text = "", Role = "Title", Scaled = true, Font = Theme.Fonts.Number, Color = H.Text, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.7, 0.06), Size = UDim2.fromScale(0.27, 0.42), Parent = panel })
	ui.PlaceOf = Kit.text({ Name = "PlaceOf", Text = "", Role = "Micro", Scaled = true, Color = H.TextMuted, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.7, 0.46), Size = UDim2.fromScale(0.27, 0.2), Parent = panel })
	ui.Bar = Kit.progress({ Name = "Progress", Color = C.Accent, Color2 = C.GoldBright, Track = H.Track, Position = UDim2.fromScale(0.04, 0.74), Size = UDim2.fromScale(0.92, 0.1), Parent = panel })
	ui.Best = Kit.text({ Name = "Best", Text = "", Role = "Micro", Scaled = true, Color = H.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.28, 0.5), Size = UDim2.fromScale(0.44, 0.2), Parent = panel })
	limit(ui.Timer, 52)
	limit(ui.Gate, 18)
	limit(ui.Lap, 18)
	limit(ui.Place, 34)
	limit(ui.PlaceOf, 14)
	limit(ui.Best, 15)
end

local function buildMarker(parent: Instance)
	local holder = Kit.frame({ Name = "GateMarker", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(80, 80), Visible = false, ZIndex = 3, Parent = parent })
	ui.Marker = holder
	-- ring (on screen)
	local ring = Kit.frame({ Name = "Ring", BackgroundTransparency = 0.88, BackgroundColor3 = GOLD, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(0.8, 0.8), Parent = holder })
	Kit.corner(ring, 999)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 5
	stroke.Color = Color3.fromRGB(255, 214, 80)
	stroke.Parent = ring
	local inner = Kit.frame({ Name = "Inner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.86), Parent = ring })
	Kit.corner(inner, 999)
	local innerStroke = Instance.new("UIStroke")
	innerStroke.Thickness = 2
	innerStroke.Color = Color3.fromRGB(255, 255, 255)
	innerStroke.Parent = inner
	ui.MarkerRing = ring
	ui.MarkerNumber = Kit.text({ Name = "Number", Text = "1", Role = "Heading", Scaled = true, Font = Theme.Fonts.Number, Color = Color3.fromRGB(255, 255, 255), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = ring })
	limit(ui.MarkerNumber, 34)
	local numberStroke = Instance.new("UIStroke")
	numberStroke.Thickness = 2
	numberStroke.Color = Color3.fromRGB(26, 20, 40)
	numberStroke.Parent = ui.MarkerNumber
	-- arrow (gate out of view): a chevron turned towards it
	local arrow = Kit.frame({ Name = "Arrow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(0.8, 0.8), Visible = false, Parent = holder })
	local chevron = Icons.make("ChevronUp", { Color = Color3.fromRGB(255, 255, 255), Accent = GOLD, Ink = Color3.fromRGB(26, 20, 40) })
	chevron.Parent = arrow
	ui.MarkerArrow = arrow
	ui.MarkerDistance = Kit.text({ Name = "Distance", Text = "", Role = "Label", Scaled = true, Color = Color3.fromRGB(255, 255, 255), XAlign = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.86), Size = UDim2.fromScale(1.2, 0.28), Parent = holder })
	limit(ui.MarkerDistance, 22)
	local distanceStroke = Instance.new("UIStroke")
	distanceStroke.Thickness = 2
	distanceStroke.Color = Color3.fromRGB(26, 20, 40)
	distanceStroke.Parent = ui.MarkerDistance
end

local function buildBoostFlash(parent: Instance)
	local label = Kit.text({
		Name = "BoostFlash",
		Text = "BOOST!",
		Role = "Title",
		Scaled = true,
		Font = Enum.Font.GothamBlack,
		Color = Color3.fromRGB(80, 235, 255),
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromScale(0.4, 0.1),
		ZIndex = 4,
		Parent = parent,
	})
	label.Visible = false
	limit(label, 54)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(10, 40, 70)
	stroke.Parent = label
	ui.BoostFlash = label
end

local function buildFinish(parent: Instance)
	local card = Kit.surface({ Name = "RaceFinish", Color = C.Panel, Transparency = 0.04, StrokeColor = GOLD, StrokeTransparency = 0.1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(400, 400), Parent = parent })
	card.Visible = false
	card.ZIndex = 6
	ui.Finish = card
	ui.FinishScale = Create("UIScale", { Parent = card })
	ui.FinishCaption = Kit.text({ Name = "Caption", Text = "FINISHED", Role = "Label", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.1, 0.03), Size = UDim2.fromScale(0.8, 0.06), Parent = card })
	ui.FinishPlace = Kit.text({ Name = "Place", Text = "1ST", Role = "Display", Scaled = true, Font = Enum.Font.GothamBlack, Color = GOLD, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.1, 0.09), Size = UDim2.fromScale(0.8, 0.2), Parent = card })
	ui.FinishTime = Kit.text({ Name = "Time", Text = "0:00.000", Role = "Title", Scaled = true, Font = Theme.Fonts.Number, Color = C.Text, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.1, 0.3), Size = UDim2.fromScale(0.8, 0.11), Parent = card })
	ui.FinishBest = Kit.text({ Name = "Best", Text = "", Role = "Label", Scaled = true, Color = C.TextMuted, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.1, 0.42), Size = UDim2.fromScale(0.8, 0.06), Parent = card })
	ui.FinishRewards = Kit.text({ Name = "Rewards", Text = "", Role = "Label", Scaled = true, Color = C.Success, XAlign = Enum.TextXAlignment.Center, YAlign = Enum.TextYAlignment.Top, Wrapped = true, Position = UDim2.fromScale(0.08, 0.49), Size = UDim2.fromScale(0.84, 0.12), Parent = card })
	ui.FinishResults = Kit.text({ Name = "Results", Text = "", Role = "Label", Scaled = true, Color = C.Text, YAlign = Enum.TextYAlignment.Top, Wrapped = true, Position = UDim2.fromScale(0.1, 0.62), Size = UDim2.fromScale(0.8, 0.2), Parent = card })
	ui.FinishResults.RichText = true
	limit(ui.FinishCaption, 20)
	limit(ui.FinishPlace, 130)
	limit(ui.FinishTime, 58)
	limit(ui.FinishBest, 24)
	limit(ui.FinishRewards, 24)
	limit(ui.FinishResults, 22)
	local again = Kit.button({ Name = "Again", Text = "RACE AGAIN", Style = "Primary", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0.07, 0.95), Size = UDim2.fromScale(0.5, 0.11), Parent = card })
	local close = Kit.button({ Name = "Close", Text = "OK", Style = "Secondary", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(0.93, 0.95), Size = UDim2.fromScale(0.3, 0.11), Parent = card })
	ui.Again = again
	again.Activated:Connect(function()
		RaceController.raceAgain()
	end)
	close.Activated:Connect(function()
		RaceController.hideFinish()
	end)
end

local function build()
	if layer then
		return
	end
	layer = makeLayer()
	buildLobby(layer)
	buildCount(layer)
	buildHud(layer)
	buildMarker(layer)
	buildBoostFlash(layer)
	buildFinish(layer)
	RaceController.layout()
end

-- ============================================================== layout
function RaceController.layout()
	if not layer then
		return
	end
	local R = Responsive
	local S = short()
	local phone = R.Device == "Phone"
	local top
	if phone then
		top = R.Portrait and (R.TopInset + math.floor(S * 0.3)) or math.floor(S * 0.19)
	else
		top = R.TopInset + math.floor(S * 0.13)
	end
	local hudW = phone and (R.Portrait and R.Width * 0.9 or S * 0.82) or S * 0.62
	local hudH = phone and (R.Portrait and hudW * 0.27 or S * 0.2) or S * 0.135
	ui.Hud.Position = UDim2.new(0.5, 0, 0, top)
	ui.Hud.Size = UDim2.fromOffset(math.floor(hudW), math.floor(hudH))
	local lobbyW = phone and (R.Portrait and R.Width * 0.9 or S * 0.95) or S * 0.5
	local lobbyH = phone and (R.Portrait and lobbyW * 0.62 or S * 0.66) or S * 0.34
	ui.Lobby.Position = UDim2.new(0.5, 0, 0, top)
	ui.Lobby.Size = UDim2.fromOffset(math.floor(lobbyW), math.floor(lobbyH))
	local finishH = phone and (R.Portrait and R.Width * 1.1 or S * 0.9) or S * 0.72
	local finishW = phone and (R.Portrait and R.Width * 0.9 or S * 1.0) or S * 0.62
	ui.Finish.Size = UDim2.fromOffset(math.floor(finishW), math.floor(finishH))
	local marker = phone and S * 0.17 or S * 0.1
	ui.Marker.Size = UDim2.fromOffset(math.floor(marker), math.floor(marker))
end

-- ============================================================== visibility
local function show(widget: string, on: boolean)
	local w = ui[widget]
	if w then
		w.Visible = on
	end
end

function RaceController.hideLobby()
	show("Lobby", false)
	if phase == "Lobby" then
		phase = "None"
	end
end

function RaceController.hideFinish()
	finishToken += 1
	if ui.Finish and ui.Finish.Visible then
		local s = ui.FinishScale
		local tw = TweenService:Create(s, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0 })
		tw.Completed:Connect(function()
			ui.Finish.Visible = false
		end)
		tw:Play()
	end
	if phase == "Finished" then
		phase = "None"
	end
end

local function stopTracking()
	if bound then
		bound = false
		pcall(function()
			RunService:UnbindFromRenderStep(BIND_NAME)
		end)
	end
	show("Marker", false)
	if highlight then
		highlight.Adornee = nil
		highlight.Parent = nil
	end
	highlightGate = -1
end

local function hideRaceUi()
	show("Hud", false)
	show("Count", false)
	stopTracking()
end

-- ============================================================== lobby
local function refreshLobby()
	if not lobby or not ui.Lobby then
		return
	end
	local columns = { {}, {} }
	for i, r in lobby.Racers or {} do
		table.insert(columns[i <= 4 and 1 or 2], string.format('<font color="rgb(246,144,44)">%d</font>  %s', i, r.Name))
	end
	ui.LobbyNames[1].Text = table.concat(columns[1], "\n")
	ui.LobbyNames[2].Text = table.concat(columns[2], "\n")
	local count = #(lobby.Racers or {})
	if lobby.State == "Lobby" then
		local left = math.max(0, (lobby.Left or 0) - (os.clock() - (lobby.Received or os.clock())))
		ui.LobbyTimer.Text = string.format("%ds", math.ceil(left))
		ui.LobbySub.Text = string.format("%d lap%s, %d gates a lap - same standard dragon for everybody", lobby.Laps or RaceConfig.Laps, (lobby.Laps or RaceConfig.Laps) == 1 and "" or "s", lobby.Gates or RaceConfig.GateCount)
		ui.StartNow.Instance.Visible = count == 1
	else
		ui.LobbyTimer.Text = ""
		ui.LobbySub.Text = "Get ready!"
		ui.StartNow.Instance.Visible = false
	end
end

local function onLobby(data)
	build()
	lobby = data
	lobby.Received = os.clock()
	if data.State == "Lobby" then
		phase = "Lobby"
		show("Lobby", true)
		show("Hud", false)
		refreshLobby()
	elseif data.State == "Countdown" then
		phase = "Countdown"
		show("Lobby", false)
		standing = false
		pass = 0
		boostUsed = {}
		lastPos = nil
		lastNumber = 0
		place, of = 0, 0
		-- the countdown screen: timer panel shows already, zeroed
		show("Hud", true)
		ui.Timer.Text = "0:00.000"
		ui.Gate.Text = string.format("GATE 1/%d", RaceConfig.GateCount)
		ui.Lap.Text = string.format("LAP 1/%d", RaceConfig.Laps)
		ui.Place.Text = ""
		ui.PlaceOf.Text = ""
		ui.Bar:SetValue(0)
		local data = registry.DataController and registry.DataController.all()
		local best = data and data.Race and tonumber(data.Race.Best) or 0
		ui.Best.Text = best > 0 and ("BEST " .. RaceConfig.formatTime(best)) or ""
		RaceController.hideFinish()
	end
end

-- ============================================================== countdown
local function popCount(text: string, color: Color3)
	local label = ui.Count
	if not label then
		return
	end
	label.Text = text
	label.TextColor3 = color
	label.TextTransparency = 0
	ui.CountStroke.Transparency = 0
	label.Visible = true
	ui.CountScale.Scale = 1.7
	TweenService:Create(ui.CountScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function fadeCount(delay: number)
	local token = lastNumber
	task.delay(delay, function()
		if ui.Count and lastNumber == token and ui.Count.Visible then
			local tw = TweenService:Create(ui.Count, TweenInfo.new(0.4), { TextTransparency = 1 })
			TweenService:Create(ui.CountStroke, TweenInfo.new(0.4), { Transparency = 1 }):Play()
			tw.Completed:Connect(function()
				if lastNumber == token then
					ui.Count.Visible = false
				end
			end)
			tw:Play()
		end
	end)
end

local function faceNorth()
	if standing then
		return
	end
	local dc = dragon()
	if dc and dc.isRiding() then
		standing = true
		dc.stand(0)
		local cam = registry.CameraController
		if cam and cam.setView then
			cam.setView(0, -0.2)
		end
	end
end

local function onCount(data)
	build()
	local n = tonumber(data.N) or 0
	lastNumber = n
	faceNorth()
	popCount(tostring(n), COUNT_COLORS[n] or C.Text)
	sound("RaceCount")
	fadeCount(0.85)
end

-- ============================================================== gate marker
local function ensureIsland(): Instance?
	if islandModel and islandModel.Parent then
		return islandModel
	end
	islandModel = Workspace:FindFirstChild("RaceIsland", true)
	return islandModel
end

local function highlightNext(index: number)
	if index == highlightGate then
		return
	end
	highlightGate = index
	local island = ensureIsland()
	local model = island and island:FindFirstChild("Gate_" .. index, true)
	if not model then
		if highlight then
			highlight.Adornee = nil
		end
		return
	end
	if not highlight then
		local h = Instance.new("Highlight")
		h.Name = "RaceNextGate"
		h.FillColor = Color3.fromRGB(255, 255, 255)
		h.FillTransparency = 0.6
		h.OutlineColor = Color3.fromRGB(255, 220, 90)
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight = h
	end
	local h = highlight :: Highlight
	h.Adornee = model
	h.Parent = model
end

local function dragonPosition(): Vector3?
	local m = dragon() and dragon().getModel()
	local root = m and m:FindFirstChild("Root") :: BasePart?
	if root then
		return root.Position
	end
	local camera = Workspace.CurrentCamera
	return camera and camera.CFrame.Position or nil
end

-- Screen position of the next gate: on screen = a ring on the gate, off screen = an arrow on the
-- edge pointing at it.
local function updateMarker(position: Vector3)
	local camera = Workspace.CurrentCamera
	if not camera or not layer or pass < 1 then
		return
	end
	local gate, index = RaceConfig.gateForPass(pass)
	local target = RaceConfig.toWorld(gate.Position)
	local abs = layer.AbsoluteSize
	local origin = layer.AbsolutePosition
	if abs.X < 1 or abs.Y < 1 then
		return
	end
	local vp = camera:WorldToViewportPoint(target)
	local x = vp.X - origin.X
	local y = vp.Y - origin.Y
	local behind = vp.Z < 0
	local marginX, marginTop, marginBottom = abs.X * 0.07, abs.Y * 0.26, abs.Y * 0.1
	local onScreen = not behind and x >= marginX and x <= abs.X - marginX and y >= marginTop and y <= abs.Y - marginBottom
	local distance = (target - position).Magnitude
	ui.MarkerDistance.Text = string.format("%d m", math.floor(distance / 3.57 + 0.5)) -- studs -> metres (1 stud ~ 0.28 m)
	ui.MarkerNumber.Text = index == 0 and "S/F" or tostring(index)
	ui.Marker.Visible = true
	if onScreen then
		ui.MarkerRing.Visible = true
		ui.MarkerArrow.Visible = false
		local pulse = 1 + 0.07 * math.sin(clockT * 7)
		ui.MarkerRing.Size = UDim2.fromScale(0.8 * pulse, 0.8 * pulse)
		-- bigger when far (so it is easy to find), smaller when close (so it does not block the ring)
		local near = math.clamp(distance / 400, 0.35, 1)
		ui.Marker.Position = UDim2.fromOffset(x, y)
		ui.MarkerRing.BackgroundTransparency = 0.82 + (1 - near) * 0.12
		ui.Marker.Visible = distance > 30
	else
		ui.MarkerRing.Visible = false
		ui.MarkerArrow.Visible = true
		-- direction from the screen centre
		local cx, cy = abs.X / 2, abs.Y / 2
		local dx, dy = x - cx, y - cy
		if behind then
			dx, dy = -dx, -dy
			if math.abs(dx) < 1 and math.abs(dy) < 1 then
				dy = abs.Y
			end
		end
		local left, right, topEdge, bottomEdge = marginX, abs.X - marginX, marginTop, abs.Y - marginBottom
		local scaleX = dx ~= 0 and math.min((dx > 0 and (right - cx) or (left - cx)) / dx, math.huge) or math.huge
		local scaleY = dy ~= 0 and math.min((dy > 0 and (bottomEdge - cy) or (topEdge - cy)) / dy, math.huge) or math.huge
		local k = math.min(math.abs(scaleX), math.abs(scaleY))
		local ex, ey = cx + dx * k, cy + dy * k
		ui.Marker.Position = UDim2.fromOffset(ex, ey)
		ui.MarkerArrow.Rotation = math.deg(math.atan2(dy, dx)) + 90
	end
end

local function flashBoost()
	local label = ui.BoostFlash
	if not label then
		return
	end
	label.Visible = true
	label.TextTransparency = 0
	label.Position = UDim2.fromScale(0.5, 0.64)
	TweenService:Create(label, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.56), TextTransparency = 1 }):Play()
end

local function triggerBoost(index: number)
	local dc = dragon()
	if not dc or not dc.dash(RaceConfig.Boost.Duration, RaceConfig.Boost.Multiplier) then
		return
	end
	flashBoost()
	sound("RaceBoost")
	Net.fire("RaceBoost", { Index = index })
end

local function checkBoosts(position: Vector3)
	local last = lastPos
	lastPos = position
	if not last then
		return
	end
	for i, b in RaceConfig.Boosts do
		local center = RaceConfig.toWorld(b.Position)
		if (position - center).Magnitude < 170 and clockT - (boostUsed[i] or -10) > 2 then
			local normal = b.Direction
			local s0 = (last - center):Dot(normal)
			local s1 = (position - center):Dot(normal)
			if s0 <= 0 and s1 > 0 then
				local f = (0 - s0) / (s1 - s0)
				local hit = last:Lerp(position, f)
				if (hit - center).Magnitude <= RaceConfig.Boost.Radius + 8 then
					boostUsed[i] = clockT
					triggerBoost(i)
				end
			end
		end
	end
end

-- ============================================================== racing frame
local function step(dt: number)
	clockT += dt
	if phase ~= "Running" then
		return
	end
	local elapsed = math.max(0, serverNow() - goTime)
	ui.Timer.Text = RaceConfig.formatTime(elapsed * 1000)
	local position = dragonPosition()
	if position then
		updateMarker(position)
		checkBoosts(position)
	end
end

local function bind()
	if bound then
		return
	end
	bound = true
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 2, step)
end

local function setPass(p: number)
	pass = p
	local per = RaceConfig.GateCount
	local gateNumber = (p - 1) % per + 1
	ui.Gate.Text = string.format("GATE %d/%d", gateNumber, per)
	ui.Lap.Text = string.format("LAP %d/%d", RaceConfig.lapOfPass(p), RaceConfig.Laps)
	ui.Bar:SetValue((p - 1) / RaceConfig.totalPasses(), true)
	local _, index = RaceConfig.gateForPass(p)
	highlightNext(index)
end

local function onGo(data)
	build()
	phase = "Running"
	goTime = tonumber(data.Start) or serverNow()
	show("Lobby", false)
	show("Hud", true)
	lastNumber += 1
	popCount("GO!", GO_COLOR)
	fadeCount(0.7)
	sound("RaceGo")
	faceNorth()
	local dc = dragon()
	if dc then
		dc.launch(RaceConfig.Standard.Cruise * 0.5)
	end
	local cam = registry.CameraController
	if cam then
		cam.shake(0.25)
	end
	setPass(tonumber(LocalPlayer:GetAttribute("RacePass")) or 1)
	lastPos = nil
	bind()
end

local function onProgress(data)
	if phase ~= "Running" then
		return
	end
	local p = tonumber(data.Pass) or pass
	setPass(p)
	sound("RaceGate")
end

local function onPosition(data)
	place = tonumber(data.Place) or 0
	of = tonumber(data.Of) or 0
	if ui.Place then
		if of > 1 and place > 0 then
			ui.Place.Text = ordinal(place)
			ui.Place.TextColor3 = hudPlaceColor(place)
			ui.PlaceOf.Text = string.format("OF %d RACERS", of)
		else
			ui.Place.Text = ""
			ui.PlaceOf.Text = ""
		end
	end
end

-- ============================================================== finish
local function rewardText(rewards): string
	local lines = {}
	for _, r in rewards or {} do
		local parts = {}
		if (r.Cash or 0) > 0 then
			table.insert(parts, "+$" .. Format.abbreviate(r.Cash))
		end
		if (r.XP or 0) > 0 then
			table.insert(parts, "+" .. r.XP .. " XP")
		end
		table.insert(lines, string.format("%s   %s", r.Label or "", table.concat(parts, "   ")))
	end
	return table.concat(lines, "\n")
end

local function resultsText(list): string
	local lines = {}
	for _, r in list or {} do
		if (r.Place or 0) > 0 then
			table.insert(lines, string.format('<font color="rgb(%d,%d,%d)">%s</font>   %s   %s', math.floor(placeColor(r.Place).R * 255), math.floor(placeColor(r.Place).G * 255), math.floor(placeColor(r.Place).B * 255), ordinal(r.Place), r.Name, RaceConfig.formatTime(r.Ms)))
		else
			table.insert(lines, string.format('<font color="rgb(150,150,150)">DNF</font>   %s   %s', r.Name, r.Reason or ""))
		end
	end
	return table.concat(lines, "\n")
end

local function showFinish()
	local card = ui.Finish
	if not card then
		return
	end
	finishToken += 1
	local token = finishToken
	card.Visible = true
	ui.FinishScale.Scale = 0.6
	TweenService:Create(ui.FinishScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(22, function()
		if finishToken == token then
			RaceController.hideFinish()
		end
	end)
end

local function onFinish(data)
	build()
	phase = "Finished"
	hideRaceUi()
	local n = tonumber(data.Place) or 1
	local solo = (tonumber(data.Racers) or 1) <= 1
	ui.FinishCaption.Text = solo and "TIME TRIAL FINISHED" or "RACE FINISHED"
	ui.FinishPlace.Text = solo and "FINISH!" or ordinal(n)
	ui.FinishPlace.TextColor3 = solo and GOLD or placeColor(n)
	ui.FinishTime.Text = RaceConfig.formatTime(data.Ms or 0)
	local best = tonumber(data.Best) or 0
	if data.NewBest then
		ui.FinishBest.Text = "NEW PERSONAL BEST!"
		ui.FinishBest.TextColor3 = GOLD
	else
		ui.FinishBest.Text = best > 0 and ("BEST  " .. RaceConfig.formatTime(best)) or ""
		ui.FinishBest.TextColor3 = C.TextMuted
	end
	if data.NewMonthBest and not data.NewBest then
		ui.FinishBest.Text = "NEW MONTHLY BEST  " .. RaceConfig.formatTime(tonumber(data.MonthBest) or 0)
		ui.FinishBest.TextColor3 = GOLD
	end
	ui.FinishRewards.Text = rewardText(data.Rewards)
	ui.FinishResults.Text = ""
	showFinish()
	sound("RaceFinish")
	local cam = registry.CameraController
	if cam then
		cam.shake(0.2)
	end
	local anim = registry.AnimationController
	if anim and anim.react then
		anim.react(n == 1 and "Rare" or "Egg", 0.2)
	end
end

local function onEnd(data)
	build()
	if data.Reason then
		-- disqualified / left / out of time: no result
		hideRaceUi()
		phase = "None"
		notify("warning", "RACE OVER - " .. tostring(data.Reason))
		return
	end
	hideRaceUi()
	if ui.Finish and ui.Finish.Visible and data.Results then
		ui.FinishResults.Text = resultsText(data.Results)
	elseif phase ~= "Finished" then
		phase = "None"
	end
end

-- ============================================================== public
function RaceController.raceAgain()
	task.spawn(function()
		local uic = registry.UIController
		local snap = Net.request("Race", "State")
		if snap.ok and not snap.data.OnIsland then
			local travel = Net.request("Travel", "To", { Place = "RaceIsland" })
			if not travel.ok then
				uic.HandleResult(travel)
				return
			end
			task.wait(1.2)
		end
		local res = Net.request("Race", "Join")
		if uic.HandleResult(res) then
			RaceController.hideFinish()
		end
	end)
end

-- Design previews (UILab): static pictures of the race screens, no server involved.
function RaceController.clear()
	if not layer then
		return
	end
	show("Lobby", false)
	show("Count", false)
	show("Hud", false)
	show("Marker", false)
	show("BoostFlash", false)
	if ui.Finish then
		ui.Finish.Visible = false
	end
	stopTracking()
	phase = "None"
end

function RaceController.preview(kind: string)
	build()
	RaceController.clear()
	local racers = { { Name = "Alice", UserId = 1 }, { Name = "PrinceMcQueen", UserId = 2 }, { Name = "N2RC1S", UserId = 3 } }
	if kind == "Lobby" then
		onLobby({ State = "Lobby", Left = 14, Laps = RaceConfig.Laps, Gates = RaceConfig.GateCount, Racers = racers })
	elseif kind == "Count" then
		onLobby({ State = "Countdown", Racers = racers })
		popCount("2", COUNT_COLORS[2])
	elseif kind == "Race" then
		show("Hud", true)
		phase = "Running"
		ui.Timer.Text = "0:42.318"
		ui.Gate.Text = string.format("GATE 9/%d", RaceConfig.GateCount)
		ui.Lap.Text = string.format("LAP 1/%d", RaceConfig.Laps)
		ui.Bar:SetValue(8 / RaceConfig.totalPasses())
		ui.Best.Text = "BEST 1:21.044"
		onPosition({ Place = 2, Of = 4 })
		ui.Marker.Visible = true
		ui.MarkerRing.Visible = true
		ui.MarkerArrow.Visible = false
		ui.MarkerNumber.Text = "9"
		ui.MarkerDistance.Text = "212 m"
		ui.Marker.Position = UDim2.fromScale(0.64, 0.46)
		ui.BoostFlash.Visible = true
		ui.BoostFlash.TextTransparency = 0.1
	elseif kind == "Finish" then
		onFinish({
			Place = 1,
			Racers = 4,
			Ms = 83456,
			NewBest = true,
			Best = 83456,
			MonthBest = 83456,
			Rewards = { { Label = "PLACE 1", Cash = 1250000, XP = 120 }, { Label = "NEW BEST", Cash = 200000, XP = 20 } },
		})
		onEnd({
			Racers = 4,
			Results = {
				{ Name = "Alice", Ms = 83456, Place = 1 },
				{ Name = "PrinceMcQueen", Ms = 85120, Place = 2 },
				{ Name = "N2RC1S", Ms = 91002, Place = 3 },
				{ Name = "Bob", Ms = 0, Place = 0, Reason = "You left the course." },
			},
		})
	end
end

function RaceController.phase(): string
	return phase
end

function RaceController.isRacing(): boolean
	return phase == "Countdown" or phase == "Running"
end

function RaceController.Init(reg)
	registry = reg
end

function RaceController.Start()
	build()
	Responsive.Changed:Connect(function()
		RaceController.layout()
	end)
	Net.onSignal("RaceLobby", onLobby)
	Net.onSignal("RaceCount", onCount)
	Net.onSignal("RaceGo", onGo)
	Net.onSignal("RaceProgress", onProgress)
	Net.onSignal("RacePos", onPosition)
	Net.onSignal("RaceFinish", onFinish)
	Net.onSignal("RaceEnd", onEnd)
	-- the lobby label counts down locally between the server's updates
	task.spawn(function()
		while true do
			task.wait(0.25)
			if phase == "Lobby" and ui.Lobby and ui.Lobby.Visible then
				pcall(refreshLobby)
			end
		end
	end)
	-- left the lobby / race for any reason: clean up
	LocalPlayer:GetAttributeChangedSignal("RaceState"):Connect(function()
		local state = LocalPlayer:GetAttribute("RaceState")
		if state == nil and (phase == "Lobby" or phase == "Countdown" or phase == "Running") then
			show("Lobby", false)
			hideRaceUi()
			phase = "None"
		end
	end)
end

return RaceController

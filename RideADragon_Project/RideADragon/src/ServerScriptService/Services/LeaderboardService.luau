--[[
	LeaderboardService
	Global top-10 boards in the hub plaza (server-built SurfaceGuis, so they
	replicate and stream like any other part).

	* Every WriteSeconds each player's values are written to one
	  OrderedDataStore per board (and once more when they leave).
	* Every RefreshSeconds the top entries are read back, merged with the
	  live values of everyone in this server (so the boards react at once),
	  and the board rows are updated.
	* Without DataStore access (Studio without API access, outages) the
	  boards simply rank the players in this server.
	* Also counts play time (data.Stats.PlayTime, seconds).
	* Hub boards stand on the plaza ring, Race boards (monthly race, fastest racers, arena warriors)
	  on the Race Island plaza. Race times are stored as scores (RaceConfig.timeScore) so that the
	  stores' "highest first" order means "fastest first".

	API: Top(boardId), TopNamed(boardId), TopOfStore(storeName, count), NameOf(userId),
	     WriteNow(player), RefreshNow(), ArrivalCFrame()
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local LeaderboardConfig = require(Configs:WaitForChild("LeaderboardConfig"))
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))

local LeaderboardService = {}

local Services
local Data
local stores: { [string]: OrderedDataStore } = {}
local storeFailed = false
local nameCache: { [number]: string } = {}
local boards: { [string]: { Rows: { any }, Status: TextLabel, Subtitle: TextLabel? } } = {}
local lastWrite: { [Player]: number } = {}
local tops: { [string]: { { UserId: number, Value: number } } } = {}
local globals: { [string]: { { UserId: number, Value: number } }? } = {} -- last read of the global tops
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

local V3 = Vector3.new
local FONT_TITLE = Enum.Font.GothamBlack
local FONT_BODY = Enum.Font.GothamBold
local WHITE = Color3.new(1, 1, 1)
local MEDALS = { Color3.fromRGB(255, 205, 60), Color3.fromRGB(205, 214, 224), Color3.fromRGB(222, 140, 80) }

-- ============================================================== values
local function valueOf(player: Player, stat: string): number
	local data = Data.Get(player)
	if not data then
		return 0
	end
	if stat == "Earned" then
		return tonumber(data.TotalEarned) or 0
	elseif stat == "Hatched" then
		return tonumber(data.Stats and data.Stats.Hatched) or 0
	elseif stat == "PlayTime" then
		return tonumber(data.Stats and data.Stats.PlayTime) or 0
	elseif stat == "Income" then
		local econ = Services.EconomyService
		return econ and econ.IncomeRate(player) or 0
	elseif stat == "DragonPower" or stat == "DragonLevel" then
		local best = 0
		for _, rec in data.Dragons do
			local v = stat == "DragonPower" and (tonumber(rec.IncomePerSecond) or 0) or (tonumber(rec.Level) or 0)
			if v > best then
				best = v
			end
		end
		return best
	elseif stat == "RaceBest" then
		local ms = tonumber(data.Race and data.Race.Best) or 0
		return ms > 0 and RaceConfig.timeScore(ms) or 0
	elseif stat == "RaceMonthly" then
		local race = data.Race
		local ms = (race and race.MonthKey == RaceConfig.monthKey()) and tonumber(race.MonthBest) or 0
		return ms > 0 and RaceConfig.timeScore(ms) or 0
	elseif stat == "ArenaKills" then
		return tonumber(data.Stats and data.Stats.ArenaKills) or 0
	end
	return 0
end
LeaderboardService.valueOf = valueOf

local function formatValue(fmt: string, v: number): string
	if fmt == "Cash" then
		return "$" .. Format.abbreviate(v)
	elseif fmt == "PerSecond" then
		return "$" .. Format.abbreviate(v) .. "/s"
	elseif fmt == "Time" then
		local h = math.floor(v / 3600)
		local m = math.floor(v % 3600 / 60)
		if h >= 24 then
			return string.format("%dd %dh", math.floor(h / 24), h % 24)
		elseif h > 0 then
			return string.format("%dh %02dm", h, m)
		end
		return string.format("%dm", m)
	elseif fmt == "Level" then
		return "LV " .. tostring(math.floor(v))
	elseif fmt == "RaceTime" then
		return RaceConfig.formatTime(RaceConfig.scoreTime(v))
	end
	return Format.abbreviate(v)
end
LeaderboardService.formatValue = formatValue

local function storeValue(v: number): number
	return math.clamp(math.floor(v), 0, 9e18)
end

local function nameFor(userId: number): string
	local online = Players:GetPlayerByUserId(userId)
	if online then
		nameCache[userId] = online.Name
		return online.Name
	end
	if nameCache[userId] then
		return nameCache[userId]
	end
	if userId <= 0 then
		return "Player" .. tostring(-userId)
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local result = ok and name or ("User" .. tostring(userId))
	nameCache[userId] = result
	return result
end

-- ============================================================== datastore
local function storeName(board): string
	local s = board.Store
	return type(s) == "function" and s() or s
end

local function storeByName(name: string): OrderedDataStore?
	if storeFailed then
		return nil
	end
	if stores[name] then
		return stores[name]
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok and store then
		stores[name] = store
		return store
	end
	storeFailed = true
	return nil
end

local function storeFor(board): OrderedDataStore?
	return storeByName(storeName(board))
end

local function writePlayer(player: Player)
	if storeFailed or player.UserId <= 0 or not Data.Get(player) then
		return
	end
	lastWrite[player] = os.clock()
	for _, board in LeaderboardConfig.Boards do
		local store = storeFor(board)
		if not store then
			return
		end
		local raw = valueOf(player, board.Stat)
		local ok = true
		if not (board.SkipZero and raw <= 0) then
			local value = storeValue(raw)
			ok = pcall(function()
				store:SetAsync(tostring(player.UserId), value)
			end)
		end
		if not ok then
			storeFailed = RunService:IsStudio() -- no API access in Studio: stop trying
			if storeFailed then
				return
			end
		end
	end
end

local function readTop(board): { { UserId: number, Value: number } }?
	local store = storeFor(board)
	if not store then
		return nil
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, LeaderboardConfig.TopCount):GetCurrentPage()
	end)
	if not ok or type(page) ~= "table" then
		if RunService:IsStudio() then
			storeFailed = true
		end
		return nil
	end
	local out = {}
	for _, entry in page do
		local id = tonumber(entry.key)
		if id then
			table.insert(out, { UserId = id, Value = tonumber(entry.value) or 0 })
		end
	end
	return out
end

-- Global entries + live values of the players in this server.
local function merged(board, global: { { UserId: number, Value: number } }?)
	local byId: { [number]: number } = {}
	for _, e in global or {} do
		byId[e.UserId] = e.Value
	end
	for _, player in Players:GetPlayers() do
		if Data.Get(player) then
			local v = valueOf(player, board.Stat)
			local id = player.UserId -- (Studio test players have negative ids)
			if v > (byId[id] or -1) then
				byId[id] = v
			end
		end
	end
	local list = {}
	for id, v in byId do
		if not board.SkipZero or v > 0 then
			table.insert(list, { UserId = id, Value = v })
		end
	end
	table.sort(list, function(a, b)
		if a.Value ~= b.Value then
			return a.Value > b.Value
		end
		return a.UserId < b.UserId
	end)
	while #list > LeaderboardConfig.TopCount do
		table.remove(list)
	end
	return list
end

-- ============================================================== boards (world)
local function part(props): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.CastShadow = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

local function label(props): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.TextColor3 = WHITE
	t.Font = FONT_BODY
	t.TextScaled = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	for k, v in props do
		(t :: any)[k] = v
	end
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(20, 24, 40)
	stroke.Transparency = 0.25
	stroke.Parent = t
	return t
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local W, H = 16, 21 -- screen size (studs)

local function buildBoard(parent: Instance, board, cf: CFrame)
	local model = Instance.new("Model")
	model.Name = "Leaderboard_" .. board.Id
	-- toy-brick frame: two posts, a base, a header block with studs
	local frameCol = Color3.fromRGB(58, 64, 92)
	for _, sx in { -1, 1 } do
		part({ Name = "Post", Size = V3(1.6, H + 6, 1.6), CFrame = cf * CFrame.new(sx * (W / 2 + 0.6), (H + 6) / 2, 0.4), Color = frameCol, Parent = model })
		part({ Name = "Foot", Size = V3(3.2, 1.2, 4), CFrame = cf * CFrame.new(sx * (W / 2 + 0.6), 0.6, 0.4), Color = board.Dark, Parent = model })
	end
	part({ Name = "Back", Size = V3(W + 1.2, H + 1.2, 0.6), CFrame = cf * CFrame.new(0, 4 + H / 2, 0.9), Color = frameCol, Parent = model })
	local header = part({ Name = "Header", Size = V3(W + 3.2, 3.2, 2.2), CFrame = cf * CFrame.new(0, 4 + H + 2.2, 0.4), Color = board.Color, Parent = model })
	for i = -3, 3 do
		local stud = part({ Name = "Stud", Shape = Enum.PartType.Cylinder, Size = V3(0.5, 1.1, 1.1), Color = board.Color, CanCollide = false, Parent = model })
		stud.CFrame = cf * CFrame.new(i * 2.4, 4 + H + 2.2 + 1.85, 0.4) * CFrame.Angles(0, 0, math.rad(90))
	end
	-- the screen
	local screen = part({
		Name = "Screen",
		Size = V3(W, H, 0.4),
		CFrame = cf * CFrame.new(0, 4 + H / 2, 0.4),
		Color = Color3.fromRGB(26, 30, 52),
		CanCollide = false,
		Parent = model,
	})
	local headerGui = Instance.new("SurfaceGui")
	headerGui.Name = "Title"
	headerGui.Face = Enum.NormalId.Front
	headerGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	headerGui.PixelsPerStud = 40
	headerGui.LightInfluence = 0
	headerGui.MaxDistance = 400
	headerGui.Adornee = header
	headerGui.Parent = header
	label({ Text = board.Title, Font = FONT_TITLE, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(0.94, 0.78), Position = UDim2.fromScale(0.03, 0.11), Parent = headerGui })

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.MaxDistance = 300
	gui.Adornee = screen
	gui.Parent = screen
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(26, 30, 52)
	bg.BorderSizePixel = 0
	bg.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.fromRGB(44, 50, 86), Color3.fromRGB(18, 20, 36))
	grad.Parent = bg
	local subtitle = label({ Text = string.upper(board.Subtitle), TextColor3 = board.Color, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(0.9, 0.055), Position = UDim2.fromScale(0.05, 0.02), Parent = bg })

	local rows = {}
	local top, rowH = 0.095, 0.083
	for i = 1, LeaderboardConfig.TopCount do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Position = UDim2.fromScale(0.03, top + (i - 1) * rowH)
		row.Size = UDim2.fromScale(0.94, rowH * 0.9)
		row.BackgroundColor3 = i <= 3 and MEDALS[i] or Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = i <= 3 and 0.72 or (i % 2 == 0 and 0.94 or 0.9)
		row.BorderSizePixel = 0
		row.Parent = bg
		corner(row, 0.25)
		local rank = Instance.new("Frame")
		rank.Size = UDim2.fromScale(0.11, 0.8)
		rank.Position = UDim2.fromScale(0.015, 0.1)
		rank.BackgroundColor3 = i <= 3 and MEDALS[i] or Color3.fromRGB(70, 78, 120)
		rank.BorderSizePixel = 0
		rank.Parent = row
		corner(rank, 0.5)
		label({ Text = tostring(i), Font = FONT_TITLE, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 0.8), Position = UDim2.fromScale(0, 0.1), Parent = rank })
		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		avatar.BackgroundColor3 = Color3.fromRGB(60, 66, 104)
		avatar.BorderSizePixel = 0
		avatar.Size = UDim2.fromScale(0.11, 0.86)
		avatar.Position = UDim2.fromScale(0.14, 0.07)
		avatar.Image = ""
		avatar.Parent = row
		corner(avatar, 0.5)
		local name = label({ Name = "PlayerName", Text = "---", Size = UDim2.fromScale(0.44, 0.62), Position = UDim2.fromScale(0.27, 0.19), Parent = row })
		local value = label({
			Name = "Value",
			Text = "",
			Font = FONT_TITLE,
			TextColor3 = i <= 3 and MEDALS[i] or board.Color,
			TextXAlignment = Enum.TextXAlignment.Right,
			Size = UDim2.fromScale(0.27, 0.62),
			Position = UDim2.fromScale(0.71, 0.19),
			Parent = row,
		})
		rows[i] = { Name = name, Value = value, Avatar = avatar }
	end
	local status = label({
		Name = "Status",
		Text = "Updating...",
		TextColor3 = Color3.fromRGB(160, 168, 200),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = FONT_BODY,
		Size = UDim2.fromScale(0.9, 0.04),
		Position = UDim2.fromScale(0.05, 0.94),
		Parent = bg,
	})
	model.PrimaryPart = screen
	model.Parent = parent
	boards[board.Id] = { Rows = rows, Status = status, Subtitle = subtitle }
	return model
end

local function groundAt(x: number, z: number): number
	local ground = Services.WorldService and Services.WorldService.Ground
	if ground then
		local ok, y = pcall(ground, x, z)
		if ok and type(y) == "number" then
			return y
		end
	end
	return WorldConfig.Hub.Height
end

local function buildAll()
	local world = Workspace:FindFirstChild("World")
	local folder = Instance.new("Folder")
	folder.Name = "Leaderboards"
	folder.Parent = world or Workspace
	local center = WorldConfig.Hub.Center
	local hubIndex = 0
	for _, board in LeaderboardConfig.Boards do
		if board.Where == "Race" then
			-- on the Race Island plaza, turned towards the spot where players arrive
			local arrival = RaceConfig.toWorld(RaceConfig.Arrival)
			for _, spot in RaceConfig.Boards do
				if spot.Id == board.Id then
					local at = RaceConfig.toWorld(spot.Position)
					buildBoard(folder, board, CFrame.lookAt(at, V3(arrival.X, at.Y, arrival.Z)))
				end
			end
		else
			hubIndex += 1
			local a = math.rad(LeaderboardConfig.Angles[hubIndex] or (180 + (hubIndex - 2.5) * 26))
			local x = center.X + math.sin(a) * LeaderboardConfig.Ring
			local z = center.Z - math.cos(a) * LeaderboardConfig.Ring
			local y = groundAt(x, z)
			-- front (-Z of the frame) faces the plaza centre
			local cf = CFrame.lookAt(V3(x, y, z), V3(center.X, y, center.Z))
			buildBoard(folder, board, cf)
		end
	end
end

-- Where the Teleport menu's "Spawn" puts the player (looking at the boards).
function LeaderboardService.ArrivalCFrame(): CFrame
	local c = WorldConfig.Hub.Center
	local a = LeaderboardConfig.Arrival
	local x, z = c.X + a.X, c.Z + a.Z
	local y = groundAt(x, z) + 3.4
	return CFrame.lookAt(V3(x, y, z), V3(x, y, z + 10))
end

-- ============================================================== refresh
local function render(board, list)
	local ui = boards[board.Id]
	if not ui then
		return
	end
	for i, rowUi in ui.Rows do
		local e = list[i]
		if e then
			rowUi.Name.Text = nameFor(e.UserId)
			rowUi.Value.Text = formatValue(board.Format, e.Value)
			rowUi.Avatar.Image = e.UserId > 0 and string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", e.UserId) or ""
		else
			rowUi.Name.Text = "---"
			rowUi.Value.Text = ""
			rowUi.Avatar.Image = ""
		end
	end
	ui.Status.Text = storeFailed and "Live ranking of this server" or "Global top 10  -  updates every minute"
	if board.Monthly and ui.Subtitle then
		local d = os.date("!*t")
		ui.Subtitle.Text = string.upper(string.format("%s %d  -  %s", MONTHS[d.month] or "", d.year, RaceConfig.Monthly.PrizeText))
	end
end

local function refresh()
	for _, board in LeaderboardConfig.Boards do
		local global = readTop(board)
		globals[board.Id] = global
		local list = merged(board, global)
		tops[board.Id] = list
		render(board, list)
	end
end

function LeaderboardService.Top(boardId: string)
	return tops[boardId] or {}
end

local function boardById(boardId: string)
	for _, board in LeaderboardConfig.Boards do
		if board.Id == boardId then
			return board
		end
	end
	return nil
end

-- A board as text rows (the Race window): live values of this server merged into the last global read.
function LeaderboardService.TopNamed(boardId: string)
	local board = boardById(boardId)
	if not board then
		return {}
	end
	local out = {}
	for i, e in merged(board, globals[boardId]) do
		out[i] = { Rank = i, Name = nameFor(e.UserId), UserId = e.UserId, Value = e.Value, Text = formatValue(board.Format, e.Value) }
	end
	return out
end

function LeaderboardService.NameOf(userId: number): string
	return nameFor(userId)
end

-- Top entries of any ordered store (monthly winner lookup). nil without DataStore access.
function LeaderboardService.TopOfStore(name: string, count: number?): { { UserId: number, Value: number } }?
	local store = storeByName(name)
	if not store then
		return nil
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, count or 1):GetCurrentPage()
	end)
	if not ok or type(page) ~= "table" then
		return nil
	end
	local out = {}
	for _, entry in page do
		local id = tonumber(entry.key)
		if id then
			table.insert(out, { UserId = id, Value = tonumber(entry.value) or 0 })
		end
	end
	return out
end

-- Writes one player's values to the stores right away (after a new race record).
function LeaderboardService.WriteNow(player: Player)
	writePlayer(player)
end

function LeaderboardService.RefreshNow()
	refresh()
end

function LeaderboardService.Init(services)
	Services = services
	Data = services.PlayerDataService
end

function LeaderboardService.Start()
	while not (Services.WorldService and Services.WorldService.Ready) do
		task.wait(0.25)
	end
	buildAll()
	Players.PlayerRemoving:Connect(function(player)
		task.spawn(writePlayer, player)
		lastWrite[player] = nil
	end)
	-- play time + periodic writes
	task.spawn(function()
		while true do
			task.wait(LeaderboardConfig.PlayTimeTick)
			for _, player in Players:GetPlayers() do
				if Data.Get(player) then
					Data.Increment(player, { "Stats", "PlayTime" }, LeaderboardConfig.PlayTimeTick)
					if os.clock() - (lastWrite[player] or 0) >= LeaderboardConfig.WriteSeconds then
						task.spawn(writePlayer, player)
					end
				end
			end
		end
	end)
	-- refresh loop (first pass shortly after start so the boards fill in)
	task.spawn(function()
		task.wait(3)
		while true do
			local ok, err = pcall(refresh)
			if not ok then
				warn("[Leaderboard] " .. tostring(err))
			end
			task.wait(storeFailed and 10 or LeaderboardConfig.RefreshSeconds)
		end
	end)
end

return LeaderboardService

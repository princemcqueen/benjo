--[[
	SanctuaryService
	Assigns each player one of the personal sanctuary plots (first free plot),
	shows their name and colour on the gate, and frees it when they leave.
	Plot models live in Workspace.World.Sanctuaries (built by WorldService).

	Perches: the owner's placed dragons are replicated to every client through
	ReplicatedStorage.SanctuaryState.Plot<i> (a Configuration, so it never
	streams out) and everyone sees each other's resting dragons (clients build
	the visuals locally - see PerchController):
	  OwnerUserId, OwnerName, PerchesUnlocked = n
	  Perch<i> = "SpeciesId|Mutation|Level|Name"   ("" = empty perch)
	Unlocked perch crystals glow (server-side, visible to all).

	API: GetPlot(player) -> Model?, GetPlotId(player) -> number?
	Replicated state: SanctuaryState (above), plot model attributes
	OwnerUserId / OwnerName, player attribute "PlotId".
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WorldConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("WorldConfig"))
local Odds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Odds"))

local SanctuaryService = {}

local Sanctuaries -- World/Sanctuaries module (visual helpers)
local Data
local Services
local owners: { [number]: Player } = {} -- plotId -> player
local byPlayer: { [Player]: number } = {}
local stateFolder: Folder

local COLORS = {
	Color3.fromRGB(150, 36, 46),
	Color3.fromRGB(38, 70, 150),
	Color3.fromRGB(40, 120, 70),
	Color3.fromRGB(170, 110, 30),
	Color3.fromRGB(110, 50, 150),
	Color3.fromRGB(30, 130, 140),
	Color3.fromRGB(150, 60, 110),
	Color3.fromRGB(90, 90, 100),
}

local function plotsFolder(): Instance?
	local world = Workspace:FindFirstChild("World")
	return world and world:FindFirstChild("Sanctuaries")
end

local function plotModel(id: number): Model?
	local f = plotsFolder()
	return f and f:FindFirstChild("Plot" .. id) :: Model?
end

local function plotState(id: number): Configuration
	return stateFolder:FindFirstChild("Plot" .. id) :: Configuration
end

-- Encodes a placed dragon for the perch attribute.
local function encode(record): string
	return string.format("%s|%s|%d|%d|%s", record.SpeciesId, record.Mutation or "None", record.Level or 1, Odds.ofRecord(record), record.Name or "")
end

local function setGems(model: Model, unlocked: number)
	if not Sanctuaries then
		return
	end
	for i = 1, WorldConfig.Sanctuary.PerchCount do
		Sanctuaries.setPerchGem(model, i, i <= unlocked)
	end
end

-- Publishes the owner's perch state (SanctuaryState.Plot<id>) and lights the unlocked perch crystals.
local function syncPerches(player: Player)
	local id = byPlayer[player]
	local data = Data and Data.Get(player)
	if not id or not data then
		return
	end
	local state = plotState(id)
	local unlocked = math.min(data.Nests.Unlocked or 0, WorldConfig.Sanctuary.PerchCount)
	if state:GetAttribute("PerchesUnlocked") ~= unlocked then
		state:SetAttribute("PerchesUnlocked", unlocked)
		local model = plotModel(id)
		if model then
			setGems(model, unlocked)
		end
	end
	for i = 1, WorldConfig.Sanctuary.PerchCount do
		local uid = data.Nests.Slots[tostring(i)]
		local record = uid and data.Dragons[uid]
		local value = record and encode(record) or ""
		if state:GetAttribute("Perch" .. i) ~= value then
			state:SetAttribute("Perch" .. i, value)
		end
	end
end
SanctuaryService.SyncPerches = syncPerches

local function clearState(id: number)
	local state = plotState(id)
	state:SetAttribute("OwnerUserId", 0)
	state:SetAttribute("OwnerName", "")
	state:SetAttribute("PerchesUnlocked", 0)
	for i = 1, WorldConfig.Sanctuary.PerchCount do
		state:SetAttribute("Perch" .. i, "")
	end
	local model = plotModel(id)
	if model then
		setGems(model, 0)
	end
end

-- Where a player appears: on their terrace between the gate and the nest,
-- facing the nest and the resting dragons.
function SanctuaryService.SpawnCFrame(id: number): CFrame?
	local f = WorldConfig.plotFrame(id)
	return f and f * CFrame.new(0, 3.4, -27) * CFrame.Angles(0, math.pi, 0) or nil
end

local function placeCharacter(player: Player, character: Model)
	local id = byPlayer[player]
	if not id then
		return
	end
	local hrp = character:WaitForChild("HumanoidRootPart", 10)
	if not hrp or player.Character ~= character then
		return
	end
	local cf = SanctuaryService.SpawnCFrame(id) :: CFrame
	pcall(function()
		player:RequestStreamAroundAsync(cf.Position, 5)
	end)
	if player.Character ~= character or not character.Parent then
		return
	end
	character:PivotTo(cf)
	-- bring the companion dragon along
	local mount = Services and Services.MountService
	if mount and mount.Spawn then
		mount.Spawn(player)
	end
end
SanctuaryService.PlaceCharacter = placeCharacter

local function assign(player: Player)
	if byPlayer[player] then
		return
	end
	-- wait for the world
	local t = 0
	while not plotsFolder() and t < 60 do
		t += task.wait(0.25)
	end
	if player.Parent ~= Players then
		return
	end
	for id = 1, WorldConfig.MaxPlots do
		if not owners[id] and plotModel(id) then
			owners[id] = player
			byPlayer[player] = id
			local model = plotModel(id) :: Model
			model:SetAttribute("OwnerUserId", player.UserId)
			model:SetAttribute("OwnerName", player.DisplayName)
			if Sanctuaries then
				Sanctuaries.setOwner(model, player.DisplayName, COLORS[id])
			end
			local state = plotState(id)
			state:SetAttribute("OwnerUserId", player.UserId)
			state:SetAttribute("OwnerName", player.DisplayName)
			player:SetAttribute("PlotId", id)
			syncPerches(player)
			-- spawn (and respawn) at the sanctuary
			player.CharacterAdded:Connect(function(character)
				task.spawn(placeCharacter, player, character)
			end)
			if player.Character then
				task.spawn(placeCharacter, player, player.Character)
			end
			return
		end
	end
	warn("[Sanctuary] no free plot for " .. player.Name)
end

local function release(player: Player)
	local id = byPlayer[player]
	if not id then
		return
	end
	byPlayer[player] = nil
	owners[id] = nil
	clearState(id)
	local model = plotModel(id)
	if model then
		model:SetAttribute("OwnerUserId", 0)
		model:SetAttribute("OwnerName", nil)
		if Sanctuaries then
			Sanctuaries.setOwner(model, nil, nil)
		end
	end
end

function SanctuaryService.GetPlotId(player: Player): number?
	return byPlayer[player]
end

function SanctuaryService.GetPlot(player: Player): Model?
	local id = byPlayer[player]
	return id and plotModel(id) or nil
end

function SanctuaryService.Init(services)
	Services = services
	Data = services.PlayerDataService
	local world = ServerScriptService:FindFirstChild("World")
	local mod = world and world:FindFirstChild("Sanctuaries")
	if mod then
		Sanctuaries = require(mod)
	end
	-- streaming-proof replicated perch state (one Configuration per plot)
	stateFolder = Instance.new("Folder")
	stateFolder.Name = "SanctuaryState"
	for id = 1, WorldConfig.MaxPlots do
		local c = Instance.new("Configuration")
		c.Name = "Plot" .. id
		c:SetAttribute("PlotId", id)
		c.Parent = stateFolder
	end
	stateFolder.Parent = ReplicatedStorage
	for id = 1, WorldConfig.MaxPlots do
		clearState(id)
	end
end

function SanctuaryService.Start()
	for _, p in Players:GetPlayers() do
		task.spawn(assign, p)
	end
	Players.PlayerAdded:Connect(function(p)
		task.spawn(assign, p)
	end)
	Players.PlayerRemoving:Connect(release)
	local dragons = Services.DragonService
	if dragons then
		dragons.PlacedChanged:Connect(syncPerches)
	end
	Data.Loaded:Connect(function(player)
		syncPerches(player)
	end)
end

return SanctuaryService

--[[
	CoinService
	Coins on the map: copper trails along the roads, gold arcs in the sky, treasure piles at the
	landmarks (CoinConfig / CoinLayout). The list of coins is the same for everybody; whether a
	coin is there is per player (it comes back CoinConfig.Kinds[kind].Respawn seconds after the
	player took it). The server builds the list from the finished world, validates every pickup
	(distance, own cooldown) and pays: the value of a coin is a few seconds of the player's income;
	coins taken in quick succession form a CHAIN that pays more per coin.

	Net (domain "Coins"):
	  Layout {}          -> { Layout = { X, Y, Z, K }, Back = { [id] = seconds left } }
	  Collect { Ids }    -> { Collected = { id... }, Gained, Chain, Mult, Total }
	Ids the server does not take (too far, not back yet) are simply left out of Collected.
	Test hooks: CoinService.List(), CoinService.State(player), CoinService.Build().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local CoinLayout = require(Shared:WaitForChild("CoinLayout"))
local CoinConfig = require(Configs:WaitForChild("CoinConfig"))

local CoinService = {}

local Data
local Services
local list: { { Kind: string, Position: Vector3 } } = {}
local packed: any = nil
local states: { [Player]: { Back: { [number]: number }, Chain: number, Last: number } } = {}

-- (the simulator's os.clock is wall time; server time is what the rest of the game uses)
local function clock(): number
	return Workspace:GetServerTimeNow()
end

-- ============================================================== layout
local function build()
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	groundParams.FilterDescendantsInstances = { Workspace.Terrain }
	groundParams.IgnoreWater = false

	local exclude = {}
	local world = Workspace:FindFirstChild("World")
	for _, name in { "Nature", "EggSpots" } do
		local folder = world and world:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	for _, name in { "Dragons", "MyEggs", "HeldEggs" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	local surfaceParams = RaycastParams.new()
	surfaceParams.FilterType = Enum.RaycastFilterType.Exclude
	surfaceParams.FilterDescendantsInstances = exclude
	surfaceParams.IgnoreWater = false

	local env = {
		ground = function(x: number, z: number)
			local hit = Workspace:Raycast(Vector3.new(x, 900, z), Vector3.new(0, -1800, 0), groundParams)
			if not hit then
				return nil
			end
			return hit.Position.Y, hit.Normal.Y, hit.Material == Enum.Material.Water
		end,
		surface = function(x: number, z: number)
			local hit = Workspace:Raycast(Vector3.new(x, 900, z), Vector3.new(0, -1800, 0), surfaceParams)
			if not hit or hit.Material == Enum.Material.Water then
				return nil
			end
			return hit.Position.Y
		end,
	}
	list = CoinLayout.generate(env)
	packed = CoinLayout.pack(list)
	return #list
end

function CoinService.Build(): number
	return build()
end

function CoinService.List()
	return list
end

-- ============================================================== players
local function stateOf(player: Player)
	local st = states[player]
	if not st then
		st = { Back = {}, Chain = 0, Last = -math.huge }
		states[player] = st
	end
	return st
end

function CoinService.State(player: Player)
	return stateOf(player)
end

-- ============================================================== net
local function handleLayout(player: Player)
	if not packed then
		return false, "NOT_READY"
	end
	-- coins the player took a short while ago are still gone (a client that restarts must not see them)
	local st = stateOf(player)
	local now = clock()
	local back = {}
	for id, at in st.Back do
		if at > now then
			back[tostring(id)] = math.ceil(at - now)
		end
	end
	return true, { Layout = packed, Back = back }
end

local function handleCollect(player: Player, p)
	local data = Data.Get(player)
	if not data or #list == 0 then
		return false, "NOT_READY"
	end
	local ids = p.Ids
	if type(ids) ~= "table" or #ids == 0 or #ids > CoinConfig.Batch.Size * 2 then
		return false, "BAD_REQUEST"
	end
	local st = stateOf(player)
	local now = clock()
	local income = Services.EconomyService.IncomeRate(player)
	local collected = {}
	local gained, mult = 0, 1
	local seen = {}
	for _, id in ids do
		if Net.check.int(id, 1, #list) and not seen[id] then
			seen[id] = true
			local coin = list[id]
			local kind = CoinConfig.Kinds[coin.Kind]
			if (st.Back[id] or 0) <= now and Services.EggService.DistanceTo(player, coin.Position) <= kind.Radius + CoinConfig.ServerSlack then
				if now - st.Last <= CoinConfig.Chain.Window then
					st.Chain += 1
				else
					st.Chain = 1
				end
				st.Last = now
				mult = CoinConfig.multiplier(st.Chain)
				gained += math.floor(CoinConfig.value(coin.Kind, income) * mult + 0.5)
				st.Back[id] = now + kind.Respawn
				table.insert(collected, id)
			end
		end
	end
	if #collected > 0 then
		Services.EconomyService.Earn(player, gained, "Coins")
		Data.Increment(player, { "Stats", "Coins" }, #collected)
	end
	local stats = data.Stats
	return true, { Collected = collected, Gained = gained, Chain = st.Chain, Mult = mult, Total = stats and stats.Coins or 0 }
end

-- ============================================================== lifecycle
function CoinService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Coins", "Layout", handleLayout, { Burst = 4, PerSecond = 1 })
	Net.handle("Coins", "Collect", handleCollect, { Burst = 8, PerSecond = 6 })
end

function CoinService.Start()
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	task.spawn(function()
		while not Workspace:GetAttribute("WorldReady") do
			task.wait(0.5)
		end
		local count = build()
		if count < 100 then
			warn(string.format("[Coins] only %d coins could be placed", count))
		end
	end)
end

return CoinService

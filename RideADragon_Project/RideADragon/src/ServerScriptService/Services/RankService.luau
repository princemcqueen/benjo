--[[
	RankService
	Five ranks (RankConfig): VIP, MOD, ADMIN, CO-OWNER, OWNER. A rank is a title: a coloured tag over the
	character, a coloured [TITLE] in chat (ChatController) and the player attributes RankLevel /
	RankTitle that every client can read.

	The owner hands ranks out with chat commands (parsed here, forwarded by AdminModule):
	  /rank <player|me|UserId> <rank|none>     rank = vip / mod / admin / coowner / owner / 1-5 / none
	  /ranks                                    the ranks and who has one in this server
	  /rankhelp
	Who may: the real owner (AdminModule.IsOwner: AdminConfig, the creator, anybody inside Studio) can
	set any rank, also for players who are not in the server (they get it when they join); a CO-OWNER can
	hand out ranks up to ADMIN to players below CO-OWNER; everybody else is refused.

	Stored in the player data (Rank). A grant for a player who is not here waits in the DataStore
	"RankGrants_v1" until they join.

	API: RankService.Level(player) -> 0..5, RankService.Set(player, level, by?) -> ok,
	     RankService.Execute(sender, text) -> boolean (true = it was a rank command)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local RankConfig = require(Configs:WaitForChild("RankConfig"))
local AdminModule = require(script.Parent.Parent:WaitForChild("AdminModule"))

local RankService = {}

local Data
local grants: any = nil

local function notify(player: Player?, kind: string, text: string)
	if player and player.Parent == Players then
		pcall(Net.notify, player, kind, text)
	end
end

-- ============================================================== level / visuals
function RankService.Level(player: Player): number
	local data = Data and Data.Get(player)
	local n = data and tonumber(data.Rank) or 0
	return math.clamp(math.floor(n or 0), 0, RankConfig.MaxLevel)
end

-- 5 for the real owner, otherwise the rank of the player
local function authority(player: Player): number
	if AdminModule.IsOwner(player) then
		return RankConfig.MaxLevel
	end
	return RankService.Level(player)
end

local function label(parent: Instance, name: string, text: string, color: Color3, position: UDim2, size: UDim2, font: Enum.Font)
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Position = position
	t.Size = size
	t.Font = font
	t.Text = text
	t.TextScaled = true
	t.TextColor3 = color
	t.Parent = parent
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(18, 20, 34)
	stroke.Parent = t
	return t
end

-- The tag above the character: TITLE in the rank colour, the epithet under it.
local function buildTag(player: Player, character: Model?)
	if not character then
		return
	end
	local old = character:FindFirstChild("RankTag", true)
	if old then
		old:Destroy()
	end
	local def = RankConfig.ByLevel[RankService.Level(player)]
	if not def then
		return
	end
	local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not head then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "RankTag"
	gui.Adornee = head :: any
	gui.Size = UDim2.fromOffset(260, 56)
	gui.StudsOffset = Vector3.new(0, 3.4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 150
	gui.LightInfluence = 0
	local star = def.Level >= 4 and "★ " or ""
	local starEnd = def.Level >= 4 and " ★" or ""
	label(gui, "Title", star .. def.Title .. starEnd, def.Color, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.62), Enum.Font.GothamBlack)
	label(gui, "Epithet", def.Epithet, Color3.fromRGB(235, 238, 250), UDim2.fromScale(0.1, 0.62), UDim2.fromScale(0.8, 0.36), Enum.Font.GothamMedium)
	gui.Parent = head
end

local function applyVisuals(player: Player)
	local lvl = RankService.Level(player)
	local def = RankConfig.ByLevel[lvl]
	player:SetAttribute("RankLevel", lvl)
	player:SetAttribute("RankTitle", def and def.Title or "")
	buildTag(player, player.Character)
end

-- ============================================================== setting a rank
function RankService.Set(player: Player, level: number, by: string?): boolean
	if not Data or not Data.Get(player) then
		return false
	end
	level = math.clamp(math.floor(tonumber(level) or 0), 0, RankConfig.MaxLevel)
	Data.Set(player, { "Rank" }, level)
	applyVisuals(player)
	if Data.SaveNow then
		Data.SaveNow(player)
	end
	local def = RankConfig.ByLevel[level]
	print(string.format("[Rank] %s is now %s%s", player.Name, def and def.Title or "no rank", by and (" (by " .. by .. ")") or ""))
	return true
end

-- A grant waiting for a player who was not in the server.
local function storeGrant(userId: number, level: number): (boolean, string?)
	if not grants then
		return false, "The rank store is not available."
	end
	local ok, err = pcall(function()
		grants:SetAsync(tostring(userId), level)
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

local function claimGrant(player: Player)
	if not grants then
		return
	end
	local ok, level = pcall(function()
		return grants:GetAsync(tostring(player.UserId))
	end)
	if ok and type(level) == "number" and level >= 0 and level <= RankConfig.MaxLevel then
		pcall(function()
			grants:RemoveAsync(tostring(player.UserId))
		end)
		if player.Parent == Players and Data.Get(player) then
			RankService.Set(player, level, "pending grant")
			local def = RankConfig.ByLevel[level]
			if def then
				notify(player, "rare", string.format("You are now %s - %s!", def.Title, def.Epithet))
			end
		end
	end
end

-- ============================================================== commands
local function helpText(): string
	local parts = {}
	for _, r in RankConfig.Ranks do
		table.insert(parts, string.format("%d %s", r.Level, r.Title))
	end
	return "RANKS:  " .. table.concat(parts, "  |  ") .. "   -   /rank <player|me> <rank|none>   /ranks"
end

local function listText(): string
	local people = {}
	for _, p in Players:GetPlayers() do
		local def = RankConfig.ByLevel[RankService.Level(p)]
		if def then
			table.insert(people, string.format("%s [%s]", p.Name, def.Title))
		end
	end
	return helpText() .. "   -   Here: " .. (#people > 0 and table.concat(people, ", ") or "nobody has a rank yet")
end

function RankService.Execute(sender: Player, raw: string): boolean
	if type(raw) ~= "string" then
		return false
	end
	local text = raw:match("^%s*(.-)%s*$") or raw
	local lower = string.lower(text)
	if lower == "/ranks" or lower == ";ranks" then
		notify(sender, "info", listText())
		return true
	end
	if lower == "/rankhelp" or lower == ";rankhelp" or lower == "/rank" or lower == ";rank" then
		notify(sender, "info", helpText())
		return true
	end
	local targetText, rankText = text:match("^[/;][Rr][Aa][Nn][Kk]%s+(%S+)%s+(.+)$")
	if not targetText then
		return false
	end

	local mine = authority(sender)
	if mine < RankConfig.CommandLevel then
		notify(sender, "error", "You are not allowed to use /rank.")
		return true
	end
	local def, isNone = RankConfig.parse(rankText)
	if not def and not isNone then
		notify(sender, "error", "Unknown rank '" .. rankText .. "'.  " .. helpText())
		return true
	end
	local newLevel = def and def.Level or 0
	-- a CO-OWNER hands out ranks below their own
	if mine < RankConfig.MaxLevel and newLevel >= mine then
		notify(sender, "error", "You can only give ranks below your own.")
		return true
	end

	local target, err = AdminModule.FindPlayer(sender, targetText)
	if target then
		if mine < RankConfig.MaxLevel and authority(target) >= mine and target ~= sender then
			notify(sender, "error", "You cannot change the rank of somebody who ranks as high as you.")
			return true
		end
		if not RankService.Set(target, newLevel, sender.Name) then
			notify(sender, "error", "That player's data is not loaded yet.")
			return true
		end
		local title = def and string.format("%s - %s", def.Title, def.Epithet) or "no rank"
		notify(sender, "success", string.format("RANK: %s is now %s.", target == sender and "you" or target.Name, title))
		if def then
			if target ~= sender then
				notify(target, "rare", string.format("You are now %s - %s!", def.Title, def.Epithet))
			end
			pcall(Net.notifyAll, "info", string.format("RANK UP: %s is now %s!", target.DisplayName, def.Title))
		elseif target ~= sender then
			notify(target, "info", "Your rank was removed.")
		end
		return true
	end

	-- not in this server: only the real owner can leave a grant for the next visit
	if not (err and string.find(err, "not in this server", 1, true)) then
		notify(sender, "error", err or "Player not found.")
		return true
	end
	if mine < RankConfig.MaxLevel then
		notify(sender, "error", err)
		return true
	end
	local userId = tonumber(targetText)
	if not userId then
		local ok, id = pcall(function()
			return Players:GetUserIdFromNameAsync(targetText)
		end)
		userId = ok and id or nil
	end
	if not userId then
		notify(sender, "error", "There is no Roblox player called '" .. targetText .. "'.")
		return true
	end
	local ok, storeErr = storeGrant(userId, newLevel)
	if ok then
		notify(sender, "success", string.format("RANK: %s gets %s the next time they join.", targetText, def and def.Title or "no rank"))
	else
		notify(sender, "error", "Could not save the rank: " .. tostring(storeErr))
	end
	return true
end

-- ============================================================== lifecycle
function RankService.Init(services)
	Data = services.PlayerDataService
end

function RankService.Start()
	local okStore, store = pcall(function()
		return DataStoreService:GetDataStore("RankGrants_v1")
	end)
	grants = okStore and store or nil

	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character)
			task.defer(buildTag, player, character)
		end)
		if player.Character then
			task.defer(buildTag, player, player.Character)
		end
	end
	Data.Loaded:Connect(function(player)
		applyVisuals(player)
		task.spawn(claimGrant, player)
	end)
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
		if Data.Get(player) then
			applyVisuals(player)
		end
	end
end

return RankService

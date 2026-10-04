--[[
    AdminModule

    Server-side /give system for Ride A Dragon.

    Examples:
      /give me Cash 10000
      /give PlayerName Spins 25
      /give PlayerName PrinceDragon
      /give PlayerName LuckPotion 5
      /give PlayerName CelestialEgg 3
      /give PlayerName EggHunter

    Potions in this game are timed boosts, not inventory objects. Giving 5 LuckPotions
    therefore applies the normal Luck Potion five times and extends its timer fivefold.

    Everything is granted through the game's existing authoritative services and a save
    is requested immediately after a successful command.

    Ranks: /rank <player|me> <rank|none>, /ranks, /rankhelp are handled by RankService (see
    RankConfig). A CO-OWNER or OWNER rank (RankConfig.GiveLevel) may use /give too.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Configs = ReplicatedStorage:WaitForChild("Configs")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local AdminConfig = require(Configs:WaitForChild("AdminConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))
local RankConfig = require(Configs:WaitForChild("RankConfig"))
local Net = require(Shared:WaitForChild("Net"))

local AdminModule = {}
local Services = nil

local function normalize(value: any): string
    return string.lower((tostring(value or ""):gsub("[%s_%-]+", "")))
end

local function finitePositiveInteger(value: any, defaultValue: number, maxValue: number): number?
    if value == nil or value == "" then
        return defaultValue
    end
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    n = math.floor(n)
    if n < 1 then
        return nil
    end
    return math.min(n, maxValue)
end

local function notify(player: Player?, kind: string, text: string)
    if not player or player.Parent ~= Players then
        return
    end
    pcall(function()
        Net.notify(player, kind, text)
    end)
end

-- The real owner: AdminConfig (usernames / user ids / the experience creator) and everybody inside
-- Roblox Studio. Can do everything, including handing out any rank.
function AdminModule.IsOwner(player: Player): boolean
    if RunService:IsStudio() and AdminConfig.AllowEveryoneInStudio then
        return true
    end

    for _, userId in AdminConfig.AdminUserIds or {} do
        if player.UserId == tonumber(userId) then
            return true
        end
    end

    local username = string.lower(player.Name)
    for _, allowedName in AdminConfig.AdminUsernames or {} do
        if username == string.lower(tostring(allowedName)) then
            return true
        end
    end

    if AdminConfig.AllowUserCreator and game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
        return true
    end

    return false
end

-- May use /give: the owner, or somebody with the CO-OWNER / OWNER rank.
function AdminModule.IsAdmin(player: Player): boolean
    if AdminModule.IsOwner(player) then
        return true
    end
    local ranks = Services and Services.RankService
    return ranks ~= nil and ranks.Level(player) >= RankConfig.GiveLevel
end

function AdminModule.FindPlayer(sender: Player, query: string): (Player?, string?)
    local q = string.lower(query or "")
    if q == "me" or q == "@me" then
        return sender, nil
    end

    -- Exact username first, then exact display name.
    for _, player in Players:GetPlayers() do
        if string.lower(player.Name) == q then
            return player, nil
        end
    end
    for _, player in Players:GetPlayers() do
        if string.lower(player.DisplayName) == q then
            return player, nil
        end
    end

    -- Unique prefix of username/display name.
    local matches = {}
    for _, player in Players:GetPlayers() do
        local name = string.lower(player.Name)
        local display = string.lower(player.DisplayName)
        if string.sub(name, 1, #q) == q or string.sub(display, 1, #q) == q then
            table.insert(matches, player)
        end
    end

    if #matches == 1 then
        return matches[1], nil
    elseif #matches > 1 then
        return nil, "More than one player matches '" .. query .. "'. Use the full username."
    end
    return nil, "Player '" .. query .. "' is not in this server."
end

local dragonLookup: { [string]: string } = {}
local eggLookup: { [string]: string } = {}
local productLookup: { [string]: string } = {}
local passLookup: { [string]: string } = {}
local defaultMutation: { [string]: string } = {}

local function buildLookups()
    table.clear(dragonLookup)
    table.clear(eggLookup)
    table.clear(productLookup)
    table.clear(passLookup)
    table.clear(defaultMutation)

    for speciesId, def in DragonConfig.Species do
        dragonLookup[normalize(speciesId)] = speciesId
        dragonLookup[normalize(def.Name)] = speciesId
    end
    -- Friendly spelling without the zero in the internal M0nica species id.
    dragonLookup["monicadragon"] = "M0nicaDragon"
    dragonLookup["monica"] = "M0nicaDragon"
    dragonLookup["m0nica"] = "M0nicaDragon"
    dragonLookup["narcisdragon"] = "N2RC1SDragon"
    dragonLookup["narcis"] = "N2RC1SDragon"

    for eggId, def in EggConfig.Eggs do
        eggLookup[normalize(eggId)] = eggId
        eggLookup[normalize(def.Name)] = eggId
    end

    for itemId, def in MonetizationConfig.Products do
        productLookup[normalize(itemId)] = itemId
        productLookup[normalize(def.Name)] = itemId
    end

    for itemId, def in MonetizationConfig.GamePasses do
        passLookup[normalize(itemId)] = itemId
        passLookup[normalize(def.Name)] = itemId
        if def.Grants then
            defaultMutation[def.Grants] = def.Mutation or "None"
        end
    end
end

buildLookups()

local function giveDragon(target: Player, speciesId: string, count: number): (boolean, string)
    local dragonService = Services and Services.DragonService
    if not dragonService then
        return false, "DragonService is not available."
    end

    local mutation = defaultMutation[speciesId] or "None"
    local added = 0
    for _ = 1, count do
        local record = dragonService.Add(target, speciesId, mutation, "Admin", true)
        if record then
            added += 1
        end
    end

    if added == 0 then
        return false, "Could not add the dragon."
    end
    return true, string.format("%dx %s", added, DragonConfig.Species[speciesId].Name)
end

local function giveEgg(target: Player, eggId: string, count: number): (boolean, string)
    local eggService = Services and Services.EggService
    if not eggService then
        return false, "EggService is not available."
    end

    local added = 0
    for _ = 1, count do
        local ok = eggService.GiveEgg(target, eggId, 1, true)
        if ok then
            added += 1
        end
    end
    if added == 0 then
        return false, "Could not add the egg."
    end
    return true, string.format("%dx %s", added, EggConfig.Eggs[eggId].Name)
end

local function giveProduct(target: Player, itemId: string, count: number): (boolean, string)
    local monetization = Services and Services.MonetizationService
    if not monetization then
        return false, "MonetizationService is not available."
    end

    local granted = 0
    local lastText = nil
    for _ = 1, count do
        local ok, text = monetization.GrantProduct(target, itemId)
        if not ok then
            break
        end
        granted += 1
        lastText = text
    end
    if granted == 0 then
        return false, "Could not grant " .. itemId .. "."
    end
    local def = MonetizationConfig.Products[itemId]
    local label = def and def.Name or itemId
    if count == 1 and lastText then
        return true, lastText
    end
    return true, string.format("%dx %s", granted, label)
end

local function givePass(target: Player, itemId: string): (boolean, string)
    local monetization = Services and Services.MonetizationService
    if not monetization then
        return false, "MonetizationService is not available."
    end
    local ok, text = monetization.GrantPass(target, itemId)
    if not ok then
        return false, "Could not grant " .. itemId .. "."
    end
    local def = MonetizationConfig.GamePasses[itemId]
    return true, text or ((def and def.Name or itemId) .. " unlocked")
end

function AdminModule.Give(sender: Player, target: Player, itemName: string, amountText: any): (boolean, string)
    if not AdminModule.IsAdmin(sender) then
        return false, "You are not allowed to use admin commands."
    end
    if not Services or not Services.PlayerDataService or not Services.PlayerDataService.Get(target) then
        return false, "That player's data is not loaded yet."
    end

    local key = normalize(itemName)

    if key == "cash" or key == "money" or key == "coins" then
        local amount = finitePositiveInteger(amountText, 1, AdminConfig.MaxCash)
        if not amount then
            return false, "Cash amount must be a positive number."
        end
        Services.EconomyService.Earn(target, amount, "Admin")
        Services.PlayerDataService.SaveNow(target)
        return true, "$" .. tostring(amount) .. " cash"
    end

    if key == "spin" or key == "spins" or key == "tickets" then
        local amount = finitePositiveInteger(amountText, 1, AdminConfig.MaxSpins)
        if not amount then
            return false, "Spin amount must be a positive number."
        end
        Services.SpinService.AddTickets(target, amount)
        Services.PlayerDataService.SaveNow(target)
        return true, tostring(amount) .. " spins"
    end

    local count = finitePositiveInteger(amountText, 1, AdminConfig.MaxItemCount)
    if not count then
        return false, "Item count must be between 1 and " .. tostring(AdminConfig.MaxItemCount) .. "."
    end

    local speciesId = dragonLookup[key]
    if speciesId then
        local ok, text = giveDragon(target, speciesId, count)
        if ok then
            Services.PlayerDataService.SaveNow(target)
        end
        return ok, text
    end

    local eggId = eggLookup[key]
    if eggId then
        local ok, text = giveEgg(target, eggId, count)
        if ok then
            Services.PlayerDataService.SaveNow(target)
        end
        return ok, text
    end

    local productId = productLookup[key]
    if productId then
        local ok, text = giveProduct(target, productId, count)
        if ok then
            Services.PlayerDataService.SaveNow(target)
        end
        return ok, text
    end

    local passId = passLookup[key]
    if passId then
        if count ~= 1 then
            return false, "Permanent pass perks can only be granted once."
        end
        local ok, text = givePass(target, passId)
        if ok then
            Services.PlayerDataService.SaveNow(target)
        end
        return ok, text
    end

    return false, "Unknown item '" .. itemName .. "'. Try /givehelp"
end

local HELP = table.concat({
    "ADMIN GIVE COMMANDS:",
    "/give <player|me> Cash <amount>",
    "/give <player|me> Spins <amount>",
    "/give <player|me> PrinceDragon [count]",
    "/give <player|me> LuckPotion [count]",
    "/give <player|me> CelestialEgg [count]",
    "/give <player|me> EggHunter",
}, "  |  ")

function AdminModule.Execute(sender: Player, rawMessage: string): boolean
    if type(rawMessage) ~= "string" then
        return false
    end

    -- /rank, /ranks, /rankhelp
    local ranks = Services and Services.RankService
    if ranks and ranks.Execute(sender, rawMessage) then
        return true
    end

    local trimmed = rawMessage:match("^%s*(.-)%s*$") or rawMessage
    local lower = string.lower(trimmed)

    if lower == "/givehelp" or lower == ";givehelp" then
        if AdminModule.IsAdmin(sender) then
            notify(sender, "rare", HELP)
        end
        return true
    end

    local prefix, targetText, itemText, amountText = trimmed:match("^([/;])give%s+(%S+)%s+(%S+)%s*(%S*)%s*$")
    if not prefix then
        return false
    end

    if not AdminModule.IsAdmin(sender) then
        notify(sender, "error", "You are not allowed to use /give.")
        return true
    end

    local target, targetErr = AdminModule.FindPlayer(sender, targetText)
    if not target then
        notify(sender, "error", targetErr or "Player not found.")
        return true
    end

    local ok, result = AdminModule.Give(sender, target, itemText, amountText ~= "" and amountText or nil)
    if not ok then
        notify(sender, "error", "ADMIN: " .. result)
        return true
    end

    local targetLabel = target == sender and "yourself" or target.Name
    notify(sender, "success", "ADMIN: Gave " .. result .. " to " .. targetLabel .. ".")
    if target ~= sender then
        notify(target, "rare", "ADMIN GIFT: You received " .. result .. ".")
    end
    print(string.format("[Admin] %s gave %s to %s", sender.Name, result, target.Name))
    return true
end

function AdminModule.Init(services)
    Services = services
    buildLookups()
end

-- Compatibility aliases for simple third-party admin scripts that wait for an AdminModule.
AdminModule.Initialize = AdminModule.Init
AdminModule.IsAuthorized = AdminModule.IsAdmin
AdminModule.RunCommand = AdminModule.Execute

return AdminModule

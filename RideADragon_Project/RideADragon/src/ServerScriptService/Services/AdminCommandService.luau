--[[
    AdminCommandService
    Hooks server-side chat and forwards /give and /givehelp to ServerScriptService.AdminModule.

    Uses Player.Chatted intentionally: the permission check and the grant both happen on the
    server. The command never trusts a client RemoteEvent or a client-provided amount.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local AdminModule = require(script.Parent.Parent:WaitForChild("AdminModule"))

local AdminCommandService = {}
local connections: { [Player]: RBXScriptConnection } = {}

local function hook(player: Player)
    if connections[player] then
        return
    end
    connections[player] = player.Chatted:Connect(function(message)
        local ok, err = pcall(AdminModule.Execute, player, message)
        if not ok then
            warn("[Admin] command failed for " .. player.Name .. ": " .. tostring(err))
        end
    end)
end

function AdminCommandService.Init(services)
    AdminModule.Init(services)
    -- With the new chat (TextChatService) the client (ChatController) takes the admin commands out of
    -- the chat so that nobody sees them, and sends the text here. The permission is checked inside
    -- AdminModule.Execute, exactly as for Player.Chatted.
    Net.handle("Admin", "Command", function(player: Player, p)
        if not Net.check.str(p.Text, 200) then
            return false, "BAD_REQUEST"
        end
        local ok, handled = pcall(AdminModule.Execute, player, p.Text)
        if not ok then
            warn("[Admin] command failed for " .. player.Name .. ": " .. tostring(handled))
            return false, "FAILED"
        end
        return true, { Handled = handled == true }
    end, { Burst = 5, PerSecond = 2 })
end

function AdminCommandService.Start()
    Players.PlayerAdded:Connect(hook)
    Players.PlayerRemoving:Connect(function(player)
        local connection = connections[player]
        if connection then
            connection:Disconnect()
            connections[player] = nil
        end
    end)
    for _, player in Players:GetPlayers() do
        hook(player)
    end
end

return AdminCommandService

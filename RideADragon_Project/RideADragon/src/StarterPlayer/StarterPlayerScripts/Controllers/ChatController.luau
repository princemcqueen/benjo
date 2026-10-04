--[[
	ChatController
	Two things in the chat (TextChatService, the current Roblox chat):
	  * RANK TAGS: a player with a rank (player attributes RankLevel / RankTitle, set by RankService) gets
	    a coloured  [TITLE]  in front of their name in every chat line.
	  * ADMIN COMMANDS: /give, /givehelp, /rank, /ranks, /rankhelp are taken out of the chat (nobody sees
	    them) and sent to the server, which decides whether the sender may use them (AdminModule).
	With the old chat this controller does nothing: the server reads Player.Chatted instead.
	Everything is wrapped so a missing chat service never breaks the game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local RankConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("RankConfig"))

local ChatController = {}

local COMMANDS = { "/give", "/givehelp", "/rank", "/ranks", "/rankhelp" }

-- The rich-text prefix of a player's rank, or nil.
function ChatController.prefixFor(player: Player?): string?
	if not player then
		return nil
	end
	local level = player:GetAttribute("RankLevel")
	local def = type(level) == "number" and RankConfig.ByLevel[level] or nil
	if not def then
		return nil
	end
	return string.format('<font color="#%s"><b>[%s]</b></font> ', RankConfig.hex(def.Color), def.Title)
end

local function registerCommands(service: any)
	local folder = service:FindFirstChild("TextChatCommands")
	if not folder then
		return
	end
	for _, alias in COMMANDS do
		local name = "RD_" .. string.sub(alias, 2)
		if not folder:FindFirstChild(name) then
			local cmd = Instance.new("TextChatCommand")
			cmd.Name = name
			cmd.PrimaryAlias = alias
			cmd.AutocompleteVisible = false
			cmd.Triggered:Connect(function(_, text)
				task.spawn(function()
					Net.request("Admin", "Command", { Text = tostring(text) })
				end)
			end)
			cmd.Parent = folder
		end
	end
end

function ChatController.Start()
	local ok, service = pcall(function()
		return game:GetService("TextChatService")
	end)
	if not ok or not service then
		return
	end
	local isNewChat = false
	pcall(function()
		isNewChat = service.ChatVersion == Enum.ChatVersion.TextChatService
	end)
	if not isNewChat then
		return
	end
	pcall(registerCommands, service)
	pcall(function()
		service.OnIncomingMessage = function(message: any)
			local props = Instance.new("TextChatMessageProperties")
			local source = message.TextSource
			if source then
				local prefix = ChatController.prefixFor(Players:GetPlayerByUserId(source.UserId))
				if prefix then
					props.PrefixText = prefix .. message.PrefixText
				end
			end
			return props
		end
	end)
end

return ChatController

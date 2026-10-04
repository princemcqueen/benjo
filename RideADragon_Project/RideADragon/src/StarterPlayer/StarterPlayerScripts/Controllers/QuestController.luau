--[[
	QuestController
	Lights the QUESTS button of the HUD with the number of rewards waiting (server signal "QuestReady", and
	once at start in case the signal came before this controller was running). The Quests window calls
	QuestController.setCount(n) after every refresh.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local QuestController = {}

local registry
local count = 0

local function show(n: number)
	count = n
	local hud = registry and registry.Hud
	if hud and hud.SetBadge then
		hud:SetBadge("Quests", n > 0 and n or nil)
	end
end

function QuestController.setCount(n: number)
	show(n)
end

function QuestController.count(): number
	return count
end

function QuestController.Init(reg)
	registry = reg
end

function QuestController.Start()
	Net.onSignal("QuestReady", function(payload)
		show(payload and tonumber(payload.Count) or 0)
	end)
	task.spawn(function()
		-- the HUD is built after the controllers start: wait for it, then ask what is waiting
		for _ = 1, 40 do
			if registry.Hud then
				break
			end
			task.wait(0.5)
		end
		local res = Net.request("Quests", "State", {})
		if res.ok and res.data then
			show(res.data.Claimable or 0)
		end
	end)
end

return QuestController

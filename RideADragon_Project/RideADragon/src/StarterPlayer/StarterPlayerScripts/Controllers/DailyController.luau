--[[
	DailyController
	Lights the DAILY button of the HUD while a daily reward is waiting (server signal "DailyReady",
	and once at start in case the signal came before this controller was running). The Daily window
	calls DailyController.clear() after a claim.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local DailyController = {}

local registry
local ready = false

local function show(on: boolean)
	ready = on
	local hud = registry and registry.Hud
	if hud and hud.SetBadge then
		hud:SetBadge("Daily", on and 1 or nil)
	end
end

function DailyController.clear()
	show(false)
end

function DailyController.isReady(): boolean
	return ready
end

function DailyController.Init(reg)
	registry = reg
end

function DailyController.Start()
	Net.onSignal("DailyReady", function()
		show(true)
	end)
	task.spawn(function()
		-- the HUD is built after the controllers start: wait for it, then ask what is waiting
		for _ = 1, 40 do
			if registry.Hud then
				break
			end
			task.wait(0.5)
		end
		local res = Net.request("Daily", "State", {})
		if res.ok and res.data and res.data.CanClaim then
			show(true)
		end
	end)
end

return DailyController

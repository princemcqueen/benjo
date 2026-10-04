--[[
	SettingsService
	Validates and saves player settings. Every key has an explicit schema;
	unknown keys or out-of-range values are rejected.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local SettingsService = {}
local Data

local SCHEMA = {
	Graphics = function(v)
		return v == "Max" or v == "High" or v == "Medium"
	end,
	Music = function(v)
		return Net.check.num(v, 0, 1)
	end,
	SFX = function(v)
		return Net.check.num(v, 0, 1)
	end,
	Sensitivity = function(v)
		return Net.check.num(v, 0.3, 2.5)
	end,
	CameraShake = Net.check.bool,
	SpeedFOV = Net.check.bool,
	MouseLock = Net.check.bool,
	InvertY = Net.check.bool,
	MenuBlur = Net.check.bool,
	UIScale = function(v)
		return Net.check.num(v, 0.8, 1.25)
	end,
}

function SettingsService.Init(services)
	Data = services.PlayerDataService
	Net.handle("Settings", "Set", function(player, payload)
		local key, value = payload.Key, payload.Value
		local validate = type(key) == "string" and SCHEMA[key]
		if not validate or not validate(value) then
			return false, "INVALID_SETTING"
		end
		if not Data.Get(player) then
			return false, "NOT_LOADED"
		end
		Data.Set(player, { "Settings", key }, value)
		return true
	end, { Burst = 20, PerSecond = 8 })
end

return SettingsService

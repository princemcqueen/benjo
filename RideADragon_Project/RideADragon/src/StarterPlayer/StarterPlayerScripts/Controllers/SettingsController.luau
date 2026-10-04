--[[
	SettingsController
	Applies settings instantly on the client and syncs them to the server
	(debounced so slider drags don't spam the network).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local SettingsController = {}
SettingsController.Current = {}

local registry = nil
local pendingSend: { [string]: any } = {}
local sendThread = nil

local function applyAll()
	local s = SettingsController.Current
	local R = registry
	if R.GraphicsController and s.Graphics then
		R.GraphicsController.setPreset(s.Graphics)
	end
	if R.AudioController then
		R.AudioController.setVolumes(s.Music or 0.6, s.SFX or 0.8)
	end
	if R.CameraController and R.CameraController.setOptions then
		R.CameraController.setOptions({
			Sensitivity = s.Sensitivity or 1,
			Shake = s.CameraShake ~= false,
			SpeedFOV = s.SpeedFOV ~= false,
			MouseLock = s.MouseLock == true,
			InvertY = s.InvertY == true,
		})
	end
	if s.UIScale then
		local Responsive = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Responsive"))
		if math.abs(Responsive.UserScale - s.UIScale) > 1e-3 then
			Responsive.setUserScale(s.UIScale)
		end
	end
end

function SettingsController.get(key: string)
	return SettingsController.Current[key]
end

function SettingsController.set(key: string, value: any)
	SettingsController.Current[key] = value
	applyAll()
	pendingSend[key] = value
	if sendThread then
		task.cancel(sendThread)
	end
	sendThread = task.delay(0.35, function()
		sendThread = nil
		local batch = pendingSend
		pendingSend = {}
		for k, v in batch do
			Net.request("Settings", "Set", { Key = k, Value = v })
		end
	end)
end

function SettingsController.Init(reg)
	registry = reg
	reg.DataController.observe("Settings", function(settings)
		if type(settings) ~= "table" then
			return
		end
		for k, v in settings do
			if pendingSend[k] == nil then
				SettingsController.Current[k] = v
			end
		end
		applyAll()
	end)
end

return SettingsController

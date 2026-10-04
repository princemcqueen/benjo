--[[
	AudioController
	- SoundGroups (Music / Ambient / SFX / UI) with player volume settings
	- playUI(key): pooled 2D sounds
	- play3D(key, parent): spatial one-shots on parts/attachments
	- loop(key, parent?): managed looping sound (wind, waterfalls)
	- music crossfades between region tracks
	Keys without an asset id (AudioConfig) are skipped silently.
	- the default Roblox character sounds (running steps, jumping, landing...) are muted while a character is
	  mounted: a rider is carried by the dragon, they would play "running" while it flies
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AudioConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("AudioConfig"))

local AudioController = {}

local groups: { [string]: SoundGroup } = {}
local pools: { [string]: { Sound } } = {}
local musicKey: string? = nil
local musicSound: Sound? = nil
local musicVolume = 0.6
local sfxVolume = 0.8

local function def(key: string)
	local d = AudioConfig.Sounds[key]
	if not d or d.Id == nil or d.Id == "" then
		return nil
	end
	return d
end

local function newSound(key: string, d, parent: Instance): Sound
	local s = Instance.new("Sound")
	s.Name = key
	s.SoundId = d.Id
	s.Volume = d.Volume or 0.5
	s.PlaybackSpeed = d.Pitch or 1
	s.Looped = d.Looped == true
	s.SoundGroup = groups[d.Group or "SFX"]
	if d.RollOffMax then
		s.RollOffMaxDistance = d.RollOffMax
		s.RollOffMinDistance = math.min(14, d.RollOffMax * 0.1)
		s.RollOffMode = Enum.RollOffMode.InverseTapered
	end
	s.Parent = parent
	return s
end

function AudioController.playUI(key: string)
	local d = def(key)
	if not d then
		return
	end
	local pool = pools[key]
	if not pool then
		pool = {}
		pools[key] = pool
	end
	for _, s in pool do
		if not s.IsPlaying then
			s.TimePosition = 0
			s:Play()
			return
		end
	end
	if #pool < 4 then
		local s = newSound(key, d, SoundService)
		table.insert(pool, s)
		s:Play()
	end
end
AudioController.play2D = AudioController.playUI

function AudioController.play3D(key: string, parent: Instance, pitchJitter: number?, volumeScale: number?)
	local d = def(key)
	if not d or not parent then
		return nil
	end
	local s = newSound(key, d, parent)
	if pitchJitter then
		s.PlaybackSpeed = (d.Pitch or 1) * (1 + (math.random() * 2 - 1) * pitchJitter)
	end
	if volumeScale then
		s.Volume *= volumeScale
	end
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(10, function()
		if s.Parent then
			s:Destroy()
		end
	end)
	return s
end

-- Returns a looping Sound (or nil) that the caller can adjust/destroy.
function AudioController.loop(key: string, parent: Instance?)
	local d = def(key)
	if not d then
		return nil
	end
	local s = newSound(key, d, parent or SoundService)
	s.Looped = true
	s:Play()
	return s
end

function AudioController.playMusic(key: string?)
	if key == musicKey then
		return
	end
	musicKey = key
	local old = musicSound
	musicSound = nil
	if old then
		local t = TweenService:Create(old, TweenInfo.new(2.5), { Volume = 0 })
		t:Play()
		t.Completed:Once(function()
			old:Destroy()
		end)
	end
	if not key then
		return
	end
	local d = def(key)
	if not d then
		return
	end
	local s = newSound(key, d, SoundService)
	s.Looped = true
	local target = d.Volume or 0.5
	s.Volume = 0
	s:Play()
	TweenService:Create(s, TweenInfo.new(3), { Volume = target }):Play()
	musicSound = s
end

function AudioController.setVolumes(music: number, sfx: number)
	musicVolume = math.clamp(music, 0, 1)
	sfxVolume = math.clamp(sfx, 0, 1)
	if groups.Music then
		groups.Music.Volume = AudioConfig.Groups.Music.Volume * musicVolume * 2
		groups.Ambient.Volume = AudioConfig.Groups.Ambient.Volume * sfxVolume * 1.25
		groups.SFX.Volume = AudioConfig.Groups.SFX.Volume * sfxVolume * 1.25
		groups.UI.Volume = AudioConfig.Groups.UI.Volume * sfxVolume * 1.25
	end
end

-- ============================================================== riders do not run
-- The sounds Roblox's own character script adds under the HumanoidRootPart of every avatar.
local CHARACTER_SOUNDS = { Running = true, Jumping = true, Landing = true, Climbing = true, Swimming = true, GettingUp = true, FreeFalling = true, Splash = true }
local muteGroup: SoundGroup? = nil

local function gateCharacter(character: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local mounted = character:GetAttribute("Mounted") == true
	for _, child in hrp:GetChildren() do
		if child:IsA("Sound") and CHARACTER_SOUNDS[child.Name] then
			if mounted then
				if child.SoundGroup ~= muteGroup then
					child.SoundGroup = muteGroup
				end
			elseif muteGroup and child.SoundGroup == muteGroup then
				child.SoundGroup = nil
			end
		end
	end
end

function AudioController.Start()
	local group = SoundService:FindFirstChild("RAD_MuteCharacter")
	if not group then
		group = Instance.new("SoundGroup")
		group.Name = "RAD_MuteCharacter"
		group.Volume = 0
		group.Parent = SoundService
	end
	muteGroup = group :: SoundGroup
	task.spawn(function()
		while true do
			task.wait(0.15)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				if character then
					gateCharacter(character)
				end
			end
		end
	end)
end

function AudioController.Init()
	for name, g in AudioConfig.Groups do
		local sg = SoundService:FindFirstChild("RAD_" .. name)
		if not sg then
			sg = Instance.new("SoundGroup")
			sg.Name = "RAD_" .. name
			sg.Volume = g.Volume
			sg.Parent = SoundService
		end
		groups[name] = sg :: SoundGroup
	end
	AudioController.setVolumes(musicVolume, sfxVolume)
end

return AudioController

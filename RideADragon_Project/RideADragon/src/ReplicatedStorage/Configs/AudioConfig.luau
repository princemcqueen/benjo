--[[
	AudioConfig
	Every sound the game plays is referenced by key. Ids that ship with the
	Roblox client (rbxasset://sounds/...) are used where suitable; the rest are
	left empty so you can paste Creator Store audio ids without code changes.
	An empty Id is skipped silently (no errors, no load warnings).

	Suggested Creator Store searches are in the comments.
]]

local AudioConfig = {}

AudioConfig.Groups = {
	Music = { Volume = 0.45 },
	Ambient = { Volume = 0.6 },
	SFX = { Volume = 0.8 },
	UI = { Volume = 0.6 },
}

AudioConfig.Sounds = {
	-- Music (search: "fantasy orchestral loop", "calm adventure")
	MusicHaven = { Id = "", Group = "Music", Volume = 0.5, Looped = true },
	MusicFrost = { Id = "", Group = "Music", Volume = 0.5, Looped = true },
	MusicEmber = { Id = "", Group = "Music", Volume = 0.5, Looped = true },
	MusicSky = { Id = "", Group = "Music", Volume = 0.5, Looped = true },

	-- Ambience
	Wind = { Id = "rbxasset://sounds/action_falling.mp3", Group = "Ambient", Volume = 0, Looped = true },
	Waterfall = { Id = "", Group = "Ambient", Volume = 0.6, Looped = true, RollOffMax = 260 }, -- "waterfall loop"
	Birds = { Id = "", Group = "Ambient", Volume = 0.3, Looped = true }, -- "forest birds ambience"

	-- Dragon (3D)
	Footstep = { Id = "rbxasset://sounds/action_jump_land.mp3", Group = "SFX", Volume = 0.35, Pitch = 0.55, RollOffMax = 120 },
	WingFlap = { Id = "", Group = "SFX", Volume = 0.7, RollOffMax = 180 }, -- "wing flap"
	Roar = { Id = "", Group = "SFX", Volume = 0.9, RollOffMax = 400 }, -- "dragon roar"
	Takeoff = { Id = "rbxasset://sounds/action_jump.mp3", Group = "SFX", Volume = 0.6, Pitch = 0.5, RollOffMax = 200 },
	Landing = { Id = "rbxasset://sounds/action_jump_land.mp3", Group = "SFX", Volume = 0.9, Pitch = 0.42, RollOffMax = 200 },
	Splash = { Id = "rbxasset://sounds/impact_water.mp3", Group = "SFX", Volume = 0.7, RollOffMax = 200 },
	Eat = { Id = "", Group = "SFX", Volume = 0.6 }, -- "munch"

	-- Eggs & hatching
	EggPickup = { Id = "", Group = "SFX", Volume = 0.7 }, -- "pickup chime"
	EggPlace = { Id = "", Group = "SFX", Volume = 0.6 }, -- "soft thud" / "wood tap" (egg set into the nest)
	EggShake = { Id = "", Group = "SFX", Volume = 0.5 }, -- "wood creak" / "egg wobble"
	EggCrack = { Id = "", Group = "SFX", Volume = 0.8 }, -- "egg crack"
	Hatch = { Id = "", Group = "SFX", Volume = 0.9 }, -- "magic burst"
	RareHatch = { Id = "", Group = "SFX", Volume = 1 }, -- "epic reveal fanfare"

	-- Economy & UI
	Collect = { Id = "", Group = "SFX", Volume = 0.7 }, -- "coins collect"
	Purchase = { Id = "", Group = "UI", Volume = 0.7 }, -- "purchase success"
	Click = { Id = "", Group = "UI", Volume = 0.5 }, -- "ui click soft"
	Hover = { Id = "", Group = "UI", Volume = 0.25 }, -- "ui hover tick"
	Open = { Id = "", Group = "UI", Volume = 0.45 }, -- "ui whoosh soft"
	Close = { Id = "", Group = "UI", Volume = 0.4 },
	Error = { Id = "", Group = "UI", Volume = 0.5 }, -- "ui error"
	Notify = { Id = "", Group = "UI", Volume = 0.45 },
	LevelUp = { Id = "", Group = "UI", Volume = 0.8 }, -- "level up"
}

return table.freeze(AudioConfig)

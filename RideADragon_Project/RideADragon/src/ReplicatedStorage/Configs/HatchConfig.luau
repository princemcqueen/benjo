--[[
	HatchConfig
	Timing of the hatching cinematic and the server-wide announcements for
	ultra-rare hatches. The result itself is always decided by the server
	(EggService); the cinematic only plays it.
]]

local HatchConfig = {}

-- A hatch whose "1 in N" odds reach MinOdds is announced to every player on the
-- server; from Mega on the banner is bigger and louder.
HatchConfig.Announce = {
	MinOdds = 25000,
	Mega = 1000000,
	BannerSeconds = 7,
	MegaBannerSeconds = 10,
	-- the banner waits for the hatcher's reveal (the cinematic runs ~9 s) so nobody is spoiled
	Delay = 8.5,
}

-- Cinematic beats in seconds. Rare results (high rarity or rare "1 in N") get a
-- longer charge and extra cracks - the same egg always feels the same, the reveal
-- grows with what is inside.
HatchConfig.Cinematic = {
	Approach = 0.8, -- camera glides to the egg
	Charge = 2.3, -- cracks appear, the roll strip spins
	ChargeRare = 3.4,
	Cracks = 4,
	CracksRare = 6,
	Walk = 2.6, -- the dragon walks towards the camera
	Roar = 1.7,
	SkipAfter = 0.5, -- the SKIP button appears after this long
}

-- A result is "rare" for the cinematic when the dragon's rarity rank is at least
-- RareRank (Epic) or its odds reach RareOdds.
HatchConfig.RareRank = 4
HatchConfig.RareOdds = 2500

return table.freeze(HatchConfig)

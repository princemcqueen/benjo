--[[
	SpinConfig
	Spin Island: a floating toy island south of the plaza with a giant prize
	wheel. One free spin every FreeSpinSeconds, plus spin tickets (start
	bonus, Robux packs, rewards). Luck (Owner Dragon, potions) multiplies the
	weights of the rare segments.

	Wheel geometry: Wheel is the rotor's centre CFrame; its LookVector points
	toward the players (and the hub). Segment 1 starts at the top and the
	segments go clockwise as seen by players.
]]

local SpinConfig = {}

SpinConfig.Island = {
	Center = Vector3.new(0, 140, 240), -- top surface centre
	Radius = 36,
}

-- Rotor centre: on the island, toward the back, facing the hub (-Z).
SpinConfig.WheelRadius = 13
SpinConfig.Wheel = CFrame.lookAt(Vector3.new(0, 140 + 18, 240 + 10), Vector3.new(0, 140 + 18, 0))

SpinConfig.FreeSpinSeconds = 15 * 60
SpinConfig.StartTickets = 3
SpinConfig.MaxDistance = 110 -- must stand near the wheel to spin
SpinConfig.SpinSeconds = 5.4
SpinConfig.Turns = 5
SpinConfig.RareFrom = 6 -- segments >= this get the luck multiplier

-- Kind: Cash (Minutes of income, at least Min), Egg, Spin (+Count tickets), Boost
SpinConfig.Segments = {
	{ Kind = "Cash", Minutes = 2, Min = 500, Label = "CASH", Weight = 22, Color = Color3.fromRGB(75, 151, 74) },
	{ Kind = "Egg", Egg = "HavenEgg", Count = 1, Label = "HAVEN EGG", Weight = 18, Color = Color3.fromRGB(13, 105, 172) },
	{ Kind = "Cash", Minutes = 10, Min = 2500, Label = "CASH x5", Weight = 14, Color = Color3.fromRGB(245, 205, 47) },
	{ Kind = "Egg", Egg = "GroveEgg", Count = 1, Label = "GROVE EGG", Weight = 12, Color = Color3.fromRGB(218, 120, 46) },
	{ Kind = "Spin", Count = 1, Label = "+1 SPIN", Weight = 9, Color = Color3.fromRGB(196, 40, 27) },
	{ Kind = "Egg", Egg = "FrostEgg", Count = 1, Label = "FROST EGG", Weight = 8, Color = Color3.fromRGB(110, 153, 202) },
	{ Kind = "Boost", Boost = "Luck", Seconds = 600, Label = "x2 LUCK", Weight = 6, Color = Color3.fromRGB(0, 150, 110) },
	{ Kind = "Egg", Egg = "EmberEgg", Count = 1, Label = "EMBER EGG", Weight = 5, Color = Color3.fromRGB(123, 46, 47) },
	{ Kind = "Cash", Minutes = 60, Min = 20000, Label = "CASH x30", Weight = 4, Color = Color3.fromRGB(170, 40, 140) },
	{ Kind = "Egg", Egg = "SkyEgg", Count = 1, Label = "SKY EGG!", Weight = 2, Color = Color3.fromRGB(222, 186, 76), Jackpot = true },
}

-- Probabilities with a luck multiplier (rare segments x luck).
function SpinConfig.odds(luck: number?): { number }
	local k = math.max(1, luck or 1)
	local weights, total = {}, 0
	for i, s in SpinConfig.Segments do
		local w = s.Weight * (i >= SpinConfig.RareFrom and k or 1)
		weights[i] = w
		total += w
	end
	for i, w in weights do
		weights[i] = w / total
	end
	return weights
end

-- Segment centre angle (degrees, clockwise from the top as players see it).
function SpinConfig.segmentAngle(i: number): number
	local n = #SpinConfig.Segments
	return (i - 0.5) * 360 / n
end

-- Where Travel "SpinIsland" puts the player: in front of the podium, facing the wheel.
function SpinConfig.arrival(): CFrame
	local w = SpinConfig.Wheel
	local front = w.Position + w.LookVector * 32
	local p = Vector3.new(front.X, SpinConfig.Island.Center.Y + 3.4, front.Z)
	return CFrame.lookAt(p, Vector3.new(w.Position.X, p.Y, w.Position.Z))
end

return table.freeze(SpinConfig)

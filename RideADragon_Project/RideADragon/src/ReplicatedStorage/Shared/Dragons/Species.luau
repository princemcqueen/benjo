--[[
	Species (visual definitions)
	Each species is a parameter set for the Builder plus optional unique
	features, giving every dragon its own silhouette (not a recolor).
]]

local Species = {}

-- Visual style for every dragon: "Brick" (toy bricks, BrickBuilder) or
-- "Classic" (smooth part-built / imported skinned meshes).
Species.Style = "Brick"

local C = Color3.fromRGB

Species.Defs = {
	GreenDrake = {
		Name = "Green Drake",
		Scale = 1.3,
		HipHeight = 5.0,
		BodyRadius = 3.9,
		Rig = "Quadruped",
		-- toy-brick plastic colours (bright, saturated, high contrast)
		Palette = {
			Main = C(75, 151, 74), -- bright green
			Dark = C(39, 112, 62), -- dark green
			Belly = C(245, 205, 47), -- bright yellow
			Horn = C(242, 243, 242), -- white
			HornTip = C(99, 95, 98), -- dark bluish grey
			Membrane = C(164, 189, 70), -- lime
			Accent = C(218, 120, 46), -- bright orange
			Eye = C(245, 205, 47),
			Pupil = C(27, 42, 52),
			Claw = C(242, 243, 242),
			Tooth = C(250, 250, 246),
			Saddle = C(196, 40, 27),
		},
		Brick = { HeadScale = 1.25, EyeScale = 1.25, HornScale = 1.6, HornTip = "HornTip", TailTip = "Accent", SpineColor = "Accent" },
		Body = { Length = 7.0, Width = 3.8, Height = 3.5, ChestScale = 1.15, HipScale = 0.9 },
		Neck = { Segments = 4, Length = 5.6, Rise = 30, Curve = 6, Thickness = 2.0, Taper = 0.68 },
		Head = { Size = 1, Snout = 1.08, Tilt = -6, Horns = "Swept", HornLength = 1.55, HornThickness = 0.55 },
		Tail = { Segments = 7, Length = 14.5, Thickness = 2.3, Taper = 0.14, Droop = 7, Lift = -2, Tip = "Spade" },
		Legs = { Front = true, Back = true, Thickness = 1.12 },
		Wings = { Type = "Bat", Span = 15, Chord = 6.4 },
		Spines = { Style = "Wedge", Height = 0.95, Color = "Dark" },
		-- mesh sculpt / texture parameters (used by the offline mesh generator)
		Mesh = {
			ScaleSize = 0.42, -- body scale size (studs at scale 1)
			Pattern = "Dapples", -- back markings
		},
	},
}

-- ============================================================== brick species
-- Toy-brick colours.
local B = {
	White = C(242, 243, 242), Black = C(27, 42, 52), LightGrey = C(163, 162, 165), DarkGrey = C(99, 95, 98),
	Red = C(196, 40, 27), DarkRed = C(123, 46, 47), Orange = C(218, 120, 46), Yellow = C(245, 205, 47),
	LightYellow = C(248, 240, 154), Tan = C(215, 197, 153), DarkTan = C(149, 138, 115), Brown = C(124, 80, 46),
	Green = C(75, 151, 74), DarkGreen = C(39, 112, 62), Lime = C(164, 189, 70), Jade = C(0, 150, 110),
	Blue = C(13, 105, 172), DarkBlue = C(32, 58, 86), MediumBlue = C(110, 153, 202), Azure = C(66, 192, 251),
	LightAqua = C(173, 221, 237), Teal = C(0, 143, 155), DarkPurple = C(52, 43, 117), Lavender = C(205, 164, 222),
	MediumLavender = C(160, 110, 185), Magenta = C(170, 40, 140), Pink = C(228, 160, 200), DarkPink = C(200, 80, 155),
	Coral = C(255, 112, 94), Gold = C(222, 186, 76), PearlGold = C(170, 127, 46), Night = C(22, 24, 44),
}
Species.BrickColors = B

local function deepCopy(t)
	local out = {}
	for k, v in t do
		out[k] = type(v) == "table" and deepCopy(v) or v
	end
	return out
end

local function merge(base, over)
	local out = deepCopy(base)
	for k, v in over or {} do
		if type(v) == "table" and type(out[k]) == "table" and #v == 0 then
			out[k] = merge(out[k], v)
		else
			out[k] = v
		end
	end
	return out
end

-- Body plans (silhouettes); every species picks one and overrides details.
local ARCH = {
	Drake = {
		Scale = 1.3, HipHeight = 5.0, BodyRadius = 3.9, Rig = "Quadruped",
		Body = { Length = 7.0, Width = 3.8, Height = 3.5, ChestScale = 1.15, HipScale = 0.9 },
		Neck = { Segments = 4, Length = 5.6, Rise = 30, Curve = 6, Thickness = 2.0, Taper = 0.68 },
		Head = { Size = 1, Snout = 1.08, Tilt = -6, Horns = "Swept", HornLength = 1.55, HornThickness = 0.55 },
		Tail = { Segments = 7, Length = 14.5, Thickness = 2.3, Taper = 0.14, Droop = 7, Lift = -2, Tip = "Spade" },
		Legs = { Front = true, Back = true, Thickness = 1.12 },
		Wings = { Type = "Bat", Span = 15, Chord = 6.4 },
		Spines = { Style = "Wedge", Height = 0.95 },
	},
	Wyvern = {
		Scale = 1.3, HipHeight = 5.4, BodyRadius = 3.6, Rig = "Quadruped",
		Body = { Length = 6.4, Width = 3.4, Height = 3.3, ChestScale = 1.1, HipScale = 0.95 },
		Neck = { Segments = 4, Length = 6.0, Rise = 34, Curve = 5, Thickness = 1.8, Taper = 0.7 },
		Head = { Size = 0.95, Snout = 1.15, Tilt = -4, Horns = "Long", HornLength = 1.3, HornThickness = 0.45 },
		Tail = { Segments = 8, Length = 16, Thickness = 2.0, Taper = 0.12, Droop = 6, Lift = 0, Tip = "Leaf" },
		Legs = { Front = false, Back = true, Thickness = 1.25 },
		Wings = { Type = "Bat", Span = 18, Chord = 7.5 },
		Spines = { Style = "Wedge", Height = 0.8 },
	},
	Serpent = {
		Scale = 1.3, HipHeight = 3.8, BodyRadius = 3.2, Rig = "Quadruped",
		Body = { Length = 8.5, Width = 2.8, Height = 2.7, ChestScale = 1.0, HipScale = 0.95 },
		Neck = { Segments = 6, Length = 8.5, Rise = 36, Curve = 3, Thickness = 1.7, Taper = 0.85 },
		Head = { Size = 1.05, Snout = 1.25, Tilt = -2, Horns = "Long", HornLength = 1.5, HornThickness = 0.42 },
		Tail = { Segments = 10, Length = 22, Thickness = 2.0, Taper = 0.12, Droop = 4, Lift = 4, Tip = "Fin" },
		Legs = { Front = true, Back = true, Thickness = 0.8 },
		Wings = { Type = "None" },
		Spines = { Style = "Wedge", Height = 0.7 },
		Features = { "Whiskers", "Mane" },
	},
	Brute = {
		Scale = 1.3, HipHeight = 5.2, BodyRadius = 4.4, Rig = "Quadruped",
		Body = { Length = 7.6, Width = 4.8, Height = 4.4, ChestScale = 1.2, HipScale = 1.0 },
		Neck = { Segments = 3, Length = 4.0, Rise = 22, Curve = 6, Thickness = 2.6, Taper = 0.8 },
		Head = { Size = 1.2, Snout = 0.95, Tilt = -10, Horns = "Ram", HornLength = 1.2, HornThickness = 0.8 },
		Tail = { Segments = 6, Length = 11, Thickness = 3.0, Taper = 0.35, Droop = 10, Lift = -4, Tip = "Club" },
		Legs = { Front = true, Back = true, Thickness = 1.5 },
		Wings = { Type = "Bat", Span = 12, Chord = 5.5 },
		Spines = { Style = "Wedge", Height = 1.2 },
	},
	Sky = {
		Scale = 1.3, HipHeight = 5.0, BodyRadius = 3.5, Rig = "Quadruped",
		Body = { Length = 6.2, Width = 3.2, Height = 3.0, ChestScale = 1.1, HipScale = 0.85 },
		Neck = { Segments = 5, Length = 6.6, Rise = 36, Curve = 5, Thickness = 1.7, Taper = 0.7 },
		Head = { Size = 0.95, Snout = 1.12, Tilt = -4, Horns = "Crown", HornLength = 1.0, HornThickness = 0.45 },
		Tail = { Segments = 9, Length = 18, Thickness = 1.9, Taper = 0.1, Droop = 5, Lift = 6, Tip = "Plume" },
		Legs = { Front = true, Back = true, Thickness = 1.0 },
		Wings = { Type = "Bat", Span = 20, Chord = 8.0 },
		Spines = { Style = "Wedge", Height = 0.7 },
	},
	Royal = {
		Scale = 1.3, HipHeight = 5.4, BodyRadius = 4.2, Rig = "Quadruped",
		Body = { Length = 7.6, Width = 4.2, Height = 3.9, ChestScale = 1.18, HipScale = 0.92 },
		Neck = { Segments = 5, Length = 6.8, Rise = 32, Curve = 6, Thickness = 2.2, Taper = 0.7 },
		Head = { Size = 1.1, Snout = 1.1, Tilt = -6, Horns = "Crown", HornLength = 1.4, HornThickness = 0.6 },
		Tail = { Segments = 8, Length = 17, Thickness = 2.5, Taper = 0.14, Droop = 6, Lift = 0, Tip = "Spade" },
		Legs = { Front = true, Back = true, Thickness = 1.25 },
		Wings = { Type = "Bat", Span = 18, Chord = 7.2 },
		Spines = { Style = "Wedge", Height = 1.0 },
	},
}

-- main, dark, belly, accent, horn, membrane, eye (+ optional extras)
local function pal(main, dark, belly, accent, horn, membrane, eye, extra)
	local p = {
		Main = main, Dark = dark, Belly = belly, Accent = accent, Horn = horn, HornTip = B.DarkGrey,
		Membrane = membrane, Eye = eye, Pupil = B.Black, Claw = B.White, Tooth = C(250, 250, 246),
		Saddle = B.Red, Glow = accent, Crystal = B.LightAqua, Mane = B.White,
	}
	for k, v in extra or {} do
		p[k] = v
	end
	return p
end

local function species(arch: string, name: string, scale: number, palette, over)
	local def = merge(ARCH[arch], over or {})
	def.Name = name
	def.Scale = scale
	def.Arch = arch
	def.Palette = palette
	def.Brick = merge({ HeadScale = 1.25, EyeScale = 1.25, HornScale = 1.6, HornTip = "HornTip", TailTip = "Accent", SpineColor = "Accent" }, def.Brick or {})
	return def
end

local D = Species.Defs
-- Common
D.PebbleDrake = species("Brute", "Pebble Drake", 1.2, pal(B.LightGrey, B.DarkGrey, B.Tan, B.Orange, B.White, B.DarkTan, B.Yellow))
D.EmberPup = species("Drake", "Ember Pup", 1.15, pal(B.Red, B.DarkRed, B.Yellow, B.Orange, B.Yellow, B.Orange, B.Yellow, { Glow = B.Orange }),
	{ Tail = { Tip = "Flame" }, Head = { Horns = "Swept", HornLength = 1.0 } })
D.SproutDrake = species("Wyvern", "Sprout Drake", 1.2, pal(B.Lime, B.Green, B.LightYellow, B.Pink, B.Tan, B.Green, B.Yellow),
	{ Head = { Horns = "Swept", HornLength = 1.0 }, Features = { "Flowers" } })
D.PuddleWyrm = species("Serpent", "Puddle Wyrm", 1.15, pal(B.MediumBlue, B.Blue, B.LightAqua, B.Azure, B.White, B.Azure, B.Yellow),
	{ Head = { Horns = "None" }, Features = { "Whiskers" } })
D.SandScuttler = species("Drake", "Sand Scuttler", 1.2, pal(B.Tan, B.DarkTan, B.LightYellow, B.Orange, B.Brown, B.Orange, B.Black, { Eye = B.Red }),
	{ Body = { Width = 4.2 }, Neck = { Segments = 3, Length = 4.4 } })
-- Uncommon
D.ForestWyvern = species("Wyvern", "Forest Wyvern", 1.35, pal(B.DarkGreen, C(24, 70, 40), B.Lime, B.Brown, B.Brown, B.Green, B.Yellow),
	{ Features = { "Antlers" } })
D.CoralGlider = species("Sky", "Coral Glider", 1.35, pal(B.Coral, B.DarkPink, B.LightYellow, B.Azure, B.White, B.Pink, B.Azure))
D.Thornback = species("Brute", "Thornback", 1.4, pal(B.DarkGreen, B.Black, B.Lime, B.Red, B.White, B.DarkGreen, B.Red),
	{ Spines = { Height = 1.6 }, Features = { "Thorns" } })
D.Frostling = species("Drake", "Frostling", 1.3, pal(B.White, B.LightAqua, B.LightAqua, B.Azure, B.Azure, B.LightAqua, B.Azure, { Crystal = B.Azure }),
	{ Tail = { Tip = "Crystal" }, Head = { Horns = "Crown", HornLength = 0.9 } })
D.SunbeamDrake = species("Sky", "Sunbeam Drake", 1.35, pal(B.Yellow, B.Orange, B.LightYellow, B.Red, B.White, B.Orange, B.Red))
D.NightWyvern = species("Wyvern", "Night Wyvern", 1.4, pal(B.DarkPurple, B.Night, B.Lavender, B.Magenta, B.Lavender, B.MediumLavender, B.Yellow),
	{ Head = { Horns = "Swept" }, Brick = { EarScale = 1.6 }, Features = { "BigEars" } })
-- Rare
D.AquaSerpent = species("Serpent", "Aqua Serpent", 1.45, pal(B.Azure, B.Blue, B.White, B.Teal, B.White, B.Azure, B.Yellow, { Mane = B.White }))
D.CrystalWyvern = species("Wyvern", "Crystal Wyvern", 1.45, pal(B.Lavender, B.MediumLavender, B.White, B.Azure, B.White, B.LightAqua, B.Azure, { Crystal = B.Azure, Glow = B.Azure }),
	{ Tail = { Tip = "Crystal" }, Wings = { Glow = true }, Features = { "Crystals" } })
D.StormHawk = species("Sky", "Storm Hawk", 1.5, pal(B.DarkGrey, B.Black, B.LightGrey, B.Yellow, B.White, B.LightGrey, B.Yellow, { Glow = B.Yellow }),
	{ Wings = { Glow = true } })
D.MagmaBrute = species("Brute", "Magma Brute", 1.55, pal(B.Black, B.DarkGrey, B.Orange, B.Orange, B.DarkGrey, B.DarkRed, B.Yellow, { Glow = B.Orange }),
	{ Features = { "BackFlames" } })
D.JadeSerpent = species("Serpent", "Jade Serpent", 1.5, pal(B.Jade, B.DarkGreen, B.Gold, B.Gold, B.Gold, B.Lime, B.Red, { Mane = B.Gold }))
-- Epic
D.FrostDragon = species("Drake", "Frost Dragon", 1.6, pal(B.White, B.MediumBlue, B.LightAqua, B.Azure, B.Azure, B.LightAqua, B.Azure, { Crystal = B.Azure, Glow = B.Azure }),
	{ Tail = { Tip = "Crystal" }, Head = { Horns = "Long" }, Wings = { Span = 17 }, Features = { "Crystals" } })
D.ThunderDragon = species("Drake", "Thunder Dragon", 1.6, pal(B.Blue, B.DarkBlue, B.Yellow, B.Yellow, B.White, B.MediumBlue, B.Yellow, { Glow = B.Yellow }),
	{ Wings = { Glow = true, Span = 17 }, Head = { Horns = "Long" } })
D.ToxicWyrm = species("Wyvern", "Toxic Wyrm", 1.6, pal(B.Lime, B.DarkPurple, B.Black, B.Magenta, B.Black, B.Lime, B.Lime, { Glow = C(140, 255, 60) }),
	{ Wings = { Glow = true }, Tail = { Tip = "Fin" }, Features = { "Thorns" } })
D.BloodmoonDrake = species("Royal", "Bloodmoon Drake", 1.65, pal(B.DarkRed, B.Black, B.Red, B.LightGrey, B.Black, B.DarkRed, B.Yellow),
	{ Head = { Horns = "Long", HornLength = 1.8 } })
D.SakuraSpirit = species("Serpent", "Sakura Spirit", 1.6, pal(B.Pink, B.DarkPink, B.White, B.White, B.White, B.Pink, B.DarkPink, { Mane = B.White }),
	{ Tail = { Tip = "Plume" }, Features = { "Whiskers", "Mane", "Flowers" } })
-- Legendary
D.InfernoDragon = species("Royal", "Inferno Dragon", 1.8, pal(B.Red, B.Black, B.Orange, B.Yellow, B.Black, B.DarkRed, B.Yellow, { Glow = B.Orange }),
	{ Tail = { Tip = "Flame" }, Features = { "BackFlames" } })
D.GoldenEmperor = species("Royal", "Golden Emperor", 1.85, pal(B.Gold, B.PearlGold, B.White, B.Red, B.White, B.Yellow, B.Red, { Saddle = B.DarkRed }),
	{ Features = { "Crown" }, Brick = { Shine = 0.12 } })
D.AbyssLeviathan = species("Serpent", "Abyss Leviathan", 1.9, pal(B.DarkBlue, B.Night, B.Teal, B.Azure, B.LightAqua, B.Teal, B.Azure, { Glow = B.Azure, Mane = B.Teal }),
	{ Features = { "Whiskers", "Mane", "Stars" } })
D.PhoenixDrake = species("Sky", "Phoenix Drake", 1.85, pal(B.Orange, B.Red, B.Yellow, B.Yellow, B.Yellow, B.Orange, B.Red, { Glow = B.Yellow }),
	{ Wings = { Glow = true }, Tail = { Tip = "Flame" }, Features = { "BackFlames" } })
-- Mythic
D.CelestialDragon = species("Sky", "Celestial Dragon", 2.0, pal(B.White, B.LightAqua, B.Gold, B.Gold, B.Gold, B.LightAqua, B.Azure, { Glow = B.White }),
	{ Wings = { Glow = true }, Features = { "Halo", "Mane" } })
D.GalaxyDragon = species("Royal", "Galaxy Dragon", 2.0, pal(B.DarkPurple, B.Night, B.MediumLavender, B.Azure, B.White, B.DarkPurple, B.Azure, { Glow = B.Azure }),
	{ Wings = { Glow = true }, Features = { "Stars" } })
-- Secret
D.VoidDragon = species("Royal", "Void Dragon", 2.15, pal(B.Night, C(10, 10, 16), B.DarkPurple, B.Magenta, B.Black, C(40, 10, 60), B.Magenta, { Glow = B.Magenta }),
	{ Wings = { Glow = true }, Head = { Horns = "Long", HornLength = 1.9 }, Features = { "Crystals", "Stars" } })
D.EternalDragon = species("Royal", "Eternal Dragon", 2.25, pal(B.White, B.Gold, B.Gold, B.Azure, B.Gold, B.LightAqua, B.Azure, { Glow = B.Gold }),
	{ Wings = { Glow = true }, Features = { "Halo", "Crown", "Mane" } })

-- Exclusive (Robux)
D.OwnerDragon = species("Royal", "Owner Dragon", 2.3, pal(C(24, 24, 30), C(8, 8, 12), B.Gold, B.Red, B.Gold, C(150, 20, 30), B.Red,
	{ Glow = C(255, 60, 40), Saddle = B.Gold, Mane = B.Gold, Crystal = C(255, 90, 90), HornTip = B.Red }),
	{ Wings = { Glow = true, Span = 20 }, Head = { Horns = "Long", HornLength = 2.0 }, Tail = { Tip = "Flame" },
		Features = { "Crown", "BackFlames", "Aura" }, Brick = { Shine = 0.15 } })

D.N2RC1SDragon = species("Royal", "N2RC1S", 2.5, pal(C(44, 22, 78), C(14, 8, 30), B.Azure, C(255, 60, 200), B.White, C(96, 34, 170), B.Azure,
	{ Glow = C(255, 70, 210), Saddle = C(14, 8, 30), Crystal = B.Azure, Mane = B.Azure, HornTip = C(255, 60, 200) }),
	{ Wings = { Glow = true, Span = 21 }, Head = { Horns = "Long", HornLength = 2.1 }, Tail = { Tip = "Crystal" },
		Features = { "Crown", "Crystals", "Stars", "Aura" }, Brick = { Shine = 0.12 } })
D.PrinceDragon = species("Royal", "PRINCE", 2.5, pal(B.White, C(32, 58, 140), B.Gold, B.Gold, B.Gold, C(120, 180, 255), C(40, 120, 255),
	{ Glow = C(255, 220, 90), Saddle = C(32, 58, 140), Mane = B.Gold, HornTip = B.Gold }),
	{ Wings = { Glow = true, Span = 21 }, Head = { Horns = "Crown", HornLength = 1.6 }, Tail = { Tip = "Plume" },
		Features = { "Crown", "Halo", "Mane", "Aura" }, Brick = { Shine = 0.14 } })

function Species.get(id: string)
	return Species.Defs[id] or Species.Defs.GreenDrake
end

local function lerp(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, t)
end

-- Mutation palettes keep the species' contrast structure but shift tones.
-- Effects beyond colour (glow, sparkles, fire...) are added by BrickBuilder.
local function shift(v: Color3, dh: number, ks: number, kv: number): Color3
	local h, sat, val = v:ToHSV()
	return Color3.fromHSV((h + dh) % 1, math.clamp(sat * ks, 0, 1), math.clamp(val * kv, 0, 1))
end

local MUTATION_PALETTES = {
	Golden = { Main = C(222, 186, 76), Dark = C(170, 127, 46), Belly = C(255, 236, 160), Membrane = C(245, 205, 47), Horn = C(255, 248, 220), Accent = C(255, 220, 120), Eye = C(255, 255, 230), Saddle = C(123, 46, 47) },
	Frost = { Main = C(173, 221, 237), Dark = C(110, 153, 202), Belly = C(242, 243, 242), Membrane = C(205, 236, 250), Horn = C(242, 243, 242), Accent = C(66, 192, 251), Eye = C(66, 192, 251), Glow = C(150, 225, 255) },
	Toxic = { Main = C(120, 200, 60), Dark = C(52, 43, 117), Belly = C(190, 255, 120), Membrane = C(140, 230, 80), Horn = C(52, 43, 117), Accent = C(200, 60, 200), Eye = C(170, 255, 80), Glow = C(150, 255, 60) },
	Lava = { Main = C(40, 30, 30), Dark = C(18, 14, 14), Belly = C(255, 120, 30), Membrane = C(123, 30, 20), Horn = C(60, 50, 50), Accent = C(255, 110, 20), Eye = C(255, 220, 60), Glow = C(255, 120, 30) },
	Shadow = { Main = C(46, 34, 72), Dark = C(18, 14, 30), Belly = C(120, 80, 170), Membrane = C(70, 40, 110), Horn = C(150, 110, 220), Accent = C(170, 60, 255), Eye = C(200, 90, 255), Glow = C(170, 60, 255) },
	Diamond = { Main = C(214, 242, 255), Dark = C(150, 210, 240), Belly = C(250, 252, 255), Membrane = C(225, 248, 255), Horn = C(255, 255, 255), Accent = C(120, 220, 255), Eye = C(80, 200, 255), Glow = C(200, 245, 255) },
	Galaxy = { Main = C(30, 30, 80), Dark = C(14, 12, 40), Belly = C(90, 60, 170), Membrane = C(60, 40, 140), Horn = C(220, 220, 255), Accent = C(66, 192, 251), Eye = C(255, 255, 255), Glow = C(120, 200, 255) },
	Void = { Main = C(16, 14, 22), Dark = C(4, 4, 8), Belly = C(50, 10, 70), Membrane = C(26, 8, 40), Horn = C(242, 243, 242), Accent = C(255, 255, 255), Eye = C(255, 255, 255), Glow = C(230, 200, 255) },
	Rainbow = { Main = C(255, 120, 170), Dark = C(120, 90, 255), Belly = C(255, 250, 220), Membrane = C(120, 220, 255), Horn = C(255, 255, 255), Accent = C(255, 220, 60), Eye = C(255, 255, 255) },
}

function Species.mutatePalette(p, mutation: string)
	local out = table.clone(p)
	if mutation == "Shiny" then
		for k, v in p do
			if k ~= "Pupil" and typeof(v) == "Color3" then
				out[k] = shift(v, 0.035, 0.9, 1.22)
			end
		end
		out.Eye = C(140, 240, 255)
		return out
	end
	local over = MUTATION_PALETTES[mutation]
	if over then
		for k, v in over do
			out[k] = v
		end
	end
	return out
end

function Species.statuePalette(color: Color3?)
	local base = color or C(176, 170, 158)
	return {
		Main = base,
		Dark = lerp(base, C(0, 0, 0), 0.18),
		Belly = lerp(base, C(255, 255, 255), 0.12),
		Horn = lerp(base, C(255, 255, 255), 0.2),
		Membrane = lerp(base, C(0, 0, 0), 0.08),
		Accent = base,
		Eye = lerp(base, C(255, 220, 140), 0.4),
		Pupil = lerp(base, C(0, 0, 0), 0.4),
		Claw = lerp(base, C(0, 0, 0), 0.25),
		Tooth = lerp(base, C(255, 255, 255), 0.3),
		Saddle = base,
		Glow = lerp(base, C(255, 230, 160), 0.5),
		Crystal = lerp(base, C(255, 255, 255), 0.2),
	}
end

-- Unique feature builders (filled in with the other species).
Species.FeatureBuilders = {}

return Species

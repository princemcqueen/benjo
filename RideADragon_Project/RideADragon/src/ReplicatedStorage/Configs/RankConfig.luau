--[[
	RankConfig
	Five ranks. A rank is a TITLE that the game owner hands out with the chat command
	  /rank <player|me> <rank|none>        (see RankService / AdminModule)
	It shows as a coloured tag over the character, as a coloured [TITLE] in chat and in /ranks.

	  Level  Title      Epithet                 Powers
	  1      VIP        Friend of the Dragons   (tag + chat colour)
	  2      MOD        Keeper of the Peace     (tag + chat colour)
	  3      ADMIN      Warden of the Realm     (tag + chat colour)
	  4      CO-OWNER   Dragon Lord             /rank (up to ADMIN) and /give
	  5      OWNER      Dragon King             everything: /rank up to OWNER, /give
	The real owner (AdminConfig: usernames / user ids / the experience creator, and everybody inside
	Roblox Studio) always has the OWNER powers, even without the tag.
]]

local RankConfig = {}

-- Level = the number you can type in the command (/rank Name 3).
RankConfig.Ranks = {
	{ Level = 1, Id = "Vip", Title = "VIP", Epithet = "Friend of the Dragons", Color = Color3.fromRGB(255, 214, 90), Aliases = { "vip" } },
	{ Level = 2, Id = "Mod", Title = "MOD", Epithet = "Keeper of the Peace", Color = Color3.fromRGB(77, 163, 255), Aliases = { "mod", "moderator" } },
	{ Level = 3, Id = "Admin", Title = "ADMIN", Epithet = "Warden of the Realm", Color = Color3.fromRGB(255, 150, 60), Aliases = { "admin", "administrator" } },
	{ Level = 4, Id = "CoOwner", Title = "CO-OWNER", Epithet = "Dragon Lord", Color = Color3.fromRGB(190, 110, 255), Aliases = { "coowner", "co-owner", "co owner", "lord", "dragonlord" } },
	{ Level = 5, Id = "Owner", Title = "OWNER", Epithet = "Dragon King", Color = Color3.fromRGB(255, 70, 80), Aliases = { "owner", "king", "dragonking" } },
}

RankConfig.MaxLevel = #RankConfig.Ranks
RankConfig.CommandLevel = 4 -- /rank may be used from this rank up (and hands out ranks below its own)
RankConfig.GiveLevel = 4 -- /give may be used from this rank up
RankConfig.NoneWords = { "none", "remove", "clear", "off", "0", "player", "default" }

RankConfig.ByLevel = {}
RankConfig.ByAlias = {}
for _, r in RankConfig.Ranks do
	RankConfig.ByLevel[r.Level] = r
	RankConfig.ByAlias[string.lower(r.Id)] = r
	RankConfig.ByAlias[string.lower(r.Title)] = r
	RankConfig.ByAlias[tostring(r.Level)] = r
	for _, a in r.Aliases do
		RankConfig.ByAlias[a] = r
	end
end

-- "co-owner", "Co Owner", "3", "admin" -> the rank (or nil); NoneWords -> 0 (no rank).
function RankConfig.parse(text: string): (any?, boolean)
	local key = string.lower((tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")))
	for _, w in RankConfig.NoneWords do
		if key == w then
			return nil, true
		end
	end
	local r = RankConfig.ByAlias[key] or RankConfig.ByAlias[(key:gsub("[%s_%-]+", ""))]
	return r, false
end

function RankConfig.hex(color: Color3): string
	return string.format("%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

return table.freeze(RankConfig)

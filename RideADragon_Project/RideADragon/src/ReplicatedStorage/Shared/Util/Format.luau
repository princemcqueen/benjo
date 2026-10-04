--[[
	Format
	Number/cash/time formatting used by every UI surface so values look the
	same everywhere ($97.49M, 2.4M, 1 in 500,000, 4m 32s).
]]

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function trimZeros(s: string): string
	if string.find(s, "%.") then
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
	end
	return s
end

-- Abbreviates with at most 2 decimals. Values are floored so a player is
-- never shown more than they actually have.
function Format.abbreviate(n: number, maxDecimals: number?): string
	if n ~= n then
		return "0"
	end
	local decimals = maxDecimals or 2
	local negative = n < 0
	n = math.abs(n)
	local result
	if n < 1000 then
		if n == math.floor(n) then
			result = tostring(math.floor(n))
		else
			result = trimZeros(string.format("%.1f", math.floor(n * 10) / 10))
		end
	else
		local tier = math.min(math.floor(math.log10(n) / 3), #SUFFIXES - 1)
		local scaled = n / 10 ^ (tier * 3)
		local factor = 10 ^ decimals
		scaled = math.floor(scaled * factor + 1e-7) / factor
		if scaled >= 1000 and tier < #SUFFIXES - 1 then
			tier += 1
			scaled = math.floor(n / 10 ^ (tier * 3) * factor + 1e-7) / factor
		end
		result = trimZeros(string.format("%." .. decimals .. "f", scaled)) .. SUFFIXES[tier + 1]
	end
	return (negative and "-" or "") .. result
end

function Format.cash(n: number): string
	if n < 0 then
		return "-$" .. Format.abbreviate(-n)
	end
	return "$" .. Format.abbreviate(n)
end

function Format.perSecond(n: number): string
	return Format.cash(n) .. "/s"
end

function Format.commas(n: number): string
	local negative = n < 0
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local out = s
	while true do
		local replaced, count = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
		out = replaced
		if count == 0 then
			break
		end
	end
	return (negative and "-" or "") .. out
end

-- "1 in 500,000" from a probability in [0, 1].
function Format.odds(p: number): string
	if p <= 0 then
		return "1 in ∞"
	end
	if p >= 0.5 then
		return string.format("%d%%", math.floor(p * 100 + 0.5))
	end
	local inv = 1 / p
	if inv < 10 then
		return "1 in " .. trimZeros(string.format("%.1f", inv))
	end
	return "1 in " .. Format.commas(inv)
end

function Format.percent(p: number): string
	local v = p * 100
	if v >= 10 then
		return string.format("%d%%", math.floor(v + 0.5))
	elseif v >= 1 then
		return trimZeros(string.format("%.1f", v)) .. "%"
	elseif v >= 0.01 then
		return trimZeros(string.format("%.2f", v)) .. "%"
	end
	return trimZeros(string.format("%.4f", v)) .. "%"
end

function Format.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = math.floor(seconds / 3600)
	local m = math.floor(seconds % 3600 / 60)
	local s = seconds % 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	elseif m > 0 then
		return string.format("%dm %02ds", m, s)
	end
	return string.format("%ds", s)
end

-- 1 stud ~= 0.28 m
function Format.kmh(studsPerSecond: number): number
	return math.floor(studsPerSecond * 0.28 * 3.6 + 0.5)
end

function Format.level(level: number): string
	return "LV " .. tostring(math.floor(level))
end

return Format

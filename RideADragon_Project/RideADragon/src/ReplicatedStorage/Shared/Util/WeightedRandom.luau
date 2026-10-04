--[[
	WeightedRandom
	pick(entries, rng) where entries = { { Id = any, Weight = number }, ... }
]]

local WeightedRandom = {}

function WeightedRandom.total(entries: { { Weight: number } }): number
	local sum = 0
	for _, e in entries do
		sum += math.max(0, e.Weight)
	end
	return sum
end

function WeightedRandom.pick<T>(entries: { T }, rng: Random): T
	local total = WeightedRandom.total(entries :: any)
	assert(total > 0, "WeightedRandom.pick: total weight must be > 0")
	local roll = rng:NextNumber(0, total)
	local acc = 0
	for _, e in entries do
		acc += math.max(0, (e :: any).Weight)
		if roll < acc then
			return e
		end
	end
	return entries[#entries]
end

return WeightedRandom

--[[
	TableUtil
]]

local TableUtil = {}

function TableUtil.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[TableUtil.deepCopy(k)] = TableUtil.deepCopy(v)
	end
	return (out :: any) :: T
end

function TableUtil.shallowCopy<T>(t: T): T
	return table.clone(t :: any) :: any
end

-- Fills keys missing from `target` with deep copies from `template`.
function TableUtil.reconcile(target: { [any]: any }, template: { [any]: any })
	for key, value in template do
		if target[key] == nil then
			target[key] = TableUtil.deepCopy(value)
		elseif type(value) == "table" and type(target[key]) == "table" and next(value) ~= nil and #value == 0 then
			TableUtil.reconcile(target[key], value)
		end
	end
	return target
end

function TableUtil.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

function TableUtil.keys(t: { [any]: any }): { any }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	return out
end

function TableUtil.values(t: { [any]: any }): { any }
	local out = {}
	for _, v in t do
		table.insert(out, v)
	end
	return out
end

function TableUtil.filter<T>(list: { T }, predicate: (T) -> boolean): { T }
	local out = {}
	for _, v in list do
		if predicate(v) then
			table.insert(out, v)
		end
	end
	return out
end

function TableUtil.map<T, U>(list: { T }, fn: (T) -> U): { U }
	local out = {}
	for i, v in list do
		out[i] = fn(v)
	end
	return out
end

function TableUtil.findWhere<T>(list: { T }, predicate: (T) -> boolean): T?
	for _, v in list do
		if predicate(v) then
			return v
		end
	end
	return nil
end

return TableUtil

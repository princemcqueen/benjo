--[[
	Trove
	Collects cleanup tasks (connections, instances, functions, objects with
	Destroy/Disconnect) and releases them all at once. Prevents leaks.
]]

local Trove = {}
Trove.__index = Trove

function Trove.new()
	return setmetatable({ _items = {} }, Trove)
end

function Trove:Add<T>(item: T): T
	table.insert(self._items, item)
	return item
end

function Trove:Connect(signal: any, fn: (...any) -> ())
	return self:Add(signal:Connect(fn))
end

local function cleanup(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		pcall(task.cancel, item)
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

function Trove:Remove(item: any)
	local index = table.find(self._items, item)
	if index then
		table.remove(self._items, index)
		cleanup(item)
	end
end

function Trove:Clean()
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		cleanup(items[i])
	end
end
Trove.Destroy = Trove.Clean

return Trove

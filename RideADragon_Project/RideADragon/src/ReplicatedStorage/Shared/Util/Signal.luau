--[[
	Signal
	Lightweight script signal. Handlers run via task.spawn so one failing
	handler can never break the code that fired the signal.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local handlers = self._signal._handlers
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
end
Connection.Destroy = Connection.Disconnect

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn: (...any) -> ())
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local connection = setmetatable({ Connected = true, _signal = self, _fn = fn }, Connection)
	table.insert(self._handlers, connection)
	return connection
end

function Signal:Once(fn: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Snapshot so handlers can connect/disconnect while firing.
	local snapshot = table.clone(self._handlers)
	for _, connection in snapshot do
		if connection.Connected then
			task.spawn(connection._fn, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, connection in table.clone(self._handlers) do
		connection.Connected = false
	end
	table.clear(self._handlers)
end
Signal.Destroy = Signal.DisconnectAll

return Signal

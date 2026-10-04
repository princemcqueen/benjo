--[[
	DataController
	Read-only client mirror of the player's server data.

	Data.get("Cash"), Data.getPath({"Upgrades","Radar"})
	Data.observe("Cash", fn)        -- fires now and on every change of that key
	Data.changed(key) -> Signal     -- (path, value) for any change under key
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local DataSync: RemoteEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DataSync")

local DataController = {}
DataController.Ready = false
DataController.ReadySignal = Signal.new()
DataController.AnyChanged = Signal.new() -- (path, value)
DataController.Temporary = false

local data = nil
local keySignals: { [string]: any } = {}

local function signalFor(key: string)
	local s = keySignals[key]
	if not s then
		s = Signal.new()
		keySignals[key] = s
	end
	return s
end

local function applySet(path: { string }, value: any)
	local node = data
	for i = 1, #path - 1 do
		local nxt = node[path[i]]
		if type(nxt) ~= "table" then
			nxt = {}
			node[path[i]] = nxt
		end
		node = nxt
	end
	node[path[#path]] = value
end

function DataController.get(key: string)
	return data and data[key]
end

function DataController.getPath(path: { string })
	local node = data
	for _, k in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[k]
	end
	return node
end

function DataController.all()
	return data
end

function DataController.changed(key: string)
	return signalFor(key)
end

-- Calls fn(value) immediately (once ready) and whenever `key` changes.
function DataController.observe(key: string, fn: (any) -> ())
	local conn = signalFor(key):Connect(function()
		fn(data[key])
	end)
	if DataController.Ready then
		task.spawn(fn, data[key])
	else
		DataController.ReadySignal:Once(function()
			fn(data[key])
		end)
	end
	return conn
end

function DataController.waitUntilReady()
	if not DataController.Ready then
		DataController.ReadySignal:Wait()
	end
	return data
end

function DataController.Init()
	DataSync.OnClientEvent:Connect(function(kind: string, a: any, b: any)
		if kind == "Init" then
			data = a
			DataController.Temporary = type(b) == "table" and b.Temporary == true
			local first = not DataController.Ready
			DataController.Ready = true
			if first then
				DataController.ReadySignal:Fire(data)
			end
			for key in data do
				signalFor(key):Fire({ key }, data[key])
			end
		elseif kind == "Batch" and data then
			local touched = {}
			for _, change in a do
				local path, value = change[1], change[2]
				applySet(path, value)
				local key = path[1]
				touched[key] = touched[key] or {}
				table.insert(touched[key], change)
			end
			for key, changes in touched do
				for _, change in changes do
					signalFor(key):Fire(change[1], change[2])
					DataController.AnyChanged:Fire(change[1], change[2])
				end
			end
		end
	end)
end

return DataController

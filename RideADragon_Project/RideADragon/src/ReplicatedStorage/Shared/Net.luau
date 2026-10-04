--[[
	Net
	Single networking layer for the whole game.

	Client -> Server:  Net.request(domain, action, payload) -> { ok, err, msg, data }
	                   Net.fire(eventName, payload)          (low-frequency state events)
	Server -> Client:  Net.notify(player, kind, text, extra)
	                   Net.signal(player, name, payload) / Net.broadcast(name, payload)
	                   DataSync is handled by PlayerDataService.

	Server handlers are registered with Net.handle(domain, action, fn, rate).
	Every request is type-checked, rate limited and pcall-protected.
	RemoteEvents are never used for per-frame data.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestRemote: RemoteFunction = Remotes:WaitForChild("Request")
local NotifyRemote: RemoteEvent = Remotes:WaitForChild("Notify")
local SignalRemote: RemoteEvent = Remotes:WaitForChild("Signal")
local ClientEventRemote: RemoteEvent = Remotes:WaitForChild("ClientEvent")

local Net = {}

local MAX_KEY_LENGTH = 40

-- ============================================================== validation helpers
Net.check = {}

function Net.check.str(v: any, maxLen: number?): boolean
	return type(v) == "string" and #v > 0 and #v <= (maxLen or 64)
end

function Net.check.num(v: any, min: number?, max: number?): boolean
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return false
	end
	if min and v < min then
		return false
	end
	if max and v > max then
		return false
	end
	return true
end

function Net.check.int(v: any, min: number?, max: number?): boolean
	return Net.check.num(v, min, max) and math.floor(v) == v
end

function Net.check.bool(v: any): boolean
	return type(v) == "boolean"
end

-- ============================================================== server
if IS_SERVER then
	local Players = game:GetService("Players")

	local handlers = {}
	local eventHandlers = {}
	local buckets = {} -- [player][key] = { tokens, last }

	local DEFAULT_RATE = { Burst = 8, PerSecond = 4 }

	local function allow(player: Player, key: string, rate): boolean
		local pb = buckets[player]
		if not pb then
			pb = {}
			buckets[player] = pb
		end
		local now = os.clock()
		local b = pb[key]
		if not b then
			b = { tokens = rate.Burst, last = now }
			pb[key] = b
		end
		b.tokens = math.min(rate.Burst, b.tokens + (now - b.last) * rate.PerSecond)
		b.last = now
		if b.tokens < 1 then
			return false
		end
		b.tokens -= 1
		return true
	end

	-- fn(player, payload) -> (ok: boolean, errOrData: any?, msg: string?)
	function Net.handle(domain: string, action: string, fn, rate)
		local key = domain .. "." .. action
		assert(handlers[key] == nil, "Duplicate Net handler " .. key)
		handlers[key] = { fn = fn, rate = rate or DEFAULT_RATE }
	end

	-- fn(player, payload)
	function Net.onEvent(name: string, fn, rate)
		assert(eventHandlers[name] == nil, "Duplicate Net event " .. name)
		eventHandlers[name] = { fn = fn, rate = rate or DEFAULT_RATE }
	end

	function Net.notify(player: Player, kind: string, text: string, extra: { [string]: any }?)
		NotifyRemote:FireClient(player, kind, text, extra)
	end

	function Net.notifyAll(kind: string, text: string, extra: { [string]: any }?)
		NotifyRemote:FireAllClients(kind, text, extra)
	end

	function Net.signal(player: Player, name: string, payload: any)
		SignalRemote:FireClient(player, name, payload)
	end

	function Net.broadcast(name: string, payload: any)
		SignalRemote:FireAllClients(name, payload)
	end

	local function fail(err: string, msg: string?)
		return { ok = false, err = err, msg = msg }
	end

	function Net.start()
		RequestRemote.OnServerInvoke = function(player: Player, domain: any, action: any, payload: any)
			if type(domain) ~= "string" or type(action) ~= "string" or #domain > MAX_KEY_LENGTH or #action > MAX_KEY_LENGTH then
				return fail("BAD_REQUEST")
			end
			if payload ~= nil and type(payload) ~= "table" then
				return fail("BAD_REQUEST")
			end
			local key = domain .. "." .. action
			local h = handlers[key]
			if not h then
				return fail("UNKNOWN_ACTION")
			end
			if not allow(player, key, h.rate) then
				return fail("RATE_LIMITED", "Slow down!")
			end
			local okCall, ok, data, msg = pcall(h.fn, player, payload or {})
			if not okCall then
				warn(string.format("[Net] %s failed for %s: %s", key, player.Name, tostring(ok)))
				return fail("SERVER_ERROR", "Something went wrong. Try again.")
			end
			if ok then
				return { ok = true, data = data }
			end
			return fail(tostring(data or "FAILED"), msg)
		end

		ClientEventRemote.OnServerEvent:Connect(function(player: Player, name: any, payload: any)
			if type(name) ~= "string" or #name > MAX_KEY_LENGTH then
				return
			end
			if payload ~= nil and type(payload) ~= "table" then
				return
			end
			local h = eventHandlers[name]
			if not h or not allow(player, "evt." .. name, h.rate) then
				return
			end
			local ok, err = pcall(h.fn, player, payload or {})
			if not ok then
				warn(string.format("[Net] event %s failed for %s: %s", name, player.Name, tostring(err)))
			end
		end)

		Players.PlayerRemoving:Connect(function(player)
			buckets[player] = nil
		end)
	end
else
	-- ========================================================== client
	local Signal = require(script.Parent:WaitForChild("Util"):WaitForChild("Signal"))

	local signalListeners = {}
	Net.Notified = Signal.new()

	function Net.request(domain: string, action: string, payload: { [string]: any }?)
		local ok, result = pcall(RequestRemote.InvokeServer, RequestRemote, domain, action, payload)
		if not ok then
			return { ok = false, err = "NETWORK", msg = "Connection problem. Try again." }
		end
		if type(result) ~= "table" then
			return { ok = false, err = "BAD_RESPONSE" }
		end
		return result
	end

	function Net.fire(name: string, payload: { [string]: any }?)
		ClientEventRemote:FireServer(name, payload)
	end

	function Net.onSignal(name: string, fn)
		local list = signalListeners[name]
		if not list then
			list = {}
			signalListeners[name] = list
		end
		table.insert(list, fn)
		return function()
			local i = table.find(list, fn)
			if i then
				table.remove(list, i)
			end
		end
	end

	SignalRemote.OnClientEvent:Connect(function(name, payload)
		local list = signalListeners[name]
		if list then
			for _, fn in table.clone(list) do
				task.spawn(fn, payload)
			end
		end
	end)

	NotifyRemote.OnClientEvent:Connect(function(kind, text, extra)
		Net.Notified:Fire(kind, text, extra)
	end)
end

return Net

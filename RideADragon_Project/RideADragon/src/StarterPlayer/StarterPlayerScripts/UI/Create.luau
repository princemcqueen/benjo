--[[
	Create
	Declarative Instance builder.

	Create("Frame", {
		Size = UDim2.fromScale(1, 1),
		[Create.Event.Activated] = function() ... end,
		[Create.Changed.AbsoluteSize] = function() ... end,
	}, { child1, child2 })
]]

local Create = {}

local eventKeys = {}
local changedKeys = {}

Create.Event = setmetatable({}, {
	__index = function(_, name)
		local key = eventKeys[name]
		if not key then
			key = { __kind = "event", name = name }
			eventKeys[name] = key
		end
		return key
	end,
})

Create.Changed = setmetatable({}, {
	__index = function(_, name)
		local key = changedKeys[name]
		if not key then
			key = { __kind = "changed", name = name }
			changedKeys[name] = key
		end
		return key
	end,
})

local function build(className: string, props: { [any]: any }?, children: { Instance }?)
	local inst = Instance.new(className)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			elseif type(k) == "table" then
				if k.__kind == "event" then
					(inst :: any)[k.name]:Connect(v)
				elseif k.__kind == "changed" then
					inst:GetPropertyChangedSignal(k.name):Connect(v)
				end
			else
				(inst :: any)[k] = v
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

setmetatable(Create, {
	__call = function(_, className, props, children)
		return build(className, props, children)
	end,
})

return Create

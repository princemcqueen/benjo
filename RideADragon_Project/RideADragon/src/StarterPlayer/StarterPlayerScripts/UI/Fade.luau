--[[
	Fade
	Opacity fade for a whole GUI subtree without CanvasGroup (CanvasGroups
	cannot host ViewportFrames reliably). Captures each element's own
	transparency values, then drives them by a single alpha.

	local state = Fade.capture(root)
	Fade.apply(state, 0.5)   -- 0 = invisible, 1 = original look
	Fade.restore(state)
]]

local Fade = {}

local PROPS = {
	Frame = { "BackgroundTransparency" },
	TextLabel = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	TextButton = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" },
	TextBox = { "BackgroundTransparency", "TextTransparency" },
	ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
	ImageButton = { "BackgroundTransparency", "ImageTransparency" },
	ViewportFrame = { "BackgroundTransparency", "ImageTransparency" },
	ScrollingFrame = { "BackgroundTransparency", "ScrollBarImageTransparency" },
	UIStroke = { "Transparency" },
}

function Fade.capture(root: Instance)
	local entries = {}
	local function add(inst: Instance)
		local props = PROPS[inst.ClassName]
		if props then
			for _, prop in props do
				local base = (inst :: any)[prop]
				if base < 1 then
					table.insert(entries, { inst, prop, base })
				end
			end
		end
	end
	add(root)
	for _, d in root:GetDescendants() do
		add(d)
	end
	return { entries = entries }
end

function Fade.apply(state, alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	for _, e in state.entries do
		local inst = e[1]
		if inst.Parent then
			(inst :: any)[e[2]] = 1 - (1 - e[3]) * alpha
		end
	end
end

function Fade.restore(state)
	Fade.apply(state, 1)
end

return Fade

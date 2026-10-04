--[[
	PromptGate
	World prompts (ProximityPrompt: the "E / F" bubbles) are switched off while something else
	owns the screen: riding a dragon, the hatch cinematic... Several reasons can be active at
	once; the prompts come back only when the last one is released.

	  PromptGate.set(reason, on)   on = true hides the prompts for that reason, false releases it
	  PromptGate.hidden()          true while any reason is active
]]

local ProximityPromptService = game:GetService("ProximityPromptService")

local PromptGate = {}

local reasons: { [string]: boolean } = {}

local function apply()
	ProximityPromptService.Enabled = next(reasons) == nil
end

function PromptGate.set(reason: string, on: boolean)
	reasons[reason] = on or nil
	apply()
end

function PromptGate.hidden(): boolean
	return next(reasons) ~= nil
end

return PromptGate

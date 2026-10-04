--[[
	InteractionController
	World interactions through ProximityPrompts:
	  * station prompts (attributes Window, Tab, Station) open UI windows
	  * prompts are hidden while riding (the dragon keys take over)
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")

local InteractionController = {}

local registry
local LocalPlayer = Players.LocalPlayer

local COMING_SOON = {
	Shop = "The Dragon Market opens soon!",
	Index = "The Hall of Dragons is being prepared.",
	Quests = "Elder Rowan will have tasks for you soon.",
}

local function onTriggered(prompt: ProximityPrompt, player: Player)
	if player ~= LocalPlayer then
		return
	end
	local window = prompt:GetAttribute("Window")
	if type(window) ~= "string" then
		return
	end
	local uic = registry.UIController
	if not uic then
		return
	end
	if (uic.Windows and uic.Windows[window]) or (uic.WindowModules and uic.WindowModules[window]) then
		uic.Open(window, { Tab = prompt:GetAttribute("Tab"), Station = prompt:GetAttribute("Station") })
	else
		uic.Notify("info", COMING_SOON[window] or "Coming soon!")
	end
end

function InteractionController.Init(reg)
	registry = reg
end

function InteractionController.Start()
	ProximityPromptService.PromptTriggered:Connect(onTriggered)
	-- hide world prompts while riding a dragon
	local function update()
		local riding = LocalPlayer:GetAttribute("Riding") == true
		ProximityPromptService.Enabled = not riding
	end
	LocalPlayer:GetAttributeChangedSignal("Riding"):Connect(update)
	update()
end

return InteractionController

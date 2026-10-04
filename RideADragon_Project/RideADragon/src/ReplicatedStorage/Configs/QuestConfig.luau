--[[
	QuestConfig
	First-time tutorial steps and repeatable quest templates.
]]

local QuestConfig = {}

-- Tutorial: Step index -> definition. The server advances steps when the
-- matching event happens (see QuestService). Target kinds drive waypoints.
QuestConfig.Tutorial = {
	{ Id = "Ride", Text = "RIDE YOUR DRAGON", Hint = "Press R or tap RIDE", Target = "None" },
	{ Id = "ReachEgg", Text = "FLY TO THE GLOWING EGG", Hint = "SPACE to take off, SHIFT to boost", Target = "TutorialEgg" },
	{ Id = "PickUpEgg", Text = "PICK UP THE EGG", Hint = "Hold E near the egg", Target = "TutorialEgg" },
	{ Id = "ReturnHome", Text = "RETURN TO YOUR SANCTUARY", Hint = "Follow the marker", Target = "Sanctuary" },
	{ Id = "PlaceEgg", Text = "PLACE THE EGG IN A NEST", Hint = "Hold E at an empty nest", Target = "Nest" },
	{ Id = "Hatch", Text = "WATCH YOUR EGG HATCH", Hint = "", Target = "None" },
	{ Id = "EquipNew", Text = "EQUIP YOUR NEW DRAGON", Hint = "Open DRAGONS (G) and press EQUIP", Target = "None" },
	{ Id = "PlaceDragon", Text = "PLACE A DRAGON TO EARN CASH", Hint = "Select a dragon and press PLACE", Target = "None", Reward = 650 },
	{ Id = "BuyUpgrade", Text = "BUY YOUR FIRST UPGRADE", Hint = "Open the SHOP (B)", Target = "None", Reward = 250 },
}

QuestConfig.ActiveCount = 3

-- Repeatable quests. Goal/Reward scale with player level.
QuestConfig.Templates = {
	FindEggs = { Text = "Find %d eggs", Goal = 3, GoalPerLevel = 0.25, Reward = 300, Stat = "EggsFound" },
	HatchDragons = { Text = "Hatch %d dragons", Goal = 2, GoalPerLevel = 0.2, Reward = 450, Stat = "Hatched" },
	FlyDistance = { Text = "Fly %s studs", Goal = 6000, GoalPerLevel = 900, Reward = 350, Stat = "DistanceFlown", Big = true },
	CollectIncome = { Text = "Collect %s from your sanctuary", Goal = 1500, GoalPerLevel = 1.0, Reward = 400, Stat = "Collected", Cash = true, Scales = true },
	FeedDragons = { Text = "Feed dragons %d times", Goal = 3, GoalPerLevel = 0.15, Reward = 300, Stat = "Fed" },
	BoostTime = { Text = "Boost for %d seconds", Goal = 30, GoalPerLevel = 2, Reward = 250, Stat = "BoostSeconds" },
}

QuestConfig.TemplateOrder = { "FindEggs", "HatchDragons", "FlyDistance", "CollectIncome", "FeedDragons", "BoostTime" }

return table.freeze(QuestConfig)

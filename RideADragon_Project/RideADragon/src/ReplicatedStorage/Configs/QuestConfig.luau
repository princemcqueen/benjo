--[[
	QuestConfig
	Elder Rowan's quests (QuestService / QuestsWindow, the QUESTS button, key Q).

	  * GETTING STARTED: a short list of first goals for a new player (each pays once). Done = a fact
	    about the player's data (Stats / perches / upgrades), nothing has to be "armed" first.
	  * ACTIVE QUESTS: always QuestConfig.ActiveCount repeatable quests picked from Templates. A quest counts
	    from the moment it is given (Stat now - Stat when given). Take the reward and a new one appears.
	    Goals and rewards grow with the player level and income. Every 3rd quest also pays a free spin.
]]

local QuestConfig = {}

QuestConfig.ActiveCount = 3
QuestConfig.SpinEvery = 3 -- every this many completed quests: +1 spin ticket

-- Cash reward = the template's Reward grown by the level, but at least this many seconds of income.
QuestConfig.RewardPerLevel = 0.35
QuestConfig.RewardIncomeSeconds = 150
QuestConfig.XPBase = 40 -- player XP of a quest, +5% per level
QuestConfig.XPPerLevel = 0.05

-- Repeatable quests. Goal = Goal + GoalPerLevel * (level - 1). Stat = a counter of data.Stats.
-- Fmt: how the goal reads in the text ("count" a whole number, "big" 12,000, "cash" $1.5K).
QuestConfig.Templates = {
	FindEggs = { Text = "Find %s eggs", Goal = 3, GoalPerLevel = 0.25, Reward = 300, Stat = "EggsFound", Fmt = "count" },
	HatchDragons = { Text = "Hatch %s dragons", Goal = 2, GoalPerLevel = 0.2, Reward = 450, Stat = "Hatched", Fmt = "count" },
	FlyDistance = { Text = "Fly %s studs", Goal = 6000, GoalPerLevel = 900, Reward = 350, Stat = "DistanceFlown", Fmt = "big" },
	CollectIncome = { Text = "Earn %s from your perch dragons", Goal = 1500, GoalPerLevel = 0, Reward = 400, Stat = "Collected", Fmt = "cash", IncomeSeconds = 240 },
	FeedDragons = { Text = "Feed dragons %s times", Goal = 3, GoalPerLevel = 0.15, Reward = 300, Stat = "Fed", Fmt = "count" },
	BoostTime = { Text = "Boost for %s seconds", Goal = 30, GoalPerLevel = 2, Reward = 250, Stat = "BoostSeconds", Fmt = "count" },
	CollectCoins = { Text = "Collect %s coins on the map", Goal = 25, GoalPerLevel = 2, Reward = 250, Stat = "Coins", Fmt = "count" },
	SellDragons = { Text = "Sell %s dragons", Goal = 2, GoalPerLevel = 0.1, Reward = 250, Stat = "Released", Fmt = "count" },
	SpinWheel = { Text = "Spin the wheel %s times", Goal = 2, GoalPerLevel = 0.1, Reward = 300, Stat = "Spins", Fmt = "count" },
	TryMutation = { Text = "Try the mutation machine %s times", Goal = 2, GoalPerLevel = 0.1, Reward = 350, Stat = "MutateTries", Fmt = "count" },
	WinDuel = { Text = "Win %s duel in the Battle Hall", Goal = 1, GoalPerLevel = 0.04, Reward = 600, Stat = "DuelsWon", Fmt = "count" },
	DefeatGuardians = { Text = "Beat %s egg guardians", Goal = 1, GoalPerLevel = 0.12, Reward = 500, Stat = "Guardians", Fmt = "count" },
}

QuestConfig.TemplateOrder = { "FindEggs", "HatchDragons", "FlyDistance", "CollectIncome", "FeedDragons", "BoostTime", "CollectCoins", "SellDragons", "SpinWheel", "TryMutation", "WinDuel", "DefeatGuardians" }

-- First goals. Check = which fact of the player's data makes it done (QuestService.starterDone).
QuestConfig.Starter = {
	{ Id = "Ride", Text = "Ride your dragon", Hint = "Press R or tap RIDE", Check = "Rides", Need = 1, Reward = 150 },
	{ Id = "Fly", Text = "Fly 500 studs", Hint = "SPACE to take off, SHIFT to boost", Check = "DistanceFlown", Need = 500, Reward = 200 },
	{ Id = "FindEgg", Text = "Win an egg from its guardian", Hint = "Fly to a nest, press X and beat the dragon that guards it", Check = "EggsFound", Need = 1, Reward = 200 },
	{ Id = "Hatch", Text = "Hatch a dragon", Hint = "Put an egg in a nest at your sanctuary", Check = "Hatched", Need = 1, Reward = 300 },
	{ Id = "Perch", Text = "Rest a dragon on a perch", Hint = "Open DRAGONS (G) and press PLACE", Check = "Perch", Need = 1, Reward = 400 },
	{ Id = "Feed", Text = "Feed a dragon", Hint = "Open DRAGONS (G) and press FEED", Check = "Fed", Need = 1, Reward = 250 },
	{ Id = "Upgrade", Text = "Buy your first upgrade", Hint = "Open the SHOP (B)", Check = "Upgrade", Need = 1, Reward = 500, Spins = 2 },
}
QuestConfig.StarterById = {}
for _, s in QuestConfig.Starter do
	QuestConfig.StarterById[s.Id] = s
end

-- (the old guided tutorial steps, kept for the day the objective HUD comes)
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

-- ============================================================== helpers
-- The goal of a template for a player of this level / income (a whole number, at least 1).
function QuestConfig.goal(templateId: string, level: number, income: number): number
	local t = QuestConfig.Templates[templateId]
	if not t then
		return 1
	end
	local goal = t.Goal + t.GoalPerLevel * (math.max(1, level) - 1)
	if t.IncomeSeconds then
		goal = math.max(goal, income * t.IncomeSeconds)
	end
	if t.Fmt == "big" then
		return math.max(1, math.floor(goal / 100 + 0.5) * 100)
	end
	if t.Fmt == "cash" then
		return math.max(1, math.floor(goal / 10 + 0.5) * 10)
	end
	return math.max(1, math.floor(goal + 0.5))
end

-- The cash a quest pays: the template reward grown by the level, never less than a few minutes of income.
function QuestConfig.cash(templateId: string, level: number, income: number): number
	local t = QuestConfig.Templates[templateId]
	if not t then
		return 0
	end
	local cash = t.Reward * (1 + QuestConfig.RewardPerLevel * (math.max(1, level) - 1))
	cash = math.max(cash, income * QuestConfig.RewardIncomeSeconds)
	return math.max(1, math.floor(cash / 10 + 0.5) * 10)
end

function QuestConfig.xp(level: number): number
	return math.floor(QuestConfig.XPBase * (1 + QuestConfig.XPPerLevel * math.max(0, level - 1)) + 0.5)
end

return table.freeze(QuestConfig)

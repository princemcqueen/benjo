--[[
	MonetizationService
	Robux purchases: developer products (ProcessReceipt, idempotent by
	PurchaseId) and game passes (ownership checked on join + purchase
	finished). Grants are applied server-side only, then saved right away.

	Studio: items whose Id is still 0 can be "bought" with Net
	Shop.TestBuy { Item } (free test purchase, Studio only).

	Net (domain "Shop"): TestBuy { Item } -> { Item, Text }
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))

local MonetizationService = {}

local Services
local Data
local MAX_RECEIPTS = 100

-- ============================================================== grants
local function ownsSpecies(data, speciesId: string): boolean
	for _, r in data.Dragons do
		if r.SpeciesId == speciesId then
			return true
		end
	end
	return false
end

-- Game pass perks (idempotent: safe to call on every join).
function MonetizationService.GrantPass(player: Player, itemId: string): (boolean, string?)
	local pass = MonetizationConfig.GamePasses[itemId]
	local data = Data.Get(player)
	if not pass or not data then
		return false, nil
	end
	local fresh = not MonetizationConfig.ownsPass(data, itemId)
	if type(data.Flags.Passes) ~= "table" then
		Data.Set(player, { "Flags", "Passes" }, {})
	end
	Data.Set(player, { "Flags", "Passes", itemId }, true)
	if itemId == "OwnerDragon" then
		Data.Set(player, { "Flags", "OwnerPass" }, true)
	end
	if pass.Grants and not ownsSpecies(data, pass.Grants) then
		local record = Services.DragonService.Add(player, pass.Grants, pass.Mutation or "None", "Purchase", true)
		if record and data.EquippedDragon == "" then
			Services.DragonService.Equip(player, record.UniqueId)
		end
	end
	if Services.BoostService then
		Services.BoostService.Refresh(player)
	end
	local text
	if fresh then
		text = string.format("%s unlocked! x%s LUCK on every roll, forever.", string.upper(pass.Name), tostring(pass.Luck or 1))
	end
	return true, text
end

-- Consumables. Returns ok, toast text.
function MonetizationService.GrantProduct(player: Player, itemId: string): (boolean, string?)
	local product = MonetizationConfig.Products[itemId]
	local data = Data.Get(player)
	if not product or not data then
		return false, nil
	end
	local kind = product.Kind
	if kind == "Boost" then
		Services.BoostService.Add(player, product.Boost, product.Seconds)
		return true, string.format("%s active for %d minutes!", MonetizationConfig.Boosts[product.Boost].Name, math.floor(product.Seconds / 60))
	elseif kind == "Cash" then
		local rate = Services.EconomyService.IncomeRate(player)
		local amount = math.max(product.Minimum or 0, math.floor(rate * (product.IncomeSeconds or 0)))
		Services.EconomyService.Earn(player, amount, "Purchase")
		return true, "+" .. Format.cash(amount) .. "!"
	elseif kind == "Spins" then
		if Services.SpinService then
			Services.SpinService.AddTickets(player, product.Count or 1)
		end
		return true, string.format("+%d spins! Use them on Spin Island.", product.Count or 1)
	elseif kind == "DragonLevel" then
		local uid = Services.DragonService.PotionTarget(player)
		if not uid then
			Services.EconomyService.Earn(player, 5000, "Purchase")
			return true, "No dragon to level up - you got $5K instead."
		end
		local gained = Services.DragonService.AddLevels(player, uid, product.Levels or 5)
		local record = data.Dragons[uid]
		if gained <= 0 then
			Services.BoostService.Add(player, "Luck", 15 * 60)
			return true, "Your dragon is max level - you got a Luck Potion instead!"
		end
		return true, string.format("%s gained %d levels!", record and record.Name or "Your dragon", gained)
	elseif kind == "DragonMutation" then
		local uid = Services.DragonService.PotionTarget(player)
		local mutation = uid and Services.DragonService.UpgradeMutation(player, uid)
		if not mutation then
			Services.BoostService.Add(player, "SuperLuck", 30 * 60)
			return true, "Already the best mutation - you got a Super Luck Potion instead!"
		end
		local m = MutationConfig.Mutations[mutation]
		local record = data.Dragons[uid]
		return true, string.format("%s is now %s!", record and record.Name or "Your dragon", string.upper(m and m.Name or mutation))
	end
	return false, nil
end

local function grant(player: Player, itemId: string, robux: number?): (boolean, string?)
	local def, kind = MonetizationConfig.find(itemId)
	if not def then
		return false, nil
	end
	local ok, text
	if kind == "Pass" then
		ok, text = MonetizationService.GrantPass(player, itemId)
	else
		ok, text = MonetizationService.GrantProduct(player, itemId)
	end
	if ok then
		Data.Increment(player, { "Purchases", "Robux" }, robux or def.Price or 0)
		Data.SaveNow(player)
	end
	return ok, text
end

-- ============================================================== receipts
local function processReceipt(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data = Data.Get(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local receipts = data.Purchases.Receipts
	if table.find(receipts, receipt.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local itemId = MonetizationConfig.byProductId(receipt.ProductId)
	if not itemId then
		warn("[Monetization] unknown product " .. tostring(receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, text = pcall(grant, player, itemId, receipt.CurrencySpent)
	if not ok then
		warn("[Monetization] grant failed: " .. tostring(text))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local list = table.clone(receipts)
	table.insert(list, receipt.PurchaseId)
	while #list > MAX_RECEIPTS do
		table.remove(list, 1)
	end
	Data.Set(player, { "Purchases", "Receipts" }, list)
	Data.SaveNow(player)
	Net.notify(player, "rare", text or "Purchase complete!")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function checkPasses(player: Player)
	for itemId, pass in MonetizationConfig.GamePasses do
		if pass.Id ~= 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.Id)
			end)
			if ok and owns then
				MonetizationService.GrantPass(player, itemId)
			end
		end
	end
	-- perks already granted earlier (e.g. Studio test purchase) stay applied
	local data = Data.Get(player)
	for itemId in MonetizationConfig.GamePasses do
		if data and MonetizationConfig.ownsPass(data, itemId) then
			MonetizationService.GrantPass(player, itemId)
		end
	end
end

-- ============================================================== net
local function testBuy(player: Player, p)
	if not RunService:IsStudio() then
		return false, "NOT_ALLOWED"
	end
	if not Net.check.str(p.Item, 40) then
		return false, "BAD_REQUEST"
	end
	local def = MonetizationConfig.find(p.Item)
	if not def then
		return false, "BAD_ITEM"
	end
	local ok, text = grant(player, p.Item, 0)
	if not ok then
		return false, "FAILED"
	end
	return true, { Item = p.Item, Text = text or ((def.Name or p.Item) .. " (test purchase)") }
end

function MonetizationService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Shop", "TestBuy", testBuy, { Burst = 4, PerSecond = 1 })
end

function MonetizationService.Start()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
			return
		end
		local itemId = MonetizationConfig.byPassId(passId)
		if itemId then
			local ok, text = grant(player, itemId)
			if ok then
				Net.notify(player, "rare", text or "Purchase complete!")
			end
		end
	end)
	Data.Loaded:Connect(function(player)
		task.spawn(checkPasses, player)
	end)
	for _, player in Players:GetPlayers() do
		if Data.Get(player) then
			task.spawn(checkPasses, player)
		end
	end
	if RunService:IsStudio() then
		ReplicatedStorage:SetAttribute("TestPurchases", true)
	end
end

return MonetizationService

--[[
	ShopWindow
	ROBUX tab: the Owner Dragon game pass (featured, 3D preview) + potions and
	cash packs (developer products). UPGRADES tab: cash upgrades (Forge).

	Buying: real items prompt MarketplaceService; items whose Id is still 0
	are free TEST purchases in Studio (server grants them), "coming soon"
	in a live game.
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
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local DragonVisual = require(Shared:WaitForChild("Dragons"):WaitForChild("DragonVisual"))
local Animator = require(Shared:WaitForChild("Dragons"):WaitForChild("Animator"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Create = require(UI.Create)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors
local LocalPlayer = Players.LocalPlayer

local ShopWindow = {}
ShopWindow.__index = ShopWindow
setmetatable(ShopWindow, { __index = WindowBase })

local function robux(n: number): string
	return "R$ " .. Format.commas(n)
end

local function iconDisc(parent: Instance, icon: string, color: Color3, props)
	local disc = Kit.frame({
		Name = "IconDisc",
		BackgroundTransparency = 0,
		BackgroundColor3 = color,
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Parent = parent,
	})
	for k, v in props do
		(disc :: any)[k] = v
	end
	Kit.corner(disc, 999)
	Create("UIGradient", { Rotation = 90, Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.25), color:Lerp(Color3.new(0, 0, 0), 0.2)), Parent = disc })
	local box = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), Parent = disc })
	Icons.make(icon, { Color = C.Ink, Accent = C.Text, Ink = color }).Parent = box
	return disc
end

function ShopWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Shop",
		Title = "Shop",
		Subtitle = "Potions, packs and upgrades",
		Icon = "Bag",
	})
	setmetatable(self, ShopWindow)
	self.UIC = ui
	self.Registry = registry
	self.Data = registry.DataController
	self.Pages = {}
	self.UpgradeRows = {}
	self.Busy = false
	self:Build()
	return self
end

-- ============================================================== layout
function ShopWindow:Build()
	local tabs = Kit.segmented({
		Name = "Tabs",
		Options = { "Robux", "Upgrades" },
		Labels = { "ROBUX", "UPGRADES" },
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.44, 0.085),
		Parent = self.Content,
	})
	self.Tabs = tabs
	tabs.Changed:Connect(function(v)
		self:ShowTab(v)
	end)
	for _, name in { "Robux", "Upgrades" } do
		self.Pages[name] = Kit.frame({ Name = name .. "Page", Position = UDim2.fromScale(0, 0.11), Size = UDim2.fromScale(1, 0.89), Parent = self.Content })
	end
	self:BuildRobux(self.Pages.Robux)
	self:BuildUpgrades(self.Pages.Upgrades)
	self:ShowTab("Robux")
end

function ShopWindow:ShowTab(name: string)
	self.Tab = name
	self.Tabs:Set(name)
	for k, page in self.Pages do
		page.Visible = k == name
	end
	if name == "Upgrades" then
		self:RefreshUpgrades()
	end
end

-- ============================================================== robux tab
function ShopWindow:BuildRobux(page: Instance)
	local scroll = Kit.scroll({ Name = "Scroll", Size = UDim2.fromScale(1, 1), Parent = page })
	Kit.padding(scroll, 2, 10, 6, 2)
	Kit.list(scroll, "V", 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

	-- featured: exclusive dragons (game passes)
	self.PassButtons = {}
	self.PassViews = {}
	for order, itemId in MonetizationConfig.passOrder() do
		self:BuildPassCard(scroll, itemId, order)
	end

	-- potions & packs
	local header = Kit.text({ Name = "PotionsHeader", Text = "POTIONS & PACKS", Role = "Heading", Color = C.Gold, LayoutOrder = 20, Parent = scroll })
	Responsive.bind(header, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(26))
	end)
	local gridHost = Kit.frame({ Name = "Products", LayoutOrder = 21, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromScale(1, 0), Parent = scroll })
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.Parent = gridHost
	Responsive.bind(grid, "CellSize", function(R)
		local cols = R.Device == "Phone" and (R.Portrait and 2 or 3) or 4
		return UDim2.new(1 / cols, -R.px(10), 0, R.px(R.Device == "Phone" and 200 or 196))
	end)
	Responsive.bind(grid, "CellPadding", function(R)
		return UDim2.fromOffset(R.px(10), R.px(10))
	end)
	for i, itemId in MonetizationConfig.ProductOrder do
		local def = MonetizationConfig.Products[itemId]
		local cell = Kit.surface({ Name = itemId, LayoutOrder = i, StrokeColor = def.Color, StrokeTransparency = 0.5, Parent = gridHost })
		iconDisc(cell, def.Icon, def.Color, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.06), Size = UDim2.fromScale(0.3, 0.3) })
		Kit.text({ Name = "Name", Text = string.upper(def.Name), Role = "Heading", Scaled = true, XAlign = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.05, 0.38), Size = UDim2.fromScale(0.9, 0.12), Parent = cell })
		Kit.text({
			Name = "Desc",
			Text = def.Description,
			Role = "Caption",
			Color = C.TextMuted,
			Wrapped = true,
			Scaled = true,
			XAlign = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(0.06, 0.51),
			Size = UDim2.fromScale(0.88, 0.22),
			Parent = cell,
		})
		local b = Kit.button({
			Name = "Buy",
			Text = robux(def.Price),
			Style = "Success",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.95),
			Size = UDim2.fromScale(0.8, 0.17),
			Parent = cell,
		})
		b.Activated:Connect(function()
			self:Buy(itemId)
		end)
	end
	local note = Kit.text({
		Name = "Note",
		Text = "Potions stack time when bought again. Level and Mutation potions apply to your equipped dragon.",
		Role = "Caption",
		Color = C.TextDim,
		Wrapped = true,
		XAlign = Enum.TextXAlignment.Center,
		LayoutOrder = 22,
		Parent = scroll,
	})
	Responsive.bind(note, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(34))
	end)
end

function ShopWindow:BuildPassCard(parent: Instance, itemId: string, order: number)
	local pass = MonetizationConfig.GamePasses[itemId]
	local rarity = DragonConfig.Rarities.Exclusive
	local top = (pass.Price or 0) >= 5000
	local accent = top and Color3.fromRGB(255, 205, 60) or rarity.Color
	local card = Kit.surface({ Name = itemId, LayoutOrder = order, StrokeColor = accent, StrokeTransparency = 0.1, Color = Color3.fromRGB(34, 20, 26), Transparency = 0.02, Parent = parent })
	Responsive.bind(card, "Size", function(R)
		return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and (R.Portrait and 330 or 230) or 250))
	end)
	Create("UIGradient", {
		Rotation = 0,
		Color = top and ColorSequence.new(Color3.fromRGB(110, 70, 20), Color3.fromRGB(40, 24, 60)) or ColorSequence.new(Color3.fromRGB(90, 30, 30), Color3.fromRGB(30, 22, 40)),
		Parent = card,
	})
	local pv = Kit.frame({ Name = "PreviewBox", Position = UDim2.fromScale(0.01, 0.04), Size = UDim2.fromScale(0.4, 0.92), Parent = card })
	local glow = Kit.frame({ Name = "Glow", BackgroundTransparency = 0.55, BackgroundColor3 = accent, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.55), Size = UDim2.fromScale(0.8, 0.8), SizeConstraint = Enum.SizeConstraint.RelativeYY, Parent = pv })
	Kit.corner(glow, 999)
	Create("UIGradient", {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
		Parent = glow,
	})
	local vp = Create("ViewportFrame", {
		Name = "Preview",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Ambient = Color3.fromRGB(160, 150, 150),
		LightColor = Color3.fromRGB(255, 240, 220),
		LightDirection = Vector3.new(-0.5, -1, -0.7),
		Parent = pv,
	})
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vp
	vp.CurrentCamera = cam
	self.PassViews[itemId] = { Viewport = vp, Camera = cam, Species = pass.Grants, Mutation = pass.Mutation or "None" }

	local info = Kit.frame({ Name = "Info", Position = UDim2.fromScale(0.43, 0.06), Size = UDim2.fromScale(0.55, 0.88), Parent = card })
	local tags = Kit.frame({ Name = "Tags", Size = UDim2.fromScale(1, 0.12), Parent = info })
	Kit.list(tags, "H", 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Kit.badge({ Text = "EXCLUSIVE", Color = rarity.Color, LayoutOrder = 1, Parent = tags })
	Kit.badge({ Text = "x" .. tostring(pass.Luck or 1) .. " LUCK", Color = C.Success, LayoutOrder = 2, Parent = tags })
	if pass.Mutation == "Omni" then
		Kit.badge({ Text = "ALL MUTATIONS", Color = Color3.fromRGB(190, 90, 255), LayoutOrder = 3, Parent = tags })
	end
	local title = Kit.text({ Name = "Title", Text = string.upper(pass.Name) .. (pass.Grants == "OwnerDragon" and "" or " DRAGON"), Role = "Display", Scaled = true, Position = UDim2.fromScale(0, 0.14), Size = UDim2.fromScale(1, 0.2), Parent = info })
	Create("UIGradient", { Rotation = 90, Color = top and ColorSequence.new(Color3.fromRGB(255, 245, 190), Color3.fromRGB(255, 180, 40)) or ColorSequence.new(rarity.Glow, rarity.Color), Parent = title })
	local perks = Kit.frame({ Name = "Perks", Position = UDim2.fromScale(0, 0.37), Size = UDim2.fromScale(1, 0.4), Parent = info })
	Kit.list(perks, "V", 2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	for i, perk in pass.Perks do
		local row = Kit.frame({ Name = "Perk" .. i, Size = UDim2.fromScale(1, 1 / #pass.Perks - 0.02), LayoutOrder = i, Parent = perks })
		local chk = Kit.frame({ Size = UDim2.fromScale(0.8, 0.8), Position = UDim2.fromScale(0, 0.1), SizeConstraint = Enum.SizeConstraint.RelativeYY, Parent = row })
		Icons.make("Check", { Color = C.Success, Accent = C.Success, Ink = C.Ink }).Parent = chk
		Kit.text({ Text = perk, Role = "Body", Scaled = true, Position = UDim2.fromScale(0.08, 0.05), Size = UDim2.fromScale(0.92, 0.9), Parent = row })
	end
	local buy = Kit.button({
		Name = "Buy",
		Text = robux(pass.Price),
		Style = "Success",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(0.62, 0.18),
		Parent = info,
	})
	buy.Activated:Connect(function()
		self:Buy(itemId)
	end)
	self.PassButtons[itemId] = buy
end

function ShopWindow:BuildPassPreviews()
	if self._previewsBuilt then
		return
	end
	self._previewsBuilt = true
	for _, view in self.PassViews do
		task.defer(function()
			local ok, model = pcall(function()
				local m = DragonVisual.build(view.Species, { Saddle = false, Detail = "Medium", Mutation = view.Mutation })
				local pose = Animator.samplePose(m, "Roar", 0.85)
				DragonVisual.pose(m, pose, CFrame.Angles(0, math.rad(150), 0))
				return m
			end)
			if not ok or not model then
				return
			end
			model.Parent = view.Viewport
			local cf, size = model:GetBoundingBox()
			local radius = math.max(size.X, size.Y, size.Z) * 0.5 * 0.62
			local dist = radius / math.tan(math.rad(view.Camera.FieldOfView) * 0.5)
			view.Camera.CFrame = CFrame.lookAt(cf.Position + Vector3.new(dist * 0.35, size.Y * 0.2, dist), cf.Position)
		end)
	end
end

-- ============================================================== upgrades tab
function ShopWindow:BuildUpgrades(page: Instance)
	local scroll = Kit.scroll({ Name = "Scroll", Size = UDim2.fromScale(1, 1), Parent = page })
	Kit.padding(scroll, 2, 10, 6, 2)
	Kit.list(scroll, "V", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local colors = {
		EggStorage = Color3.fromRGB(110, 208, 104),
		DragonStorage = Color3.fromRGB(77, 163, 255),
		HatchLuck = Color3.fromRGB(64, 236, 214),
		Radar = Color3.fromRGB(255, 140, 60),
	}
	for i, id in EconomyConfig.UpgradeOrder do
		local def = EconomyConfig.Upgrades[id]
		local color = colors[id] or C.Gold
		local row = Kit.surface({ Name = id, LayoutOrder = i, StrokeColor = color, StrokeTransparency = 0.55, Parent = scroll })
		Responsive.bind(row, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and 92 or 84))
		end)
		iconDisc(row, def.Icon, color, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.015, 0.5), Size = UDim2.fromScale(0.7, 0.7) })
		Kit.text({ Name = "Name", Text = string.upper(def.Name), Role = "Heading", Position = UDim2.fromScale(0.13, 0.12), Size = UDim2.fromScale(0.46, 0.34), Truncate = true, Parent = row })
		Kit.text({ Name = "Desc", Text = def.Description, Role = "Caption", Color = C.TextMuted, Position = UDim2.fromScale(0.13, 0.5), Size = UDim2.fromScale(0.46, 0.3), Truncate = true, Parent = row })
		local level = Kit.text({ Name = "Level", Text = "", Role = "Label", Color = color, XAlign = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.5, 0.2), Size = UDim2.fromScale(0.2, 0.6), Parent = row })
		local buy = Kit.button({
			Name = "Buy",
			Text = "BUY",
			Style = "Gold",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(0.985, 0.5),
			Size = UDim2.fromScale(0.25, 0.62),
			Parent = row,
		})
		buy.Activated:Connect(function()
			self:BuyUpgrade(id)
		end)
		self.UpgradeRows[id] = { Level = level, Buy = buy }
	end
end

local function fmtValue(def, v: number): string
	if def.Format == "Percent" then
		return "+" .. math.floor(v * 100 + 0.5) .. "%"
	elseif def.Format == "Range" then
		return v >= 100000 and "MAP" or (tostring(v) .. "m")
	end
	return tostring(v)
end

function ShopWindow:RefreshUpgrades()
	local data = self.Data and self.Data.all()
	if not data then
		return
	end
	for id, row in self.UpgradeRows do
		local def = EconomyConfig.Upgrades[id]
		local level = tonumber(data.Upgrades and data.Upgrades[id]) or 0
		local cur = def.Levels[level + 1]
		local nxt = def.Levels[level + 2]
		if nxt then
			row.Level.Text = string.format("%s  >  %s", fmtValue(def, cur.Value), fmtValue(def, nxt.Value))
			row.Buy:SetText(Format.cash(nxt.Price))
			row.Buy:SetEnabled((data.Cash or 0) >= nxt.Price)
		else
			row.Level.Text = fmtValue(def, cur.Value)
			row.Buy:SetText("MAXED")
			row.Buy:SetEnabled(false)
		end
	end
end

function ShopWindow:BuyUpgrade(id: string)
	if self.Busy then
		return
	end
	self.Busy = true
	task.spawn(function()
		local res = Net.request("Shop", "BuyUpgrade", { Id = id })
		self.Busy = false
		if self.UIC.HandleResult(res, EconomyConfig.Upgrades[id].Name .. " upgraded!") then
			self:RefreshUpgrades()
		end
	end)
end

-- ============================================================== buying
function ShopWindow:Buy(itemId: string)
	local def, kind = MonetizationConfig.find(itemId)
	if not def or self.Busy then
		return
	end
	if kind == "Pass" and self:OwnsPass(itemId) then
		self.UIC.Notify("info", "You already own the " .. def.Name .. "!")
		return
	end
	if def.Id ~= 0 then
		local ok, err = pcall(function()
			if kind == "Pass" then
				MarketplaceService:PromptGamePassPurchase(LocalPlayer, def.Id)
			else
				MarketplaceService:PromptProductPurchase(LocalPlayer, def.Id)
			end
		end)
		if not ok then
			warn("[Shop] prompt failed: " .. tostring(err))
		end
		return
	end
	if not (RunService:IsStudio() or ReplicatedStorage:GetAttribute("TestPurchases")) then
		self.UIC.Notify("info", def.Name .. " is coming soon!")
		return
	end
	-- Studio: free test purchase (the item is not created on Roblox yet)
	self.Busy = true
	task.spawn(function()
		local res = Net.request("Shop", "TestBuy", { Item = itemId })
		self.Busy = false
		if res.ok then
			self.UIC.Notify("rare", (res.data and res.data.Text or def.Name) .. "  (TEST)")
			self:Refresh()
		else
			self.UIC.HandleResult(res)
		end
	end)
end

function ShopWindow:OwnsPass(itemId: string): boolean
	local data = self.Data and self.Data.all()
	return MonetizationConfig.ownsPass(data, itemId)
end

function ShopWindow:Refresh()
	for itemId, button in self.PassButtons do
		local owned = self:OwnsPass(itemId)
		button:SetText(owned and "OWNED" or robux(MonetizationConfig.GamePasses[itemId].Price))
		button:SetStyle(owned and "Secondary" or "Success")
	end
	if self.Tab == "Upgrades" then
		self:RefreshUpgrades()
	end
end

function ShopWindow:OnOpen(args)
	self:BuildPassPreviews()
	self:ShowTab(args and args.Tab == "Upgrades" and "Upgrades" or "Robux")
	self:Refresh()
	if not self._observing and self.Data then
		self._observing = true
		for _, key in { "Flags", "Upgrades", "Cash" } do
			self.Data.changed(key):Connect(function()
				if self.Root.Visible then
					self:Refresh()
				end
			end)
		end
	end
end

return ShopWindow

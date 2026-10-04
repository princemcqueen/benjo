--[[
	EggStorageWindow ("Egg Bag")
	Carried eggs as 3D cards (ViewportFrames), nest status, and actions:
	place a chosen egg in the sanctuary nest, or the best egg in one click.
	Data: data.Eggs (list), data.Incubator, data.Upgrades.EggStorage.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local WindowBase = require(UI.WindowBase)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))

local C = Theme.Colors

local EggStorageWindow = {}
EggStorageWindow.__index = EggStorageWindow
setmetatable(EggStorageWindow, { __index = WindowBase })

local TIER_NAMES = { "Tier I", "Tier II", "Tier III", "Tier IV", "Tier V", "Tier VI" }

function EggStorageWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "EggStorage",
		Title = "Egg Bag",
		Icon = "Egg",
		Spec = {
			Desktop = { Width = 0.56, Height = 0.7, Aspect = 1.5 },
			Tablet = { Width = 0.84, Height = 0.8, Aspect = 1.45 },
			Phone = { Width = 0.9, Height = 1 },
			PhonePortrait = { Width = 0.96, Height = 1 },
		},
	})
	setmetatable(self, EggStorageWindow)
	self.UIC = ui
	self.Registry = registry
	self.Cards = {}
	self:Build()
	return self
end

function EggStorageWindow:Build()
	-- status strip
	local strip = Kit.surface({ Name = "Status", Size = UDim2.fromScale(1, 0.13), Parent = self.Content })
	local sp = Kit.frame({ Size = UDim2.fromScale(1, 1), Parent = strip })
	Kit.scalePadding(sp, 0.12, 0.02, 0.12, 0.02)
	self.BagText = Kit.text({ Name = "Bag", Text = "", Role = "Heading", Size = UDim2.fromScale(0.34, 1), Parent = sp })
	self.NestText = Kit.text({
		Name = "Nest",
		Text = "",
		Role = "Body",
		Color = C.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.34, 0),
		Size = UDim2.fromScale(0.32, 1),
		Parent = sp,
	})
	local placeBest = Kit.button({
		Name = "PlaceBest",
		Text = "PLACE IN NEST",
		Icon = "Home",
		Style = "Primary",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromScale(0.32, 0.9),
		Parent = sp,
	})
	placeBest.Activated:Connect(function()
		self:Place(nil)
	end)
	self.PlaceBest = placeBest

	-- grid of egg cards
	local scroll = Kit.scroll({ Name = "Grid", Position = UDim2.fromScale(0, 0.16), Size = UDim2.fromScale(1, 0.72), Parent = self.Content })
	Kit.padding(scroll, 4, 10, 4, 4)
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.Parent = scroll
	Responsive.bind(grid, "CellSize", function(R)
		local cols = R.Device == "Phone" and (R.Portrait and 2 or 4) or 5
		return UDim2.new(1 / cols, -R.px(10), 0, R.px(R.Device == "Phone" and 170 or 196))
	end)
	Responsive.bind(grid, "CellPadding", function(R)
		return UDim2.fromOffset(R.px(10), R.px(10))
	end)
	self.Grid = scroll
	self.Empty = Kit.text({
		Name = "Empty",
		Text = "Your bag is empty.\nFly around Dragon Haven and grab the glowing eggs!",
		Role = "Body",
		Color = C.TextMuted,
		Wrapped = true,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.1, 0.35),
		Size = UDim2.fromScale(0.8, 0.3),
		Parent = self.Content,
	})
	self.Hint = Kit.text({
		Name = "Hint",
		Text = "Eggs hatch in your sanctuary nest. Bigger bag: Egg Storage upgrade at the Forge.",
		Role = "Caption",
		Color = C.TextDim,
		Scaled = true,
		Wrapped = true,
		MinTextSize = 9,
		XAlign = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.08),
		Parent = self.Content,
	})
end

local function eggCard(egg, order: number, onPlace: () -> ())
	local def = EggConfig.Eggs[egg.Type] or EggConfig.Eggs.HavenEgg
	local card = Kit.surface({ Name = "Egg_" .. egg.Id, LayoutOrder = order })
	-- 3D egg preview
	local vp = Instance.new("ViewportFrame")
	vp.Name = "Preview"
	vp.BackgroundTransparency = 1
	vp.Size = UDim2.fromScale(1, 0.58)
	vp.Ambient = Color3.fromRGB(150, 150, 160)
	vp.LightColor = Color3.fromRGB(255, 244, 230)
	vp.LightDirection = Vector3.new(-0.4, -1, -0.6)
	vp.Parent = card
	local model = EggVisual.build(egg.Type, { Beam = false, Sparkles = false, Light = false })
	EggVisual.place(model, CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(25), math.rad(-8)))
	model.Parent = vp
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.CFrame = CFrame.lookAt(Vector3.new(0, 0.6, 8.4), Vector3.new(0, 0.1, 0))
	cam.Parent = vp
	vp.CurrentCamera = cam
	-- glow chip
	local glow = Kit.frame({
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.32),
		Size = UDim2.fromScale(0.55, 0.45),
		BackgroundColor3 = def.Glow,
		BackgroundTransparency = 0.82,
		ZIndex = 0,
		Parent = card,
	})
	Kit.corner(glow, "pill")
	-- luck badge (top-left)
	local luck = math.max(1, tonumber(egg.Luck) or 1)
	local lb = Kit.text({
		Name = "Luck",
		Text = "x" .. tostring(luck) .. " LUCK",
		Role = "Label",
		Font = Theme.Fonts.Title,
		Color = EggConfig.luckColor(luck),
		XAlign = Enum.TextXAlignment.Left,
		Position = UDim2.fromScale(0.06, 0.03),
		Size = UDim2.fromScale(0.88, 0.1),
		ZIndex = 3,
		Parent = card,
	})
	lb.TextStrokeTransparency = 0.4
	Kit.text({
		Name = "Name",
		Text = def.Name,
		Role = "Label",
		Font = Theme.Fonts.Title,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.05, 0.58),
		Size = UDim2.fromScale(0.9, 0.12),
		Truncate = true,
		Parent = card,
	})
	Kit.text({
		Name = "Info",
		Text = string.format("%s  -  %s", TIER_NAMES[def.Tier] or "", Format.duration(def.HatchTime)),
		Role = "Caption",
		Color = C.TextMuted,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.05, 0.7),
		Size = UDim2.fromScale(0.9, 0.1),
		Parent = card,
	})
	local btn = Kit.button({
		Name = "Place",
		Text = "PLACE",
		Style = "Secondary",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.96, 0),
		Size = UDim2.fromScale(0.8, 0.14),
		Parent = card,
	})
	btn.Activated:Connect(onPlace)
	return card
end

function EggStorageWindow:Place(id: string?)
	self.PlaceBest:SetBusy(true)
	task.spawn(function()
		local res = Net.request("Egg", "Place", id and { Id = id } or {})
		self.PlaceBest:SetBusy(false)
		if self.UIC.HandleResult(res, "Egg placed in your nest!") then
			self:Refresh()
		end
	end)
end

function EggStorageWindow:Refresh()
	local D = self.Registry and self.Registry.DataController
	local data = D and D.all()
	if not data then
		return
	end
	local eggs = data.Eggs or {}
	local cap = EconomyConfig.upgradeValue("EggStorage", data.Upgrades and data.Upgrades.EggStorage or 0)
	self.BagText.Text = string.format("BAG  %d / %d", #eggs, cap)
	self.BagText.TextColor3 = #eggs >= cap and C.Warning or C.Text
	local inc = data.Incubator or { Unlocked = 0, Slots = {} }
	local used, ready = 0, 0
	local now = workspace:GetServerTimeNow()
	for _, s in inc.Slots or {} do
		used += 1
		if s.Ready <= now then
			ready += 1
		end
	end
	self.NestText.Text = string.format("Nest  %d / %d%s", used, inc.Unlocked, ready > 0 and ("  -  " .. ready .. " ready!") or "")
	self.NestText.TextColor3 = ready > 0 and C.Success or C.TextMuted
	self.PlaceBest:SetEnabled(#eggs > 0 and used < inc.Unlocked)
	for _, c in self.Cards do
		c:Destroy()
	end
	table.clear(self.Cards)
	for i, egg in eggs do
		local card = eggCard(egg, i, function()
			self:Place(egg.Id)
		end)
		card.Parent = self.Grid
		table.insert(self.Cards, card)
	end
	self.Empty.Visible = #eggs == 0
	self:SetSubtitle(string.format("%d egg%s", #eggs, #eggs == 1 and "" or "s"))
end

function EggStorageWindow:OnOpen()
	self:Refresh()
	if not self._observing then
		self._observing = true
		local D = self.Registry and self.Registry.DataController
		if D then
			D.changed("Eggs"):Connect(function()
				if self.Root.Visible then
					self:Refresh()
				end
			end)
			D.changed("Incubator"):Connect(function()
				if self.Root.Visible then
					self:Refresh()
				end
			end)
		end
	end
end

return EggStorageWindow

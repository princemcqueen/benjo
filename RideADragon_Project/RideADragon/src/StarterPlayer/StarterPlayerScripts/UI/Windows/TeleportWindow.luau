--[[
	TeleportWindow
	Fast travel: one big button per destination (server validates the place
	and the cooldown; riding players travel with their dragon).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local WorldConfig = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("WorldConfig"))

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Responsive = require(UI.Responsive)
local Kit = require(UI.Kit)
local Icons = require(UI.Icons)
local WindowBase = require(UI.WindowBase)

local C = Theme.Colors

local TeleportWindow = {}
TeleportWindow.__index = TeleportWindow
setmetatable(TeleportWindow, { __index = WindowBase })

TeleportWindow.Places = {
	{ Id = "Sanctuary", Title = "MY SANCTUARY", Sub = "Your plot, nests and perches", Icon = "Home", Color = Color3.fromRGB(110, 208, 104) },
	{ Id = "Spawn", Title = "SPAWN", Sub = "Leaderboards and the fountain", Icon = "Trophy", Color = Color3.fromRGB(255, 196, 48) },
	{ Id = "SpinIsland", Title = "SPIN ISLAND", Sub = "Spin the wheel, win eggs", Icon = "Star", Color = Color3.fromRGB(255, 110, 190) },
	{ Id = "RaceIsland", Title = "RACE ISLAND", Sub = "Sky races, duels, monthly prize", Icon = "Trophy", Color = Color3.fromRGB(255, 80, 70) },
	{ Id = "Shop", Title = "DRAGON MARKET", Sub = "Potions, boosts and eggs", Icon = "Bag", Color = Color3.fromRGB(77, 163, 255) },
	{ Id = "Forge", Title = "DRAGONSMITH FORGE", Sub = "Upgrades", Icon = "Flame", Color = Color3.fromRGB(255, 140, 60) },
	{ Id = "Duel", Title = "BATTLE HALL", Sub = "Turn-based dragon duels", Icon = "Sword", Color = Color3.fromRGB(255, 110, 90) },
	{ Id = "Quests", Title = "ELDER ROWAN", Sub = "Quests and rewards", Icon = "Scroll", Color = Color3.fromRGB(205, 164, 222) },
	{ Id = "Library", Title = "HALL OF DRAGONS", Sub = "Dragon Index", Icon = "Book", Color = Color3.fromRGB(64, 236, 214) },
}
-- the floating sky islands (WorldConfig.SkyIslands): rare eggs grow on them
for _, isle in WorldConfig.SkyIslands do
	table.insert(TeleportWindow.Places, { Id = isle.Id, Title = string.upper(isle.Name), Sub = isle.Sub, Icon = isle.Icon, Color = isle.Color })
end

function TeleportWindow.new(ui, registry)
	local self = WindowBase.new({
		Name = "Teleport",
		Title = "Teleport",
		Subtitle = "Fly there instantly",
		Icon = "Map",
		Spec = {
			Desktop = { Width = 0.46, Height = 0.8, Aspect = 0.95 },
			Tablet = { Width = 0.72, Height = 0.86, Aspect = 0.95 },
			Phone = { Width = 0.7, Height = 1 },
			PhonePortrait = { Width = 0.96, Height = 1 },
		},
	})
	setmetatable(self, TeleportWindow)
	self.UIC = ui
	self.Registry = registry
	self.Buttons = {}
	self.Busy = false
	self:Build()
	return self
end

function TeleportWindow:Build()
	local scroll = Kit.scroll({ Name = "List", Size = UDim2.fromScale(1, 1), Parent = self.Content })
	Kit.padding(scroll, 2, 8, 2, 2)
	Kit.list(scroll, "V", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	for i, place in TeleportWindow.Places do
		local row = Kit.surface({ Name = place.Id, LayoutOrder = i, StrokeColor = place.Color, StrokeTransparency = 0.45, Parent = scroll })
		Responsive.bind(row, "Size", function(R)
			return UDim2.new(1, 0, 0, R.px(R.Device == "Phone" and 78 or 74))
		end)
		-- icon disc
		local disc = Kit.frame({
			Name = "IconDisc",
			BackgroundTransparency = 0,
			BackgroundColor3 = place.Color,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0.025, 0.5),
			Size = UDim2.fromScale(0.72, 0.72),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			Parent = row,
		})
		Kit.corner(disc, 999)
		local iconBox = Kit.frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), Parent = disc })
		Icons.make(place.Icon, { Color = C.Ink, Accent = C.Text, Ink = place.Color }).Parent = iconBox
		Kit.text({
			Name = "Title",
			Text = place.Title,
			Role = "Heading",
			Position = UDim2.fromScale(0.2, 0.14),
			Size = UDim2.fromScale(0.52, 0.42),
			Truncate = true,
			Parent = row,
		})
		Kit.text({
			Name = "Sub",
			Text = place.Sub,
			Role = "Caption",
			Color = C.TextMuted,
			Position = UDim2.fromScale(0.2, 0.56),
			Size = UDim2.fromScale(0.52, 0.3),
			Truncate = true,
			Parent = row,
		})
		local go = Kit.button({
			Name = "Go",
			Text = "GO",
			Style = i == 1 and "Success" or "Primary",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(0.975, 0.5),
			Size = UDim2.fromScale(0.22, 0.66),
			Parent = row,
		})
		go.Activated:Connect(function()
			self:Go(place)
		end)
		self.Buttons[place.Id] = go
	end
end

-- Quick dark "blink" so the jump does not feel like a glitch.
function TeleportWindow:Blink()
	local layer = self.UIC.Layers.GameModal and self.UIC.Layers.GameModal.Root
	if not layer then
		return
	end
	local f = Instance.new("Frame")
	f.Name = "TeleportBlink"
	f.BackgroundColor3 = Color3.fromRGB(10, 12, 24)
	f.BackgroundTransparency = 0.05
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = 50
	f.Parent = layer
	local tw = TweenService:Create(f, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { BackgroundTransparency = 1 })
	tw.Completed:Connect(function()
		f:Destroy()
	end)
	tw:Play()
end

function TeleportWindow:Go(place)
	if self.Busy then
		return
	end
	self.Busy = true
	local button = self.Buttons[place.Id]
	if button then
		button:SetBusy(true)
	end
	task.spawn(function()
		local res = Net.request("Travel", "To", { Place = place.Id })
		if button then
			button:SetBusy(false)
		end
		self.Busy = false
		if res.ok then
			self:Blink()
			self.UIC.Close()
			self.UIC.Notify("success", "Welcome to " .. place.Title:sub(1, 1) .. place.Title:sub(2):lower() .. "!")
		else
			self.UIC.HandleResult(res)
		end
	end)
end

function TeleportWindow:OnOpen() end

return TeleportWindow

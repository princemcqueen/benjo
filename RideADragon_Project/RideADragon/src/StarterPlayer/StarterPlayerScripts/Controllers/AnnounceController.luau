--[[
	AnnounceController
	Server-wide announcements. When somebody hatches something ultra rare
	(HatchConfig.Announce.MinOdds, "1 in 25,000" or rarer) every player on the server
	sees a banner under the cash row:

	  [ ALICE hatched a SHADOW VOID DRAGON! ]
	  [ 1 in 2,500,000 ]

	From HatchConfig.Announce.Mega on the banner is bigger, stays longer and gets a
	rainbow outline. Banners queue up (at most 3 waiting) and slide in one by one.

	Net signal "RareHatch" { Player, UserId, Species, Mutation, Rarity, Odds, Mega, Text?, Sub? }
	(Text / Sub replace the two lines of the banner: used for other big server news, e.g. the
	monthly race champion)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Odds = require(Shared:WaitForChild("Odds"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))
local HatchConfig = require(Configs:WaitForChild("HatchConfig"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Responsive = require(UI:WaitForChild("Responsive"))
local Kit = require(UI:WaitForChild("Kit"))

local C = Theme.Colors

local AnnounceController = {}

local registry
local holder: Frame? = nil
local queue: { any } = {}
local current: any = nil -- { Frame, Info }
local MAX_WAITING = 3

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 60)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 255, 100)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 200, 255)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(170, 110, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 110, 200)),
})

local function article(word: string): string
	return string.find(string.lower(string.sub(word, 1, 1)), "[aeiou]") and "an" or "a"
end

-- ============================================================== layout
local function layout()
	if not holder then
		return
	end
	local R = Responsive
	local short = math.min(R.Width, R.Height)
	local top, w, h
	if R.Device == "Phone" then
		top = R.TopInset + short * 0.2
		if R.Portrait then
			w = R.Width * 0.94
			h = w * 0.22
		else
			h = short * 0.2
			w = h * 4.6
		end
	else
		top = R.TopInset + short * 0.145
		h = short * 0.115
		w = h * 5.4
	end
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, math.floor(top))
	holder.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

local function getHolder(): Frame?
	if holder and holder.Parent then
		return holder
	end
	local uic = registry and registry.UIController
	local layer = uic and uic.Layers and (uic.Layers.GameNotifications or uic.Layers.GameUI)
	if not layer then
		return nil
	end
	holder = Kit.frame({ Name = "Announcements", Size = UDim2.fromOffset(300, 60), Parent = layer.Root })
	holder.ZIndex = 30
	layout()
	return holder
end

-- ============================================================== banner
local function build(info): Frame
	local parent = holder :: Frame
	local rarity = DragonConfig.Rarities[info.Rarity] or DragonConfig.Rarities.Common
	local color = Odds.color(info.Odds)
	local sp = DragonConfig.Species[info.Species]
	local speciesName = string.upper(sp and sp.Name or tostring(info.Species))
	local mutation = MutationConfig.Mutations[info.Mutation or "None"]
	local what = speciesName
	if mutation and info.Mutation ~= "None" then
		what = string.upper(mutation.Name) .. " " .. speciesName
	end
	local frame = Kit.surface({
		Name = "RareBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -90),
		Size = UDim2.fromScale(1, 1),
		Color = C.Panel,
		Transparency = 0.04,
		StrokeColor = color,
		StrokeTransparency = 0.05,
		Radius = "Window",
		Parent = parent,
	})
	local outline = frame:FindFirstChildWhichIsA("UIStroke")
	if outline then
		outline.Thickness = info.Mega and 4 or 3
	end
	local pad = Kit.frame({ Name = "Pad", Size = UDim2.fromScale(1, 1), Parent = frame })
	Kit.scalePadding(pad, 0.04, 0.08, 0.04, 0.08)
	local line1 = Kit.text({
		Name = "Headline",
		Text = info.Text or string.format("%s hatched %s %s!", info.Player, article(what), what),
		Role = "Heading",
		Scaled = true,
		MinTextSize = 10,
		Color = Color3.new(1, 1, 1),
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 0.56),
		Parent = pad,
	})
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(rarity.Glow, rarity.Color)
	grad.Parent = line1
	Kit.text({
		Name = "Odds",
		Text = info.Sub or ((info.Mega and "MEGA RARE  -  " or "") .. Odds.format(info.Odds)),
		Role = "Title",
		Scaled = true,
		MinTextSize = 9,
		Color = color,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.6),
		Size = UDim2.fromScale(1, 0.4),
		Parent = pad,
	})
	if info.Mega then
		local stroke = frame:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			local g = Instance.new("UIGradient")
			g.Color = RAINBOW
			g.Parent = stroke
			frame:SetAttribute("Rainbow", true)
		end
	end
	return frame
end

local function advance()
	if current or #queue == 0 then
		return
	end
	if not getHolder() then
		return
	end
	local info = table.remove(queue, 1)
	local frame = build(info)
	current = { Frame = frame, Info = info }
	local audio = registry.AudioController
	if audio then
		audio.playUI(info.Mega and "RareHatch" or "LevelUp")
	end
	local seconds = info.Mega and HatchConfig.Announce.MegaBannerSeconds or HatchConfig.Announce.BannerSeconds
	TweenService:Create(frame, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0) }):Play()
	task.delay(seconds, function()
		if current and current.Frame == frame then
			TweenService:Create(frame, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.new(0.5, 0, 0, -120) }):Play()
			task.delay(0.45, function()
				frame:Destroy()
				if current and current.Frame == frame then
					current = nil
				end
				advance()
			end)
		end
	end)
end

-- info: { Player, Species, Mutation, Rarity, Odds, Mega }
function AnnounceController.show(info)
	if type(info) ~= "table" or type(info.Player) ~= "string" or type(info.Species) ~= "string" then
		return
	end
	info.Odds = tonumber(info.Odds) or 0
	if #queue >= MAX_WAITING then
		table.remove(queue, 1)
	end
	table.insert(queue, info)
	advance()
end

function AnnounceController.clear()
	table.clear(queue)
	if current then
		current.Frame:Destroy()
		current = nil
	end
end

-- UILab: a sample banner.
function AnnounceController.preview(mega: boolean?)
	AnnounceController.clear()
	AnnounceController.show({
		Player = "DragonRiderXx",
		Species = "VoidDragon",
		Mutation = "Rainbow",
		Rarity = "Secret",
		Odds = mega and 12500000 or 62500,
		Mega = mega == true,
	})
end

function AnnounceController.isShowing(): boolean
	return current ~= nil
end

function AnnounceController.Init(reg)
	registry = reg
end

function AnnounceController.Start()
	Net.onSignal("RareHatch", AnnounceController.show)
	Responsive.Changed:Connect(layout)
	-- rainbow outline of mega banners
	local t = 0
	RunService.Heartbeat:Connect(function(dt)
		if current and current.Frame:GetAttribute("Rainbow") then
			t += dt
			local stroke = current.Frame:FindFirstChildWhichIsA("UIStroke")
			local g = stroke and stroke:FindFirstChildWhichIsA("UIGradient")
			if g then
				g.Rotation = (t * 120) % 360
			end
		end
	end)
end

return AnnounceController

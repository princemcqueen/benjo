--[[
	LoadingScreen (ReplicatedFirst)
	Replaces Roblox's default loading screen while the server writes Dragon
	Haven (terrain, village, nature) and the game assets arrive. Shows the
	title, a gold progress bar (Workspace attribute WorldProgress) and tips;
	fades out once the world is ready and the character has spawned.
	Scale-based layout (phones to 4K).
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local GOLD = Color3.fromRGB(206, 170, 98)
local GOLD_BRIGHT = Color3.fromRGB(242, 208, 134)
local TEXT = Color3.fromRGB(246, 238, 221)
local MUTED = Color3.fromRGB(180, 172, 156)

local bg = Instance.new("Frame")
bg.Name = "Backdrop"
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
bg.BorderSizePixel = 0
bg.Parent = gui
local grad = Instance.new("UIGradient")
grad.Rotation = 90
grad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 28, 38)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(12, 14, 20)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 7, 10)),
})
grad.Parent = bg

local center = Instance.new("Frame")
center.Name = "Center"
center.AnchorPoint = Vector2.new(0.5, 0.5)
center.Position = UDim2.fromScale(0.5, 0.5)
center.Size = UDim2.fromScale(0.62, 0.36)
center.BackgroundTransparency = 1
center.Parent = bg
local aspect = Instance.new("UIAspectRatioConstraint")
aspect.AspectRatio = 3.2
aspect.Parent = center

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Size = UDim2.fromScale(1, 0.42)
title.Font = Enum.Font.GothamBlack
title.Text = "RIDE A DRAGON"
title.TextScaled = true
title.TextColor3 = TEXT
title.Parent = center
local tg = Instance.new("UIGradient")
tg.Rotation = 90
tg.Color = ColorSequence.new(GOLD_BRIGHT, GOLD)
tg.Parent = title
local ts = Instance.new("UIStroke")
ts.Thickness = 2
ts.Color = Color3.fromRGB(60, 40, 14)
ts.Transparency = 0.2
ts.Parent = title

local sub = Instance.new("TextLabel")
sub.Name = "Subtitle"
sub.BackgroundTransparency = 1
sub.Position = UDim2.fromScale(0, 0.44)
sub.Size = UDim2.fromScale(1, 0.12)
sub.Font = Enum.Font.GothamMedium
sub.Text = "Entering Dragon Haven"
sub.TextScaled = true
sub.TextColor3 = MUTED
sub.Parent = center

local track = Instance.new("Frame")
track.Name = "Track"
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.fromScale(0.5, 0.66)
track.Size = UDim2.fromScale(0.7, 0.05)
track.BackgroundColor3 = Color3.fromRGB(34, 36, 44)
track.BorderSizePixel = 0
track.Parent = center
local tc = Instance.new("UICorner")
tc.CornerRadius = UDim.new(1, 0)
tc.Parent = track
local tstroke = Instance.new("UIStroke")
tstroke.Color = GOLD
tstroke.Transparency = 0.55
tstroke.Thickness = 1
tstroke.Parent = track
local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0.02, 1)
fill.BackgroundColor3 = GOLD
fill.BorderSizePixel = 0
fill.Parent = track
local fc = Instance.new("UICorner")
fc.CornerRadius = UDim.new(1, 0)
fc.Parent = fill
local fg = Instance.new("UIGradient")
fg.Color = ColorSequence.new(GOLD, GOLD_BRIGHT)
fg.Parent = fill

local tip = Instance.new("TextLabel")
tip.Name = "Tip"
tip.BackgroundTransparency = 1
tip.Position = UDim2.fromScale(0, 0.8)
tip.Size = UDim2.fromScale(1, 0.1)
tip.Font = Enum.Font.GothamMedium
tip.TextScaled = true
tip.TextColor3 = MUTED
tip.TextTransparency = 0.15
tip.Parent = center

local TIPS = {
	"Press R near your dragon to ride it.",
	"Hold Space to take off, Shift to boost.",
	"Find dragon eggs all over Dragon Haven.",
	"Your sanctuary earns coins from every dragon you place.",
	"Mutated dragons are rarer and far more valuable.",
}
tip.Text = TIPS[math.random(1, #TIPS)]

gui.Parent = player:WaitForChild("PlayerGui")

local shown = 0
local tipClock = 0
local tipIndex = 1
local conn
conn = RunService.RenderStepped:Connect(function(dt)
	local worldP = Workspace:GetAttribute("WorldProgress") or 0
	local ready = Workspace:GetAttribute("WorldReady") == true
	local target = ready and 1 or math.clamp(0.05 + worldP * 0.9, 0, 0.95)
	shown += (target - shown) * math.min(1, dt * 4)
	fill.Size = UDim2.fromScale(math.max(0.02, shown), 1)
	tipClock += dt
	if tipClock > 4.5 then
		tipClock = 0
		tipIndex = tipIndex % #TIPS + 1
		tip.Text = TIPS[tipIndex]
	end
end)

-- finish: world ready + character present (or a safety timeout)
local t0 = os.clock()
while not (Workspace:GetAttribute("WorldReady") and player.Character) and os.clock() - t0 < 45 do
	task.wait(0.1)
end
task.wait(0.6)
conn:Disconnect()
local info = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
for _, d in gui:GetDescendants() do
	if d:IsA("TextLabel") then
		TweenService:Create(d, info, { TextTransparency = 1 }):Play()
	elseif d:IsA("UIStroke") then
		TweenService:Create(d, info, { Transparency = 1 }):Play()
	elseif d:IsA("Frame") then
		TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play()
	end
end
task.wait(0.65)
gui:Destroy()

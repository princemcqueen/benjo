--[[
	TitleController
	RNG-style titles above every player's dragon: name (rarity colour),
	"1 in 12,500,000" (colour by how rare it is) and the mutation.
	Built locally from the companion model's attributes (DisplayName,
	SpeciesId, Rarity, Mutation, Odds, Exclusive), so they cost the server
	nothing. Your own dragon's title hides while you ride it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Odds = require(Shared:WaitForChild("Odds"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local MutationConfig = require(Configs:WaitForChild("MutationConfig"))

local TitleController = {}

local LocalPlayer = Players.LocalPlayer
local titles: { [Model]: { Gui: BillboardGui, Conn: { RBXScriptConnection } } } = {}

local MAX_DISTANCE = 160

local function label(parent: Instance, name: string, y: number, h: number, font: Enum.Font): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromScale(0, y)
	t.Size = UDim2.fromScale(1, h)
	t.Font = font
	t.TextScaled = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.35
	t.Parent = parent
	return t
end

local function fill(model: Model, gui: BillboardGui)
	local speciesId = model:GetAttribute("SpeciesId")
	local species = speciesId and DragonConfig.Species[speciesId]
	if not species then
		gui.Enabled = false
		return
	end
	local rarity = DragonConfig.Rarities[species.Rarity] or DragonConfig.Rarities.Common
	local mutationId = model:GetAttribute("Mutation") or "None"
	local mutation = MutationConfig.Mutations[mutationId]
	local exclusive = model:GetAttribute("Exclusive") == true
	local odds = tonumber(model:GetAttribute("Odds")) or Odds.base(speciesId, mutationId)
	local name = gui:FindFirstChild("Name") :: TextLabel
	local title = gui:FindFirstChild("Title") :: TextLabel
	local tag = gui:FindFirstChild("Tag") :: TextLabel
	name.Text = model:GetAttribute("DisplayName") or species.Name
	name.TextColor3 = rarity.Glow
	title.Text = Odds.format(odds, exclusive)
	title.TextColor3 = exclusive and rarity.Glow or Odds.color(odds)
	local shimmer = title:FindFirstChild("Shimmer") :: UIGradient?
	local top = exclusive or Odds.tier(odds) >= 6
	if top and not shimmer then
		local g = Instance.new("UIGradient")
		g.Name = "Shimmer"
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 230, 150)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
		})
		g.Parent = title
	elseif not top and shimmer then
		shimmer:Destroy()
	end
	if mutation and mutationId ~= "None" then
		tag.Visible = true
		tag.Text = string.upper(mutation.Name)
		tag.TextColor3 = mutation.Color
	else
		tag.Visible = false
	end
	gui.Enabled = true
end

local function heightFor(model: Model): number
	local br = tonumber(model:GetAttribute("BodyRadius")) or 4
	local hip = tonumber(model:GetAttribute("HipHeight")) or 5
	return br * 0.9 + hip * 0.55 + 4
end

local function untrack(model: Model)
	local t = titles[model]
	if t then
		titles[model] = nil
		for _, c in t.Conn do
			c:Disconnect()
		end
		t.Gui:Destroy()
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or titles[model] then
		return
	end
	local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not root then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "DragonTitle"
	gui.Size = UDim2.fromScale(12, 3.6) -- studs
	gui.StudsOffsetWorldSpace = Vector3.new(0, heightFor(model), 0)
	gui.MaxDistance = MAX_DISTANCE
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	gui.Adornee = root
	label(gui, "Tag", 0, 0.24, Enum.Font.GothamBlack)
	label(gui, "Name", 0.24, 0.32, Enum.Font.GothamBlack)
	label(gui, "Title", 0.56, 0.42, Enum.Font.GothamBlack)
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	local entry = { Gui = gui, Conn = {} }
	titles[model :: Model] = entry
	fill(model :: Model, gui)
	table.insert(entry.Conn, model.AttributeChanged:Connect(function(attr)
		if attr == "Odds" or attr == "Mutation" or attr == "SpeciesId" or attr == "DisplayName" or attr == "Exclusive" then
			fill(model :: Model, gui)
		elseif attr == "BodyRadius" or attr == "HipHeight" then
			gui.StudsOffsetWorldSpace = Vector3.new(0, heightFor(model :: Model), 0)
		end
	end))
	table.insert(entry.Conn, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			untrack(model :: Model)
		end
	end))
end

local function ownModel(model: Model): boolean
	return model.Name == "Dragon_" .. LocalPlayer.UserId
end

function TitleController.Start()
	task.spawn(function()
		local folder = Workspace:WaitForChild("Dragons", 60)
		if not folder then
			return
		end
		for _, m in folder:GetChildren() do
			track(m)
		end
		folder.ChildAdded:Connect(function(m)
			task.defer(track, m)
		end)
		folder.ChildRemoved:Connect(function(m)
			if m:IsA("Model") then
				untrack(m)
			end
		end)
		-- hide your own title while riding; retry roots that streamed in late
		RunService.Heartbeat:Connect(function()
			local riding = LocalPlayer:GetAttribute("Riding") == true
			for model, t in titles do
				if ownModel(model) then
					t.Gui.Enabled = not riding and t.Gui:FindFirstChild("Name") ~= nil
				end
			end
		end)
		while true do
			task.wait(2)
			for _, m in folder:GetChildren() do
				track(m)
			end
		end
	end)
end

function TitleController.Init() end

return TitleController

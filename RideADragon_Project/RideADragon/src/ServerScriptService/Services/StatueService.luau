--[[
	StatueService
	The statue in the middle of the plaza is the OWNER: it stands on the plinth of the fountain instead of
	the stone dragon. It is built from the owner's real Roblox avatar (WorldConfig.PlazaStatue.Username /
	UserId): Players:GetHumanoidDescriptionFromUserId + CreateHumanoidModelFromDescription, scaled up,
	posed (right fist raised, standing tall), anchored. If the avatar cannot be loaded (no web access, the
	name is wrong) a marble-and-gold "Dragon King" built from parts stands there instead. A plaque on the
	plinth and a floating title ("OWNER - Dragon King", the rank colours of RankConfig) say whose it is.

	Change who it is in WorldConfig > PlazaStatue ({ Username, UserId?, Scale }).

	API: StatueService.Ready (bool), StatueService.Kind ("Avatar" | "Fallback")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Configs = ReplicatedStorage:WaitForChild("Configs")
local WorldConfig = require(Configs:WaitForChild("WorldConfig"))
local RankConfig = require(Configs:WaitForChild("RankConfig"))

local StatueService = {}
StatueService.Ready = false
StatueService.Kind = ""

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

-- ============================================================== the avatar
local function ownerUserId(def): number?
	if def.UserId and def.UserId > 0 then
		return def.UserId
	end
	local ok, id = pcall(function()
		return Players:GetUserIdFromNameAsync(def.Username)
	end)
	return ok and tonumber(id) or nil
end

local function loadAvatar(userId: number): Model?
	local ok, model = pcall(function()
		local description = Players:GetHumanoidDescriptionFromUserId(userId)
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if ok and typeof(model) == "Instance" and model:IsA("Model") then
		return model
	end
	return nil
end

-- Swings a whole limb about its joint so that it points along `direction` (given in the model's own
-- frame: x right, y up, -z forward). It works from where the limb IS, so it does not matter how the rig
-- rests (T-pose or arms down). Only the joint's C0 changes: the engine moves the limb with everything
-- that hangs on it (forearm, hand, gloves, accessories) because they are joined to it.
local function aim(model: Model, jointName: string, tipName: string, direction: Vector3, frame: CFrame)
	local joint = nil
	for _, d in model:GetDescendants() do
		if d.Name == jointName and d:IsA("Motor6D") then
			joint = d
			break
		end
	end
	local tip = model:FindFirstChild(tipName, true)
	if not joint or not joint.Part0 or not joint.Part1 or not tip then
		return
	end
	local part0 = joint.Part0.CFrame
	local pivot = (part0 * joint.C0).Position
	local current = tip.Position - pivot
	local target = frame:VectorToWorldSpace(direction)
	if current.Magnitude < 0.05 or target.Magnitude < 0.05 then
		return
	end
	local axis = current.Unit:Cross(target.Unit)
	if axis.Magnitude < 1e-4 then
		return
	end
	local angle = math.acos(math.clamp(current.Unit:Dot(target.Unit), -1, 1))
	local swing = CF(pivot) * CFrame.fromAxisAngle(axis.Unit, angle) * CF(-pivot)
	-- Part1 = Part0 * C0 * C1^-1 must become swing * (the old Part1)
	joint.C0 = part0:Inverse() * swing * part0 * joint.C0
end

-- Right fist raised, left arm by the side, feet a little apart.
local function pose(model: Model, frame: CFrame)
	aim(model, "RightShoulder", "RightHand", V(0.22, 0.95, -0.2), frame)
	aim(model, "LeftShoulder", "LeftHand", V(-0.16, -1, -0.04), frame)
	aim(model, "RightHip", "RightFoot", V(0.12, -1, 0), frame)
	aim(model, "LeftHip", "LeftFoot", V(-0.12, -1, 0), frame)
end

-- Takes out the scripts and the humanoid; only the root stays anchored (the limbs hang on it through their
-- joints, so the pose holds and nothing falls); nothing collides.
local function freeze(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	for _, d in model:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = (d == root)
			d.CanCollide = false
			d.CanTouch = false
			d.CastShadow = true
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
end

-- After the engine has moved the posed limbs: put the lowest foot exactly on the plate.
local function settle(model: Model, feetY: number)
	task.wait(0.3)
	local lowest = math.huge
	for _, name in { "LeftFoot", "RightFoot" } do
		local foot = model:FindFirstChild(name, true)
		if foot and foot:IsA("BasePart") then
			lowest = math.min(lowest, foot.Position.Y - foot.Size.Y / 2)
		end
	end
	if lowest < math.huge then
		model:PivotTo(model:GetPivot() + V(0, feetY - lowest, 0))
	end
end

-- ============================================================== the fallback king (marble and gold)
local function fallbackKing(parent: Instance, base: CFrame, scale: number): Model
	local Kit = require(ServerScriptService:WaitForChild("World"):WaitForChild("Kit"))
	local b = Kit.new(parent, base, "OwnerStatue")
	local s = scale
	local marble = Color3.fromRGB(226, 220, 206)
	local gold = Color3.fromRGB(236, 190, 70)
	local cape = Color3.fromRGB(170, 40, 50)
	local M = Kit.M
	local props = { CanCollide = false, CanTouch = false }
	for _, sx in { -1, 1 } do
		b:box(V(1.05 * s, 2.2 * s, 1.1 * s), V(sx * 0.62 * s, 1.1 * s, 0), marble, M.Marble, props)
		b:box(V(1.15 * s, 0.4 * s, 1.8 * s), V(sx * 0.62 * s, 0.2 * s, -0.3 * s), marble, M.Marble, props)
	end
	b:box(V(2.5 * s, 2.3 * s, 1.3 * s), V(0, 3.35 * s, 0), marble, M.Marble, props)
	b:box(V(2.6 * s, 0.35 * s, 1.4 * s), V(0, 2.3 * s, 0), gold, M.Foil, props)
	b:box(V(2.7 * s, 2.7 * s, 0.35 * s), V(0, 3.2 * s, 0.85 * s), cape, M.Fabric, props)
	-- left arm by the side, right arm raised
	b:box(V(0.85 * s, 2.3 * s, 0.9 * s), CF(-1.75 * s, 3.3 * s, 0) * ANG(0, 0, 0.1), marble, M.Marble, props)
	b:box(V(0.85 * s, 2.5 * s, 0.9 * s), CF(1.95 * s, 4.7 * s, -0.2 * s) * ANG(0.2, 0, -0.32), marble, M.Marble, props)
	b:ball(1.1 * s, V(2.5 * s, 6.1 * s, -0.5 * s), marble, M.Marble, props)
	-- head and crown
	b:ball(1.5 * s, V(0, 5.15 * s, 0), marble, M.Marble, props)
	b:cyl(0.45 * s, 1.55 * s, V(0, 5.95 * s, 0), gold, M.Foil, props)
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2
		b:box(V(0.22 * s, 0.6 * s, 0.22 * s), V(math.cos(a) * 0.6 * s, 6.35 * s, math.sin(a) * 0.6 * s), gold, M.Foil, props)
	end
	return b.Model
end

-- ============================================================== plaque + floating title
local function plaque(statueModel: Model, base: Vector3, facing: Vector3, def)
	local rank = RankConfig.ByLevel[RankConfig.MaxLevel]
	-- the plinth is a square block: put the plaque on the face that looks at the spawn
	local out = math.abs(facing.X) > math.abs(facing.Z) and V(facing.X > 0 and 1 or -1, 0, 0) or V(0, 0, facing.Z > 0 and 1 or -1)
	local at = base + V(0, 9.5, 0) + out * 5.62
	local part = Instance.new("Part")
	part.Name = "OwnerPlaque"
	part.Anchored = true
	part.CanCollide = false
	part.Size = V(8.6, 3, 0.4)
	part.Color = Color3.fromRGB(46, 40, 34)
	part.Material = Enum.Material.Slate
	part.CFrame = CFrame.lookAt(at, at + out)
	part.Parent = statueModel
	local gui = Instance.new("SurfaceGui")
	gui.Name = "PlaqueGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0
	gui.Parent = part
	local function line(name: string, text: string, color: Color3, y: number, h: number)
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Position = UDim2.fromScale(0.04, y)
		t.Size = UDim2.fromScale(0.92, h)
		t.Font = Enum.Font.GothamBlack
		t.Text = text
		t.TextScaled = true
		t.TextColor3 = color
		t.Parent = gui
	end
	line("Owner", string.upper(def.Username), Color3.fromRGB(255, 226, 150), 0.06, 0.52)
	line("Rank", string.format("%s  -  %s", rank.Title, string.upper(rank.Epithet)), rank.Color, 0.6, 0.32)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 150)
	light.Range = 22
	light.Brightness = 1.4
	light.Parent = part
end

local function titleSign(statueModel: Model, top: Vector3, height: number, def)
	local rank = RankConfig.ByLevel[RankConfig.MaxLevel]
	local anchor = Instance.new("Part")
	anchor.Name = "TitleAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = V(1, 1, 1)
	anchor.Position = top + V(0, height + 4, 0)
	anchor.Parent = statueModel
	local gui = Instance.new("BillboardGui")
	gui.Name = "TitleGui"
	gui.Size = UDim2.fromOffset(300, 76)
	gui.MaxDistance = 260
	gui.LightInfluence = 0
	gui.Adornee = anchor
	gui.Parent = anchor
	local function line(name: string, text: string, color: Color3, y: number, h: number, font: Enum.Font)
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Position = UDim2.fromScale(0, y)
		t.Size = UDim2.fromScale(1, h)
		t.Font = font
		t.Text = text
		t.TextScaled = true
		t.TextColor3 = color
		t.Parent = gui
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.5
		stroke.Color = Color3.fromRGB(18, 20, 34)
		stroke.Parent = t
	end
	line("Title", "★ " .. rank.Title .. " ★", rank.Color, 0, 0.6, Enum.Font.GothamBlack)
	line("Epithet", rank.Epithet .. "  -  " .. def.Username, Color3.fromRGB(235, 238, 250), 0.62, 0.36, Enum.Font.GothamMedium)
end

-- ============================================================== build
local function build()
	local def = WorldConfig.PlazaStatue
	local hub = Workspace:WaitForChild("World", 180):WaitForChild("Hub", 180)
	local plinth = hub and hub:WaitForChild("DragonStatue", 180)
	if not plinth then
		warn("[Statue] no plaza statue to replace")
		return
	end
	local base = V(0, WorldConfig.Hub.Height, 0)
	local top = base + V(0, 14, 0) -- the gold plate of the plinth
	local spawn = WorldConfig.Spawn.Position
	local facing = V(spawn.X - base.X, 0, spawn.Z - base.Z)
	if facing.Magnitude < 1 then
		facing = V(0, 0, 1)
	end
	local frame = CFrame.lookAt(top, top + facing)
	local height = 5.4 * def.Scale

	local avatar = nil
	local userId = ownerUserId(def)
	if userId then
		avatar = loadAvatar(userId)
	end
	local model: Model
	if avatar then
		model = avatar
		model.Name = "OwnerStatue"
		pcall(function()
			model:ScaleTo(def.Scale)
		end)
		model:PivotTo(frame * CF(0, 6 * def.Scale, 0))
		local okPose, err = pcall(pose, model, frame)
		if not okPose then
			warn("[Statue] pose failed: " .. tostring(err))
		end
		freeze(model)
		model.Parent = plinth
		StatueService.Kind = "Avatar"
		pcall(settle, model, top.Y)
	else
		model = fallbackKing(plinth, frame, def.Scale * 0.9)
		StatueService.Kind = "Fallback"
		height = 6.6 * def.Scale * 0.9
	end
	-- the stone dragon makes room for the owner
	local dragon = plinth:FindFirstChild("StatueDragon")
	if dragon then
		dragon:Destroy()
	end
	plaque(plinth, base, facing, def)
	titleSign(plinth, top, height, def)
	model:SetAttribute("Owner", def.Username)
	StatueService.Ready = true
end

-- (exposed for the tests: the posing runs on a rig built by hand)
StatueService._test = { pose = pose, freeze = freeze, settle = settle }

function StatueService.Init(_services) end

function StatueService.Start()
	task.spawn(function()
		local ok, err = pcall(build)
		if not ok then
			warn("[Statue] failed: " .. tostring(err))
		end
	end)
end

return StatueService

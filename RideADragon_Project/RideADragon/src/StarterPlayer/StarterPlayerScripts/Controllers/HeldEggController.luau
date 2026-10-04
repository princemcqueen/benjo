--[[
	HeldEggController
	The egg in your hand. A picked-up egg is carried in the character's right hand
	(the arm cradles it) until you put it into a nest spot at your sanctuary - the nest
	prompts live in SanctuaryController, the server (EggService) owns the rules.

	Everybody sees it: the server replicates the hand through the player attributes
	HeldEggId / HeldEggType / HeldEggLuck and every client draws the egg itself for every
	player that holds one (client-only models, nothing is replicated). It is hidden while
	riding a dragon.

	API (local player):
	  HeldEggController.id() / .type() / .luck()   what is in hand (nil = empty)
	  HeldEggController.hold(id) / .holdBest() / .putAway()   ask the server
	  HeldEggController.handPosition(player?)      world position of the held egg
	  HeldEggController.fly(eggType, from, to, duration, onDone)   an egg flying along an arc
	  HeldEggController.flyIn(eggType, from)       a freshly picked egg flies into the hand
	  HeldEggController.burst(position, color)     small light burst
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local EggVisual = require(Shared:WaitForChild("EggVisual"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))

local HeldEggController = {}

local registry
local LocalPlayer = Players.LocalPlayer

local HELD_SCALE = 0.42 -- the egg shell is 2.4 x 3.1 studs at scale 1
local NEST_SCALE = 0.95 -- as drawn by SanctuaryController on the nest
local FLY_IN_TIME = 0.4
-- R15 arm pose that cradles the egg in front of the chest (radians): the elbow bends,
-- the upper arm swings a little forward and tucks in towards the body
local ARM_SHOULDER = math.rad(9)
local ARM_ELBOW = math.rad(102)
local ARM_ADDUCT = math.rad(-19)

local folder: Folder? = nil
local holds: { [Player]: any } = {} -- player -> { Type, Luck, Char, Model, Pose, Phase }
local flights: { any } = {}
local hiddenUntil: { [Player]: number } = {} -- hand visual waits for the fly-in to land
local clock = 0

local function getFolder(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "HeldEggs"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

-- ============================================================== what is in hand
function HeldEggController.id(player: Player?): string?
	local id = (player or LocalPlayer):GetAttribute("HeldEggId")
	return type(id) == "string" and id ~= "" and id or nil
end

function HeldEggController.type(player: Player?): string?
	local t = (player or LocalPlayer):GetAttribute("HeldEggType")
	return type(t) == "string" and EggConfig.Eggs[t] and t or nil
end

function HeldEggController.luck(player: Player?): number
	return math.max(1, tonumber((player or LocalPlayer):GetAttribute("HeldEggLuck")) or 1)
end

-- ============================================================== hand geometry
local function handOf(char: Model): (BasePart?, boolean)
	local hand = char:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		return hand, true
	end
	local arm = char:FindFirstChild("Right Arm") -- R6
	if arm and arm:IsA("BasePart") then
		return arm, false
	end
	return nil, false
end

-- Pivot of the egg held by `char`: just beyond the hand, standing upright, facing like the character.
local function holdCFrame(char: Model, t: number): CFrame?
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hand, r15 = handOf(char)
	local base: CFrame
	if hand then
		base = hand.CFrame * (r15 and CFrame.new(0, -0.42, 0) or CFrame.new(0, -1.3, -0.4))
	else
		local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or hrp
		if not (torso and torso:IsA("BasePart")) then
			return nil
		end
		base = torso.CFrame * CFrame.new(0.9, 0.2, -1.2)
	end
	local facing = hrp and hrp:IsA("BasePart") and hrp.CFrame.Rotation or CFrame.identity
	-- a gentle wobble, as if the egg were warm and alive
	local wobble = CFrame.Angles(math.sin(t * 2.3) * 0.05, math.sin(t * 0.7) * 0.2, math.cos(t * 1.9) * 0.05)
	return CFrame.new(base.Position + Vector3.new(0, 0.25, 0)) * facing * wobble
end

-- R15 right arm: raise it forward and bend the elbow so the hand holds the egg in front of the chest.
local function applyPose(st)
	local char = st.Char
	local upper = char:FindFirstChild("RightUpperArm")
	local lower = char:FindFirstChild("RightLowerArm")
	local shoulder = upper and upper:FindFirstChild("RightShoulder")
	local elbow = lower and lower:FindFirstChild("RightElbow")
	if shoulder and shoulder:IsA("Motor6D") and elbow and elbow:IsA("Motor6D") then
		st.Pose = { Shoulder = shoulder, ShoulderC0 = shoulder.C0, Elbow = elbow, ElbowC0 = elbow.C0 }
		shoulder.C0 = shoulder.C0 * CFrame.Angles(ARM_SHOULDER, 0, ARM_ADDUCT)
		elbow.C0 = elbow.C0 * CFrame.Angles(ARM_ELBOW, 0, 0)
	end
end

local function removePose(st)
	local pose = st.Pose
	st.Pose = nil
	if pose then
		if pose.Shoulder.Parent then
			pose.Shoulder.C0 = pose.ShoulderC0
		end
		if pose.Elbow.Parent then
			pose.Elbow.C0 = pose.ElbowC0
		end
	end
end

-- ============================================================== visuals
local function dispose(player: Player)
	local st = holds[player]
	if not st then
		return
	end
	holds[player] = nil
	removePose(st)
	if st.Model then
		st.Model:Destroy()
	end
end

local function build(player: Player, eggType: string, luck: number, char: Model)
	local model = EggVisual.build(eggType, { Beam = false, Scale = HELD_SCALE, Sparkles = luck >= 10 })
	model.Name = "HeldEgg_" .. player.UserId
	local shell = model.PrimaryPart
	local light = shell and shell:FindFirstChildWhichIsA("PointLight")
	if light then
		light.Range = 7
		light.Brightness = 0.7
	end
	local st = { Type = eggType, Luck = luck, Char = char, Model = model, Phase = math.random() * 6.28, Attached = false }
	holds[player] = st
	applyPose(st)
	return st
end

-- Brings the visual in line with the attributes / character / riding state of `player`.
local function refresh(player: Player)
	local eggType = HeldEggController.type(player)
	local char = player.Character
	local want = eggType ~= nil
		and char ~= nil
		and char.Parent ~= nil
		and player:GetAttribute("Riding") ~= true
		and (hiddenUntil[player] or 0) <= clock
	local st = holds[player]
	if st and (not want or st.Type ~= eggType or st.Char ~= char or (st.Attached and not st.Model.Parent)) then
		dispose(player)
		st = nil
	end
	if want and not st then
		build(player, eggType :: string, HeldEggController.luck(player), char :: Model)
	end
end

local function track(player: Player)
	local function update()
		refresh(player)
	end
	player:GetAttributeChangedSignal("HeldEggType"):Connect(update)
	player:GetAttributeChangedSignal("HeldEggLuck"):Connect(update)
	player:GetAttributeChangedSignal("Riding"):Connect(update)
	player.CharacterAdded:Connect(function()
		task.defer(update)
	end)
	player.CharacterRemoving:Connect(function()
		dispose(player)
	end)
	update()
end

-- ============================================================== effects
function HeldEggController.burst(position: Vector3, color: Color3)
	local burst = Instance.new("Part")
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.Shape = Enum.PartType.Ball
	burst.Material = Enum.Material.Neon
	burst.Color = color
	burst.Size = Vector3.new(1.5, 1.5, 1.5)
	burst.CFrame = CFrame.new(position)
	burst.Transparency = 0.25
	burst.CastShadow = false
	burst.Parent = getFolder()
	TweenService:Create(burst, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(8, 8, 8),
		Transparency = 1,
	}):Play()
	task.delay(0.45, function()
		burst:Destroy()
	end)
end

-- An egg flying from `from` to `to` (a Vector3, or a function returning one) along a
-- high arc, growing from the hand size to the nest size. onDone runs when it lands.
function HeldEggController.fly(eggType: string, from: Vector3, to: any, duration: number, onDone: (() -> ())?, fromScale: number?, toScale: number?)
	local startScale = fromScale or HELD_SCALE
	local endScale = toScale or NEST_SCALE
	local model = EggVisual.build(eggType, { Beam = false, Scale = 1 })
	model:ScaleTo(startScale)
	model.Name = "FlyingEgg"
	model.Parent = getFolder()
	table.insert(flights, {
		Model = model,
		Type = eggType,
		From = from,
		To = to,
		Age = 0,
		Duration = math.max(0.1, duration),
		OnDone = onDone,
		StartScale = startScale,
		EndScale = endScale,
		Spin = (math.random() - 0.5) * 6,
	})
end

-- A freshly picked-up egg jumps from where it lay into the hand; the held visual
-- (already replicated) waits until it has landed.
function HeldEggController.flyIn(eggType: string, from: Vector3)
	hiddenUntil[LocalPlayer] = clock + FLY_IN_TIME
	refresh(LocalPlayer)
	HeldEggController.fly(eggType, from, function()
		return HeldEggController.handPosition(LocalPlayer) or from
	end, FLY_IN_TIME, function()
		hiddenUntil[LocalPlayer] = nil
		refresh(LocalPlayer)
	end, 1, HELD_SCALE)
end

-- World position of the egg in `player`'s hand (nil when the character has no hand yet).
function HeldEggController.handPosition(player: Player?): Vector3?
	local p = player or LocalPlayer
	local char = p.Character
	local cf = char and holdCFrame(char, clock)
	return cf and cf.Position or nil
end

local function stepFlights(dt: number)
	for i = #flights, 1, -1 do
		local f = flights[i]
		f.Age += dt
		local t = math.clamp(f.Age / f.Duration, 0, 1)
		local ease = t * t * (3 - 2 * t)
		local target = type(f.To) == "function" and f.To() or f.To
		local height = math.clamp((target - f.From).Magnitude * 0.3, 1.5, 9)
		local pos = f.From:Lerp(target, ease) + Vector3.new(0, math.sin(t * math.pi) * height, 0)
		if f.Model.Parent then
			f.Model:ScaleTo(f.StartScale + (f.EndScale - f.StartScale) * ease)
			EggVisual.place(f.Model, CFrame.new(pos) * CFrame.Angles(0, f.Spin * f.Age, math.sin(t * math.pi) * 0.4))
		end
		if t >= 1 then
			table.remove(flights, i)
			f.Model:Destroy()
			if f.OnDone then
				task.spawn(f.OnDone)
			end
		end
	end
end

local function step(dt: number)
	clock += dt
	stepFlights(dt)
	for player, st in holds do
		local char = st.Char
		local model = st.Model
		if char.Parent then
			local cf = holdCFrame(char, clock + st.Phase)
			if cf then
				EggVisual.place(model, cf)
				if not st.Attached then
					st.Attached = true
					model.Parent = getFolder()
				end
			end
		else
			task.defer(refresh, player)
		end
	end
	-- a pickup that never landed must not leave the hand empty
	for player, releaseAt in hiddenUntil do
		if releaseAt <= clock then
			hiddenUntil[player] = nil
			refresh(player)
		end
	end
end

-- ============================================================== requests (local player)
local function ask(payload, okText: string?)
	task.spawn(function()
		local res = Net.request("Egg", "Hold", payload)
		local uic = registry and registry.UIController
		if not res.ok and uic then
			uic.HandleResult(res)
		elseif res.ok and okText and uic then
			uic.Notify("info", okText)
		end
	end)
end

function HeldEggController.hold(id: string)
	if HeldEggController.id() == id then
		return
	end
	ask({ Id = id })
end

function HeldEggController.holdBest()
	ask({ Best = true })
end

function HeldEggController.putAway()
	if HeldEggController.id() then
		ask({}, "Egg back in your bag.")
	end
end

-- ============================================================== hud
function HeldEggController.updateHud()
	local hud = registry and registry.Hud
	if not hud or not hud.SetHeldEgg then
		return
	end
	local eggType = HeldEggController.type()
	if not eggType then
		hud:SetHeldEgg(nil)
		return
	end
	local def = EggConfig.Eggs[eggType] or EggConfig.Eggs.HavenEgg
	hud:SetHeldEgg({
		Id = HeldEggController.id(),
		Type = eggType,
		Name = def.Name,
		Luck = HeldEggController.luck(),
		Glow = def.Glow,
	})
end

function HeldEggController.Init(reg)
	registry = reg
end

function HeldEggController.Start()
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player)
		dispose(player)
		hiddenUntil[player] = nil
	end)
	RunService.Heartbeat:Connect(step)
	for _, attr in { "HeldEggId", "HeldEggType", "HeldEggLuck" } do
		LocalPlayer:GetAttributeChangedSignal(attr):Connect(HeldEggController.updateHud)
	end
	HeldEggController.updateHud()
end

return HeldEggController

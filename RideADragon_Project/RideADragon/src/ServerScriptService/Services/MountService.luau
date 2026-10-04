--[[
	MountService
	Owns each player's companion dragon on the server. The server only creates
	the invisible physics Root (+ LinearVelocity / AlignOrientation) and the
	identity attributes; every client builds the visual model locally.

	The owner's client simulates the root (network ownership) - riding input
	or the follow AI - and sends only low-frequency state changes (mode,
	boost, one-shot actions). The server validates speed/altitude and snaps
	the dragon back on violations.

	Mounting joints the character's HumanoidRootPart to the root with a
	Motor6D ("RiderJoint"); clients animate its Transform so the rider moves
	with the dragon's body.

	Net: Mount.Toggle, Mount.Ride, Mount.Dismount, Mount.Recall
	     event DragonState { Mode, Boost, Shot }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local DragonStats = require(Shared:WaitForChild("DragonStats"))
local Odds = require(Shared:WaitForChild("Odds"))
local Builder = require(Shared:WaitForChild("Dragons"):WaitForChild("Builder"))
local GameConfig = require(Configs:WaitForChild("GameConfig"))
local BondConfig = require(Configs:WaitForChild("BondConfig"))

local MountService = {}
MountService.Mounted = Signal.new() -- (player, model)
MountService.Dismounted = Signal.new() -- (player, model)

local Data
local DragonService
local PhysicsGroups
local TreeService

local folder: Folder
local companions: { [Player]: any } = {}

local MODES = { Ground = true, Air = true, Takeoff = true, Fly = true, Landing = true }
local SHOTS = { Jump = true, Takeoff = true, Landing = true, Roar = true }
local VALIDATE_INTERVAL = 0.25

local rayParams = RaycastParams.new()
rayParams.CollisionGroup = "DragonQuery"
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = false

local function groundBelow(pos: Vector3, depth: number): number?
	local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -(depth + 4), 0), rayParams)
	return hit and hit.Position.Y or nil
end

local function characterParts(player: Player)
	local character = player.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character, hrp, humanoid
end

local function yawOnly(cf: CFrame): CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(Vector3.zero, flat.Unit)
end

-- ============================================================== spawning
function MountService.Get(player: Player)
	return companions[player]
end

function MountService.GetModel(player: Player): Model?
	local c = companions[player]
	return c and c.Model or nil
end

local function despawn(player: Player)
	local comp = companions[player]
	if not comp then
		return
	end
	companions[player] = nil
	if comp.Riding then
		local character, hrp, humanoid = characterParts(player)
		if character and hrp and humanoid then
			humanoid.PlatformStand = false
			character:SetAttribute("Mounted", nil)
			PhysicsGroups.setGroup(character, "Characters")
		end
	end
	if comp.Model then
		comp.Model:Destroy()
	end
end

-- Great Tree bonus of the owner (fraction): FlySpeed "Wind Wings", RunSpeed "Swift Paws".
local function treeBonus(player: Player?, id: string): number
	return player and TreeService and TreeService.Bonus(player, id) or 0
end

-- Identity + stat attributes of the companion model for a dragon record.
local function writeRecordAttributes(model: Model, record, info, player: Player?)
	model:SetAttribute("DragonUid", record.UniqueId)
	model:SetAttribute("SpeciesId", record.SpeciesId)
	model:SetAttribute("Mutation", record.Mutation)
	model:SetAttribute("DisplayName", record.Name)
	model:SetAttribute("Level", record.Level)
	model:SetAttribute("Rarity", record.Rarity)
	model:SetAttribute("HipHeight", info.HipHeight)
	model:SetAttribute("BodyRadius", info.BodyRadius)
	model:SetAttribute("Scale", info.Scale)
	model:SetAttribute("RunSpeed", DragonStats.runSpeed(record, treeBonus(player, "RunSpeed")))
	model:SetAttribute("CruiseSpeed", DragonStats.cruiseSpeed(record, treeBonus(player, "FlySpeed")))
	model:SetAttribute("BondLevel", BondConfig.levelFor(record.BondXP))
	model:SetAttribute("Odds", Odds.ofRecord(record))
	model:SetAttribute("Exclusive", Odds.isExclusive(record.SpeciesId))
end

local function spawnFor(player: Player)
	despawn(player)
	-- developer switch (UI test harness): no companions at all
	if ReplicatedStorage:GetAttribute("DevDisableCompanions") then
		return nil
	end
	local data = Data.Get(player)
	if not data then
		return nil
	end
	local uid = data.EquippedDragon
	local record = uid ~= "" and data.Dragons[uid] or nil
	if not record then
		return nil
	end
	local character, hrp = characterParts(player)
	if not character or not hrp then
		return nil
	end
	local info = Builder.mountInfo(record.SpeciesId)

	-- beside and slightly behind the player, on the ground
	local base = yawOnly(hrp.CFrame) + hrp.Position
	local spot = (base * CFrame.new(info.BodyRadius + 4, 0, info.BodyRadius * 0.6)).Position
	local gy = groundBelow(spot + Vector3.new(0, 20, 0), 80) or (hrp.Position.Y - 3)
	local cf = CFrame.new(spot.X, gy + info.HipHeight, spot.Z) * yawOnly(hrp.CFrame)

	local model = Instance.new("Model")
	model.Name = "Dragon_" .. player.UserId
	model:SetAttribute("OwnerUserId", player.UserId)
	writeRecordAttributes(model, record, info, player)
	model:SetAttribute("Mode", "Ground")
	model:SetAttribute("Boost", false)
	model:SetAttribute("Breathing", false)
	model:SetAttribute("RiderUserId", 0)
	model:SetAttribute("ShotId", 0)
	model:SetAttribute("Kind", "Companion")
	model:SetAttribute("VisualRev", 0)

	local root = Builder.makeRoot(record.SpeciesId)
	root.CFrame = cf
	root.Parent = model
	model.PrimaryPart = root
	local att = root:FindFirstChild("RootAttachment") :: Attachment

	local lv = Instance.new("LinearVelocity")
	lv.Name = "Drive"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root

	local ao = Instance.new("AlignOrientation")
	ao.Name = "Attitude"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = true
	ao.MaxTorque = math.huge
	ao.Responsiveness = 200
	ao.CFrame = cf.Rotation
	ao.Parent = root

	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	end)
	PhysicsGroups.setGroup(model, "Dragons")
	model.Parent = folder
	pcall(function()
		model:AddPersistentPlayer(player)
	end)
	pcall(function()
		root:SetNetworkOwner(player)
	end)

	local comp = {
		Player = player,
		Model = model,
		Root = root,
		Uid = uid,
		Record = record,
		Info = info,
		Riding = false,
		Joint = nil,
		LastPos = root.Position,
		LastGood = cf,
		LastT = os.clock(),
		Violations = 0,
		ShotId = 0,
	}
	companions[player] = comp
	return comp
end
MountService.Spawn = spawnFor

-- Hot-swaps the companion to another dragon record without despawning: the
-- physics root keeps flying, a rider stays seated, and clients rebuild only
-- the visual (VisualRev changes). Used for equip switches and mutations.
local function swapRecord(comp, record)
	local info = Builder.mountInfo(record.SpeciesId)
	local model = comp.Model
	writeRecordAttributes(model, record, info, comp.Player)
	comp.Root.Size = info.RootSize
	comp.Uid = record.UniqueId
	comp.Record = record
	comp.Info = info
	if comp.Joint then
		comp.Joint.C0 = info.Saddle
	end
	model:SetAttribute("VisualRev", (model:GetAttribute("VisualRev") or 0) + 1)
end

-- ============================================================== mount / dismount
local function mount(player: Player)
	local comp = companions[player] or spawnFor(player)
	if not comp then
		return false, "NO_DRAGON", "Equip a dragon first."
	end
	if comp.Riding then
		return true
	end
	local character, hrp, humanoid = characterParts(player)
	if not character or not hrp or not humanoid then
		return false, "NO_CHARACTER"
	end
	local root = comp.Root
	-- far away (e.g. after a teleport): bring the dragon to the rider first
	if (root.Position - hrp.Position).Magnitude > 90 then
		comp = spawnFor(player)
		if not comp then
			return false, "NO_DRAGON"
		end
		root = comp.Root
	end
	local joint = Instance.new("Motor6D")
	joint.Name = "RiderJoint"
	joint.Part0 = root
	joint.Part1 = hrp
	joint.C0 = comp.Info.Saddle
	joint.C1 = CFrame.new(0, -(hrp.Size.Y * 0.5 + 0.12), 0)
	character:SetAttribute("Mounted", true)
	PhysicsGroups.setGroup(character, "Riders")
	humanoid.PlatformStand = true
	humanoid.Sit = false
	joint.Parent = root
	comp.Joint = joint
	comp.Riding = true
	comp.Model:SetAttribute("RiderUserId", player.UserId)
	player:SetAttribute("Riding", true)
	pcall(function()
		root:SetNetworkOwner(player)
	end)
	MountService.Mounted:Fire(player, comp.Model)
	return true
end

local function dismount(player: Player)
	local comp = companions[player]
	if not comp or not comp.Riding then
		return true
	end
	comp.Riding = false
	if comp.Joint then
		comp.Joint:Destroy()
		comp.Joint = nil
	end
	comp.Model:SetAttribute("RiderUserId", 0)
	player:SetAttribute("Riding", false)
	local character, hrp, humanoid = characterParts(player)
	if character and hrp and humanoid then
		character:SetAttribute("Mounted", nil)
		PhysicsGroups.setGroup(character, "Characters")
		humanoid.PlatformStand = false
		-- step off on the dragon's left side, upright
		local root = comp.Root
		local side = (yawOnly(root.CFrame) + root.Position) * CFrame.new(-(comp.Info.RootSize.X * 0.5 + 3), 0, 0)
		local pos = side.Position
		local gy = groundBelow(pos + Vector3.new(0, 6, 0), comp.Info.HipHeight + 30)
		local y = gy and (gy + humanoid.HipHeight + hrp.Size.Y * 0.5 + 0.2) or pos.Y
		hrp.CFrame = CFrame.new(pos.X, y, pos.Z) * yawOnly(root.CFrame)
		hrp.AssemblyLinearVelocity = Vector3.zero
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	pcall(function()
		comp.Root:SetNetworkOwner(player)
	end)
	MountService.Dismounted:Fire(player, comp.Model)
	return true
end
MountService.Mount = mount
MountService.Dismount = dismount

-- Re-reads stat attributes after something changed them (Great Tree bonuses, bond level).
-- The visual is rebuilt when the Bond Aura (bond level 50) appears.
function MountService.RefreshStats(player: Player)
	local comp = companions[player]
	if comp and comp.Model.Parent then
		local data = Data.Get(player)
		local record = data and data.Dragons[comp.Uid] or comp.Record
		comp.Record = record
		local hadAura = (comp.Model:GetAttribute("BondLevel") or 0) >= BondConfig.PerkById.Aura.Level
		writeRecordAttributes(comp.Model, record, comp.Info, player)
		local hasAura = (comp.Model:GetAttribute("BondLevel") or 0) >= BondConfig.PerkById.Aura.Level
		if hadAura ~= hasAura then
			comp.Model:SetAttribute("VisualRev", (comp.Model:GetAttribute("VisualRev") or 0) + 1)
		end
	end
end

-- Server-validated one-shot animation for everybody else (BondService: Dash, Flourish).
function MountService.PlayShot(player: Player, shot: string)
	local comp = companions[player]
	if not comp or not comp.Model.Parent then
		return
	end
	comp.ShotId = (comp.ShotId + 1) % 10000
	comp.Model:SetAttribute("Shot", shot)
	comp.Model:SetAttribute("ShotId", comp.ShotId)
end

function MountService.IsRiding(player: Player): boolean
	local comp = companions[player]
	return comp ~= nil and comp.Riding
end

-- Server teleport of the companion (fast travel while riding): moves the
-- physics root (the rider follows through the joint) and resets the
-- movement validation so the jump is not treated as a speed violation.
function MountService.MoveTo(player: Player, cf: CFrame)
	local comp = companions[player]
	if not comp or not comp.Root.Parent then
		return false
	end
	local root = comp.Root
	local target = CFrame.new(cf.Position) * yawOnly(cf)
	root.CFrame = target
	root.AssemblyLinearVelocity = Vector3.zero
	comp.LastPos = target.Position
	comp.LastGood = target
	comp.LastT = os.clock()
	comp.Violations = 0
	return true
end

-- ============================================================== validation
local function maxSpeedFor(comp): number
	local cruise = DragonStats.cruiseSpeed(comp.Record, treeBonus(comp.Player, "FlySpeed"))
	local run = DragonStats.runSpeed(comp.Record, treeBonus(comp.Player, "RunSpeed"))
	local m = GameConfig.Movement
	-- boost + dive bonus + generous slack for latency (+ the Wind Dash window)
	local limit = math.max(cruise * m.BoostMultiplier * 1.75, run * 1.6) + 60
	if comp.DashUntil and os.clock() < comp.DashUntil then
		limit *= 1.6
	end
	return limit
end

local function snapBack(player: Player, comp)
	local root = comp.Root
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	root.CFrame = comp.LastGood
	root.AssemblyLinearVelocity = Vector3.zero
	task.delay(0.4, function()
		if companions[player] == comp and root.Parent then
			pcall(function()
				root:SetNetworkOwner(player)
			end)
		end
	end)
end

local function validate()
	local t = os.clock()
	for player, comp in companions do
		local root = comp.Root
		if not root.Parent then
			continue
		end
		local dt = t - comp.LastT
		if dt < VALIDATE_INTERVAL then
			continue
		end
		local pos = root.Position
		local dist = (pos - comp.LastPos).Magnitude
		local allowed = maxSpeedFor(comp) * dt + 25
		local ok = dist <= allowed
		if not ok then
			-- follow catch-up teleports to the owner are allowed
			local _, hrp = characterParts(player)
			if hrp and not comp.Riding and (pos - hrp.Position).Magnitude < 60 then
				ok = true
			end
		end
		if pos.Y > GameConfig.Riding.Ceiling + 120 or pos.Y < Workspace.FallenPartsDestroyHeight + 50 then
			ok = false
		end
		if ok then
			comp.Violations = math.max(0, comp.Violations - 0.5)
			comp.LastGood = root.CFrame
		else
			comp.Violations += 1
			if comp.Violations >= 3 then
				comp.Violations = 0
				snapBack(player, comp)
				pos = comp.LastGood.Position
			end
		end
		comp.LastPos = pos
		comp.LastT = t
	end
end

-- ============================================================== state relay
local function onDragonState(player: Player, p)
	local comp = companions[player]
	if not comp then
		return
	end
	local model = comp.Model
	if type(p.Mode) == "string" and MODES[p.Mode] then
		model:SetAttribute("Mode", p.Mode)
	end
	if type(p.Boost) == "boolean" then
		model:SetAttribute("Boost", p.Boost)
	end
	if type(p.Shot) == "string" and SHOTS[p.Shot] then
		comp.ShotId = (comp.ShotId + 1) % 10000
		model:SetAttribute("Shot", p.Shot)
		model:SetAttribute("ShotId", comp.ShotId)
	end
end

-- ============================================================== lifecycle
function MountService.Init(services)
	Data = services.PlayerDataService
	DragonService = services.DragonService
	PhysicsGroups = services.PhysicsGroups
	TreeService = services.TreeService

	folder = Workspace:FindFirstChild("Dragons") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Dragons"
		folder.Parent = Workspace
	end

	Net.handle("Mount", "Ride", function(player)
		return mount(player)
	end, { Burst = 4, PerSecond = 1.5 })
	Net.handle("Mount", "Dismount", function(player)
		return dismount(player)
	end, { Burst = 4, PerSecond = 1.5 })
	Net.handle("Mount", "Toggle", function(player)
		local comp = companions[player]
		if comp and comp.Riding then
			local ok = dismount(player)
			return ok, { Riding = false }
		end
		local ok, err, msg = mount(player)
		if ok then
			return true, { Riding = true }
		end
		return false, err, msg
	end, { Burst = 4, PerSecond = 1.5 })
	Net.handle("Mount", "Recall", function(player)
		local riding = MountService.IsRiding(player)
		if riding then
			return false, "RIDING"
		end
		return spawnFor(player) ~= nil
	end, { Burst = 2, PerSecond = 0.2 })
	Net.onEvent("DragonState", onDragonState, { Burst = 12, PerSecond = 8 })
end

function MountService.Start()
	DragonService.EquippedChanged:Connect(function(player: Player, uid: string)
		local comp = companions[player]
		local data = Data.Get(player)
		local record = data and uid ~= "" and data.Dragons[uid] or nil
		if comp and comp.Model.Parent and record then
			if comp.Uid == uid and comp.Record.Mutation == record.Mutation then
				-- same dragon (fed / levelled): refresh stats and labels
				comp.Record = record
				writeRecordAttributes(comp.Model, record, comp.Info, player)
			else
				-- another dragon or a new mutation: hot swap in place
				swapRecord(comp, record)
			end
			return
		end
		if comp and comp.Riding then
			dismount(player)
		end
		despawn(player)
		if record then
			spawnFor(player)
		end
	end)

	local function onCharacter(player: Player, character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then
			return
		end
		character:WaitForChild("HumanoidRootPart", 10)
		task.wait(0.2)
		if player.Parent ~= Players or player.Character ~= character then
			return
		end
		if Data.Get(player) then
			spawnFor(player)
		end
		humanoid.Died:Connect(function()
			local comp = companions[player]
			if comp and comp.Riding then
				comp.Riding = false
				if comp.Joint then
					comp.Joint:Destroy()
					comp.Joint = nil
				end
				comp.Model:SetAttribute("RiderUserId", 0)
				player:SetAttribute("Riding", false)
			end
		end)
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(despawn)
	Data.Loaded:Connect(function(player)
		if player.Character and not companions[player] then
			spawnFor(player)
		end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= VALIDATE_INTERVAL then
			acc = 0
			validate()
		end
	end)
end

return MountService

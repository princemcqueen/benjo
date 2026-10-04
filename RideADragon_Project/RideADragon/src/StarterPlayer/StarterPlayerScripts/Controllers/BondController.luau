--[[
	BondController
	Client side of the Dragon Bond (see BondConfig / BondService):

	  * reads the equipped dragon's bond (data.Dragons[uid].BondXP) and exposes it
	    (BondController.info()) for the HUD bond bar
	  * input while riding: Q dash, hold E fire breath, Z sky dance - only the
	    abilities the dragon's bond level has unlocked; cooldowns mirror the server
	    (Great Tree "Quick Feathers" shortens them)
	  * everybody's fire breath: watches the "Breathing" attribute of every dragon
	    model (BreathFX flames + the held FireBreath animation), so other players see
	    your flames too
	  * level-up fanfare on the "BondUp" signal
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local BreathFX = require(Shared:WaitForChild("Dragons"):WaitForChild("BreathFX"))
local BondConfig = require(Configs:WaitForChild("BondConfig"))
local TreeConfig = require(Configs:WaitForChild("TreeConfig"))

local BondController = {}

local LocalPlayer = Players.LocalPlayer
local registry
local cooldownEnd = { Dash = 0, Fire = 0, Flourish = 0 }
local cooldownLen = { Dash = 1, Fire = 1, Flourish = 1 }
local firing = false
local fireStart = 0
local lastHint = 0
local watched: { [Model]: boolean } = {}

-- ============================================================== bond state
local function equipped()
	local data = registry.DataController.all()
	local uid = data and data.EquippedDragon
	local record = data and uid and uid ~= "" and data.Dragons[uid] or nil
	return record, uid
end

function BondController.points(): number
	local record = equipped()
	return record and tonumber(record.BondXP) or 0
end

function BondController.level(): number
	return BondConfig.levelFor(BondController.points())
end

function BondController.has(perk: string): boolean
	return BondConfig.has(BondController.points(), perk)
end

local function cooldownScale(): number
	return 1 - math.clamp(TreeConfig.bonus(registry.DataController.all(), "QuickFeathers"), 0, 0.9)
end

-- 0 (ready) .. 1 (just used)
function BondController.cooldown(action: string): number
	local left = cooldownEnd[action] - os.clock()
	if left <= 0 then
		return 0
	end
	return math.clamp(left / math.max(0.1, cooldownLen[action]), 0, 1)
end

-- Everything the HUD bond bar shows.
function BondController.info()
	local record = equipped()
	local points = record and tonumber(record.BondXP) or 0
	local level, into, need = BondConfig.progress(points)
	local nextPerk = BondConfig.nextPerk(level)
	return {
		HasDragon = record ~= nil,
		Name = record and record.Name or "",
		Level = level,
		Into = into,
		Need = need,
		NextPerk = nextPerk,
		Unlocked = {
			Dash = level >= BondConfig.PerkById.Dash.Level,
			Fire = level >= BondConfig.PerkById.Fire.Level,
			Flourish = level >= BondConfig.PerkById.Flourish.Level,
			Aura = level >= BondConfig.PerkById.Aura.Level,
		},
		Cooldown = { Dash = BondController.cooldown("Dash"), Fire = BondController.cooldown("Fire"), Flourish = BondController.cooldown("Flourish") },
		Firing = firing,
	}
end

-- ============================================================== abilities
local function locked(perkId: string)
	local perk = BondConfig.PerkById[perkId]
	if os.clock() - lastHint < 2.5 then
		return
	end
	lastHint = os.clock()
	registry.UIController.Notify("info", string.format("Ride this dragon until Bond Level %d to unlock %s.", perk.Level, perk.Name))
end

local function ready(action: string): boolean
	return os.clock() >= cooldownEnd[action]
end

local function startCooldown(action: string, base: number)
	local len = base * cooldownScale()
	cooldownLen[action] = len
	cooldownEnd[action] = os.clock() + len
end

local function tryDash()
	if not BondController.has("Dash") then
		return locked("Dash")
	end
	if LocalPlayer:GetAttribute("RaceActive") then
		return -- races are flown with the standard dragon: no bond perks, the boost rings do the job
	end
	if not ready("Dash") then
		return
	end
	local ab = BondConfig.Abilities.Dash
	if registry.DragonController.dash(ab.Duration, ab.Multiplier) then
		startCooldown("Dash", ab.Cooldown)
		Net.fire("BondAction", { Action = "Dash" })
	end
end

local function tryFlourish()
	if not BondController.has("Flourish") then
		return locked("Flourish")
	end
	if not ready("Flourish") then
		return
	end
	local model = registry.DragonController.getModel()
	if not model then
		return
	end
	startCooldown("Flourish", BondConfig.Abilities.Flourish.Cooldown)
	registry.AnimationController.play(model, "Flourish")
	registry.CameraController.shake(0.08)
	Net.fire("BondAction", { Action = "Flourish" })
end

local function startFire()
	if firing then
		return
	end
	if not BondController.has("Fire") then
		return locked("Fire")
	end
	if not ready("Fire") then
		return
	end
	local model = registry.DragonController.getModel()
	if not model then
		return
	end
	firing = true
	fireStart = os.clock()
	BreathFX.start(model)
	registry.AnimationController.play(model, "FireBreath")
	-- the lunge (0.2 s into the animation): the camera kicks as the flames burst out
	task.delay(0.2, function()
		if firing then
			registry.CameraController.shake(0.12)
		end
	end)
	Net.fire("BondAction", { Action = "FireStart" })
end

local function stopFire()
	if not firing then
		return
	end
	firing = false
	startCooldown("Fire", BondConfig.Abilities.Fire.Cooldown)
	local model = registry.DragonController.getModel()
	if model then
		BreathFX.stop(model)
		registry.AnimationController.stop(model, "FireBreath")
	end
	Net.fire("BondAction", { Action = "FireStop" })
end

-- ============================================================== everybody's flames
local function watch(model: Instance)
	if not model:IsA("Model") or watched[model] then
		return
	end
	watched[model] = true
	local function apply()
		local on = model:GetAttribute("Breathing") == true
		local mine = model:GetAttribute("OwnerUserId") == LocalPlayer.UserId
		if mine then
			-- the owner drives their own flames (instant response); the server flag
			-- only ends them if the server refused or timed the breath out
			if not on and firing and os.clock() - fireStart > 0.6 then
				stopFire()
			end
			return
		end
		if on then
			BreathFX.start(model)
			registry.AnimationController.play(model, "FireBreath")
		else
			BreathFX.stop(model)
			registry.AnimationController.stop(model, "FireBreath")
		end
	end
	model:GetAttributeChangedSignal("Breathing"):Connect(apply)
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			watched[model] = nil
			BreathFX.stop(model)
		end
	end)
	apply()
end

-- ============================================================== fanfare
local function burstAt(position: Vector3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(position)
	p.Parent = Workspace
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(255, 226, 120), Color3.fromRGB(255, 150, 200))
	e.LightEmission = 1
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.9, 1.6)
	e.Speed = NumberRange.new(14, 30)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -6, 0)
	e.Drag = 2
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
	e.Parent = p
	e:Emit(70)
	task.delay(2.2, function()
		p:Destroy()
	end)
end

local function onBondUp(payload)
	local model = registry.DragonController.getModel()
	local root = model and model:FindFirstChild("Root") :: BasePart?
	if root then
		burstAt(root.Position + Vector3.new(0, 4, 0))
	end
	registry.AudioController.playUI("LevelUp")
	if registry.DragonController.isRiding() then
		registry.CameraController.shake(0.1)
	end
	registry.AnimationController.react("LevelUp", 1)
	local _ = payload
end

-- ============================================================== lifecycle
function BondController.Init(reg)
	registry = reg
end

function BondController.Start()
	registry.InputController.Pressed:Connect(function(action)
		if not registry.DragonController.isRiding() then
			return
		end
		if action == "Dash" then
			tryDash()
		elseif action == "Flourish" then
			tryFlourish()
		elseif action == "Fire" then
			startFire()
		end
	end)
	local hudTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		hudTimer += dt
		if hudTimer >= 0.1 and registry.Hud and registry.DragonController.isRiding() then
			hudTimer = 0
			registry.Hud:SetBond(BondController.info())
		end
		if firing then
			local input = registry.InputController
			local maxSeconds = BondConfig.Abilities.Fire.MaxSeconds
			if not registry.DragonController.isRiding() or not input.isDown("Fire") or os.clock() - fireStart > maxSeconds then
				stopFire()
			end
		end
	end)
	Net.onSignal("BondUp", onBondUp)
	task.spawn(function()
		local folder = Workspace:WaitForChild("Dragons", 30)
		if not folder then
			return
		end
		for _, m in folder:GetChildren() do
			watch(m)
		end
		folder.ChildAdded:Connect(watch)
	end)
	-- ending a ride ends the flames
	registry.DragonController.RidingChanged:Connect(function(riding)
		if not riding then
			stopFire()
		end
	end)
end

return BondController

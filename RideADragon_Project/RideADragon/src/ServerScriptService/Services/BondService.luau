--[[
	BondService
	Dragon Bond: riding one dragon raises ITS bond (data.Dragons[uid].BondXP).
	Perks unlock by bond level (BondConfig): Wind Dash (5), Fire Breath (10),
	Sky Dance (20), Bond Aura (50).

	Server authority:
	  * points are only earned while riding AND moving (no AFK farming)
	  * a client can only use an ability its dragon's bond has unlocked, and the
	    cooldowns / breath duration are enforced here
	  * abilities are replicated to everyone through attributes on the dragon's
	    model: Shot (Dash / Flourish, via MountService.PlayShot), Breathing (bool)
	    and BondLevel (aura at level 50)

	Net event "BondAction" { Action = "Dash" | "Flourish" | "FireStart" | "FireStop" }
	Net signal "BondUp"  { Uid, Level, Perks = { id... } }  (level-up fanfare)
	Signals: LevelUp(player, uid, level, perks), Burned(player, instance)

	Burnable things: any instance tagged "Burnable" within the breath cone catches
	fire, burns away and comes back after RespawnSeconds (attribute, default 40).
	Optional attribute Reward = cash paid to the player who burned it.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local BondConfig = require(Configs:WaitForChild("BondConfig"))

local BondService = {}
BondService.LevelUp = Signal.new() -- (player, uid, level, perks)
BondService.Burned = Signal.new() -- (player, instance)

local Data
local Services

local lastPos: { [Player]: Vector3 } = {}
local cooldowns: { [Player]: { [string]: number } } = {}
local breathing: { [Player]: { Token: number, Start: number } } = {}
local tokenCounter = 0

-- ============================================================== queries
local function record(player: Player, uid: string?)
	local data = Data.Get(player)
	return data and uid and data.Dragons[uid] or nil
end

function BondService.Points(player: Player, uid: string?): number
	local r = record(player, uid)
	return r and tonumber(r.BondXP) or 0
end

function BondService.Level(player: Player, uid: string?): number
	return BondConfig.levelFor(BondService.Points(player, uid))
end

-- The dragon the player is riding right now (comp), if any.
local function riding(player: Player)
	local mount = Services.MountService
	local comp = mount and mount.Get(player)
	if comp and comp.Riding and comp.Model.Parent then
		return comp
	end
	return nil
end

-- Does the dragon the player is riding (or has equipped) have this perk?
function BondService.Has(player: Player, perkId: string): boolean
	local comp = riding(player)
	local uid = comp and comp.Uid
	if not uid then
		local data = Data.Get(player)
		uid = data and data.EquippedDragon
	end
	return uid ~= nil and uid ~= "" and BondConfig.has(BondService.Points(player, uid), perkId)
end

-- ============================================================== points
local function refreshModel(player: Player)
	local mount = Services.MountService
	if mount and mount.RefreshStats then
		mount.RefreshStats(player)
	end
end

function BondService.AddPoints(player: Player, uid: string, points: number)
	local r = record(player, uid)
	if not r or points <= 0 then
		return
	end
	local old = tonumber(r.BondXP) or 0
	local cap = BondConfig.threshold(BondConfig.MaxLevel)
	local new = math.floor(math.min(cap, old + points) * 10 + 0.5) / 10
	if new == old then
		return
	end
	Data.Set(player, { "Dragons", uid, "BondXP" }, new)
	local oldLevel, newLevel = BondConfig.levelFor(old), BondConfig.levelFor(new)
	if newLevel > oldLevel then
		local perks = {}
		for _, perk in BondConfig.unlockedBetween(oldLevel, newLevel) do
			table.insert(perks, perk.Id)
		end
		refreshModel(player)
		Net.signal(player, "BondUp", { Uid = uid, Level = newLevel, Perks = perks })
		Net.notify(player, "rare", string.format("%s: Bond Level %d!", r.Name, newLevel))
		for _, perk in BondConfig.unlockedBetween(oldLevel, newLevel) do
			local key = perk.Key and (" (" .. perk.Key .. ")") or ""
			Net.notify(player, "rare", string.format("Unlocked %s%s", perk.Name, key))
		end
		BondService.LevelUp:Fire(player, uid, newLevel, perks)
	end
end

local function tick()
	local cfg = BondConfig
	for _, player in Players:GetPlayers() do
		local comp = riding(player)
		if comp then
			local pos = comp.Root.Position
			local prev = lastPos[player]
			lastPos[player] = pos
			if prev and (pos - prev).Magnitude >= cfg.MinMove then
				local model = comp.Model
				local rate = cfg.Rate.Ground
				if model:GetAttribute("Boost") == true then
					rate = cfg.Rate.Boost
				elseif model:GetAttribute("Mode") == "Fly" then
					rate = cfg.Rate.Fly
				end
				BondService.AddPoints(player, comp.Uid, rate * cfg.TickSeconds)
			end
		else
			lastPos[player] = nil
		end
	end
end

-- ============================================================== burnables
local function ignite(player: Player, inst: Instance)
	if inst:GetAttribute("Burning") then
		return
	end
	inst:SetAttribute("Burning", true)
	local parts = {}
	if inst:IsA("BasePart") then
		table.insert(parts, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local first = parts[1]
	if not first then
		inst:SetAttribute("Burning", nil)
		return
	end
	local fire = Instance.new("Fire")
	fire.Heat = 8
	fire.Size = math.clamp(first.Size.Magnitude * 0.5, 4, 14)
	fire.Parent = first
	task.delay(1.4, function()
		fire:Destroy()
		local saved = {}
		for _, p in parts do
			saved[p] = { Transparency = p.Transparency, CanCollide = p.CanCollide, CanQuery = p.CanQuery, CanTouch = p.CanTouch }
			p.Transparency = 1
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
		end
		local reward = tonumber(inst:GetAttribute("Reward")) or 0
		if reward > 0 and player.Parent == Players then
			Services.EconomyService.Earn(player, reward, "Burn")
		end
		BondService.Burned:Fire(player, inst)
		task.delay(tonumber(inst:GetAttribute("RespawnSeconds")) or 40, function()
			for p, s in saved do
				if p.Parent then
					p.Transparency = s.Transparency
					p.CanCollide = s.CanCollide
					p.CanQuery = s.CanQuery
					p.CanTouch = s.CanTouch
				end
			end
			inst:SetAttribute("Burning", nil)
		end)
	end)
end

local function instancePosition(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	local part = inst:FindFirstChildWhichIsA("BasePart", true)
	return part and part.Position or nil
end

-- One breath tick: burn Burnable things inside the cone in front of the dragon.
local function breathTick(player: Player, comp)
	local root = comp.Root
	local cfg = BondConfig.Abilities.Fire
	local origin = root.Position + root.CFrame.LookVector * (comp.Info and comp.Info.BodyRadius or 4)
	local look = root.CFrame.LookVector
	for _, inst in CollectionService:GetTagged("Burnable") do
		if not inst:GetAttribute("Burning") then
			local pos = instancePosition(inst)
			if pos then
				local to = pos - origin
				local d = to.Magnitude
				if d <= cfg.Range + 6 and (d < 6 or to.Unit:Dot(look) > 0.55) then
					ignite(player, inst)
				end
			end
		end
	end
end

local function stopBreath(player: Player, token: number?)
	local b = breathing[player]
	if not b or (token and b.Token ~= token) then
		return
	end
	breathing[player] = nil
	local mount = Services.MountService
	local model = mount and mount.GetModel(player)
	if model then
		model:SetAttribute("Breathing", false)
	end
	local cd = cooldowns[player]
	if cd then
		cd.Fire = os.clock() + BondConfig.Abilities.Fire.Cooldown
	end
end

local function startBreath(player: Player, comp)
	tokenCounter += 1
	local token = tokenCounter
	breathing[player] = { Token = token, Start = os.clock() }
	comp.Model:SetAttribute("Breathing", true)
	local cfg = BondConfig.Abilities.Fire
	task.spawn(function()
		local elapsed = 0
		while breathing[player] and breathing[player].Token == token and elapsed < cfg.MaxSeconds do
			task.wait(cfg.Tick)
			elapsed += cfg.Tick
			local c = riding(player)
			if not c then
				break
			end
			breathTick(player, c)
		end
		stopBreath(player, token)
	end)
end

-- ============================================================== actions
local function onAction(player: Player, p)
	if not Net.check.str(p.Action, 12) then
		return
	end
	local comp = riding(player)
	if not comp then
		return
	end
	local points = BondService.Points(player, comp.Uid)
	local cd = cooldowns[player]
	if not cd then
		cd = {}
		cooldowns[player] = cd
	end
	local t = os.clock()
	local ab = BondConfig.Abilities
	local mount = Services.MountService
	local action = p.Action
	if action == "Dash" then
		if BondConfig.has(points, "Dash") and t >= (cd.Dash or 0) then
			cd.Dash = t + ab.Dash.Cooldown
			comp.DashUntil = t + ab.Dash.Duration + ab.Dash.Allowance
			mount.PlayShot(player, "Dash")
		end
	elseif action == "Flourish" then
		if BondConfig.has(points, "Flourish") and t >= (cd.Flourish or 0) then
			cd.Flourish = t + ab.Flourish.Cooldown
			mount.PlayShot(player, "Flourish")
		end
	elseif action == "FireStart" then
		if BondConfig.has(points, "Fire") and t >= (cd.Fire or 0) and not breathing[player] then
			startBreath(player, comp)
		end
	elseif action == "FireStop" then
		stopBreath(player)
	end
end

-- ============================================================== lifecycle
function BondService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.onEvent("BondAction", onAction, { Burst = 12, PerSecond = 5 })
end

function BondService.Start()
	task.spawn(function()
		while true do
			task.wait(BondConfig.TickSeconds)
			pcall(tick)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
		cooldowns[player] = nil
		breathing[player] = nil
	end)
	-- dismounting ends the breath at once
	local mount = Services.MountService
	if mount and mount.Dismounted then
		mount.Dismounted:Connect(function(player)
			stopBreath(player)
		end)
	end
end

return BondService

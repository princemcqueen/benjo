--[[
	CombatService
	Dragon duels in the arena of the Race Island (CombatConfig). The server decides everything:

	  ZONE     every ZoneSeconds the riders inside the arena cylinder become fighters (player
	           attributes InArena, HP, MaxHP, Downed); flying out, dismounting or racing ends it.
	           Nobody is ever hit outside the arena.
	  STRIKE   a bite and tail slam in a cone in front of the dragon           (event CombatStrike)
	  BLAST    a fireball the server flies step by step, aimed with a direction  (event CombatBlast { Dir })
	  KO       to a respawn pad for RespawnDelay seconds (frozen there), then back with full HP and a
	           few seconds of protection. A knockout pays the killer cash + XP and counts for the
	           Arena Warriors board (Stats.ArenaKills).

	Hit points come from the dragon's level and rarity (CombatConfig.maxHP), so a fresh dragon is
	never helpless against a legend; damage grows the same way.

	Signals to everybody near the arena (spectators too):
	  CombatFx  { Kind = "Strike" | "Blast", Id?, From, Pos, Dir, Speed?, Life? }
	  CombatHit { Target, By, Damage, Crit, Kind, Pos }
	  CombatKO  { Victim, Killer, VictimName, KillerName }
	  CombatBlastEnd { Id, Pos, Hit }
	Signals to the fighter: CombatEnter { MaxHP, Invulnerable }, CombatLeave, CombatDown { Delay, By },
	                        CombatRespawn { Invulnerable }, CombatReward { Cash, XP, Victim }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local DragonConfig = require(Configs:WaitForChild("DragonConfig"))
local CombatConfig = require(Configs:WaitForChild("CombatConfig"))
local RaceConfig = require(Configs:WaitForChild("RaceConfig"))

local CombatService = {}

local Services
local Data

type Fighter = {
	Player: Player,
	MaxHP: number,
	HP: number,
	Level: number,
	Rank: number,
	Radius: number,
	Invuln: number,
	Dead: boolean,
	RespawnAt: number,
	LastHit: number,
	NextStrike: number,
	NextBlast: number,
}

local dummy = { HP = CombatConfig.Dummy.HP, Down = false, RespawnAt = 0, Model = nil :: Model? }
local fighters: { [Player]: Fighter } = {}
local blasts: { any } = {}
local nextBlastId = 0
local lastKill: { [string]: number } = {} -- "killer:victim" -> time of the last paid knockout

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- ============================================================== helpers
local function ridden(player: Player)
	local mount = Services.MountService
	local comp = mount and mount.Get(player)
	if comp and comp.Riding and comp.Root.Parent then
		return comp
	end
	return nil
end

local function insideArena(position: Vector3, margin: number?): boolean
	local center, radius, height = CombatConfig.arenaWorld()
	local m = margin or 0
	local dx, dz = position.X - center.X, position.Z - center.Z
	local r = radius + m
	return dx * dx + dz * dz <= r * r and position.Y >= center.Y - 8 - m and position.Y <= center.Y + height + m
end

-- Players who should see the fight: fighters and anybody on / near the island.
local function audience(): { Player }
	local center = CombatConfig.arenaWorld()
	local list = {}
	for _, p in Players:GetPlayers() do
		local comp = ridden(p)
		local position = comp and comp.Root.Position
		if not position then
			local character = p.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			position = hrp and hrp.Position
		end
		if fighters[p] or (position and (position - center).Magnitude < 700) then
			table.insert(list, p)
		end
	end
	return list
end

local function toNear(name: string, payload)
	for _, p in audience() do
		Net.signal(p, name, payload)
	end
end

local function setHP(player: Player, f: Fighter)
	player:SetAttribute("HP", math.max(0, math.floor(f.HP + 0.5)))
end

-- ============================================================== zone
local function enter(player: Player, comp)
	local record = comp.Record
	local level = tonumber(record.Level) or 1
	local rank = DragonConfig.rarityRank(record.Rarity)
	local maxHP = CombatConfig.maxHP(level, rank)
	local f: Fighter = {
		Player = player,
		MaxHP = maxHP,
		HP = maxHP,
		Level = level,
		Rank = rank,
		Radius = (comp.Info and comp.Info.BodyRadius) or 4,
		Invuln = now() + CombatConfig.Invulnerable,
		Dead = false,
		RespawnAt = 0,
		LastHit = 0,
		NextStrike = 0,
		NextBlast = 0,
	}
	fighters[player] = f
	player:SetAttribute("MaxHP", maxHP)
	player:SetAttribute("HP", maxHP)
	player:SetAttribute("Downed", nil)
	player:SetAttribute("InArena", true)
	Net.signal(player, "CombatEnter", { MaxHP = maxHP, Invulnerable = CombatConfig.Invulnerable })
end

local function leave(player: Player)
	local f = fighters[player]
	if not f then
		return
	end
	fighters[player] = nil
	player:SetAttribute("InArena", nil)
	player:SetAttribute("HP", nil)
	player:SetAttribute("MaxHP", nil)
	player:SetAttribute("Downed", nil)
	if f.Dead then
		local mount = Services.MountService
		if mount and mount.Freeze then
			mount.Freeze(player, false)
		end
	end
	for i = #blasts, 1, -1 do
		if blasts[i].Owner == player then
			table.remove(blasts, i)
		end
	end
	Net.signal(player, "CombatLeave", {})
end

-- The respawn pad farthest from everybody who is still standing.
local function pickRespawn(victim: Player): Vector3
	local best, bestScore = nil, -1
	for _, pad in CombatConfig.Respawns do
		local world = RaceConfig.toWorld(pad)
		local score = math.huge
		for other, of in fighters do
			if other ~= victim and not of.Dead then
				local comp = ridden(other)
				if comp then
					score = math.min(score, (comp.Root.Position - world).Magnitude)
				end
			end
		end
		if score > bestScore then
			best, bestScore = world, score
		end
	end
	return best or RaceConfig.toWorld(CombatConfig.Respawns[1])
end

local function respawn(player: Player, f: Fighter)
	f.Dead = false
	f.HP = f.MaxHP
	f.Invuln = now() + CombatConfig.Invulnerable
	f.LastHit = 0
	setHP(player, f)
	player:SetAttribute("Downed", nil)
	local mount = Services.MountService
	if mount and mount.Freeze then
		mount.Freeze(player, false)
	end
	Net.signal(player, "CombatRespawn", { Invulnerable = CombatConfig.Invulnerable })
end

local function dummyStep()
	if dummy.Down and now() >= dummy.RespawnAt then
		dummy.Down = false
		dummy.HP = CombatConfig.Dummy.HP
		if dummy.Model then
			dummy.Model:SetAttribute("HP", dummy.HP)
			dummy.Model:SetAttribute("Down", nil)
		end
	end
end

local function zoneStep()
	local t = now()
	dummyStep()
	for _, player in Players:GetPlayers() do
		local comp = ridden(player)
		local raceBusy = player:GetAttribute("RaceActive") == true
		local f = fighters[player]
		local inside = comp ~= nil and not raceBusy and insideArena(comp.Root.Position)
		if inside and not f then
			enter(player, comp)
		elseif f and not inside then
			leave(player)
		elseif f then
			if f.Dead then
				if t >= f.RespawnAt then
					respawn(player, f)
				end
			elseif f.HP < f.MaxHP and t - f.LastHit > CombatConfig.RegenDelay then
				f.HP = math.min(f.MaxHP, f.HP + f.MaxHP * CombatConfig.RegenPerSecond * CombatConfig.ZoneSeconds)
				setHP(player, f)
			end
		end
	end
end

-- ============================================================== damage / knockout
local function pay(killer: Player, victim: Player)
	local key = killer.UserId .. ":" .. victim.UserId
	local t = now()
	local repeated = lastKill[key] and t - lastKill[key] < 45
	lastKill[key] = t
	Data.Increment(killer, { "Stats", "ArenaKills" }, 1)
	if repeated then
		Net.notify(killer, "info", "Knockout! (no reward for the same opponent again so soon)")
		return
	end
	local reward = CombatConfig.KillReward
	local econ = Services.EconomyService
	local rate = econ and econ.IncomeRate(killer) or 0
	local cash = math.max(reward.Min, math.floor(rate * reward.Minutes * 60))
	if econ and cash > 0 then
		econ.Earn(killer, cash, "Arena")
	end
	local level = Services.LevelService
	if level and reward.XP > 0 then
		level.Add(killer, reward.XP, "Arena")
	end
	Net.signal(killer, "CombatReward", { Cash = cash, XP = reward.XP, Victim = victim.DisplayName })
	Net.notify(killer, "success", string.format("KNOCKOUT! %s  +$%s  +%d XP", victim.DisplayName, Format.abbreviate(cash), reward.XP))
end

local function knockOut(victim: Player, vf: Fighter, killer: Player?)
	vf.Dead = true
	vf.HP = 0
	vf.RespawnAt = now() + CombatConfig.RespawnDelay
	victim:SetAttribute("HP", 0)
	victim:SetAttribute("Downed", true)
	Data.Increment(victim, { "Stats", "ArenaDeaths" }, 1)
	-- to a respawn pad (nobody is standing next to it), held there until the delay is over
	local mount = Services.MountService
	local comp = ridden(victim)
	if comp and mount then
		local pad = pickRespawn(victim)
		local hip = comp.Model:GetAttribute("HipHeight") or 5
		local pos = Vector3.new(pad.X, pad.Y + 2 + hip, pad.Z)
		local centre = CombatConfig.arenaWorld()
		mount.MoveTo(victim, CFrame.lookAt(pos, Vector3.new(centre.X, pos.Y, centre.Z)))
		mount.Freeze(victim, true)
	end
	toNear("CombatKO", {
		Victim = victim.UserId,
		Killer = killer and killer.UserId or 0,
		VictimName = victim.DisplayName,
		KillerName = killer and killer.DisplayName or "",
	})
	Net.signal(victim, "CombatDown", { Delay = CombatConfig.RespawnDelay, By = killer and killer.DisplayName or "" })
	if killer and killer ~= victim then
		pay(killer, victim)
	end
end

local function damage(target: Player, amount: number, attacker: Player, kind: string, crit: boolean, at: Vector3): boolean
	local tf = fighters[target]
	if not tf or tf.Dead or now() < tf.Invuln then
		return false
	end
	local dealt = math.max(1, math.floor(amount + 0.5))
	tf.HP = math.max(0, tf.HP - dealt)
	tf.LastHit = now()
	setHP(target, tf)
	toNear("CombatHit", { Target = target.UserId, By = attacker.UserId, Damage = dealt, Crit = crit, Kind = kind, Pos = at })
	local mount = Services.MountService
	if mount and mount.PlayShot then
		mount.PlayShot(target, "Hurt")
	end
	if tf.HP <= 0 then
		knockOut(target, tf, attacker)
	end
	return true
end

-- The dummy is for practice: it only takes hits while nobody else stands in the arena, so in a duel
-- it never gets in the way (strikes and fireballs pass through it).
local function practicing(player: Player): boolean
	for other, f in fighters do
		if other ~= player and not f.Dead then
			return false
		end
	end
	return true
end

-- The training dummy: same damage rules, no reward, it does not hit back.
local function damageDummy(amount: number, attacker: Player, kind: string, crit: boolean, at: Vector3): boolean
	local cfg = CombatConfig.Dummy
	if dummy.Down then
		return false
	end
	local dealt = math.max(1, math.floor(amount + 0.5))
	dummy.HP = math.max(0, dummy.HP - dealt)
	if dummy.Model then
		dummy.Model:SetAttribute("HP", dummy.HP)
	end
	toNear("CombatHit", { Target = 0, By = attacker.UserId, Damage = dealt, Crit = crit, Kind = kind, Pos = at })
	if dummy.HP <= 0 then
		dummy.Down = true
		dummy.RespawnAt = now() + cfg.Respawn
		if dummy.Model then
			dummy.Model:SetAttribute("Down", true)
		end
		toNear("CombatKO", { Victim = 0, Killer = attacker.UserId, VictimName = cfg.Name, KillerName = attacker.DisplayName })
	end
	return true
end

-- ============================================================== attacks
local function attackReady(player: Player, kind: string)
	local f = fighters[player]
	local comp = ridden(player)
	if not f or f.Dead or not comp then
		return nil
	end
	local t = now()
	if kind == "Strike" then
		if t < f.NextStrike then
			return nil
		end
		f.NextStrike = t + CombatConfig.Strike.Cooldown * 0.9 -- a little slack for latency
	else
		if t < f.NextBlast then
			return nil
		end
		f.NextBlast = t + CombatConfig.Blast.Cooldown * 0.9
	end
	return f, comp
end

function CombatService.Strike(player: Player): boolean
	local f, comp = attackReady(player, "Strike")
	if not f then
		return false
	end
	local cfg = CombatConfig.Strike
	local root = comp.Root
	local forward = root.CFrame.LookVector
	local origin = root.Position
	local mount = Services.MountService
	mount.PlayShot(player, "Strike")
	toNear("CombatFx", { Kind = "Strike", From = player.UserId, Pos = origin, Dir = forward })
	local base = CombatConfig.baseDamage(f.Level, f.Rank) * cfg.Multiplier
	local cosLimit = math.cos(math.rad(cfg.Cone))
	for other, of in table.clone(fighters) do
		if other ~= player and not of.Dead then
			local ocomp = ridden(other)
			if ocomp then
				local delta = ocomp.Root.Position - origin
				local dist = delta.Magnitude
				if dist > 0.1 and dist <= cfg.Reach + of.Radius + f.Radius and delta.Unit:Dot(forward) >= cosLimit then
					local crit = math.random() < cfg.Crit
					damage(other, base * (crit and 1.5 or 1), player, "Strike", crit, ocomp.Root.Position)
				end
			end
		end
	end
	-- the dummy
	local target = CombatConfig.dummyWorld()
	local delta = target - origin
	local dist = delta.Magnitude
	if dist > 0.1 and dist <= cfg.Reach + CombatConfig.Dummy.Radius + f.Radius and delta.Unit:Dot(forward) >= cosLimit and practicing(player) then
		local crit = math.random() < cfg.Crit
		damageDummy(base * (crit and 1.5 or 1), player, "Strike", crit, target)
	end
	return true
end

-- The aim the client claims is trusted only within MaxAimSlack degrees of where the dragon points.
local function aimDirection(forward: Vector3, claimed: any): Vector3
	if typeof(claimed) ~= "Vector3" or claimed.Magnitude < 0.1 or claimed.Magnitude ~= claimed.Magnitude then
		return forward
	end
	local want = claimed.Unit
	local angle = math.acos(math.clamp(want:Dot(forward), -1, 1))
	local limit = math.rad(CombatConfig.MaxAimSlack)
	if angle <= limit then
		return want
	end
	local sideways = want - forward * want:Dot(forward)
	if sideways.Magnitude < 1e-3 then
		return forward
	end
	return (forward * math.cos(limit) + sideways.Unit * math.sin(limit)).Unit
end

function CombatService.Blast(player: Player, claimed: any?): boolean
	local f, comp = attackReady(player, "Blast")
	if not f then
		return false
	end
	local cfg = CombatConfig.Blast
	local root = comp.Root
	local dir = aimDirection(root.CFrame.LookVector, claimed)
	local origin = root.Position + dir * (f.Radius + 3)
	nextBlastId += 1
	local b = {
		Id = nextBlastId,
		Owner = player,
		Pos = origin,
		Dir = dir,
		Born = now(),
		Damage = CombatConfig.baseDamage(f.Level, f.Rank) * cfg.Multiplier,
	}
	table.insert(blasts, b)
	Services.MountService.PlayShot(player, "Cast")
	toNear("CombatFx", { Kind = "Blast", Id = b.Id, From = player.UserId, Pos = origin, Dir = dir, Speed = cfg.Speed, Life = cfg.Lifetime })
	return true
end

local function stepBlasts(dt: number)
	local cfg = CombatConfig.Blast
	local t = now()
	for i = #blasts, 1, -1 do
		local b = blasts[i]
		local prev = b.Pos
		local nextPos = prev + b.Dir * (cfg.Speed * dt)
		local seg = nextPos - prev
		local segLen2 = seg:Dot(seg)
		local hitPlayer: Player? = nil
		local hitDummy = false
		local hitAt = nextPos
		local bestT = 2
		do
			local c = CombatConfig.dummyWorld()
			local u = segLen2 > 0 and math.clamp((c - prev):Dot(seg) / segLen2, 0, 1) or 0
			local closest = prev + seg * u
			if not dummy.Down and (closest - c).Magnitude <= cfg.Radius + CombatConfig.Dummy.Radius and practicing(b.Owner) then
				bestT, hitDummy, hitAt = u, true, closest
			end
		end
		for other, of in fighters do
			if other ~= b.Owner and not of.Dead then
				local comp = ridden(other)
				if comp then
					local c = comp.Root.Position
					local u = segLen2 > 0 and math.clamp((c - prev):Dot(seg) / segLen2, 0, 1) or 0
					local closest = prev + seg * u
					if (closest - c).Magnitude <= cfg.Radius + of.Radius and u < bestT then
						bestT, hitPlayer, hitDummy, hitAt = u, other, false, closest
					end
				end
			end
		end
		if hitPlayer or hitDummy then
			table.remove(blasts, i)
			local crit = math.random() < CombatConfig.Strike.Crit
			if hitPlayer then
				damage(hitPlayer, b.Damage * (crit and 1.5 or 1), b.Owner, "Blast", crit, hitAt)
			else
				damageDummy(b.Damage * (crit and 1.5 or 1), b.Owner, "Blast", crit, hitAt)
			end
			toNear("CombatBlastEnd", { Id = b.Id, Pos = hitAt, Hit = true })
		elseif t - b.Born >= cfg.Lifetime or not insideArena(nextPos, 30) then
			table.remove(blasts, i)
			toNear("CombatBlastEnd", { Id = b.Id, Pos = nextPos, Hit = false })
		else
			b.Pos = nextPos
		end
	end
end

-- ============================================================== lifecycle
function CombatService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.onEvent("CombatStrike", function(player)
		CombatService.Strike(player)
	end, { Burst = 4, PerSecond = 2 })
	Net.onEvent("CombatBlast", function(player, p)
		CombatService.Blast(player, p and p.Dir)
	end, { Burst = 3, PerSecond = 1 })
end

-- The fighter record of a player (nil when not in the arena): other services / tests.
function CombatService.Fighter(player: Player): Fighter?
	return fighters[player]
end

function CombatService.Active(player: Player): boolean
	return fighters[player] ~= nil
end

function CombatService._blasts()
	return blasts
end

function CombatService._dummy()
	return dummy
end

function CombatService._zone()
	zoneStep()
end

function CombatService._step(dt: number)
	stepBlasts(dt)
end

function CombatService.Start()
	-- the dummy model is built with the island (RaceService): find it and give it its hit points
	task.spawn(function()
		for _ = 1, 120 do
			local m = Workspace:FindFirstChild("TrainingDummy", true)
			if m and m:IsA("Model") then
				dummy.Model = m
				m:SetAttribute("MaxHP", CombatConfig.Dummy.HP)
				m:SetAttribute("HP", dummy.HP)
				return
			end
			task.wait(1)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		fighters[player] = nil
		for i = #blasts, 1, -1 do
			if blasts[i].Owner == player then
				table.remove(blasts, i)
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(CombatConfig.ZoneSeconds)
			local ok, err = pcall(zoneStep)
			if not ok then
				warn("[Combat] zone: " .. tostring(err))
			end
		end
	end)
	task.spawn(function()
		local last = now()
		while true do
			task.wait(CombatConfig.Blast.Step)
			local t = now()
			local dt = math.clamp(t - last, 0.01, 0.2)
			last = t
			if #blasts > 0 then
				local ok, err = pcall(stepBlasts, dt)
				if not ok then
					warn("[Combat] blast: " .. tostring(err))
				end
			end
		end
	end)
end

return CombatService

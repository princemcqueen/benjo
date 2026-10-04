--[[
	SpinService
	Spin Island: builds the floating toy island (stand, podium + prompt,
	trees, clouds; the wheel rotor itself is built by each client) and runs
	the server-authoritative spins.

	data.Spin = { NextFree = os.time when the free spin is ready, Tickets = n }

	Net (domain "Spin"): Roll {} -> { Index, Prize = { Kind, Label, Amount?, Egg?, Count? }, Free, Tickets, NextFree }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))
local SpinConfig = require(Configs:WaitForChild("SpinConfig"))
local EggConfig = require(Configs:WaitForChild("EggConfig"))
local EconomyConfig = require(Configs:WaitForChild("EconomyConfig"))
local MonetizationConfig = require(Configs:WaitForChild("MonetizationConfig"))

local SpinService = {}

local Services
local Data
local rng = Random.new()

local V3 = Vector3.new
local CF = CFrame.new

local function now(): number
	return os.time()
end

-- ============================================================== island (world)
local GRASS = Color3.fromRGB(75, 151, 74)
local DIRT = Color3.fromRGB(124, 80, 46)
local ROCK = Color3.fromRGB(163, 162, 165)
local ROCK_DARK = Color3.fromRGB(99, 95, 98)
local RED = Color3.fromRGB(196, 40, 27)
local YELLOW = Color3.fromRGB(245, 205, 47)
local WHITE = Color3.fromRGB(242, 243, 242)
local BLUE = Color3.fromRGB(13, 105, 172)

local function buildIsland()
	local Kit = require(ServerScriptService:WaitForChild("World"):WaitForChild("Kit"))
	local world = Workspace:FindFirstChild("World") or Workspace
	local center = SpinConfig.Island.Center
	local r = SpinConfig.Island.Radius
	local b = Kit.new(world, CF(center), "SpinIsland")
	pcall(function()
		(b.Model :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	-- floating base: grass plate, dirt layer, stacked rock cone underneath
	b:cyl(3, r * 2, V3(0, -1.5, 0), GRASS)
	b:cyl(3, r * 2 - 2, V3(0, -4.5, 0), DIRT)
	local y = -6
	for i, d in { r * 1.7, r * 1.35, r * 1.0, r * 0.68, r * 0.38, r * 0.16 } do
		local h = 6 + i
		b:cyl(h, d, V3(0, y - h / 2, 0), i % 2 == 0 and ROCK_DARK or ROCK)
		y -= h
	end
	-- toy studs around the rim
	for i = 0, 23 do
		local a = i / 24 * math.pi * 2
		b:cyl(0.6, 2.2, V3(math.sin(a) * (r - 2.5), 0.3, math.cos(a) * (r - 2.5)), GRASS)
	end
	-- wheel stand (the rotor is built by the clients at SpinConfig.Wheel)
	local wheel = SpinConfig.Wheel
	local wr = SpinConfig.WheelRadius
	local stand = Kit.new(b.Model, wheel, "WheelStand")
	-- (stand-local frame = rotor frame: -Z faces the players, ground at y = -groundDrop)
	local groundDrop = wheel.Position.Y - center.Y
	local top = wr + 2.6
	local postH = top + groundDrop
	for _, sx in { -1, 1 } do
		stand:box(V3(2.4, postH, 2.4), V3(sx * (wr + 2.4), (top - groundDrop) / 2, 1.6), RED)
		stand:box(V3(4, 1.6, 6), V3(sx * (wr + 2.4), -groundDrop + 0.8, 1.6), YELLOW)
	end
	stand:box(V3(wr * 2 + 7.2, 2.4, 2.4), V3(0, top, 1.6), RED)
	-- axle behind the rotor + a strut up to the crossbar
	stand:box(V3(2, 2, 3.4), V3(0, 0, 1.9), ROCK_DARK)
	stand:box(V3(2.4, top, 2.4), V3(0, top / 2, 3.2), RED)
	-- pointer: two mirrored wedges forming a downward triangle in front of the rim
	local ph, pd = 3, 1.5
	local py = wr + 0.3 + ph / 2
	stand:wedge(V3(0.8, ph, pd), CFrame.fromMatrix(V3(-pd / 2, py, -1.7), V3(0, 0, 1), V3(0, -1, 0), V3(1, 0, 0)), YELLOW).Name = "Pointer"
	stand:wedge(V3(0.8, ph, pd), CFrame.fromMatrix(V3(pd / 2, py, -1.7), V3(0, 0, -1), V3(0, -1, 0), V3(-1, 0, 0)), YELLOW).Name = "Pointer"
	-- sign above
	local sign = stand:box(V3(18, 4, 1), V3(0, top + 3.4, 1.6), BLUE)
	sign.Name = "Sign"
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = sign
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBlack
	t.Text = "SPIN TO WIN EGGS!"
	t.TextScaled = true
	t.TextColor3 = YELLOW
	t.Parent = gui
	local st = Instance.new("UIStroke")
	st.Thickness = 3
	st.Color = Color3.fromRGB(20, 24, 40)
	st.Parent = t
	-- podium with the prompt, between the arrival point and the wheel
	local podiumPos = wheel.Position + wheel.LookVector * 16
	local podium = Kit.new(b.Model, CF(V3(podiumPos.X, center.Y, podiumPos.Z)), "Podium")
	podium:cyl(1.2, 10, V3(0, 0.6, 0), YELLOW)
	podium:cyl(0.6, 8, V3(0, 1.5, 0), RED)
	local pad = podium:cyl(0.4, 6, V3(0, 2, 0), WHITE, Enum.Material.Neon)
	pad.Name = "SpinPad"
	podium:prompt(pad, "Spin the Wheel", "Spin Island", { Window = "Spin" })
	-- brick trees, flowers and a couple of lamp posts
	for i, p in { V3(-24, 0, -6), V3(25, 0, -10), V3(-20, 0, 18), V3(22, 0, 16), V3(-8, 0, -26), V3(10, 0, -27) } do
		local h = 5 + (i % 3)
		b:box(V3(1.6, h, 1.6), V3(p.X, h / 2, p.Z), DIRT)
		b:box(V3(6, 4, 6), V3(p.X, h + 1.6, p.Z), Color3.fromRGB(39, 112, 62))
		b:box(V3(4, 3, 4), V3(p.X, h + 5, p.Z), GRASS)
	end
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2 + 0.2
		local rr = r - 6 - (i % 3) * 3
		local col = ({ RED, YELLOW, WHITE, Color3.fromRGB(228, 160, 200) })[i % 4 + 1]
		b:cyl(0.4, 1.4, V3(math.sin(a) * rr, 0.2, math.cos(a) * rr), col)
	end
	-- clouds hugging the underside
	for i, p in { V3(-30, -14, 8), V3(28, -18, -6), V3(4, -24, 30), V3(-12, -20, -30) } do
		local cl = Kit.new(b.Model, CF(center + p), "Cloud" .. i)
		cl:box(V3(14, 4, 8), V3(0, 0, 0), WHITE, nil, { CanCollide = false, CastShadow = false })
		cl:box(V3(8, 4, 6), V3(-3, 2.5, 0), WHITE, nil, { CanCollide = false, CastShadow = false })
		cl:box(V3(6, 3, 6), V3(4, 2, 1), WHITE, nil, { CanCollide = false, CastShadow = false })
	end
	return b.Model
end

-- ============================================================== spins
local function spinState(data)
	local s = data.Spin
	if type(s) ~= "table" then
		s = { NextFree = 0, Tickets = SpinConfig.StartTickets }
	end
	return s
end

local function nearWheel(player: Player): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. player.UserId)
	local positions = { (hrp :: BasePart).Position }
	if model and model.PrimaryPart then
		table.insert(positions, model.PrimaryPart.Position)
	end
	for _, p in positions do
		if (p - SpinConfig.Wheel.Position).Magnitude <= SpinConfig.MaxDistance then
			return true
		end
	end
	return false
end

local function pick(luck: number): number
	local odds = SpinConfig.odds(luck)
	local r = rng:NextNumber()
	for i, p in odds do
		r -= p
		if r <= 0 then
			return i
		end
	end
	return #odds
end

local function giveEggs(player: Player, eggType: string, count: number): number
	local data = Data.Get(player)
	if not data then
		return 0
	end
	local cap = EconomyConfig.upgradeValue("EggStorage", data.Upgrades.EggStorage or 0)
	local list = table.clone(data.Eggs)
	local given = 0
	for _ = 1, count do
		if #list >= cap + 20 then
			break
		end
		table.insert(list, { Id = Data.NextId(player, "EggSerial", "E"), Type = eggType, Found = now(), Luck = EggConfig.rollLuck(eggType, rng, true) })
		given += 1
	end
	Data.Set(player, { "Eggs" }, list)
	return given
end

local function grantPrize(player: Player, seg): { [string]: any }
	local prize = { Kind = seg.Kind, Label = seg.Label }
	if seg.Kind == "Cash" then
		local rate = Services.EconomyService.IncomeRate(player)
		local amount = math.max(seg.Min or 0, math.floor(rate * 60 * (seg.Minutes or 1)))
		Services.EconomyService.Earn(player, amount, "Spin")
		prize.Amount = amount
		prize.Label = Format.cash(amount)
	elseif seg.Kind == "Egg" then
		local given = giveEggs(player, seg.Egg, seg.Count or 1)
		prize.Egg = seg.Egg
		prize.Count = given
		if given < (seg.Count or 1) then
			-- bag overflowing: pay the egg out in cash instead
			local amount = 5000 * (EggConfig.Eggs[seg.Egg] and EggConfig.Eggs[seg.Egg].Tier or 1)
			Services.EconomyService.Earn(player, amount, "Spin")
			prize.Amount = amount
		end
	elseif seg.Kind == "Spin" then
		Data.Increment(player, { "Spin", "Tickets" }, seg.Count or 1)
		prize.Count = seg.Count or 1
	elseif seg.Kind == "Boost" then
		Services.BoostService.Add(player, seg.Boost, seg.Seconds or 600)
		prize.Boost = seg.Boost
		prize.Seconds = seg.Seconds
	end
	return prize
end

local function roll(player: Player)
	local data = Data.Get(player)
	if not data then
		return false, "NOT_LOADED"
	end
	if not nearWheel(player) then
		return false, "TOO_FAR", "Go to Spin Island to spin the wheel."
	end
	local s = spinState(data)
	if data.Spin ~= s then
		Data.Set(player, { "Spin" }, s)
	end
	local free = now() >= (tonumber(s.NextFree) or 0)
	if free then
		Data.Set(player, { "Spin", "NextFree" }, now() + SpinConfig.FreeSpinSeconds)
	elseif (tonumber(s.Tickets) or 0) > 0 then
		Data.Increment(player, { "Spin", "Tickets" }, -1)
	else
		return false, "NO_SPINS", "No spins left. Your free spin is coming soon!"
	end
	local luck = Services.BoostService and Services.BoostService.LuckMultiplier(player) or 1
	local index = pick(luck)
	local prize = grantPrize(player, SpinConfig.Segments[index])
	Data.Increment(player, { "Stats", "Spins" }, 1)
	local after = Data.Get(player).Spin
	return true, { Index = index, Prize = prize, Free = free, Tickets = after.Tickets, NextFree = after.NextFree }
end

-- Robux spin packs (MonetizationService calls this for Kind = "Spins").
function SpinService.AddTickets(player: Player, count: number)
	local data = Data.Get(player)
	if not data then
		return
	end
	if type(data.Spin) ~= "table" then
		Data.Set(player, { "Spin" }, { NextFree = 0, Tickets = SpinConfig.StartTickets })
	end
	Data.Increment(player, { "Spin", "Tickets" }, count)
end

function SpinService.Init(services)
	Services = services
	Data = services.PlayerDataService
	Net.handle("Spin", "Roll", roll, { Burst = 2, PerSecond = 0.5 })
	local _ = MonetizationConfig
end

function SpinService.Start()
	while not (Services.WorldService and Services.WorldService.Ready) do
		task.wait(0.25)
	end
	local ok, err = pcall(buildIsland)
	if not ok then
		warn("[Spin] island build failed: " .. tostring(err))
	end
end

return SpinService

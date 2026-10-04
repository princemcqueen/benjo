--[[
	CoinController
	Client side of the coins on the map (CoinService / CoinConfig / CoinLayout):

	  * asks the server for the coin list once (retrying until the world is ready) and builds the
	    coins that are near the player: spinning, bobbing gold coins on the roads, big sky coins in
	    arcs, glowing treasure piles at the landmarks
	  * flying or walking into a coin takes it (it vanishes with a little burst); touched coins are
	    sent to the server in small batches, the server decides what it pays
	  * a CHAIN pill in the HUD (under the cash) counts the chain and the cash earned by it while
	    coins keep coming; coins the server did not take simply come back

	Coins come back after their own respawn time (the server tells the rest of it when this
	client starts late).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Configs = ReplicatedStorage:WaitForChild("Configs")
local Net = require(Shared:WaitForChild("Net"))
local CoinLayout = require(Shared:WaitForChild("CoinLayout"))
local CoinConfig = require(Configs:WaitForChild("CoinConfig"))

local LocalPlayer = Players.LocalPlayer

local CoinController = {}

local registry
local coins: { { Kind: string, Def: any, Position: Vector3, Phase: number } } = {}
local visible: { [number]: Model } = {} -- built coins by id
local hidden: { [number]: number } = {} -- id -> clock when it comes back
local retry: { [number]: number } = {} -- id -> clock before which a refused coin is not tried again
local queue: { number } = {}
local flushing = false
local flushAt = 0
local clock = 0
local streamAcc = 0
local folder: Folder? = nil
local chain = { N = 0, Until = 0, Gained = 0, Mult = 1 }
local loaded = false
local total = 0
local touching = true -- off: coins are not taken by touching them (UI Lab, tests)

-- ============================================================== visuals
local function part(name: string, size: Vector3, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function buildCoin(kindId: string): Model
	local def = CoinConfig.Kinds[kindId]
	local model = Instance.new("Model")
	model.Name = "Coin"
	model:SetAttribute("Kind", kindId)
	local s = def.Size
	if kindId == "Gem" then
		-- a gem: a block that place() stands on a corner (45 degrees twice) and a second one turned
		-- 45 degrees against it, whose corners poke out in the other colour - a crystal star
		local body = part("Body", Vector3.new(s * 0.72, s * 0.72, s * 0.72), def.Color, Enum.Material.Neon, model)
		local core = part("Core", Vector3.new(s * 0.66, s * 0.66, s * 0.66), def.Rim, Enum.Material.Neon, model)
		core.CFrame = CFrame.Angles(0, math.rad(45), 0)
		model.PrimaryPart = body
		local light = Instance.new("PointLight")
		light.Color = def.Color
		light.Range = 16
		light.Brightness = 1.4
		light.Parent = body
		local sparkles = Instance.new("ParticleEmitter")
		sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkles.Color = ColorSequence.new(def.Color, def.Rim)
		sparkles.LightEmission = 1
		sparkles.Rate = 6
		sparkles.Lifetime = NumberRange.new(0.8, 1.5)
		sparkles.Speed = NumberRange.new(1, 3)
		sparkles.SpreadAngle = Vector2.new(180, 180)
		sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 0.7), NumberSequenceKeypoint.new(1, 0) })
		sparkles.Parent = body
		return model
	end
	-- a coin: a thin disc with a darker inner disc on both faces (a cylinder's axis is X)
	local sky = kindId == "Gold"
	local material = sky and Enum.Material.Neon or Enum.Material.Metal
	local body = part("Body", Vector3.new(s * 0.16, s, s), def.Color, material, model)
	body.Shape = Enum.PartType.Cylinder
	local face = part("Face", Vector3.new(s * 0.2, s * 0.62, s * 0.62), def.Rim, material, model)
	face.Shape = Enum.PartType.Cylinder
	model.PrimaryPart = body
	return model
end

local GEM_TILT = CFrame.Angles(math.rad(45), 0, math.rad(45))

-- Coins spin around the vertical axis; gems stand on a corner.
local function place(model: Model, position: Vector3, spin: number, kind: string)
	local cf = CFrame.new(position) * CFrame.Angles(0, spin, 0)
	model:PivotTo(kind == "Gem" and cf * GEM_TILT or cf)
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = "Coins"
	folder.Parent = Workspace
	return folder
end

local function burst(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "CoinBurst"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.5, 0.5, 0.5)
	anchor.Position = position
	anchor.Parent = getFolder()
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(color)
	pe.LightEmission = 1
	pe.Rate = 0
	pe.Lifetime = NumberRange.new(0.4, 0.8)
	pe.Speed = NumberRange.new(8, 16)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = anchor
	pe:Emit(9)
	local audio = registry and registry.AudioController
	if audio then
		audio.play3D("CoinPickup", anchor, 0.12, 0.8)
	end
	Debris:AddItem(anchor, 1.2)
end

-- ============================================================== chain pill
local function showChain()
	local hud = registry and registry.Hud
	if not hud or not hud.SetCoinChain then
		return
	end
	if chain.N > 0 and clock < chain.Until then
		hud:SetCoinChain(chain.Mult, chain.Gained, chain.N)
	else
		hud:SetCoinChain(nil)
	end
end

-- ============================================================== streaming
local function myPositions(): ({ Vector3 }, number)
	local out = {}
	local slack = 0
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		table.insert(out, hrp.Position)
	end
	local dragons = Workspace:FindFirstChild("Dragons")
	local model = dragons and dragons:FindFirstChild("Dragon_" .. LocalPlayer.UserId)
	local root = model and model:FindFirstChild("Root") :: BasePart?
	if root then
		table.insert(out, root.Position)
		slack = ((model :: Model):GetAttribute("BodyRadius") or 0) * 0.5
		if (model :: Model):GetAttribute("RiderUserId") == LocalPlayer.UserId then
			slack += 5 -- swooping through a coin while riding is enough
		end
	end
	return out, slack
end

local function remove(id: number)
	local model = visible[id]
	if model then
		model:Destroy()
		visible[id] = nil
	end
end

-- Builds the coins around the player and removes the far ones.
local function stream(positions: { Vector3 })
	local ref = positions[1]
	local camera = Workspace.CurrentCamera
	if not ref and camera then
		ref = camera.CFrame.Position
	end
	if not ref then
		return
	end
	local r2 = CoinConfig.ViewRadius * CoinConfig.ViewRadius
	for id = 1, #coins do
		local coin = coins[id]
		local d = coin.Position - ref
		local back = hidden[id]
		if back and clock >= back then
			hidden[id] = nil
			back = nil
		end
		if not back and d.X * d.X + d.Y * d.Y + d.Z * d.Z <= r2 then
			if not visible[id] then
				local model = buildCoin(coin.Kind)
				model.Name = "Coin" .. id
				place(model, coin.Position, coin.Phase, coin.Kind)
				model.Parent = getFolder()
				visible[id] = model
			end
		else
			remove(id)
		end
	end
end

-- ============================================================== taking coins
local function flush()
	if flushing or #queue == 0 then
		return
	end
	local ids = {}
	for _ = 1, math.min(#queue, CoinConfig.Batch.Size) do
		table.insert(ids, table.remove(queue, 1))
	end
	flushing = true
	task.spawn(function()
		local res = Net.request("Coins", "Collect", { Ids = ids })
		flushing = false
		if not res.ok or not res.data then
			-- (not loaded yet, rate limited...) the coins come back and can be tried again
			for _, id in ids do
				hidden[id] = nil
				retry[id] = clock + 3
			end
			return
		end
		local took = {}
		for _, id in res.data.Collected or {} do
			took[id] = true
		end
		for _, id in ids do
			if not took[id] then
				hidden[id] = nil -- the server did not take it (too far, not back yet): it stays in the world
				retry[id] = clock + 4
			end
		end
		total = res.data.Total or total
		if #(res.data.Collected or {}) > 0 then
			if clock >= chain.Until then
				chain.Gained = 0
			end
			chain.N = res.data.Chain or 1
			chain.Mult = res.data.Mult or 1
			chain.Gained += res.data.Gained or 0
			chain.Until = clock + CoinConfig.Chain.Window + 0.6
			local audio = registry and registry.AudioController
			if audio and chain.N >= 3 and audio.playUI then
				audio.playUI("CoinChain")
			end
			showChain()
		end
	end)
end

local function touch(id: number)
	local coin = coins[id]
	local def = coin.Def
	hidden[id] = clock + def.Respawn + 5 -- until the server says otherwise
	remove(id)
	burst(coin.Position, def.Color)
	table.insert(queue, id)
	if #queue >= CoinConfig.Batch.Size then
		flush()
	end
end

local function step(dt: number)
	clock += dt
	if #coins == 0 then
		return
	end
	local positions, slack = myPositions()
	streamAcc += dt
	if streamAcc >= 0.25 then
		streamAcc = 0
		stream(positions)
	end
	for id, model in visible do
		local coin = coins[id]
		local t = clock * 2.2 + coin.Phase
		place(model, coin.Position + Vector3.new(0, math.sin(t * 0.8) * 0.4, 0), t, coin.Kind)
		if touching and (retry[id] or 0) <= clock then
			local reach = coin.Def.Radius + slack
			for _, p in positions do
				if (p - coin.Position).Magnitude <= reach then
					touch(id)
					break
				end
			end
		end
	end
	if clock >= flushAt then
		flushAt = clock + CoinConfig.Batch.Interval
		flush()
	end
	if chain.N > 0 and clock >= chain.Until then
		chain.N = 0
		chain.Gained = 0
		chain.Mult = 1
		showChain()
	end
end

-- ============================================================== loading
local function load()
	local res = Net.request("Coins", "Layout", {})
	if not res.ok or not res.data then
		return false
	end
	local list = CoinLayout.unpack(res.data.Layout)
	local rng = Random.new(77)
	table.clear(coins)
	for i, c in list do
		coins[i] = { Kind = c.Kind, Def = CoinConfig.Kinds[c.Kind], Position = c.Position, Phase = rng:NextNumber(0, math.pi * 2) }
	end
	table.clear(hidden)
	for key, seconds in res.data.Back or {} do
		local id = tonumber(key)
		if id and coins[id] then
			hidden[id] = clock + seconds
		end
	end
	loaded = true
	return true
end

-- ============================================================== public
function CoinController.count(): number
	return #coins
end

-- The model of one coin kind (not placed anywhere) - tools and the UI Lab.
function CoinController.build(kindId: string): Model
	return buildCoin(kindId)
end

function CoinController.place(model: Model, position: Vector3, spin: number, kind: string)
	place(model, position, spin, kind)
end

function CoinController.visibleCount(): number
	local n = 0
	for _ in visible do
		n += 1
	end
	return n
end

function CoinController.total(): number
	return total
end

-- Is coin `id` built right now / where is it / what is it (tools and tests).
function CoinController.isVisible(id: number): boolean
	return visible[id] ~= nil
end

function CoinController.position(id: number): Vector3?
	return coins[id] and coins[id].Position or nil
end

function CoinController.kind(id: number): string?
	return coins[id] and coins[id].Kind or nil
end

function CoinController.chain()
	return chain
end

-- Coins are taken by touching them; tools and tests switch that off.
function CoinController.setTouch(on: boolean)
	touching = on
end

-- UI Lab: the chain pill with sample numbers, whatever the data says.
function CoinController.preview(on: boolean)
	touching = not on
	local hud = registry and registry.Hud
	if hud and hud.SetCoinChain then
		if on then
			hud:SetCoinChain(2.75, 18400, 8)
		else
			showChain()
		end
	end
end

function CoinController.Init(reg)
	registry = reg
end

function CoinController.Start()
	RunService.Heartbeat:Connect(step)
	task.spawn(function()
		-- the world may not be ready yet: ask again until the list comes
		while not loaded do
			if not load() then
				task.wait(3)
			end
		end
	end)
end

return CoinController

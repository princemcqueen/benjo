--[[
	Dragon Animator (procedural, blended)

	Base locomotion states (crossfaded by weight, never snapped):
	  Idle, Walk, Run, Fall, Hover, Fly, FastFly, Dive, Ascend, Descend, Sleep,
	  Rest (lying down awake - sanctuary perches)
	One-shot actions (with fade in/out envelopes):
	  Jump, Takeoff, Landing, Roar, Eat, IdleVariant
	  Dragon Bond: Dash, FireBreath (held until Stop), Flourish (Sky Dance)
	Additive layers:
	  wing banking, breathing, head look, spring-driven tail/neck motion.

	Joint rotations are authored in each joint's model-aligned rest frame
	(CFrame.Angles(rx, ry, rz)). Sign conventions:
	  Body / Chest / Head / Neck rx > 0 : nose up
	  Tail rx > 0                       : tail lowers
	  Limb rx > 0                       : limb swings forward
	  Wing (left) rz < 0                : wing rises; ry > 0 sweeps back
	Right-side joints are mirrored automatically (ry, rz and px negated).

	Wings: the folded pose is solved per model from target bone directions,
	so every wing shape folds tightly. Membranes are re-stretched between
	bone anchors after each pose (Membranes.luau) using forward kinematics,
	so they never lag a frame behind the bones.
]]

local Membranes = require(script.Parent:WaitForChild("Membranes"))

local Animator = {}
Animator.__index = Animator

local TAU = math.pi * 2
local sin, cos, rad, exp, clamp, max = math.sin, math.cos, math.rad, math.exp, math.clamp, math.max

local BASE_STATES = { "Idle", "Walk", "Run", "Fall", "Hover", "Fly", "FastFly", "Dive", "Ascend", "Descend", "Sleep", "Rest" }
Animator.States = BASE_STATES

local ONESHOTS = {
	Jump = { Duration = 0.55, FadeIn = 0.06, FadeOut = 0.2 },
	Takeoff = { Duration = 0.75, FadeIn = 0.1, FadeOut = 0.25 },
	Landing = { Duration = 0.55, FadeIn = 0.08, FadeOut = 0.22 },
	Roar = { Duration = 1.7, FadeIn = 0.18, FadeOut = 0.35 },
	Eat = { Duration = 2.4, FadeIn = 0.25, FadeOut = 0.35 },
	IdleVariant = { Duration = 2.6, FadeIn = 0.4, FadeOut = 0.5 },
	-- Dragon Bond abilities
	Dash = { Duration = 0.55, FadeIn = 0.05, FadeOut = 0.22 },
	-- Hold: the clip sustains at that time until Stop() (or MaxHold seconds)
	FireBreath = { Duration = 4.6, FadeIn = 0.18, FadeOut = 0.35, Hold = 0.45, MaxHold = 3.9 },
	Flourish = { Duration = 1.8, FadeIn = 0.12, FadeOut = 0.3 },
}
Animator.OneShots = ONESHOTS

-- Folded wing: target directions (model space, left wing; outward = -X).
-- The fingers fan down the flank so the folded membrane drapes like a cape.
local FOLD_AIMS = {
	Vector3.new(-0.16, -0.22, 0.96), -- humerus: back and a little down along the flank
	Vector3.new(-0.08, 0.16, -0.98), -- forearm: folds forward, wrist beside the shoulder
	Vector3.new(-0.05, 0.0, 1.0), -- main finger: straight back along the upper flank
	Vector3.new(-0.05, -0.3, 0.95), -- finger 2: back and down
	Vector3.new(-0.04, -0.55, 0.83), -- finger 3: down the flank
}
local FOLD_NORMAL = Vector3.new(-1, 0.15, 0) -- membrane faces outward when folded
local WING_JOINTS = { "WingL1", "WingL2", "WingL3", "WingL4", "WingL5", "WingR1", "WingR2", "WingR3", "WingR4", "WingR5" }
local FOLD_PARENT = { 0, 1, 2, 3, 3 } -- parent index in the wing chain (0 = chest)

-- ============================================================== math helpers
local function wrapAngle(a: number): number
	return (a + math.pi) % TAU - math.pi
end

-- Euler XYZ decomposition choosing the solution with the smallest rotation
-- amounts (so blending from rest moves joints along the natural path).
local function eulerMin(cf: CFrame): (number, number, number)
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	local ax, ay, az = wrapAngle(rx + math.pi), wrapAngle(math.pi - ry), wrapAngle(rz + math.pi)
	if math.abs(ax) + math.abs(ay) + math.abs(az) < math.abs(rx) + math.abs(ry) + math.abs(rz) then
		return ax, ay, az
	end
	return rx, ry, rz
end

-- Canonical rotation vector (axis * angle, angle in [0, pi]).
local function rotVec(cf: CFrame): Vector3
	local axis, angle = cf:ToAxisAngle()
	if angle ~= angle or axis.Magnitude < 1e-6 then
		return Vector3.zero
	end
	angle = angle % (2 * math.pi)
	if angle > math.pi then
		angle = 2 * math.pi - angle
		axis = -axis
	end
	return axis.Unit * angle
end

local function fromRotVec(v: Vector3): CFrame
	local m = v.Magnitude
	if m < 1e-6 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(v / m, m)
end

local function aimFrame(aim: Vector3, normalHint: Vector3): CFrame
	local a = aim.Unit
	local n = normalHint - a * normalHint:Dot(a)
	if n.Magnitude < 1e-4 then
		n = Vector3.zAxis - a * a.Z
	end
	n = n.Unit
	return CFrame.fromMatrix(Vector3.zero, a, n, a:Cross(n))
end

-- ============================================================== construction
-- Rig joint names (sockets such as FootFL, WingTipL, MemF1L, Mouth are not joints).
local JOINT_PATTERNS = {
	"^Body$", "^Chest$", "^Pelvis$", "^Head$", "^Jaw$", "^Neck%d+$", "^Tail%d+$",
	"^Arm[LR]%d$", "^Leg[LR]%d$", "^Hand[LR]$", "^Foot[LR]$", "^Wing[LR]%d$",
}
local function isJointName(name: string): boolean
	for _, p in JOINT_PATTERNS do
		if string.match(name, p) then
			return true
		end
	end
	return false
end
Animator.isJointName = isJointName

function Animator.new(model: Model)
	local self = setmetatable({}, Animator)
	self.Model = model
	-- Motors: joint name -> Motor6D (part-built dragons) or Bone (skinned mesh
	-- dragons); both expose .Transform with the same model-aligned convention.
	-- Joints: name -> { Parent, C0, C1inv } for forward kinematics.
	self.Motors = {}
	self.Joints = {}
	self.MeshRig = model:GetAttribute("MeshRig") == true
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Name ~= "MemJoint" then
			self.Motors[d.Name] = d
			if d.Part0 then
				self.Joints[d.Name] = { Parent = d.Part0.Name, C0 = d.C0, C1inv = d.C1:Inverse() }
			end
		elseif d:IsA("Bone") and isJointName(d.Name) then
			self.Motors[d.Name] = d
			local p = d.Parent
			self.Joints[d.Name] = {
				Parent = (p and p:IsA("Bone")) and p.Name or "Root",
				C0 = d.CFrame,
				C1inv = CFrame.identity,
			}
		end
	end
	local m = self.Motors
	self.HasFront = m.ArmL1 ~= nil
	self.HasBack = m.LegL1 ~= nil
	self.HasWings = m.WingL1 ~= nil
	self.Neck = {}
	for i = 1, 8 do
		if m["Neck" .. i] then
			table.insert(self.Neck, "Neck" .. i)
		end
	end
	self.Tail = {}
	for i = 1, 16 do
		if m["Tail" .. i] then
			table.insert(self.Tail, "Tail" .. i)
		end
	end
	self.Rig = model:GetAttribute("Rig") or "Quadruped"
	self.Scale = model:GetAttribute("Scale") or 1
	self.Weights = {}
	for _, s in BASE_STATES do
		self.Weights[s] = 0
	end
	self.Weights.Idle = 1
	self.Target = "Idle"
	self.Gait = 0
	self.Flap = 0
	self.Breath = math.random()
	self.Time = math.random() * 10
	self.Shots = {}
	self.Acc = {}
	for name in m do
		self.Acc[name] = { 0, 0, 0, 0, 0, 0 }
	end
	self.SpreadW = 0 -- total weight of spread-wing contributions this frame
	self.FoldW = 0 -- total weight of the folded-wing pose this frame
	self.WingBank = 0
	self.Params = {
		Speed = 0, -- horizontal speed (studs/s)
		RunSpeed = 40,
		WalkSpeed = 16,
		Vertical = 0, -- vertical speed
		TurnRate = 0, -- yaw rate rad/s
		Bank = 0, -- radians, + = right bank
		Pitch = 0, -- flight pitch (radians, + = nose up)
		Mode = "Ground", -- Ground | Air | Fly | Sleep
		Boost = false,
		Look = Vector2.zero, -- head look (yaw, pitch) radians
	}
	self.TailSpring = { 0, 0 }
	self.TailPitch = { 0, 0 }
	self.NeckSpring = { 0, 0 }
	self.BankSmoothed = 0
	self.OnFootstep = nil -- fn(side)
	self.OnFlap = nil -- fn()
	self.Paused = false
	self:_buildSkeleton()
	self:_solveFold()
	self.Membranes = Membranes.new(model)
	self.MembranesEnabled = self.Membranes.Valid
	self.Transforms = {}
	self.BoneCF = { Root = CFrame.identity }
	self.LastWingSig = nil
	return self
end

-- Joint tree (parent-first order) for forward kinematics.
function Animator:_buildSkeleton()
	local byParent: { [string]: { any } } = {}
	for name, j in self.Joints do
		byParent[j.Parent] = byParent[j.Parent] or {}
		table.insert(byParent[j.Parent], { Name = name, Parent = j.Parent, C0 = j.C0, C1inv = j.C1inv })
	end
	local order = {}
	local queue = { "Root" }
	local seen = { Root = true }
	while #queue > 0 do
		local parent = table.remove(queue, 1)
		for _, j in byParent[parent] or {} do
			if not seen[j.Name] then
				seen[j.Name] = true
				table.insert(order, j)
				table.insert(queue, j.Name)
			end
		end
	end
	self.Chain = order
	-- rest pose (root space)
	local rest = { Root = CFrame.identity }
	for _, j in order do
		local pcf = rest[j.Parent]
		if pcf then
			rest[j.Name] = pcf * j.C0 * j.C1inv
		end
	end
	self.Rest = rest
end

-- Solves the folded wing rotations for this model's wing geometry.
function Animator:_solveFold()
	if not self.HasWings or not self.Motors.WingL5 then
		self.Fold = nil
		return
	end
	local rest = self.Rest
	local function pivot(name: string): Vector3
		local j = self.Joints[name]
		return (rest[j.Parent] * j.C0).Position
	end
	local function attachPos(name: string): Vector3?
		local att = self.Model:FindFirstChild(name, true)
		if att and att:IsA("Attachment") and att.Parent then
			-- part-built: attachment on a bone part (rest = part frame);
			-- mesh: socket Bone under a joint Bone (rest = joint frame)
			local base = rest[att.Parent.Name]
			if att.Parent:IsA("Bone") and att.Parent.Name == "Root" then
				base = CFrame.identity
			end
			if base then
				return base * att.Position
			end
		end
		return nil
	end
	local S, E, W = pivot("WingL1"), pivot("WingL2"), pivot("WingL3")
	local F1 = attachPos("MemF1L") or W + Vector3.new(-3, 0, 1)
	local F2 = attachPos("MemF2L") or W + Vector3.new(-1.5, 0, 3)
	local F3 = attachPos("MemF3L") or W + Vector3.new(1, 0, 4)
	local restAims = { E - S, W - E, F1 - W, F2 - W, F3 - W }
	local D = {}
	for i = 1, 5 do
		local rf = aimFrame(restAims[i], Vector3.yAxis)
		local tf = aimFrame(FOLD_AIMS[i], FOLD_NORMAL)
		D[i] = tf * rf:Inverse()
	end
	local fold = {}
	local foldCF = {}
	local foldRV = {}
	for i = 1, 5 do
		local parentIdx = FOLD_PARENT[i]
		local local_ = parentIdx == 0 and D[i] or D[parentIdx]:Inverse() * D[i]
		local rx, ry, rz = eulerMin(local_)
		fold[i] = { rx, ry, rz }
		foldCF["WingL" .. i] = CFrame.Angles(rx, ry, rz)
		foldCF["WingR" .. i] = CFrame.Angles(rx, -ry, -rz)
		foldRV["WingL" .. i] = rotVec(foldCF["WingL" .. i])
		foldRV["WingR" .. i] = rotVec(foldCF["WingR" .. i])
	end
	self.Fold = fold
	self.FoldCF = foldCF
	self.FoldRV = foldRV
end

-- ============================================================== control
function Animator:SetParams(p: { [string]: any })
	for k, v in p do
		self.Params[k] = v
	end
end

function Animator:Play(name: string, speed: number?)
	local def = ONESHOTS[name]
	if not def then
		return
	end
	for i = #self.Shots, 1, -1 do
		if self.Shots[i].Name == name then
			table.remove(self.Shots, i)
		end
	end
	-- StartFold lets a shot begin from the wing state it interrupts (e.g. a
	-- takeoff from a jump starts with open wings, from the ground folded)
	table.insert(self.Shots, { Name = name, T = 0, Speed = speed or 1, Def = def, StartFold = self.LastFoldW or 1 })
end

function Animator:IsPlaying(name: string): boolean
	for _, s in self.Shots do
		if s.Name == name then
			return true
		end
	end
	return false
end

function Animator:Stop(name: string)
	for _, s in self.Shots do
		if s.Name == name then
			s.Released = true
			if s.T < s.Def.Duration - s.Def.FadeOut then
				s.T = s.Def.Duration - s.Def.FadeOut
			end
		end
	end
end

-- Instantly snaps to a state (no crossfade); used when spawning.
function Animator:Snap(state: string)
	for _, s in BASE_STATES do
		self.Weights[s] = s == state and 1 or 0
	end
	self.Target = state
end

local function chooseTarget(p): string
	local mode = p.Mode
	if mode == "Sleep" then
		return "Sleep"
	elseif mode == "Rest" then
		return "Rest"
	elseif mode == "Ground" then
		if p.Speed < 1.2 then
			return "Idle"
		elseif p.Speed < (p.WalkSpeed + p.RunSpeed) * 0.5 then
			return "Walk"
		end
		return "Run"
	elseif mode == "Air" then
		return "Fall"
	end
	-- flying
	if p.Vertical < -p.Speed * 0.7 and p.Speed > 25 then
		return "Dive"
	end
	if p.Boost then
		return "FastFly"
	end
	if p.Speed < 14 then
		if p.Vertical > 8 then
			return "Ascend"
		elseif p.Vertical < -8 then
			return "Descend"
		end
		return "Hover"
	end
	if p.Vertical > p.Speed * 0.45 then
		return "Ascend"
	end
	return "Fly"
end
Animator.chooseTarget = chooseTarget

-- ============================================================== pose helpers
local function add(acc, joint: string, w: number, rx: number, ry: number, rz: number, px: number?, py: number?, pz: number?)
	local a = acc[joint]
	if not a then
		return
	end
	a[1] += rx * w
	a[2] += ry * w
	a[3] += rz * w
	if px then
		a[4] += px * w
		a[5] += (py or 0) * w
		a[6] += (pz or 0) * w
	end
end

-- Left joint gets (rx, ry, rz); right mirror gets (rx, -ry, -rz).
local function sym(acc, base: string, w: number, rx: number, ry: number, rz: number, px: number?, py: number?, pz: number?)
	add(acc, (base:gsub("%%", "L")), w, rx, ry, rz, px and -px or nil, py, pz)
	add(acc, (base:gsub("%%", "R")), w, rx, -ry, -rz, px, py, pz)
end

local function side(acc, base: string, s: string, w: number, rx: number, ry: number, rz: number)
	if s == "L" then
		add(acc, (base:gsub("%%", "L")), w, rx, ry, rz)
	else
		add(acc, (base:gsub("%%", "R")), w, rx, -ry, -rz)
	end
end

local function wave(phase: number, offset: number?): number
	return sin((phase + (offset or 0)) * TAU)
end

-- Wing beat curve: fast downstroke, slower upstroke. Returns -1..1 (+ = up).
local function beat(phase: number): number
	local p = phase % 1
	if p < 0.42 then
		return cos(p / 0.42 * math.pi)
	end
	return -cos((p - 0.42) / 0.58 * math.pi)
end
Animator.beat = beat

local function neck(self, acc, w: number, rx: number, ry: number?)
	local n = #self.Neck
	for _, j in self.Neck do
		add(acc, j, w, rx / n, (ry or 0) / n, 0)
	end
end

local function tail(self, acc, w: number, rx: number, ry: number?, waveAmp: number?, wavePhase: number?)
	local n = #self.Tail
	for i, j in self.Tail do
		local k = i / n
		local wv = waveAmp and wave(wavePhase or 0, -i * 0.11) * waveAmp * (0.5 + k) or 0
		add(acc, j, w, rx / n, (ry or 0) / n + wv, 0)
	end
end

-- ============================================================== wing poses
-- Wings blend between a spread pose (Euler accumulation, weighted) and the
-- solved folded pose by quaternion slerp, so folding follows the natural
-- shortest rotation of each joint instead of an Euler-blend path.
local function wingsFolded(self, acc, w: number)
	if w > 0 then
		self.FoldW += w
	end
end

-- Spread wing. b: flap position (-1 down .. 1 up); lag: delayed flap for the
-- outer wing; sweep: 0 open .. 1 swept back; close: fingers closing 0..1.
local function wingsSpread(self, acc, w: number, b: number, lag: number, sweep: number, close: number?)
	if w <= 0 then
		return
	end
	self.SpreadW += w
	local up = b > 0 and b * rad(50) or b * rad(40)
	sym(acc, "Wing%1", w, rad(3) - b * rad(5), rad(4) + sweep * rad(30), -up + rad(4))
	sym(acc, "Wing%2", w, 0, rad(3) - sweep * rad(24), -lag * rad(18) - sweep * rad(8))
	sym(acc, "Wing%3", w, 0, sweep * rad(26) - b * rad(4), -lag * rad(12) + sweep * rad(10))
	local cl = (close or 0) + max(0, lag) * 0.22 + sweep * 0.3
	sym(acc, "Wing%4", w, 0, -0.42 * cl, 0)
	sym(acc, "Wing%5", w, 0, -0.85 * cl, 0)
end

-- ============================================================== leg poses
local function legCycle(self, acc, w: number, phase: number, stride: number, lift: number, bound: number)
	local fOff = { L = 0, R = 0.5 }
	local bOff = { L = 0.5, R = 0.0 }
	if bound > 0.5 then
		fOff = { L = 0, R = 0.08 }
		bOff = { L = 0.5, R = 0.58 }
	end
	for _, s in { "L", "R" } do
		if self.HasFront then
			local ph = phase + fOff[s]
			local swing = wave(ph) * stride
			local up = max(0, wave(ph, 0.25)) * lift
			side(acc, "Arm%1", s, w, swing, 0, 0)
			side(acc, "Arm%2", s, w, -up * 1.1, 0, 0)
			side(acc, "Hand%", s, w, -swing + up * 0.9, 0, 0)
		end
		if self.HasBack then
			local ph = phase + bOff[s]
			local swing = wave(ph) * stride * 0.9
			local up = max(0, wave(ph, 0.25)) * lift
			side(acc, "Leg%1", s, w, swing + up * 0.25, 0, 0)
			side(acc, "Leg%2", s, w, -up * 0.85, 0, 0)
			side(acc, "Foot%", s, w, -swing + up * 0.55, 0, 0)
		end
	end
end

local function tuckLegs(self, acc, w: number, amount: number)
	if self.HasFront then
		sym(acc, "Arm%1", w, -0.75 * amount, 0, 0.05)
		sym(acc, "Arm%2", w, 1.25 * amount, 0, 0)
		sym(acc, "Hand%", w, 0.55 * amount, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, -0.85 * amount, 0, 0)
		sym(acc, "Leg%2", w, -0.5 * amount, 0, 0)
		sym(acc, "Foot%", w, 1.2 * amount, 0, 0)
	end
end

-- ============================================================== base states
local States = {}

States.Idle = function(self, acc, w)
	local br = wave(self.Breath)
	local t = self.Time
	add(acc, "Chest", w, br * 0.02, 0, 0, 0, br * 0.05 * self.Scale, 0)
	add(acc, "Body", w, 0, 0, 0, 0, br * 0.035 * self.Scale, 0)
	neck(self, acc, w, -0.1 + sin(t * 0.7) * 0.04, sin(t * 0.33) * 0.12)
	add(acc, "Head", w, 0.12 + sin(t * 0.9) * 0.03, sin(t * 0.41) * 0.12, 0)
	tail(self, acc, w, 0.12, 0, 0.06, t * 0.13)
	wingsFolded(self, acc, w)
	add(acc, "Jaw", w, 0.02 + max(0, br) * 0.02, 0, 0)
end

States.Walk = function(self, acc, w)
	local ph = self.Gait
	legCycle(self, acc, w, ph, 0.38, 0.5, 0)
	local bob = cos(ph * TAU * 2)
	add(acc, "Body", w, 0, wave(ph) * 0.03, wave(ph) * 0.025, 0, bob * 0.1 * self.Scale, 0)
	neck(self, acc, w, -0.18 - bob * 0.03, -wave(ph) * 0.06)
	add(acc, "Head", w, 0.16 + bob * 0.03, wave(ph) * 0.04, 0)
	tail(self, acc, w, 0.06, 0, 0.09, ph)
	wingsFolded(self, acc, w)
end

States.Run = function(self, acc, w)
	local ph = self.Gait
	legCycle(self, acc, w, ph, 0.7, 0.85, 1)
	local bob = cos(ph * TAU)
	add(acc, "Body", w, 0, 0, 0, 0, bob * 0.22 * self.Scale - 0.08 * self.Scale, 0)
	add(acc, "Chest", w, bob * 0.06, 0, 0)
	add(acc, "Pelvis", w, -bob * 0.08, 0, 0)
	neck(self, acc, w, -0.42 - bob * 0.06, 0)
	add(acc, "Head", w, 0.34 + bob * 0.05, 0, 0)
	tail(self, acc, w, -0.12 + bob * 0.05, 0, 0.05, ph)
	wingsFolded(self, acc, w)
end

States.Fall = function(self, acc, w)
	local t = self.Time
	wingsSpread(self, acc, w, 0.4 + sin(t * 3) * 0.1, 0.3, 0.2, 0.2)
	if self.HasFront then
		sym(acc, "Arm%1", w, 0.35, 0, 0)
		sym(acc, "Arm%2", w, -0.4, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, 0.25, 0, 0)
		sym(acc, "Leg%2", w, -0.3, 0, 0)
	end
	neck(self, acc, w, 0.1)
	tail(self, acc, w, -0.15)
end

States.Hover = function(self, acc, w)
	local b = beat(self.Flap)
	local lag = beat(self.Flap - 0.12)
	wingsSpread(self, acc, w, b * 0.95, lag * 0.95, 0, 0)
	-- upright posture; body rises on each downstroke
	add(acc, "Body", w, 0.22, 0, 0, 0, -b * 0.25 * self.Scale, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, 0.2, 0, 0.04)
		sym(acc, "Arm%2", w, 0.7, 0, 0)
		sym(acc, "Hand%", w, 0.5, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, -0.15, 0, 0)
		sym(acc, "Leg%2", w, -0.2, 0, 0)
		sym(acc, "Foot%", w, 0.6, 0, 0)
	end
	neck(self, acc, w, -0.24 + b * 0.05)
	add(acc, "Head", w, 0.02, 0, 0)
	tail(self, acc, w, 0.45, 0, 0.06, self.Flap)
end

States.Fly = function(self, acc, w)
	local b = beat(self.Flap) * 0.6
	local lag = beat(self.Flap - 0.13) * 0.6
	wingsSpread(self, acc, w, b, lag, 0.08, 0)
	add(acc, "Body", w, 0, 0, 0, 0, -b * 0.15 * self.Scale, 0)
	tuckLegs(self, acc, w, 0.85)
	neck(self, acc, w, -0.38)
	add(acc, "Head", w, 0.3, 0, 0)
	tail(self, acc, w, -0.18, 0, 0.04, self.Flap * 0.5)
end

States.FastFly = function(self, acc, w)
	local b = beat(self.Flap) * 0.3
	wingsSpread(self, acc, w, b - 0.08, b * 0.6, 0.85, 0.2)
	tuckLegs(self, acc, w, 1)
	neck(self, acc, w, -0.5)
	add(acc, "Head", w, 0.4, 0, 0)
	tail(self, acc, w, -0.24, 0, 0.03, self.Time * 1.8)
end

States.Dive = function(self, acc, w)
	-- wings tucked and swept back, fingers closed, body streamlined
	wingsSpread(self, acc, w, 0.18, 0.05, 1, 0.85)
	sym(acc, "Wing%1", w, 0, rad(24), rad(-8))
	sym(acc, "Wing%2", w, 0, rad(-16), rad(4))
	sym(acc, "Wing%3", w, 0, rad(30), 0)
	tuckLegs(self, acc, w, 1)
	neck(self, acc, w, -0.45)
	add(acc, "Head", w, 0.42, 0, 0)
	tail(self, acc, w, -0.25)
end

States.Ascend = function(self, acc, w)
	local b = beat(self.Flap)
	local lag = beat(self.Flap - 0.1)
	wingsSpread(self, acc, w, b, lag, 0, 0)
	add(acc, "Body", w, 0.12, 0, 0, 0, -b * 0.22 * self.Scale, 0)
	tuckLegs(self, acc, w, 0.55)
	neck(self, acc, w, -0.1)
	add(acc, "Head", w, 0.1, 0, 0)
	tail(self, acc, w, 0.2)
end

States.Descend = function(self, acc, w)
	local b = beat(self.Flap) * 0.4 + 0.3
	wingsSpread(self, acc, w, b, b * 0.8, 0.1, 0)
	tuckLegs(self, acc, w, 0.25)
	if self.HasFront then
		sym(acc, "Arm%1", w, 0.3, 0, 0)
	end
	neck(self, acc, w, -0.15)
	add(acc, "Head", w, 0.2, 0, 0)
	tail(self, acc, w, 0.3)
end

States.Sleep = function(self, acc, w)
	local br = wave(self.Breath * 0.6)
	local s = self.Scale
	add(acc, "Body", w, 0, 0, 0, 0, -1.9 * s + br * 0.05 * s, 0)
	add(acc, "Chest", w, br * 0.015, 0, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, 1.3, 0, 0.1)
		sym(acc, "Arm%2", w, -1.5, 0, 0)
		sym(acc, "Hand%", w, 0.25, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, 1.05, 0, -0.08)
		sym(acc, "Leg%2", w, -1.1, 0, 0)
		sym(acc, "Foot%", w, 0.1, 0, 0)
	end
	-- head lowered and curled toward the tail
	neck(self, acc, w, -0.9, 0.95)
	add(acc, "Head", w, 0.55, 0.35, 0.15)
	tail(self, acc, w, 0.2, -0.95)
	wingsFolded(self, acc, w)
end

-- Lying down but awake (sanctuary perches): belly on the ground, forelegs
-- folded, head up and slowly looking around, tail curled beside the body.
States.Rest = function(self, acc, w)
	local br = wave(self.Breath)
	local s = self.Scale
	local t = self.Time
	add(acc, "Body", w, 0.03, 0, 0, 0, -1.8 * s + br * 0.04 * s, 0)
	add(acc, "Chest", w, 0.06 + br * 0.02, 0, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, 1.25, 0, 0.08)
		sym(acc, "Arm%2", w, -1.45, 0, 0)
		sym(acc, "Hand%", w, 0.3, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, 1.0, 0, -0.1)
		sym(acc, "Leg%2", w, -1.05, 0, 0)
		sym(acc, "Foot%", w, 0.12, 0, 0)
	end
	neck(self, acc, w, 0.1 + sin(t * 0.5) * 0.03, sin(t * 0.23) * 0.28)
	add(acc, "Head", w, -0.02 + sin(t * 0.7) * 0.04, sin(t * 0.31) * 0.22, 0)
	tail(self, acc, w, 0.22, -0.85, 0.035, t * 0.1)
	wingsFolded(self, acc, w)
	add(acc, "Jaw", w, 0.015 + max(0, br) * 0.015, 0, 0)
end

-- ============================================================== one-shots
local Shots = {}

Shots.Jump = function(self, acc, w, t)
	local crouch = t < 0.12 and t / 0.12 or max(0, 1 - (t - 0.12) / 0.1)
	add(acc, "Body", w, 0, 0, 0, 0, -crouch * 0.7 * self.Scale, 0)
	tuckLegs(self, acc, w, clamp((t - 0.15) / 0.2, 0, 1) * 0.5)
	local open = clamp(t / 0.25, 0, 1)
	wingsSpread(self, acc, w * open, 0.55, 0.45, 0.2, 0.2)
	wingsFolded(self, acc, w * (1 - open))
end

local function smooth(e0: number, e1: number, x: number): number
	local t = clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Takeoff flap curve: raise during the crouch, one powerful downstroke on
-- the leap, then continuous climbing beats (C0-continuous everywhere).
local function takeoffBeat(u: number): number
	if u < 0.18 then
		return 0.4 + 0.55 * smooth(0, 0.18, u)
	elseif u < 0.38 then
		return 0.95 - 1.9 * smooth(0.18, 0.38, u)
	end
	return beat(0.42 + (u - 0.38) * 2.3) * 0.95
end

Shots.Takeoff = function(self, acc, w, t, shot)
	-- crouch (0-0.18), leap + downstroke (0.18-0.38), climbing beats.
	-- Every term is a smooth curve of t, so there are no pose jumps.
	local s = self.Scale
	local crouch = smooth(0, 0.18, t) * (1 - smooth(0.18, 0.32, t))
	local lift = smooth(0.16, 0.36, t)
	local settle = smooth(0.38, 0.75, t)
	local startFold = shot and shot.StartFold or 1
	local open = 1 - startFold * (1 - smooth(0, 0.16, t))
	add(acc, "Body", w, -0.06 * crouch + 0.2 * lift * (1 - settle), 0, 0, 0, -0.9 * s * crouch, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, -0.35 * crouch, 0, 0)
		sym(acc, "Arm%2", w, 0.55 * crouch, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, 0.45 * crouch, 0, 0)
		sym(acc, "Leg%2", w, -0.55 * crouch, 0, 0)
		sym(acc, "Foot%", w, 0.3 * crouch, 0, 0)
	end
	tuckLegs(self, acc, w, 0.6 * lift)
	wingsSpread(self, acc, w * open, takeoffBeat(t), takeoffBeat(t - 0.05), 0, 0.25 * (1 - open))
	wingsFolded(self, acc, w * (1 - open))
	neck(self, acc, w, -0.3 * crouch + 0.05 * lift - 0.15 * settle)
	add(acc, "Head", w, 0.25 * crouch + 0.15 * lift, 0, 0)
end

Shots.Landing = function(self, acc, w, t)
	-- flare (wings spread, nose up), touchdown absorb, wings fold away
	local s = self.Scale
	local flare = 1 - smooth(0.06, 0.3, t)
	local absorb = sin(clamp((t - 0.06) / 0.45, 0, 1) * math.pi)
	local fold = smooth(0.12, 0.5, t)
	add(acc, "Body", w, 0.18 * flare - 0.03 * absorb, 0, 0, 0, -0.75 * s * absorb, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, 0.35 * flare - 0.3 * absorb, 0, 0)
		sym(acc, "Arm%2", w, 0.45 * absorb, 0, 0)
	end
	if self.HasBack then
		sym(acc, "Leg%1", w, 0.4 * absorb, 0, 0)
		sym(acc, "Leg%2", w, -0.5 * absorb, 0, 0)
		sym(acc, "Foot%", w, 0.15 * absorb, 0, 0)
	end
	wingsSpread(self, acc, w * (1 - fold), 0.8 * flare + 0.55 * (1 - flare), 0.6 * flare + 0.4 * (1 - flare), 0.25 * (1 - flare), 0.4 * (1 - flare))
	wingsFolded(self, acc, w * fold)
	neck(self, acc, w, -0.2 * absorb)
	add(acc, "Head", w, 0.15 * absorb, 0, 0)
end

Shots.Roar = function(self, acc, w, t)
	local rise = clamp(t / 0.35, 0, 1)
	local thrust = clamp((t - 0.35) / 0.25, 0, 1)
	local hold = (t > 0.6 and t < 1.35) and 1 or 0
	local shake = hold * sin(t * 70) * 0.025
	add(acc, "Chest", w, 0.12 * rise - 0.08 * thrust, 0, 0, 0, 0.12 * self.Scale * rise, 0)
	neck(self, acc, w, 0.55 * rise - 1.05 * thrust, shake * 3)
	add(acc, "Head", w, -0.25 * rise + 0.6 * thrust, 0, shake)
	add(acc, "Jaw", w, (0.12 * rise + 0.5 * thrust) * (t < 1.4 and 1 or 0), 0, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, -0.15 * rise + 0.15 * thrust, 0, 0)
	end
	local open = rise * 0.9
	wingsSpread(self, acc, w * open, 0.5 + shake * 4, 0.4, 0, 0)
	wingsFolded(self, acc, w * (1 - open))
	tail(self, acc, w, -0.2 * rise, 0, 0.05 * hold, t * 3)
end

-- Wind Dash: a streamlined lunge - body pitched forward, neck stretched, legs tucked,
-- wings swept back.
Shots.Dash = function(self, acc, w, t)
	local s = self.Scale
	local k = sin(clamp(t / 0.55, 0, 1) * math.pi)
	add(acc, "Body", w, -0.2 * k, 0, 0, 0, -0.25 * s * k, 0)
	neck(self, acc, w, -0.4 * k)
	add(acc, "Head", w, 0.25 * k, 0, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, -0.7 * k, 0, 0)
		sym(acc, "Arm%2", w, -0.5 * k, 0, 0)
	end
	tuckLegs(self, acc, w, 0.85 * k)
	wingsSpread(self, acc, w, 0.25 * k, 0.3, 0.3 * k, 0.3 * k)
	tail(self, acc, w, 0.3 * k, 0, 0.02, t * 8)
end

-- Fire Breath (held): rear the head back, thrust it forward with the jaw wide open,
-- wings spread, a trembling hold while the flames last.
Shots.FireBreath = function(self, acc, w, t, shot)
	local rise = clamp(t / 0.3, 0, 1)
	local thrust = smooth(0.15, 0.42, t)
	local hold = shot and shot.HoldTime or 0
	local shake = hold > 0 and sin((t + hold) * 55) * 0.02 or 0
	add(acc, "Chest", w, 0.1 * rise - 0.06 * thrust, 0, 0, 0, 0.1 * self.Scale * rise, 0)
	neck(self, acc, w, 0.55 * rise - 0.95 * thrust, shake * 3)
	add(acc, "Head", w, -0.2 * rise + 0.45 * thrust, 0, shake)
	add(acc, "Jaw", w, 0.58 * thrust, 0, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, -0.15 * rise, 0, 0)
	end
	if self.Params.Mode == "Fly" or self.Params.Mode == "Air" then
		tuckLegs(self, acc, w, 0.5)
	end
	local open = rise * 0.9
	wingsSpread(self, acc, w * open, 0.55 + shake * 5, 0.4, 0, 0)
	wingsFolded(self, acc, w * (1 - open))
	tail(self, acc, w, -0.15 * rise, 0, 0.04, t * 3)
end

-- Sky Dance (bond level 20): a full barrel roll with strong wing beats in the air, a
-- proud rear-up with a roar on the ground.
Shots.Flourish = function(self, acc, w, t)
	local mode = self.Params.Mode
	local air = mode == "Fly" or mode == "Air" or mode == "Takeoff"
	local s = self.Scale
	if air then
		local roll = TAU * smooth(0.08, 1.35, t)
		local arch = sin(clamp(t / 1.6, 0, 1) * math.pi)
		add(acc, "Body", w, 0.1 * arch, 0, roll)
		neck(self, acc, w, 0.35 * arch)
		add(acc, "Head", w, 0.2 * arch, 0, 0)
		add(acc, "Jaw", w, 0.25 * arch, 0, 0)
		tuckLegs(self, acc, w, 0.7)
		wingsSpread(self, acc, w, sin(t * 11) * 0.9, sin(t * 11 - 0.6) * 0.8, 0, 0)
		tail(self, acc, w, 0.1, 0, 0.12, t * 6)
	else
		local up = smooth(0, 0.4, t) * (1 - smooth(1.35, 1.8, t))
		local bellow = (t > 0.45 and t < 1.3) and 1 or 0
		local shake = bellow * sin(t * 60) * 0.02
		add(acc, "Body", w, 0.55 * up, 0, 0, 0, 0.6 * s * up, 0)
		add(acc, "Chest", w, 0.15 * up, 0, 0)
		neck(self, acc, w, 0.35 * up, shake * 3)
		add(acc, "Head", w, 0.15 * up, 0, shake)
		add(acc, "Jaw", w, 0.45 * bellow, 0, 0)
		if self.HasFront then
			sym(acc, "Arm%1", w, 0.95 * up, 0, 0)
			sym(acc, "Arm%2", w, 0.6 * up, 0, 0)
		end
		if self.HasBack then
			sym(acc, "Leg%1", w, -0.25 * up, 0, 0)
			sym(acc, "Leg%2", w, 0.2 * up, 0, 0)
		end
		wingsSpread(self, acc, w * up, 0.6 + sin(t * 7) * 0.35 * up, 0.5, 0.1, 0)
		wingsFolded(self, acc, w * (1 - up))
		tail(self, acc, w, -0.1 * up, 0, 0.12 * up, t * 4)
	end
end

Shots.Eat = function(self, acc, w, t)
	local down = clamp(t / 0.5, 0, 1) * clamp((2.4 - t) / 0.5, 0, 1)
	local chew = (t > 0.55 and t < 1.9) and max(0, sin(t * 14)) or 0
	neck(self, acc, w, -1.25 * down)
	add(acc, "Head", w, -0.15 * down - chew * 0.05, 0, 0)
	add(acc, "Jaw", w, chew * 0.32, 0, 0)
	if self.HasFront then
		sym(acc, "Arm%1", w, -0.15 * down, 0, 0)
	end
	wingsFolded(self, acc, w)
end

Shots.IdleVariant = function(self, acc, w, t)
	-- look around, then a wing stretch
	local a = clamp(t / 0.6, 0, 1) * clamp((2.6 - t) / 0.6, 0, 1)
	local look = sin(t * 2.2) * 0.45
	add(acc, "Head", w, 0.1 * a, look * a, 0)
	neck(self, acc, w, 0.15 * a, look * 0.6 * a)
	local stretch = clamp((t - 0.6) / 0.5, 0, 1) * clamp((2.0 - t) / 0.5, 0, 1)
	wingsFolded(self, acc, w * (1 - stretch * 0.8))
	wingsSpread(self, acc, w * stretch * 0.8, 0.7, 0.5, 0.25, 0.2)
end

-- ============================================================== update
local function spring(state, target: number, freq: number, damping: number, dt: number)
	-- semi-implicit damped spring with fixed substeps (frame-rate independent)
	local steps = math.max(1, math.ceil(dt / (1 / 120)))
	local h = dt / steps
	local w = TAU * freq
	for _ = 1, steps do
		local a = -w * w * (state[1] - target) - 2 * damping * w * state[2]
		state[2] += a * h
		state[1] += state[2] * h
	end
	return state[1]
end

function Animator:Update(dt: number)
	if self.Paused then
		return
	end
	dt = math.min(dt, 0.1)
	local p = self.Params
	self.Time += dt
	self.Breath = (self.Breath + dt * 0.28) % 1

	-- state weights (exponential crossfade, normalized)
	local target = chooseTarget(p)
	self.Target = target
	local blendRate = (target == "Dive" or target == "FastFly") and 5 or 7
	local a = 1 - exp(-blendRate * dt)
	local total = 0
	for _, s in BASE_STATES do
		local tw = (s == target) and 1 or 0
		local w = self.Weights[s] + (tw - self.Weights[s]) * a
		if w < 0.002 then
			w = 0
		end
		self.Weights[s] = w
		total += w
	end

	-- gait phase (stride length scales with the dragon)
	if p.Mode == "Ground" then
		local running = p.Speed > (p.WalkSpeed + p.RunSpeed) * 0.5
		local strideLen = (running and 21 or 9.5) * self.Scale
		local freq = clamp(p.Speed / strideLen, 0.35, 3.4)
		local prev = self.Gait
		self.Gait = (self.Gait + dt * freq) % 1
		if self.OnFootstep and p.Speed > 1 then
			if self.Gait < prev then
				self.OnFootstep("L")
			elseif prev < 0.5 and self.Gait >= 0.5 then
				self.OnFootstep("R")
			end
		end
	end
	-- flap phase
	local flapFreq
	if target == "Hover" or target == "Ascend" then
		flapFreq = 1.9
	elseif target == "Fly" then
		flapFreq = 1.2 + clamp(p.Speed / 250, 0, 0.5)
	elseif target == "FastFly" then
		flapFreq = 2.4
	elseif target == "Descend" then
		flapFreq = 1.0
	else
		flapFreq = 1.4
	end
	if self:IsPlaying("Takeoff") then
		flapFreq = 2.3
	end
	flapFreq /= math.sqrt(self.Scale)
	local prevFlap = self.Flap
	self.Flap = (self.Flap + dt * flapFreq) % 1
	if self.OnFlap and p.Mode == "Fly" and target ~= "Dive" and target ~= "FastFly" then
		-- fire at the start of each downstroke
		if self.Flap < prevFlap then
			self.OnFlap()
		end
	end

	-- clear accumulators
	local acc = self.Acc
	for _, v in acc do
		v[1], v[2], v[3], v[4], v[5], v[6] = 0, 0, 0, 0, 0, 0
	end
	self.FoldW, self.SpreadW = 0, 0

	-- base layer
	if total > 0 then
		for _, s in BASE_STATES do
			local w = self.Weights[s]
			if w > 0 then
				States[s](self, acc, w / total)
			end
		end
	end

	-- one-shots override proportionally to their envelope
	for i = #self.Shots, 1, -1 do
		local shot = self.Shots[i]
		local def = shot.Def
		local advance = dt * shot.Speed
		if def.Hold and not shot.Released and shot.T + advance >= def.Hold then
			-- held clip (fire breath): sustain until Stop() or MaxHold
			shot.T = def.Hold
			shot.HoldTime = (shot.HoldTime or 0) + dt
			if shot.HoldTime >= (def.MaxHold or 4) then
				shot.Released = true
			end
		else
			shot.T += advance
		end
		if shot.T >= def.Duration then
			table.remove(self.Shots, i)
		else
			local env = clamp(shot.T / def.FadeIn, 0, 1) * clamp((def.Duration - shot.T) / def.FadeOut, 0, 1)
			env = env * env * (3 - 2 * env)
			if env > 0 then
				for _, v in acc do
					for k = 1, 6 do
						v[k] *= (1 - env)
					end
				end
				self.FoldW *= (1 - env)
				self.SpreadW *= (1 - env)
				Shots[shot.Name](self, acc, env, shot.T, shot)
			end
		end
	end

	self.LastFoldW = clamp(self.FoldW, 0, 1)

	-- additive: banking (outer wing lowers, inner rises)
	self.BankSmoothed += (p.Bank - self.BankSmoothed) * (1 - exp(-6 * dt))
	local bank = self.BankSmoothed
	self.WingBank = (self.HasWings and (p.Mode == "Fly" or p.Mode == "Air")) and bank or 0
	-- tail: lags behind turns with a little overshoot; follows vertical speed
	local tailTarget = -clamp(p.TurnRate, -2.5, 2.5) * (p.Mode == "Ground" and 0.12 or 0.09)
	local tailVal = spring(self.TailSpring, tailTarget, 1.6, 0.45, dt)
	local tailPitchTarget = clamp(p.Vertical / 60, -0.6, 0.6) * 0.18
	local tailPitch = spring(self.TailPitch, tailPitchTarget, 1.4, 0.5, dt)
	local nT = #self.Tail
	for i, j in self.Tail do
		local k = i / nT
		add(acc, j, 1, tailPitch * (0.5 + k), tailVal * (0.6 + k * 0.9), 0)
	end
	-- neck/head lead into turns and toward the requested look direction
	local neckTarget = clamp(p.TurnRate, -2.5, 2.5) * 0.08 + (p.Look and p.Look.X or 0) * 0.6
	local neckVal = spring(self.NeckSpring, neckTarget, 2.2, 0.8, dt)
	local nN = math.max(1, #self.Neck)
	for _, j in self.Neck do
		add(acc, j, 1, 0, neckVal / nN, 0)
	end
	add(acc, "Head", 1, (p.Look and p.Look.Y or 0) * 0.4, neckVal * 0.5, 0)
end

-- Computes transforms from the accumulators (no instance writes).
function Animator:_buildTransforms()
	local CFnew, CFangles = CFrame.new, CFrame.Angles
	local T = self.Transforms
	local acc = self.Acc
	for name, v in acc do
		T[name] = CFnew(v[4], v[5], v[6]) * CFangles(v[1], v[2], v[3])
	end
	if self.HasWings then
		-- wings: normalized spread pose, banked, then blended toward the fold
		-- in rotation-vector space (continuous even for ~180 degree folds,
		-- where a shortest-path slerp would flip sides)
		local fw = clamp(self.FoldW, 0, 1)
		local sw = self.SpreadW
		local inv = sw > 1e-4 and 1 / sw or 0
		local bank = self.WingBank
		local foldRV = self.FoldRV
		for _, name in WING_JOINTS do
			local v = acc[name]
			if v then
				local bz = 0
				if bank ~= 0 then
					-- inner wing rises, outer wing lowers (same sign on both sides
					-- because the right side's roll axis is mirrored)
					local seg = string.sub(name, -1)
					bz = seg == "1" and bank * 0.3 or (seg == "2" and bank * 0.1 or 0)
				end
				local spread = CFangles(v[1] * inv, v[2] * inv, v[3] * inv + bz)
				if fw > 0.999 and foldRV then
					T[name] = self.FoldCF[name]
				elseif fw > 0.001 and foldRV then
					T[name] = fromRotVec(rotVec(spread) * (1 - fw) + foldRV[name] * fw)
				else
					T[name] = spread
				end
			end
		end
	end
	return T
end

-- Forward kinematics in Root space for the current transforms.
function Animator:_forwardKinematics()
	local T = self.Transforms
	local out = self.BoneCF
	for _, j in self.Chain do
		local pcf = out[j.Parent]
		if pcf then
			out[j.Name] = pcf * j.C0 * (T[j.Name] or CFrame.identity) * j.C1inv
		end
	end
	return out
end

-- Cheap signature of the wing pose; membranes only re-solve when it moves.
function Animator:_wingSignature(): number
	local s = self.FoldW * 5.3 + self.SpreadW * 1.7 + self.WingBank * 2.9
	for i, name in { "WingL1", "WingL2", "WingL3", "WingR1", "WingR2", "WingR3", "Body", "Chest", "WingL4", "WingL5" } do
		local v = self.Acc[name]
		if v then
			s += (v[1] * 1.3 + v[2] * 2.1 + v[3] * 3.7 + v[5] * 0.7) * i
		end
	end
	return s
end

-- Writes the pose to the Motor6Ds and re-stretches the membranes.
-- membranes: false skips the membrane solve (LOD).
function Animator:Apply(membranes: boolean?)
	local T = self:_buildTransforms()
	for name, motor in self.Motors do
		local tr = T[name]
		if tr then
			motor.Transform = tr
		end
	end
	if self.MembranesEnabled and membranes ~= false then
		local sig = self:_wingSignature()
		if self.LastWingSig == nil or math.abs(sig - self.LastWingSig) > 1e-4 then
			self.LastWingSig = sig
			self.Membranes:Solve(self:_forwardKinematics())
		end
	end
end

-- Fills the accumulators with a single state/shot at time t (previews).
function Animator:Sample(state: string, t: number?)
	local acc = self.Acc
	for _, v in acc do
		v[1], v[2], v[3], v[4], v[5], v[6] = 0, 0, 0, 0, 0, 0
	end
	self.Time = t or 0
	self.Flap = (t or 0) % 1
	self.Gait = (t or 0) % 1
	self.Breath = 0
	self.FoldW, self.SpreadW, self.WingBank = 0, 0, 0
	if States[state] then
		States[state](self, acc, 1)
	elseif Shots[state] then
		Shots[state](self, acc, 1, t or 0)
	end
	self.LastWingSig = nil
end

-- Static pose sample: returns { [joint] = CFrame } (for Builder.pose).
function Animator.samplePose(model: Model, state: string, t: number?, params: { [string]: any }?)
	local anim = Animator.new(model)
	if params then
		anim:SetParams(params)
	end
	anim:Sample(state, t)
	local out = {}
	for name, tr in anim:_buildTransforms() do
		out[name] = tr
	end
	return out
end

return Animator

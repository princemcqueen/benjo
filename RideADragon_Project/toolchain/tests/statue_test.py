"""The owner's statue in the middle of the plaza (StatueService): it replaces the stone dragon on the plinth
(a marble king when the avatar cannot be loaded, like in the simulator), with a plaque and a floating
title in the OWNER colours; and the posing / freezing of a real avatar rig, tested on a hand-built R15-like
rig (right fist up, left arm down, feet on the plate)."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, lua_table_to_py  # noqa: E402

FAIL = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        FAIL.append(label)


def srv(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    head = '''
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local SS = require(SSS.Services.StatueService)
local WC = require(RS.Configs.WorldConfig)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


RIG = '''
local function part(model, name, size, pos)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.new(pos)
	p.Anchored = false
	p.Parent = model
	return p
end
local function joint(model, name, p0, p1, c0, c1)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = p0
	m.Part1 = p1
	m.C0 = c0
	m.C1 = c1 or CFrame.identity
	m.Parent = p1
	return m
end
local model = Instance.new("Model")
model.Name = "Rig"
local hrp = part(model, "HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 4.5, 0))
local lower = part(model, "LowerTorso", Vector3.new(2, 0.4, 1), Vector3.new(0, 4, 0))
local upper = part(model, "UpperTorso", Vector3.new(2, 2, 1), Vector3.new(0, 5, 0))
local ruarm = part(model, "RightUpperArm", Vector3.new(1.2, 1, 1), Vector3.new(1.6, 5.8, 0))
local rlarm = part(model, "RightLowerArm", Vector3.new(1.2, 1, 1), Vector3.new(2.9, 5.8, 0))
local rhand = part(model, "RightHand", Vector3.new(1, 1, 1), Vector3.new(3.9, 5.8, 0))
local luarm = part(model, "LeftUpperArm", Vector3.new(1.2, 1, 1), Vector3.new(-1.6, 5.8, 0))
local llarm = part(model, "LeftLowerArm", Vector3.new(1.2, 1, 1), Vector3.new(-2.9, 5.8, 0))
local lhand = part(model, "LeftHand", Vector3.new(1, 1, 1), Vector3.new(-3.9, 5.8, 0))
local rul = part(model, "RightUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5, 3.0, 0))
local rll = part(model, "RightLowerLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5, 1.9, 0))
local rfoot = part(model, "RightFoot", Vector3.new(1, 0.4, 2), Vector3.new(0.5, 0.9, 0))
local lul = part(model, "LeftUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(-0.5, 3.0, 0))
local lll = part(model, "LeftLowerLeg", Vector3.new(1, 1.2, 1), Vector3.new(-0.5, 1.9, 0))
local lfoot = part(model, "LeftFoot", Vector3.new(1, 0.4, 2), Vector3.new(-0.5, 0.9, 0))
local glove = part(model, "Glove", Vector3.new(1.3, 1.3, 1.3), Vector3.new(3.9, 5.8, 0))
joint(model, "Root", hrp, lower, CFrame.new(0, -0.5, 0))
joint(model, "Waist", lower, upper, CFrame.new(0, 1, 0))
joint(model, "RightShoulder", upper, ruarm, CFrame.new(1, 0.8, 0), CFrame.new(-0.6, 0, 0))
joint(model, "RightElbow", ruarm, rlarm, CFrame.new(0.65, 0, 0), CFrame.new(-0.65, 0, 0))
joint(model, "RightWrist", rlarm, rhand, CFrame.new(0.55, 0, 0), CFrame.new(-0.45, 0, 0))
joint(model, "LeftShoulder", upper, luarm, CFrame.new(-1, 0.8, 0), CFrame.new(0.6, 0, 0))
joint(model, "LeftElbow", luarm, llarm, CFrame.new(-0.65, 0, 0), CFrame.new(0.65, 0, 0))
joint(model, "LeftWrist", llarm, lhand, CFrame.new(-0.55, 0, 0), CFrame.new(0.45, 0, 0))
joint(model, "RightHip", lower, rul, CFrame.new(0.5, -0.2, 0), CFrame.new(0, 0.8, 0))
joint(model, "RightKnee", rul, rll, CFrame.new(0, -0.55, 0), CFrame.new(0, 0.55, 0))
joint(model, "RightAnkle", rll, rfoot, CFrame.new(0, -0.55, 0), CFrame.new(0, 0.45, 0))
joint(model, "LeftHip", lower, lul, CFrame.new(-0.5, -0.2, 0), CFrame.new(0, 0.8, 0))
joint(model, "LeftKnee", lul, lll, CFrame.new(0, -0.55, 0), CFrame.new(0, 0.55, 0))
joint(model, "LeftAnkle", lll, lfoot, CFrame.new(0, -0.55, 0), CFrame.new(0, 0.45, 0))
local weld = Instance.new("Weld")
weld.Name = "AccessoryWeld"
weld.Part0 = glove
weld.Part1 = rhand
weld.Parent = glove
model.PrimaryPart = hrp
model.Parent = workspace
'''


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    sim.add_player("Alice", 7001)
    sim.run_for(14, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    r = srv(sim, '''
local plinth = workspace.World.Hub:FindFirstChild("DragonStatue")
local out = { ready = SS.Ready, kind = SS.Kind, plinth = plinth ~= nil }
if plinth then
	local owner = plinth:FindFirstChild("OwnerStatue")
	out.owner = owner ~= nil
	out.dragon = plinth:FindFirstChild("StatueDragon") ~= nil
	local n = 0
	if owner then for _, d in owner:GetDescendants() do if d:IsA("BasePart") then n += 1 end end end
	out.parts = n
	local pl = plinth:FindFirstChild("OwnerPlaque")
	local gui = pl and pl:FindFirstChild("PlaqueGui")
	out.name = gui and gui:FindFirstChild("Owner") and gui.Owner.Text or ""
	out.rank = gui and gui:FindFirstChild("Rank") and gui.Rank.Text or ""
	local anchor = plinth:FindFirstChild("TitleAnchor")
	local tg = anchor and anchor:FindFirstChild("TitleGui")
	out.title = tg and tg:FindFirstChild("Title") and tg.Title.Text or ""
	out.epithet = tg and tg:FindFirstChild("Epithet") and tg.Epithet.Text or ""
	out.basin = plinth:FindFirstChildWhichIsA("Part") ~= nil
	-- the statue stands on the gold plate of the plinth
	local lowest = math.huge
	if owner then for _, d in owner:GetDescendants() do if d:IsA("BasePart") then lowest = math.min(lowest, d.Position.Y - d.Size.Y / 2) end end end
	out.lowest = lowest
	out.plate = WC.Hub.Height + 14
	out.owner_attr = owner and owner:GetAttribute("Owner") or ""
end
shared.R = out''')
    print("statue", r)
    check(r["ready"] and r["plinth"] and r["owner"], "the owner's statue stands on the plinth")
    check(not r["dragon"], "the stone dragon is gone")
    check(r["kind"] == "Fallback" and r["parts"] >= 14, f"without the avatar a marble king ({r['parts']:.0f} parts) stands there ({r['kind']})")
    check(r["name"] == "BENDZAMINOO" and "OWNER" in r["rank"] and "DRAGON KING" in r["rank"], f"the plaque names the owner ({r['name']} / {r['rank']})")
    check("OWNER" in r["title"] and "Dragon King" in r["epithet"] and "Bendzaminoo" in r["epithet"], f"a floating title ({r['title']} / {r['epithet']})")
    check(abs(r["lowest"] - r["plate"]) < 1.5, f"the feet are on the plate (lowest {r['lowest']:.1f}, plate {r['plate']:.1f})")
    check(r["owner_attr"] == "Bendzaminoo", "the statue is tagged with the owner's name")

    # the posing and freezing of an avatar rig (hand-built, arms out like an R15 T-pose)
    r = srv(sim, RIG + '''
local frame = CFrame.identity
SS._test.pose(model, frame)
-- forward kinematics: Part1 = Part0 * C0 * C1^-1 (what the engine does with the new C0 values)
local function child(parentCF, name)
	local m
	for _, d in model:GetDescendants() do if d:IsA("Motor6D") and d.Name == name then m = d end end
	return parentCF * m.C0 * m.C1:Inverse()
end
local upperCF = model.UpperTorso.CFrame
local lowerCF = model.LowerTorso.CFrame
local rua = child(upperCF, "RightShoulder")
local rla = child(rua, "RightElbow")
local rh = child(rla, "RightWrist")
local lua = child(upperCF, "LeftShoulder")
local lla = child(lua, "LeftElbow")
local lh = child(lla, "LeftWrist")
local rul = child(lowerCF, "RightHip")
local rll = child(rul, "RightKnee")
local rf = child(rll, "RightAnkle")
local lul = child(lowerCF, "LeftHip")
local lll = child(lul, "LeftKnee")
local lf = child(lll, "LeftAnkle")
local function v(cf) return { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z } end
shared.R = { rhand = v(rh), lhand = v(lh), rfoot = v(rf), lfoot = v(lf), torso = v(upperCF),
	rlen = (rh.Position - Vector3.new(1, 5.8, 0)).Magnitude, llen = (lh.Position - Vector3.new(-1, 5.8, 0)).Magnitude,
	rfootLen = (rf.Position - Vector3.new(0.5, 3.8, 0)).Magnitude }
SS._test.freeze(model)
task.spawn(function() SS._test.settle(model, 20) end)
''')
    sim.run_for(1.0, 1 / 30)
    r["frozen"] = srv(sim, '''
local model = workspace:FindFirstChild("Rig")
local rootOnly = true
for _, d in model:GetDescendants() do
	if d:IsA("BasePart") and d.Anchored ~= (d.Name == "HumanoidRootPart") then rootOnly = false end
end
local lowest = math.huge
for _, name in { "LeftFoot", "RightFoot" } do
	local f = model[name]
	lowest = math.min(lowest, f.Position.Y - f.Size.Y / 2)
end
shared.R = { rootOnly = rootOnly, feetY = lowest, humanoid = model:FindFirstChildOfClass("Humanoid") == nil }
''')
    print("pose", r)
    check(r["rhand"]["y"] > 5.8 + 2.4 and r["rhand"]["x"] > 0.9, f"the right fist goes up ({r['rhand']['x']:.1f}, {r['rhand']['y']:.1f}, {r['rhand']['z']:.1f})")
    check(r["rhand"]["z"] < 0, "...and a little forward")
    check(r["lhand"]["y"] < 5.8 - 2.4, f"the left arm hangs down (y {r['lhand']['y']:.1f})")
    check(abs(r["rlen"] - 2.9) < 0.05 and abs(r["llen"] - 2.9) < 0.05, f"the arms keep their length ({r['rlen']:.2f} / {r['llen']:.2f})")
    check(abs(r["torso"]["y"] - 5) < 0.01, "the torso does not move")
    check(r["rfoot"]["x"] > 0.5 and r["lfoot"]["x"] < -0.5, f"the feet go a little apart ({r['lfoot']['x']:.2f} / {r['rfoot']['x']:.2f})")
    check(abs(r["rfootLen"] - 2.9) < 0.05, f"the legs keep their length ({r['rfootLen']:.2f})")
    check(r["frozen"]["rootOnly"] and r["frozen"]["humanoid"], "frozen: only the root is anchored (the limbs hang on it), the humanoid is gone")
    check(abs(r["frozen"]["feetY"] - 20) < 0.3, f"settled: the feet are on the plate ({r['frozen']['feetY']:.2f})")

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    check(len(sim.errors) == 0, "no script errors")
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")
    print("ALL OK" if not FAIL else "SOME FAILED")


if __name__ == "__main__":
    main()

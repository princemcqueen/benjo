"""Renders the toy-brick dragon (BrickBuilder) in poses from several views."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_runner import boot
import preview3d
import luau_interp as LI

SNIP = r'''
local RS = game:GetService("ReplicatedStorage")
local DV = require(RS.Shared.Dragons.DragonVisual)
local Animator = require(RS.Shared.Dragons.Animator)
local Builder = require(RS.Shared.Dragons.Builder)
local m = DV.build("%(species)s", { Detail = "High", Mutation = "%(mutation)s" })
m.Parent = workspace
local pose = Animator.samplePose(m, "%(state)s", %(t)s)
Builder.pose(m, pose, CFrame.new(%(x)s, 0, 0))
shared.PARTS = m:GetAttribute("Parts")
shared.HIP = m:GetAttribute("HipHeight")
'''


def build_scene(entries):
    sim = boot()
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    hip = 6.5
    for i, (species, mutation, state, t, x) in enumerate(entries):
        fn = LI.load(SNIP % dict(species=species, mutation=mutation, state=state, t=t, x=x), f"brick{i}", env)
        sim.in_ctx(ctx, fn)
        hip = ctx.shared.get("HIP") or hip
        print(species, mutation, state, "parts", ctx.shared.get("PARTS"))
    if sim.errors:
        print("ERRORS", sim.errors[:5])
    # keep only the posed dragons (skip the generated world / terrain props)
    ws = sim.services["Workspace"]
    for ch in list(ws.children):
        if ch.cls.name == "Model" and ch.attrs.get("Style") == "Brick":
            continue
        if ch.cls.name in ("Camera", "Terrain"):
            continue
        ch.parent = None
    parts = [p for p in preview3d.part_records(sim)
             if abs(p["cf"][0]) < 400 and abs(p["cf"][2]) < 60 and p["cf"][1] < 20]
    parts.append({"shape": "Block", "cf": [0, -hip - 0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [600, 1, 600],
                  "color": [110, 170, 90], "mat": "plastic", "t": 0})
    return parts, hip


def render(entries, views, out, size=(900, 600), target=(0, 1, 2), fov=45):
    parts, hip = build_scene(entries)
    jobs, paths = [], []
    for i, v in enumerate(views):
        yaw, pitch, dist = v[0], v[1], v[2]
        tgt = target if len(views[i]) < 4 else views[i][3]
        cam = preview3d.orbit_camera(list(tgt), dist, yaw, pitch, fov=fov)
        sc = preview3d.make_scene(parts, cam, fog_density=0.0004, shadow_center=list(tgt), shadow_extent=40)
        p = f"{out[:-4]}_{i}.png"
        jobs.append((sc, p, size[0], size[1]))
        paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, [f"view {v[:2]}" for v in views], out, cols=2)
    return out


if __name__ == "__main__":
    state = sys.argv[1] if len(sys.argv) > 1 else "Idle"
    print(render([("GreenDrake", "None", state, 0.4, 0)], [(150, 12, 46), (90, 8, 44), (210, 24, 40), (30, 35, 48)],
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", f"brick_{state}.png")))

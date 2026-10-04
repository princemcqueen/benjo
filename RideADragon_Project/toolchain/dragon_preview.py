"""Builds a dragon in the sim and renders it from several angles."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_runner import boot
import preview3d
import luau_interp as LI

SNIP = r'''
local RS = game:GetService("ReplicatedStorage")
local Builder = require(RS.Shared.Dragons.Builder)
local m = Builder.build("%(species)s", { Detail = "%(detail)s", Mutation = "%(mutation)s" })
m.Parent = workspace
%(pose)s
shared.parts = m:GetAttribute("Parts")
'''

def build_and_render(species="GreenDrake", detail="High", mutation="None", out_prefix=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "drake"),
                     views=((35, 18), (125, 12), (215, 25), (300, 60)), pose_lua="", dist=None, size=(900, 600)):
    sim = boot()
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    fn = LI.load(SNIP % {"species": species, "detail": detail, "mutation": mutation, "pose": pose_lua}, "preview", env)
    sim.in_ctx(ctx, fn)
    if sim.errors:
        print("ERRORS", sim.errors)
    parts = preview3d.part_records(sim)
    print("parts:", len(parts), "attr:", ctx.shared.get("parts"))
    # ground plane
    hip = None
    for p in sim.services["Workspace"].descendants():
        if p.cls.name == "Model" and p.attrs.get("HipHeight"):
            hip = p.attrs["HipHeight"]
    hip = hip or 5.4
    parts.append({"shape": "Block", "cf": [0, -hip - 0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [80, 1, 80],
                  "color": [98, 130, 78], "mat": "plastic", "t": 0})
    outs = []
    for i, (yaw, pitch) in enumerate(views):
        cam = preview3d.orbit_camera([0, 0.5, 1.5], dist or 32, yaw, pitch, fov=45)
        path = f"{out_prefix}_{i}.png"
        preview3d.render(parts, cam, path, w=size[0], h=size[1], shadow_center=[0, 0, 0], shadow_extent=24,
                         fog_density=0.002)
        outs.append(path)
    return outs

if __name__ == "__main__":
    sp = sys.argv[1] if len(sys.argv) > 1 else "GreenDrake"
    print(build_and_render(sp))

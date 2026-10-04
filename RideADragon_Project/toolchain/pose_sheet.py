"""Renders a contact sheet of animation poses for a species.

usage: python3 pose_sheet.py GreenDrake "Idle:0,Walk:0.25,Fly:0.1" [yaw pitch] [out]
Each entry is State:t (t = phase/time). Shots (Takeoff, Landing...) use t in seconds.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_runner import boot
import preview3d
import luau_interp as LI

SNIP = r'''
local RS = game:GetService("ReplicatedStorage")
local Builder = require(RS.Shared.Dragons.Builder)
local Animator = require(RS.Shared.Dragons.Animator)
local m = Builder.build("%(species)s", { Detail = "%(detail)s", Mutation = "%(mutation)s" })
m.Parent = workspace
if %(static)s then
	Builder.pose(m, Animator.samplePose(m, "%(state)s", %(t)s, %(params)s))
else
	local anim = Animator.new(m)
	if %(params)s then anim:SetParams(%(params)s) end
	anim:Sample("%(state)s", %(t)s)
	anim:Apply()
end
%(extra)s
'''


def pose_parts(species, state, t, params="nil", detail="High", mutation="None", extra="", ground=True,
               ground_y=None, static=False):
    sim = boot()
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    fn = LI.load(SNIP % dict(species=species, detail=detail, mutation=mutation, state=state, t=t,
                            params=params, extra=extra, static="true" if static else "false"), "pose", env)
    sim.in_ctx(ctx, fn)
    if sim.errors:
        print("ERRORS", sim.errors)
    parts = preview3d.part_records(sim)
    hip = 4.8
    for p in sim.services["Workspace"].descendants():
        if p.cls.name == "Model" and p.attrs.get("HipHeight"):
            hip = p.attrs["HipHeight"]
    if ground:
        gy = ground_y if ground_y is not None else -hip
        parts.append({"shape": "Block", "cf": [0, gy - 0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [90, 1, 90],
                      "color": [98, 130, 78], "mat": "plastic", "t": 0})
    return parts


def sheet(species, entries, yaw=35, pitch=18, out=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "poses.png"), dist=34, size=(640, 430),
          cols=3, params="nil", static=False, target=(0, 0.5, 1.5)):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    jobs, paths, labels = [], [], []
    for i, (state, t) in enumerate(entries):
        parts = pose_parts(species, state, t, params, static=static)
        cam = preview3d.orbit_camera(list(target), dist, yaw, pitch, fov=45)
        scene = preview3d.make_scene(parts, cam, fog_density=0.002, shadow_center=[0, 0, 0], shadow_extent=26)
        path = f"{out[:-4]}_{i}.png"
        jobs.append((scene, path, size[0], size[1]))
        paths.append(path)
        labels.append(f"{state} t={t}")
    preview3d.render_batch(jobs)
    return preview3d.contact_sheet(paths, labels, out, cols=cols)


if __name__ == "__main__":
    sp = sys.argv[1]
    ent = []
    for e in sys.argv[2].split(","):
        s, _, t = e.partition(":")
        ent.append((s, t or "0"))
    yaw = float(sys.argv[3]) if len(sys.argv) > 3 else 35
    pitch = float(sys.argv[4]) if len(sys.argv) > 4 else 18
    out = sys.argv[5] if len(sys.argv) > 5 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "poses.png")
    print(sheet(sp, ent, yaw, pitch, out))


def views(species, state, t, out, view_list=((90, 8), (180, 10), (145, 28), (35, 70)), dist=30, size=(640, 430),
          params="nil", static=False, target=(0, 0.8, 0.5)):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    parts = pose_parts(species, state, t, params, static=static)
    jobs, paths, labels = [], [], []
    for i, (yaw, pitch) in enumerate(view_list):
        cam = preview3d.orbit_camera(list(target), dist, yaw, pitch, fov=45)
        scene = preview3d.make_scene(parts, cam, fog_density=0.002, shadow_center=[0, 0, 0], shadow_extent=26)
        path = f"{out[:-4]}_{i}.png"
        jobs.append((scene, path, size[0], size[1]))
        paths.append(path)
        labels.append(f"{state} t={t} yaw={yaw} pitch={pitch}")
    preview3d.render_batch(jobs)
    return preview3d.contact_sheet(paths, labels, out, cols=2)

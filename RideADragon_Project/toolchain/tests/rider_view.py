"""Renders the dragon with an R15 block rider from outside views (rider pose QA)."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import paths
import ride_test as RT
from sim_runner import boot, client_of
import rbx_physics, rbx_api, preview3d
import luau_interp as LI


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    RT.server_lua(sim, RT.WORLD)
    player = sim.add_player()
    RT.run(2, sim)
    char = player.props.get("Character")
    rig_src = open(os.path.join(os.path.dirname(__file__), "r15rig.lua")).read()
    ctx = sim.server_ctx
    fn = LI.load(rig_src, "rig", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn, char)
    RT.run(1, sim)
    RT.key(sim, player, "R", True); RT.run(0.1, sim); RT.key(sim, player, "R", False)
    RT.run(1.5, sim)
    model, root, cf, v = RT.snapshot(sim, "mounted")
    jobs = []
    outs = []
    def shoot(tag, views, dist=30, ty=2.5):
        parts = preview3d.part_records(sim)
        p = rbx_api.part_cframe(sim, root).p
        for i, (yaw, pitch) in enumerate(views):
            cam = preview3d.orbit_camera([p[0], p[1] + ty, p[2]], dist, yaw, pitch, fov=40)
            scene = preview3d.make_scene(parts, cam, fog_density=0.001, shadow_center=[p[0], 0, p[2]], shadow_extent=40)
            path = f"{paths.OUT}/rider_{tag}_{i}.png"
            jobs.append((scene, path, 640, 430))
            outs.append((path, f"{tag} yaw={yaw}"))
    shoot("idle", [(90, 8), (150, 18), (30, 25)])
    RT.key(sim, player, "W", True)
    RT.key(sim, player, "Space", True)
    RT.run(2.2, sim)
    RT.key(sim, player, "Space", False)
    RT.run(1.2, sim)
    RT.snapshot(sim, "flying")
    shoot("fly", [(90, 5), (150, 15), (30, 30)], dist=34)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet([o[0] for o in outs], [o[1] for o in outs], paths.OUT + "/rider_sheet.png", cols=3)
    print("errors", len(sim.errors), sim.errors[:3])

if __name__ == "__main__":
    main()

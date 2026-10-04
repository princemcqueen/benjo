"""Skinned-mesh dragon end-to-end test in the simulator.

Injects an importer-like template (MeshPart + Bones from the exported rig) into
Workspace, boots the game (DragonAssetService adopts it into
ReplicatedStorage.DragonModels), spawns the companion, rides it through ground
and flight, checks that every joint Bone is driven smoothly, and renders
frames with linear-blend skinning of the real exported mesh."""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "meshgen"))
import build_place  # noqa: E402
import rbx_api  # noqa: E402
import rbx_physics  # noqa: E402
import preview3d  # noqa: E402
from rbx_sim import Sim  # noqa: E402
from rbx_types import CFrame, Vector3  # noqa: E402
from sim_runner import PROJECT, client_of  # noqa: E402
from PIL import Image  # noqa: E402
import skin_render  # noqa: E402
from ride_test import key, Smoothness  # noqa: E402

OUT = "/tmp/claude-0/out"
SMOOTH = Smoothness()
SKIN = None
IMGS = None


def sample_bones(sim):
    folder = sim.services["Workspace"].find_child("Dragons")
    model = folder.find_child("Dragon_1001") if folder else None
    if not model:
        return
    vis = model.find_child("Visual")
    if vis is None:
        return
    items = []
    root = model.find_child("Root")
    if root is not None:
        items.append(("ROOT", root.props.get("CFrame").r))
    for d in vis.descendants():
        if d.cls.name == "Bone":
            tr = d.props.get("Transform")
            if tr is not None:
                items.append((d.props.get("Name"), tr.r))
    for name, r in items:
        p = SMOOTH.prev.get(name)
        if p is not None:
            a = SMOOTH.angle(p, r)
            w = SMOOTH.worst.get(name)
            if w is None or a > w[0]:
                SMOOTH.worst[name] = (a, SMOOTH.label)
        SMOOTH.prev[name] = r


def dragon(sim):
    folder = sim.services["Workspace"].find_child("Dragons")
    return folder.find_child("Dragon_1001") if folder else None


def render(sim, player, out, cam_offset=None, size=(1100, 640)):
    global SKIN, IMGS
    if SKIN is None:
        SKIN = skin_render.Skinner()
        IMGS = [Image.open(f"/home/claude/toolchain/meshgen/out/GreenDrake_{k}.png").convert("RGB")
                for k in ("color", "normal", "mr")]
    model = dragon(sim)
    vis = model.find_child("Visual")
    mesh = [d for d in vis.descendants() if d.cls.name == "MeshPart"][0]
    V, N, T4 = SKIN.pose(sim, mesh)
    ent = preview3d.texmesh_entry(V, SKIN.F, N, SKIN.UV, IMGS[0], IMGS[1], IMGS[2], T4)
    parts = preview3d.part_records(sim)
    root = model.find_child("Root")
    rcf = rbx_api.part_cframe(sim, root)
    c = Vector3(*rcf.p)
    if cam_offset is None:
        client = client_of(player)
        cam = getattr(client, "camera", None)
        ccf = cam.props.get("CFrame")
        look = ccf.vector_to_world(Vector3(0, 0, -1))
        camd = {"pos": list(ccf.p), "target": [ccf.p[0] + look.x * 30, ccf.p[1] + look.y * 30, ccf.p[2] + look.z * 30],
                "fov": cam.props.get("FieldOfView", 70)}
    else:
        off = rcf.vector_to_world(Vector3(*cam_offset))
        camd = {"pos": [c.x + off.x, c.y + off.y, c.z + off.z], "target": [c.x, c.y + 2, c.z], "fov": 50}
    sc = preview3d.make_scene(parts, camd, fog_density=0.0012, shadow_center=[c.x, c.y - 5, c.z], shadow_extent=45)
    sc["texMeshes"] = [ent]
    preview3d.render_batch([(sc, out, size[0], size[1])])
    return out


def main(fps=60):
    dt = 1 / fps
    sim = Sim(instant_tweens=True, signal_behavior="Deferred")
    name, tree = build_place.load_project(PROJECT)
    build_place.load_into_sim(sim, tree)
    import sim_runner as _SR
    sys.path.insert(0, "/home/claude/toolchain/worldgen")
    import terrain_data as _TD
    _TD.inject_into_sim(sim, _SR._haven_cache())
    skin_render.make_template(sim, "GreenDrake", parent=sim.services["Workspace"])
    sim.start()
    sim.physics = rbx_physics.make_physics()
    base = sim.physics

    def phys(s, step):
        base(s, step)
        sample_bones(s)
    sim.physics = phys
    rs = sim.services["ReplicatedStorage"]
    dm = rs.find_child("DragonModels")
    print("templates adopted:", [c.props.get("Name") for c in dm.children] if dm else None,
          "attr:", rs.attrs.get("MeshDragonTemplates"))
    player = sim.add_player()
    sim.run_for(3, dt)
    model = dragon(sim)
    assert model is not None, "no companion"
    vis = model.find_child("Visual")
    print("visual:", vis is not None, "MeshRig:", vis.attrs.get("MeshRig") if vis else None,
          "children:", [c.cls.name for c in vis.children] if vis else None)
    frames = []
    SMOOTH.label = "idle"
    frames.append(render(sim, player, f"{OUT}/mesh_idle.png", cam_offset=(-26, 9, -20)))
    # mount + run
    char = player.props.get("Character")
    key(sim, player, "R", True); sim.run_for(0.1, dt); key(sim, player, "R", False)
    sim.run_for(1.0, dt)
    print("rider:", model.attrs.get("RiderUserId"))
    SMOOTH.label = "run"
    key(sim, player, "W", True)
    sim.run_for(2.0, dt)
    frames.append(render(sim, player, f"{OUT}/mesh_run.png", cam_offset=(-22, 8, 8)))
    SMOOTH.label = "takeoff"
    key(sim, player, "Space", True)
    sim.run_for(0.5, dt)
    frames.append(render(sim, player, f"{OUT}/mesh_takeoff.png", cam_offset=(-24, 6, 10)))
    sim.run_for(1.2, dt)
    key(sim, player, "Space", False)
    SMOOTH.label = "fly"
    sim.run_for(2.5, dt)
    frames.append(render(sim, player, f"{OUT}/mesh_fly.png", cam_offset=(-20, 10, 18)))
    SMOOTH.label = "boost"
    key(sim, player, "LeftShift", True)
    sim.run_for(1.5, dt)
    frames.append(render(sim, player, f"{OUT}/mesh_boost.png"))
    key(sim, player, "LeftShift", False)
    key(sim, player, "W", False)
    SMOOTH.label = "hover"
    sim.run_for(1.5, dt)
    frames.append(render(sim, player, f"{OUT}/mesh_hover.png", cam_offset=(-24, 4, -14)))
    SMOOTH.label = "descend"
    key(sim, player, "LeftControl", True)
    sim.run_for(6.0, dt)
    key(sim, player, "LeftControl", False)
    sim.run_for(1.0, dt)
    SMOOTH.label = "landed"
    frames.append(render(sim, player, f"{OUT}/mesh_landed.png", cam_offset=(-26, 8, -16)))
    preview3d.contact_sheet(frames, ["idle", "run", "takeoff", "fly", "boost (camera)", "hover", "landed"],
                            f"{OUT}/mesh_sheet.png", cols=2)
    spikes = SMOOTH.report(dt)
    print("animation spikes:", spikes)
    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    return sim


if __name__ == "__main__":
    main(int(os.environ.get("FPS", "60")))

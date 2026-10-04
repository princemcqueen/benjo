"""Boots the full game with the Dragon Haven world in the simulator (terrain
injected as the exact analytic column function), checks the build and
renders views of the world."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worldgen"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "meshgen"))
import build_place  # noqa: E402
import preview3d  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_sim import Sim  # noqa: E402
from sim_runner import PROJECT  # noqa: E402
import terrain_data  # noqa: E402
import paths  # noqa: E402

from paths import OUT  # noqa: E402

VIEWS = {
    "hub": ((0, 40, 0), 190, 20, 30),
    "hub_low": ((0, 36, -20), 110, 160, 12),
    "plot": ((128, 40, -310), 150, 200, 28),
    "bridge": ((455, 40, 96), 110, 300, 18),
    "ruins": ((-500, 105, -540), 150, 140, 24),
    "falls": ((424, 120, -770), 260, 10, 10),
    "overview": ((0, 60, 0), 1300, 10, 32),
    "pillar": ((-905, 200, 300), 420, 80, 12),
}


def boot(mesh=False):
    sim = Sim(instant_tweens=True, signal_behavior="Deferred")
    name, tree = build_place.load_project(PROJECT)
    build_place.load_into_sim(sim, tree)
    import sim_runner as _SR
    ref = terrain_data.inject_into_sim(sim, _SR._haven_cache())
    if mesh:
        import skin_render
        skin_render.make_template(sim, "GreenDrake", parent=sim.services["Workspace"])
    t = time.time()
    sim.start()
    sim.physics = rbx_physics.make_physics()
    ws = sim.services["Workspace"]
    for _ in range(600):
        sim.step(1 / 30)
        if ws.attrs.get("WorldReady"):
            break
    print(f"world ready={ws.attrs.get('WorldReady')} in {time.time() - t:.1f}s sim; errors={len(sim.errors)}")
    for e in sim.errors[:8]:
        print("   ", e)
    world = ws.find_child("World")
    if world:
        n = sum(1 for d in world.descendants() if d.is_a("BasePart"))
        print("world parts:", n, " children:", [c.props.get("Name") for c in world.children])
    return sim, ref


def render(sim, names, out, size=(960, 560)):
    terrain = sim.haven.preview_terrain()
    parts = preview3d.part_records(sim)
    jobs, paths = [], []
    for nm in names:
        target, dist, yaw, pitch = VIEWS[nm]
        cam = preview3d.orbit_camera(list(target), dist, yaw, pitch, fov=55)
        sc = preview3d.make_scene(parts, cam, terrain=terrain, fog_density=0.00045, shadow_center=list(target),
                                  shadow_extent=min(dist, 500))
        p = f"{OUT}/haven_{nm}.png"
        jobs.append((sc, p, size[0], size[1]))
        paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, names, out, cols=2)
    return out


def prop_entries(target, radius, layout_mod=os.path.join(paths.WORLD_SRC, "HavenLayout.luau")):
    """Textured meshes of trees/bushes/rocks around target (merged per prop)."""
    import pickle
    import re
    import numpy as np
    from export_dragon import tangents
    props = pickle.load(open(os.path.join(paths.MESHGEN_OUT, "props.pkl"), "rb"))
    byname = {p[0]: p for p in props}
    src = open(layout_mod).read()

    def section(name):
        m = re.search(name + r" = \{(.*?)\n\t\},", src, re.S)
        rows = re.findall(r"\{ ([^{}]*?) \}", m.group(1))
        return [[float(v) for v in r.split(",")] for r in rows]
    trees = section("Trees")
    bushes = section("Bushes")
    rocks = section("Rocks")
    kinds = ["Oak", "Pine", "Birch"]
    groups = {}

    def add(name, x, y, z, yaw, s):
        if (x - target[0]) ** 2 + (z - target[2]) ** 2 > radius * radius:
            return
        groups.setdefault(name, []).append((x, y, z, yaw, s))
    for i, t in enumerate(trees):
        kind = kinds[int(t[0]) - 1]
        n = {"Oak": 3, "Pine": 3, "Birch": 2}[kind]
        add(f"{kind}{(i % n) + 1}", t[1], t[2] - 0.4, t[3], t[4], t[5])
    for i, b in enumerate(bushes):
        add(f"Bush{(i % 2) + 1}", b[0], b[1] - 0.3, b[2], b[3], b[4])
    for r in rocks:
        add(f"Rock{int(r[5]) % 4 + 1}", r[0], r[1], r[2], r[3], r[4])
    ents = []
    for name, inst in groups.items():
        _, V, F, N, UV, ic, inn = byname[name]
        Vs, Fs, Ns, UVs = [], [], [], []
        off = 0
        for x, y, z, yaw, s in inst:
            c, sn = np.cos(yaw), np.sin(yaw)
            R = np.array([[c, 0, sn], [0, 1, 0], [-sn, 0, c]])
            base = -V[:, 1].min()
            Vw = (V * s) @ R.T + np.array([x, y + base * s + V[:, 1].min() * s, z])
            Vs.append(Vw)
            Ns.append(N @ R.T)
            Fs.append(F + off)
            UVs.append(UV)
            off += len(V)
        Vv, Ff, Nn, UVv = np.vstack(Vs), np.vstack(Fs), np.vstack(Ns), np.vstack(UVs)
        T4 = tangents(Vv, Ff, UVv, Nn)
        ents.append(preview3d.texmesh_entry(np.round(Vv, 2), Ff, np.round(Nn, 2), np.round(UVv, 4), ic, inn, None, np.round(T4, 2)))
    return ents


def render_with_props(sim, names, out, radius=320, size=(960, 560)):
    terrain = sim.haven.preview_terrain()
    nature = sim.services["Workspace"].find_child("World").find_child("Nature")
    if nature is not None:
        nature.parent = None
    parts = [p for p in preview3d.part_records(sim)]
    jobs, paths = [], []
    for nm in names:
        target, dist, yaw, pitch = VIEWS[nm]
        cam = preview3d.orbit_camera(list(target), dist, yaw, pitch, fov=55)
        sc = preview3d.make_scene(parts, cam, terrain=terrain, fog_density=0.00045, shadow_center=list(target),
                                  shadow_extent=min(dist, 500))
        sc["texMeshes"] = prop_entries(target, radius)
        p = f"{OUT}/havenp_{nm}.png"
        jobs.append((sc, p, size[0], size[1]))
        paths.append(p)
    for j in jobs:
        preview3d.render_batch([j])
    preview3d.contact_sheet(paths, names, out, cols=2)
    return out


if __name__ == "__main__":
    sim, ref = boot()
    if "--props" in sys.argv:
        print(render_with_props(sim, ["hub", "hub_low", "plot", "bridge"], f"{OUT}/havenp_sheet.png"))
    else:
        print(render(sim, ["hub", "hub_low", "plot", "bridge", "ruins", "falls"], f"{OUT}/haven_sheet.png"))

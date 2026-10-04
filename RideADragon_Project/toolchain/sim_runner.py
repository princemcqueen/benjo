"""Helpers to boot the RideADragon project inside the simulator."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import paths
import build_place
import rbx_sim
import rbx_api
import rbx_render
from rbx_sim import Sim, Device

PROJECT = paths.PROJECT

DEVICES = {
    "1280x720": Device((1280, 720)),
    "1366x768": Device((1366, 768)),
    "1600x900": Device((1600, 900)),
    "1920x1080": Device((1920, 1080)),
    "1920x1200": Device((1920, 1200)),
    "2560x1440": Device((2560, 1440)),
    "2560x1600": Device((2560, 1600)),
    "3440x1440": Device((3440, 1440)),
    "3840x2160": Device((3840, 2160)),
    "phone_landscape": Device((844, 390), touch=True, keyboard=False, mouse=False, topbar=(0, 0, 160, 44), name="Phone"),
    "phone_portrait": Device((390, 844), touch=True, keyboard=False, mouse=False, topbar=(0, 0, 160, 44), name="Phone"),
    "tablet": Device((1180, 820), touch=True, keyboard=False, mouse=False, topbar=(0, 0, 220, 58), name="Tablet"),
}


_HAVEN = []


def _haven_cache():
    if not _HAVEN:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "worldgen"))
        import layout as LY
        hv, lay = LY.build_all() if False else (None, None)
        import haven as HV
        import pickle
        cache = paths.out("haven_layout.pkl")
        if os.path.exists(cache):
            with open(cache, "rb") as f:
                hv, lay = pickle.load(f)
        else:
            hv, lay = LY.build_all()
            with open(cache, "wb") as f:
                pickle.dump((hv, lay), f)
        _HAVEN.append(hv)
    return _HAVEN[0]


def find_node(node, name):
    """First node called `name` in a build_place tree (for patch_tree hooks)."""
    if node.name == name:
        return node
    for ch in node.children:
        hit = find_node(ch, name)
        if hit:
            return hit
    return None


# A server script for tests that walk into world eggs: no guardian duel in the way (EggConfig.Guardians).
# Usage: boot(extra_server=[NO_GUARDIANS]). The guardian tests leave guardians on.
NO_GUARDIANS = """
require(game:GetService("ReplicatedStorage"):WaitForChild("Configs"):WaitForChild("EggConfig")).Guardians.Enabled = false
"""


def boot(extra_server=None, extra_client=None, instant_tweens=True, verbose=False, datastore=None,
         signal_behavior="Deferred", project=PROJECT, inject_terrain=True, patch_tree=None):
    sim = Sim(verbose=verbose, instant_tweens=instant_tweens, datastore=datastore, signal_behavior=signal_behavior)
    name, tree = build_place.load_project(project)
    if patch_tree:
        patch_tree(tree)  # tests: swap script sources (fault injection)
    build_place.load_into_sim(sim, tree)
    if inject_terrain:
        # Dragon Haven terrain as the exact analytic column function (the Luau
        # voxel writer is far too slow inside the Python-hosted interpreter)
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "worldgen"))
        import terrain_data
        terrain_data.inject_into_sim(sim, _haven_cache())
    if extra_server:
        for i, src in enumerate(extra_server):
            sim.new("Script", parent=sim.services["ServerScriptService"], Name=f"TestServer{i}", Source=src)
    if extra_client:
        sps = sim.services["StarterPlayer"].find_child("StarterPlayerScripts")
        for i, src in enumerate(extra_client):
            sim.new("LocalScript", parent=sps, Name=f"TestClient{i}", Source=src)
    sim.start()
    return sim


def client_of(player):
    return player.extra["ctx"]


def render(sim, player, path, debug=True):
    return rbx_render.render_client(sim, client_of(player), path, debug=debug)


def run_client_lua(sim, player, src, max_steps=600, dt=1 / 60):
    """Runs a Lua snippet in the player's client context; returns its results."""
    import luau_interp as LI
    ctx = client_of(player)
    env = sim.script_env(None, ctx)
    fn = LI.load(src, f"qa_snippet_{abs(hash(src)) % 100000}", env)
    th = LI.LuaThread(fn, context=ctx)
    result = {}
    r = LI.thread_resume(th, ())
    if not r[0]:
        raise RuntimeError(f"client snippet error: {r[1]}")
    steps = 0
    while th.status != "dead" and steps < max_steps:
        sim.step(dt)
        steps += 1
    if th.status != "dead":
        raise RuntimeError("client snippet did not finish")
    # results captured via shared table
    return ctx.shared


def lua_table_to_py(t):
    import luau_interp as LI
    if isinstance(t, LI.LuaTable):
        if t.arr and not t.hash:
            return [lua_table_to_py(v) for v in t.arr]
        d = {}
        for k, v in t.items():
            d[k] = lua_table_to_py(v)
        return d
    return t

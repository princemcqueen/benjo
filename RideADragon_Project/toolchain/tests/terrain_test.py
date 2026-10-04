"""Checks the Luau TerrainWriter against the Python reference (sampling) and
writes one chunk through the simulated WriteVoxels API."""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worldgen"))
import build_place  # noqa: E402
import luau_interp as LI  # noqa: E402
from rbx_sim import Sim  # noqa: E402
from sim_runner import PROJECT  # noqa: E402
import haven as HV  # noqa: E402
from terrain_data import Reference  # noqa: E402

PTS = [(0, 0), (12.5, -7.25), (335 * 0.38, -335 * 0.92), (450, -20), (430, -760), (150, 742), (-905, 300),
       (-500, -540), (706, -600), (1000, 1000), (-1150, 1140), (470.3, 160.7), (196, 790), (-3.9, 41.1)]

SRC = r'''
local SSS = game:GetService("ServerScriptService")
local TW = require(SSS.World.TerrainWriter)
local data = require(SSS.World.HavenTerrainData)
local t0 = os.clock()
local map = TW.load(data)
local out = {}
for i, p in PTS do
	local h, m, w = TW.sample(map, p[1], p[2])
	out[i] = { h, m, w }
end
local region, mats, occ, liq, hasLiquid = TW.buildChunk(map, 384, -128, 128)
workspace.Terrain:WriteVoxels(region, 4, mats, occ)
shared.RESULT = { out = out, ymin = region.CFrame.Position.Y - region.Size.Y / 2, ny = #mats[1], liquid = hasLiquid, t = os.clock() - t0 }
'''


def main():
    sim = Sim(instant_tweens=True)
    name, tree = build_place.load_project(PROJECT)
    build_place.load_into_sim(sim, tree)
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    pts = "{" + ",".join(f"{{{x},{z}}}" for x, z in PTS) + "}"
    t = time.time()
    fn = LI.load(SRC.replace("PTS", pts), "terrain_test", env)
    sim.in_ctx(ctx, fn)
    print(f"luau run {time.time() - t:.1f}s; errors {sim.errors[:3]}")
    from sim_runner import lua_table_to_py
    res = lua_table_to_py(ctx.shared.get("RESULT"))
    hv = HV.Haven().build()
    ref = Reference(hv)
    X = np.array([p[0] for p in PTS], float)
    Z = np.array([p[1] for p in PTS], float)
    h, m, w = ref.sample(X, Z)
    worst = 0
    for i, p in enumerate(PTS):
        lh, lm, lw = res["out"][i]
        dh = abs(lh - h[i])
        worst = max(worst, dh, abs(lw - w[i]))
        flag = "" if dh < 1e-6 and int(lm) - 1 == int(m[i]) and abs(lw - w[i]) < 1e-6 else "  <-- MISMATCH"
        print(f"  {str(p):22s} luau h={lh:8.3f} m={int(lm) - 1:2d} w={lw:7.3f} | py h={h[i]:8.3f} m={int(m[i]):2d} w={w[i]:7.3f}{flag}")
    print("max abs diff", worst, " chunk ymin", res["ymin"], "ny", res["ny"], "liquid", res["liquid"])
    st = getattr(sim, "terrain_store", None)
    print("terrain ops:", len(st.ops) if st else 0)
    return sim, res


if __name__ == "__main__":
    sim, env = main()

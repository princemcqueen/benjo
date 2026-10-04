"""One-shot offline world build: terrain (with building pads) + layout ->
Luau data modules, plus the simulator cache."""
import os
import pickle
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import layout as LY  # noqa: E402
import terrain_data as TD  # noqa: E402

SRC = paths.WORLD_SRC

if __name__ == "__main__":
    t = time.time()
    hv, lay = LY.build_all()
    n1 = TD.write_luau(hv, os.path.join(SRC, "HavenTerrainData.luau"))
    n2 = LY.write_luau(lay, os.path.join(SRC, "HavenLayout.luau"))
    with open(paths.out("haven_layout.pkl"), "wb") as f:
        pickle.dump((hv, lay), f)
    print(f"terrain {n1 // 1024} KB, layout {n2 // 1024} KB, buildings {len(lay.buildings)}, trees {len(lay.trees)}, "
          f"rocks {len(lay.rocks)}, eggs {len(lay.eggs)} in {time.time() - t:.1f}s")

"""Quick pose views of the skinned mesh dragon (idle = folded wings, or a
forced state) from several angles."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "meshgen"))
import build_place  # noqa: E402
import rbx_physics  # noqa: E402
import preview3d  # noqa: E402
from rbx_sim import Sim  # noqa: E402
from sim_runner import PROJECT, run_client_lua  # noqa: E402
import skin_render  # noqa: E402
import paths  # noqa: E402
import mesh_test as MT  # noqa: E402

from paths import OUT  # noqa: E402


def main(state=None, views=((-26, 9, -20), (26, 6, 4), (0, 24, 14), (-14, 3, 22)), tag="pose"):
    sim = Sim(instant_tweens=True, signal_behavior="Deferred")
    name, tree = build_place.load_project(PROJECT)
    build_place.load_into_sim(sim, tree)
    import sim_runner as _SR
    sys.path.insert(0, os.path.join(paths.TOOLCHAIN, "worldgen"))
    import terrain_data as _TD
    _TD.inject_into_sim(sim, _SR._haven_cache())
    skin_render.make_template(sim, "GreenDrake", parent=sim.services["Workspace"])
    sim.start()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(3, 1 / 60)
    if state:
        run_client_lua(sim, player, f'''
local AC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.AnimationController)
local m = workspace.Dragons:FindFirstChild("Dragon_1001")
local e = AC.get(m)
e.Anim.Paused = false
e.Anim:Snap("{state}")
e.ForceState = "{state}"
''')
        sim.run_for(0.05, 1 / 60)
    paths = []
    for i, off in enumerate(views):
        paths.append(MT.render(sim, player, f"{OUT}/{tag}_{i}.png", cam_offset=off, size=(800, 520)))
    preview3d.contact_sheet(paths, [str(v) for v in views], f"{OUT}/{tag}_sheet.png", cols=2)
    print("errors", len(sim.errors), sim.errors[:3])


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)

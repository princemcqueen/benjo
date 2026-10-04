"""Renders the Race & Battle Island (overview, start grid, plaza, arena, podium, a gate) from the
simulator for visual QA.

    python3 toolchain/tests/race_view.py [prefix]       -> <prefix>_{0..5}.png and a sheet
"""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import preview3d  # noqa: E402
from sim_runner import boot  # noqa: E402
from paths import OUT  # noqa: E402

CENTER = (640, 340, -560)


def at(x, y, z):
    return [CENTER[0] + x, CENTER[1] + y, CENTER[2] + z]


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else f"{OUT}/race_view"
    sim = boot()
    sim.add_player("Viewer", 1001)
    sim.run_for(8, 1 / 30)
    ws = sim.services["Workspace"]
    island = ws.find_child("World").find_child("RaceIsland")
    parts = preview3d.part_records(sim, root=island)
    print("island parts:", len(parts))
    gate3 = at(70, 74, -520)
    views = [
        ("island from the south", at(0, 10, -40), 360, 20, 26),
        ("start grid and arch (from behind the pads)", at(0, 16, -90), 170, 8, 14),
        ("plaza, join pad and boards", at(0, 8, 14), 150, 10, 16),
        ("duel arena", at(0, 8, 98), 140, 160, 24),
        ("arena with the training dummy", at(0, 10, 98), 70, 200, 30),
        ("podium", at(-124, 10, 20), 80, 330, 14),
        ("a ring gate and a boost ring", at(70, 70, -500), 150, 90, 8),
    ]
    jobs, paths, labels = [], [], []
    for i, (label, target, dist, yaw, pitch) in enumerate(views):
        tgt = target
        cam = preview3d.orbit_camera(tgt, dist, yaw, pitch, fov=55)
        sc = preview3d.make_scene(parts, cam, terrain=None, fog_density=0.0002, shadow_center=tgt, shadow_extent=max(80, dist))
        path = f"{prefix}_{i}.png"
        jobs.append((sc, path, 960, 600))
        paths.append(path)
        labels.append(label)
    _ = gate3, math
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{prefix}_sheet.png", cols=2)
    print("rendered", paths, "errors:", len(sim.errors), sim.errors[:2])


if __name__ == "__main__":
    main()

"""Renders the four sky islands (a wide view and a close view of each) for visual QA.

    python3 toolchain/tests/island_view.py [prefix]       -> <prefix>_{0..7}.png and a sheet
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import preview3d  # noqa: E402
from sim_runner import boot  # noqa: E402
from paths import OUT  # noqa: E402

ISLANDS = [
    ("CrystalIsle", (-430, 330, 560), 64),
    ("BloomIsle", (380, 290, 330), 60),
    ("EmberIsle", (-780, 380, -330), 66),
    ("FrostIsle", (60, 430, -880), 62),
]


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else f"{OUT}/island_view"
    sim = boot()
    sim.add_player("Viewer", 1001)
    sim.run_for(12, 1 / 30)
    ws = sim.services["Workspace"]
    folder = ws.find_child("World").find_child("SkyIslands")
    print("islands built:", len(folder.children) if folder else 0)
    jobs, paths, labels = [], [], []
    i = 0
    for name, c, r in ISLANDS:
        model = folder.find_child(name) if folder else None
        if model is None:
            print("missing", name)
            continue
        parts = preview3d.part_records(sim, root=model)
        print(name, "parts:", len(parts))
        for label, tgt, dist, yaw, pitch in (
            ("wide", [c[0], c[1] + 6, c[2]], 215, 200, 17),
            ("close", [c[0], c[1] + 8, c[2]], 120, 150, 30),
        ):
            cam = preview3d.orbit_camera(tgt, dist, yaw, pitch, fov=55)
            sc = preview3d.make_scene(parts, cam, terrain=None, fog_density=0.0002, shadow_center=tgt, shadow_extent=max(100, dist))
            path = f"{prefix}_{i}.png"
            jobs.append((sc, path, 960, 600))
            paths.append(path)
            labels.append(f"{name} {label}")
            i += 1
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, labels, f"{prefix}_sheet.png", cols=2)
    print("rendered", len(paths), "errors:", len(sim.errors), sim.errors[:2])


if __name__ == "__main__":
    main()

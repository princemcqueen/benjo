"""3D previews of the generated Haven terrain."""
import os
import sys
import math

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import preview3d  # noqa: E402
from haven import Haven  # noqa: E402

VIEWS = {
    "overview_from_south": ([0, 60, 0], 1500, 0, 30),
    "overview_from_west": ([0, 60, 0], 1500, 270, 26),
    "hub_looking_north": ([0, 60, -260], 380, 0, 10),
    "falls_from_south": ([424, 100, -780], 320, 10, 8),
    "lake_from_north": ([150, 40, 742], 460, 180, 16),
    "pillar_from_east": ([-905, 160, 300], 520, 90, 10),
}


def render(hv, names=None, out="/tmp/claude-0/out/haven_views.png", size=(800, 480), extra_parts=None):
    terrain = hv.preview_terrain()
    jobs, paths = [], []
    for name in (names or VIEWS.keys()):
        target, dist, yaw, pitch = VIEWS[name]
        cam = preview3d.orbit_camera(target, dist, yaw, pitch, fov=55)
        sc = preview3d.make_scene(extra_parts or [], cam, terrain=terrain, fog_density=0.00035,
                                  shadow_center=target, shadow_extent=900)
        p = f"/tmp/claude-0/out/haven_{name}.png"
        jobs.append((sc, p, size[0], size[1]))
        paths.append(p)
    preview3d.render_batch(jobs)
    preview3d.contact_sheet(paths, list(names or VIEWS.keys()), out, cols=2)
    return out


if __name__ == "__main__":
    hv = Haven().build()
    print(render(hv))

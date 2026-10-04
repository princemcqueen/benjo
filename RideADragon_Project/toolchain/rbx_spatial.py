"""Uniform grid over anchored, queryable parts for fast raycasts."""
import math
from rbx_types import Vector3

CELL = 32.0


def _aabb(sim, p):
    from rbx_api import part_cframe
    cf = part_cframe(sim, p)
    s = p.get_prop("Size")
    r = cf.r
    hx, hy, hz = s.x / 2, s.y / 2, s.z / 2
    ex = abs(r[0]) * hx + abs(r[1]) * hy + abs(r[2]) * hz
    ey = abs(r[3]) * hx + abs(r[4]) * hy + abs(r[5]) * hz
    ez = abs(r[6]) * hx + abs(r[7]) * hy + abs(r[8]) * hz
    c = cf.p
    return (c[0] - ex, c[1] - ey, c[2] - ez, c[0] + ex, c[1] + ey, c[2] + ez)


def rebuild(sim):
    from rbx_api import all_parts
    grid = {}
    dynamic = []
    big = []
    for p in all_parts(sim):
        if not p.props.get("CanQuery", True):
            continue
        if not p.props.get("Anchored"):
            dynamic.append(p)
            continue
        a = _aabb(sim, p)
        x0, y0, z0 = int(math.floor(a[0] / CELL)), int(math.floor(a[1] / CELL)), int(math.floor(a[2] / CELL))
        x1, y1, z1 = int(math.floor(a[3] / CELL)), int(math.floor(a[4] / CELL)), int(math.floor(a[5] / CELL))
        if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 4000:
            big.append(p)
            continue
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                for z in range(z0, z1 + 1):
                    grid.setdefault((x, y, z), []).append(p)
    sim.spatial = (grid, dynamic, big)
    sim.spatial_dirty = False


def candidates(sim, origin, d, length, radius):
    if sim.spatial_dirty or getattr(sim, "spatial", None) is None:
        rebuild(sim)
    grid, dynamic, big = sim.spatial
    seen = set()
    out = []
    for p in dynamic:
        if p.parent is not None:
            out.append(p)
    for p in big:
        out.append(p)
    pad = radius + 1.0
    steps = int(length / (CELL * 0.5)) + 2
    for i in range(steps + 1):
        t = min(length, i * CELL * 0.5)
        pt = (origin.x + d.x * t, origin.y + d.y * t, origin.z + d.z * t)
        cx, cy, cz = int(math.floor(pt[0] / CELL)), int(math.floor(pt[1] / CELL)), int(math.floor(pt[2] / CELL))
        rr = 1 if pad < CELL else int(pad / CELL) + 1
        for x in range(cx - rr, cx + rr + 1):
            for y in range(cy - rr, cy + rr + 1):
                for z in range(cz - rr, cz + rr + 1):
                    lst = grid.get((x, y, z))
                    if lst:
                        for p in lst:
                            if p.uid not in seen:
                                seen.add(p.uid)
                                out.append(p)
    return out
